package httpapi

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/burakoner/go-ledger-service/internal/idempotency"
	"github.com/burakoner/go-ledger-service/internal/service"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const (
	healthTimeout             = 2 * time.Second
	transactionIdempotencyTTL = 24 * time.Hour
	balanceDecimalDigits      = 2
)

type LedgerAPI struct {
	db                 *sql.DB
	tenantAuthService  service.TenantAuthService
	ledgerBalance      service.LedgerBalanceService
	ledgerEntry        service.LedgerEntryService
	transactionService service.LedgerTransactionService
	idempotencyStore   idempotency.ReferenceStore
}

func NewLedgerAPI(
	db *sql.DB,
	tenantAuthService service.TenantAuthService,
	ledgerBalance service.LedgerBalanceService,
	ledgerEntry service.LedgerEntryService,
	transactionService service.LedgerTransactionService,
	idempotencyStore idempotency.ReferenceStore,
) *LedgerAPI {
	return &LedgerAPI{
		db:                 db,
		tenantAuthService:  tenantAuthService,
		ledgerBalance:      ledgerBalance,
		ledgerEntry:        ledgerEntry,
		transactionService: transactionService,
		idempotencyStore:   idempotencyStore,
	}
}

func (a *LedgerAPI) NewMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.withRequestID(a.handleHealth))
	mux.HandleFunc("/api/v1/balance", a.withRequestID(a.withTenantAuth(a.handleBalance)))
	mux.HandleFunc("/api/v1/ledger", a.withRequestID(a.withTenantAuth(a.handleLedger)))
	mux.HandleFunc("/api/v1/transactions", a.withRequestID(a.withTenantAuth(a.handleTransactions)))
	mux.HandleFunc("/api/v1/transactions/", a.withRequestID(a.withTenantAuth(a.handleTransactionByID)))
	return mux
}

func (a *LedgerAPI) withRequestID(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		requestID := normalizeRequestID(r.Header.Get(requestIDHeaderName))
		if requestID == "" {
			requestID = generateRequestID()
		}

		w.Header().Set(requestIDHeaderName, requestID)
		ctx := withRequestIDContext(r.Context(), requestID)
		next(w, r.WithContext(ctx))
	}
}

func (a *LedgerAPI) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.db == nil {
		writeAPIError(w, r, http.StatusServiceUnavailable, "DB_UNAVAILABLE", "database is not configured")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
	defer cancel()
	if err := a.db.PingContext(ctx); err != nil {
		writeAPIError(w, r, http.StatusServiceUnavailable, "DB_UNAVAILABLE", "database is unreachable")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"service": "ledger-api",
		"status":  "HEALTHY",
	})
}

func (a *LedgerAPI) withTenantAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if a.tenantAuthService == nil {
			writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "tenant auth service is not configured")
			return
		}

		plainAPIKey := strings.TrimSpace(r.Header.Get("X-API-Key"))
		if plainAPIKey == "" {
			writeAPIError(w, r, http.StatusUnauthorized, "UNAUTHORIZED", "missing X-API-Key header")
			return
		}

		tenantValue, err := a.tenantAuthService.ResolveAuthorizedTenant(r.Context(), plainAPIKey)
		if err != nil {
			if errors.Is(err, service.ErrInvalidAPIKey) {
				writeAPIError(w, r, http.StatusUnauthorized, "UNAUTHORIZED", "invalid API key")
				return
			}
			if errors.Is(err, service.ErrTenantSuspended) {
				writeAPIError(w, r, http.StatusForbidden, "TENANT_SUSPENDED", "tenant is suspended")
				return
			}

			log.Printf("tenant resolution failed: %v", err)
			writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to resolve tenant")
			return
		}

		ctx := tenant.WithContext(r.Context(), tenantValue)
		next(w, r.WithContext(ctx))
	}
}

func (a *LedgerAPI) handleBalance(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.ledgerBalance == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "ledger balance service is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	balance, err := a.ledgerBalance.GetBalance(r.Context(), tenantValue)
	if err != nil {
		log.Printf("get balance failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch balance")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tenant_id":  tenantValue.TenantID,
		"currency":   tenantValue.Currency,
		"balance":    balance.AvailableBalance,
		"updated_at": balance.UpdatedAt,
	})
}

