package httpapi

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/burakoner/go-ledger-service/internal/service"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const healthTimeout = 2 * time.Second

// LedgerAPI handles runtime ledger HTTP endpoints.
type LedgerAPI struct {
	db                *sql.DB
	tenantAuthService service.TenantAuthService
	ledgerQuery       service.LedgerQueryService
	transactionQuery  service.TransactionQueryService
}

// NewLedgerAPI builds a new ledger API handler set.
func NewLedgerAPI(
	db *sql.DB,
	tenantAuthService service.TenantAuthService,
	ledgerQuery service.LedgerQueryService,
	transactionQuery service.TransactionQueryService,
) *LedgerAPI {
	return &LedgerAPI{
		db:                db,
		tenantAuthService: tenantAuthService,
		ledgerQuery:       ledgerQuery,
		transactionQuery:  transactionQuery,
	}
}

// NewMux builds the HTTP router for ledger-api endpoints.
func (a *LedgerAPI) NewMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.withRequestID(a.handleHealth))
	mux.HandleFunc("/api/v1/health", a.withRequestID(a.handleHealth))
	mux.HandleFunc("/api/v1/transactions", a.withRequestID(a.withTenantAuth(a.handleTransactions)))
	mux.HandleFunc("/api/v1/transactions/", a.withRequestID(a.withTenantAuth(a.handleTransactionByID)))
	mux.HandleFunc("/api/v1/balance", a.withRequestID(a.withTenantAuth(a.handleBalance)))
	mux.HandleFunc("/api/v1/ledger", a.withRequestID(a.withTenantAuth(a.handleLedger)))
	return mux
}

// withRequestID ensures each request has a request ID in context and response header.
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

// handleHealth checks process and database availability.
func (a *LedgerAPI) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/health" && r.URL.Path != "/api/v1/health" {
		writeAPIError(w, r, http.StatusNotFound, "NOT_FOUND", "route not found")
		return
	}
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

// withTenantAuth validates X-API-Key and injects tenant metadata into request context.
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

// handleTransactions routes list/create behavior on /api/v1/transactions.
func (a *LedgerAPI) handleTransactions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		a.handleTransactionsList(w, r)
		return
	case http.MethodPost:
		a.handleTransactionsPlaceholder(w, r)
		return
	default:
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET and POST are allowed")
		return
	}
}

// handleTransactionsPlaceholder keeps POST behavior as placeholder until async flow is implemented.
func (a *LedgerAPI) handleTransactionsPlaceholder(w http.ResponseWriter, r *http.Request) {
	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	writeJSON(w, http.StatusNotImplemented, map[string]string{
		"message":   "transactions endpoint will be implemented in next step",
		"tenant_id": tenantValue.TenantID,
	})
}

// handleTransactionsList returns transaction list with optional status filter and pagination.
func (a *LedgerAPI) handleTransactionsList(w http.ResponseWriter, r *http.Request) {
	if a.transactionQuery == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "transaction query service is not configured")
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

	transactions, normalizedStatus, normalizedLimit, normalizedOffset, err := a.transactionQuery.ListTransactions(
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

// handleTransactionByID returns one transaction by path parameter.
func (a *LedgerAPI) handleTransactionByID(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.transactionQuery == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "transaction query service is not configured")
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

	transactionResult, err := a.transactionQuery.GetTransactionByID(r.Context(), tenantValue, transactionID)
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

// handleBalance returns current balance for authenticated tenant.
func (a *LedgerAPI) handleBalance(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.ledgerQuery == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "ledger query service is not configured")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, r, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	balance, err := a.ledgerQuery.GetBalance(r.Context(), tenantValue)
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

// handleLedger returns ledger entries for authenticated tenant.
func (a *LedgerAPI) handleLedger(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.ledgerQuery == nil {
		writeAPIError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "ledger query service is not configured")
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

	entries, normalizedLimit, normalizedOffset, err := a.ledgerQuery.ListLedgerEntries(r.Context(), tenantValue, limit, offset)
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

// parsePaginationQuery parses optional limit and offset query params.
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

// parseOptionalIntQueryParam parses one optional integer query parameter.
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

// parseTransactionIDFromPath extracts transaction ID from /api/v1/transactions/:id path.
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
