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
}

// NewLedgerAPI builds a new ledger API handler set.
func NewLedgerAPI(db *sql.DB, tenantAuthService service.TenantAuthService, ledgerQuery service.LedgerQueryService) *LedgerAPI {
	return &LedgerAPI{
		db:                db,
		tenantAuthService: tenantAuthService,
		ledgerQuery:       ledgerQuery,
	}
}

// NewMux builds the HTTP router for ledger-api endpoints.
func (a *LedgerAPI) NewMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.withRequestID(a.handleHealth))
	mux.HandleFunc("/api/v1/health", a.withRequestID(a.handleHealth))
	mux.HandleFunc("/api/v1/transactions", a.withRequestID(a.withTenantAuth(a.handleTransactionsPlaceholder)))
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

// handleTransactionsPlaceholder is a protected placeholder until transaction flow is implemented.
func (a *LedgerAPI) handleTransactionsPlaceholder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, r, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only POST is allowed")
		return
	}

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