func (a *LedgerAPI) handleLedger(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.ledgerEntry == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "ledger entry service is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	limit, offset, err := parsePaginationQuery(r)
	if err != nil {
		writeAPIError(w, r, http.StatusBadRequest, "INVALID_PAGINATION", err.Error())
		return
	}

	entries, normalizedLimit, normalizedOffset, err := a.ledgerEntry.ListLedgerEntries(r.Context(), tenantValue, limit, offset)
	if err != nil {
		if errors.Is(err, service.ErrInvalidPagination) {
			writeAPIError(w, r, http.StatusBadRequest, "INVALID_PAGINATION", err.Error())
			return
		}

		log.Printf("list ledger entries failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch ledger entries")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tenant_id": tenantValue.TenantID,
		"limit":     normalizedLimit,
		"offset":    normalizedOffset,
		"entries":   entries,
	})
}

func (a *LedgerAPI) handleTransactions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		a.handleTransactionList(w, r)
		return
	case http.MethodPost:
		a.handleTransactionPlace(w, r)
		return
	default:
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET and POST are allowed")
		return
	}
}

func (a *LedgerAPI) handleTransactionList(w http.ResponseWriter, r *http.Request) {
	if a.transactionService == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "transaction service is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	statusFilter := strings.TrimSpace(r.URL.Query().Get("status"))
	limit, offset, err := parsePaginationQuery(r)
	if err != nil {
		writeAPIError(w, r, http.StatusBadRequest, "INVALID_QUERY", err.Error())
		return
	}

	transactions, normalizedStatus, normalizedLimit, normalizedOffset, err := a.transactionService.ListTransactions(
		r.Context(),
		tenantValue,
		statusFilter,
		limit,
		offset,
	)
	if err != nil {
		if errors.Is(err, service.ErrInvalidTransactionQuery) {
			writeAPIError(w, r, http.StatusBadRequest, "INVALID_QUERY", err.Error())
			return
		}

		log.Printf("list transactions failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch transactions")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tenant_id":     tenantValue.TenantID,
		"status_filter": normalizedStatus,
		"limit":         normalizedLimit,
		"offset":        normalizedOffset,
		"transactions":  transactions,
	})
}

func (a *LedgerAPI) handleTransactionPlace(w http.ResponseWriter, r *http.Request) {
	if a.transactionService == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "transaction service is not configured")
		return
	}
	if a.idempotencyStore == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "idempotency store is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	req, err := decodeCreateTransactionRequest(r)
	if err != nil {
		writeAPIError(w, r, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}

	beginState, err := a.idempotencyStore.Begin(
		r.Context(),
		tenantValue.TenantID,
		req.Reference,
		requestIDFromContext(r.Context()),
		transactionIdempotencyTTL,
	)
	if err != nil {
		log.Printf("idempotency begin failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to start idempotency control")
		return
	}

	if !beginState.Acquired {
		if beginState.CompletedResponse != nil {
			writeRawIdempotentResponse(
				w,
				beginState.CompletedResponse.StatusCode,
				beginState.CompletedResponse.Body,
				true,
			)
			return
		}

		if beginState.CompletedTransactionID != "" {
			existingByID, byIDErr := a.transactionService.GetTransactionByID(r.Context(), tenantValue, beginState.CompletedTransactionID)
			if byIDErr == nil {
				if markErr := a.cacheAcceptedTransactionResponse(
					r.Context(),
					tenantValue.TenantID,
					req.Reference,
					existingByID,
				); markErr != nil {
					log.Printf("idempotency mark completed failed: %v", markErr)
				}
				writeTransactionReplayResponse(w, tenantValue.TenantID, existingByID)
				return
			}
			log.Printf("idempotency cached transaction lookup failed: %v", byIDErr)
		}

		existingByReference, byReferenceErr := a.transactionService.GetTransactionByReference(r.Context(), tenantValue, req.Reference)
		if byReferenceErr == nil {
			if markErr := a.cacheAcceptedTransactionResponse(
				r.Context(),
				tenantValue.TenantID,
				req.Reference,
				existingByReference,
			); markErr != nil {
				log.Printf("idempotency mark completed failed: %v", markErr)
			}
			writeTransactionReplayResponse(w, tenantValue.TenantID, existingByReference)
			return
		}
		if !errors.Is(byReferenceErr, service.ErrTransactionNotFound) {
			log.Printf("idempotency fallback lookup failed: %v", byReferenceErr)
			writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to resolve idempotent request")
			return
		}

		writeAPIError(w, r, http.StatusConflict, "IDEMPOTENCY_IN_PROGRESS", "another request with same reference is in progress")
		return
	}

	result, err := a.transactionService.CreatePendingTransaction(r.Context(), tenantValue, service.CreatePendingTransactionInput{
		Reference:   req.Reference,
		Type:        req.Type,
		Amount:      req.Amount,
		Description: req.Description,
		Metadata:    req.Metadata,
	})
	if err != nil {
		if errors.Is(err, service.ErrTransactionReferenceAlreadyExists) {
			existingByReference, byReferenceErr := a.transactionService.GetTransactionByReference(r.Context(), tenantValue, req.Reference)
			if byReferenceErr == nil {
				if markErr := a.cacheAcceptedTransactionResponse(
					r.Context(),
					tenantValue.TenantID,
					req.Reference,
					existingByReference,
				); markErr != nil {
					log.Printf("idempotency mark completed failed after duplicate: %v", markErr)
				}
				writeTransactionReplayResponse(w, tenantValue.TenantID, existingByReference)
				return
			}
			log.Printf("reference duplicate fallback failed: %v", byReferenceErr)
		}

		if clearErr := a.idempotencyStore.Clear(r.Context(), tenantValue.TenantID, req.Reference); clearErr != nil {
			log.Printf("idempotency clear failed after create error: %v", clearErr)
		}

		if errors.Is(err, service.ErrInvalidTransactionInput) {
			writeAPIError(w, r, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
			return
		}

		log.Printf("create pending transaction failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create transaction")
		return
	}

	if markErr := a.cacheAcceptedTransactionResponse(
		r.Context(),
		tenantValue.TenantID,
		req.Reference,
		result,
	); markErr != nil {
		// Transaction is already stored in DB. We only log redis failure.
		log.Printf("idempotency mark completed failed: %v", markErr)
	}

	writeTransactionAcceptedResponse(w, tenantValue.TenantID, result)
}

func (a *LedgerAPI) handleTransactionByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.transactionService == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "transaction service is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	transactionID, err := parseTransactionIDFromPath(r.URL.Path)
	if err != nil {
		writeAPIError(w, r, http.StatusBadRequest, "INVALID_TRANSACTION_ID", err.Error())
		return
	}

	transactionResult, err := a.transactionService.GetTransactionByID(r.Context(), tenantValue, transactionID)
	if err != nil {
		if errors.Is(err, service.ErrInvalidTransactionQuery) {
			writeAPIError(w, r, http.StatusBadRequest, "INVALID_TRANSACTION_ID", err.Error())
			return
		}
		if errors.Is(err, service.ErrTransactionNotFound) {
			writeAPIError(w, r, http.StatusNotFound, "TRANSACTION_NOT_FOUND", "transaction not found")
			return
		}

		log.Printf("get transaction by id failed: %v", err)
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch transaction")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"tenant_id":   tenantValue.TenantID,
		"transaction": transactionResult,
	})
}

type transactionAcceptedResponse struct {
	TenantID    string                    `json:"tenant_id"`
	Transaction service.TransactionResult `json:"transaction"`
	QueueStatus string                    `json:"queue_status"`
}

func (a *LedgerAPI) cacheAcceptedTransactionResponse(
	ctx context.Context,
	tenantID,
	reference string,
	transaction service.TransactionResult,
) error {
	responseBody, err := encodeTransactionAcceptedResponse(tenantID, transaction)
	if err != nil {
		return err
	}

	return a.idempotencyStore.MarkCompleted(
		ctx,
		tenantID,
		reference,
		transaction.ID,
		idempotency.CachedResponse{
			StatusCode: http.StatusAccepted,
			Body:       responseBody,
		},
		transactionIdempotencyTTL,
	)
}

func writeTransactionAcceptedResponse(w http.ResponseWriter, tenantID string, transaction service.TransactionResult) {
	responseBody, err := encodeTransactionAcceptedResponse(tenantID, transaction)
	if err != nil {
		log.Printf("transaction response encode failed: %v", err)
		writeRawIdempotentResponse(w, http.StatusAccepted, []byte(`{}`), false)
		return
	}

	writeRawIdempotentResponse(w, http.StatusAccepted, responseBody, false)
}

func writeTransactionReplayResponse(w http.ResponseWriter, tenantID string, transaction service.TransactionResult) {
	responseBody, err := encodeTransactionAcceptedResponse(tenantID, transaction)
	if err != nil {
		log.Printf("transaction replay response encode failed: %v", err)
		writeRawIdempotentResponse(w, http.StatusAccepted, []byte(`{}`), true)
		return
	}

	writeRawIdempotentResponse(w, http.StatusAccepted, responseBody, true)
}

func encodeTransactionAcceptedResponse(tenantID string, transaction service.TransactionResult) ([]byte, error) {
	response := transactionAcceptedResponse{
		TenantID:    tenantID,
		Transaction: transaction,
		QueueStatus: "pending",
	}

	return json.Marshal(response)
}

func writeRawIdempotentResponse(w http.ResponseWriter, statusCode int, body []byte, replayed bool) {
	if replayed {
		w.Header().Set("Idempotency-Replayed", "true")
	} else {
		w.Header().Set("Idempotency-Replayed", "false")
	}

	if statusCode <= 0 {
		statusCode = http.StatusAccepted
	}
	if len(body) == 0 {
		body = []byte(`{}`)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if _, err := w.Write(body); err != nil {
		log.Printf("failed to write raw idempotent response: %v", err)
	}
}

func parsePaginationQuery(r *http.Request) (int, int, error) {
	limit, err := parseOptionalIntQueryParam(r, "limit")
	if err != nil {
		return 0, 0, err
	}
	offset, err := parseOptionalIntQueryParam(r, "offset")
	if err != nil {
		return 0, 0, err
	}
	return limit, offset, nil
}

func parseOptionalIntQueryParam(r *http.Request, name string) (int, error) {
	rawValue := strings.TrimSpace(r.URL.Query().Get(name))
	if rawValue == "" {
		return 0, nil
	}

	value, err := strconv.Atoi(rawValue)
	if err != nil {
		return 0, errors.New(name + " must be a valid integer")
	}
	return value, nil
}

func parseTransactionIDFromPath(path string) (string, error) {
	const prefix = "/api/v1/transactions/"
	if !strings.HasPrefix(path, prefix) {
		return "", errors.New("invalid transaction path")
	}

	transactionID := strings.TrimSpace(strings.TrimPrefix(path, prefix))
	if transactionID == "" {
		return "", errors.New("transaction id is required")
	}
	if strings.Contains(transactionID, "/") {
		return "", errors.New("transaction id is invalid")
	}

	return transactionID, nil
}

type createTransactionRequest struct {
	Reference   string          `json:"reference"`
	Type        string          `json:"type"`
	Amount      int64           `json:"amount"`
	Description string          `json:"description"`
	Metadata    json.RawMessage `json:"metadata"`
}

func decodeCreateTransactionRequest(r *http.Request) (createTransactionRequest, error) {
	defer func() {
		_ = r.Body.Close()
	}()

	var req createTransactionRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&req); err != nil {
		return createTransactionRequest{}, fmtJSONDecodeError(err)
	}

	var extra struct{}
	if err := decoder.Decode(&extra); err != io.EOF {
		return createTransactionRequest{}, errors.New("request body must contain only one JSON object")
	}

	return req, nil
}

func fmtJSONDecodeError(err error) error {
	if errors.Is(err, io.EOF) {
		return errors.New("request body is required")
	}
	return errors.New("invalid JSON body: " + err.Error())
}
