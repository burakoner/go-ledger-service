package httpapi

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
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
}

// NewLedgerAPI builds a new ledger API handler set.
func NewLedgerAPI(db *sql.DB, tenantAuthService service.TenantAuthService) *LedgerAPI {
	return &LedgerAPI{
		db:                db,
		tenantAuthService: tenantAuthService,
	}
}

// NewMux builds the HTTP router for ledger-api endpoints.
func (a *LedgerAPI) NewMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", a.handleRoot)
	mux.HandleFunc("/health", a.handleHealth)
	mux.HandleFunc("/api/v1/transactions", a.withTenantAuth(a.handleTransactionsPlaceholder))
	mux.HandleFunc("/api/v1/balance", a.withTenantAuth(a.handleBalancePlaceholder))
	mux.HandleFunc("/api/v1/ledger", a.withTenantAuth(a.handleLedgerPlaceholder))
	return mux
}

// handleRoot returns a simple service readiness text.
func (a *LedgerAPI) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	writeText(w, http.StatusOK, "Go Ledger Service API")
}

// handleHealth checks process and database availability.
func (a *LedgerAPI) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}
	if a.db == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "DB_UNAVAILABLE", "database is not configured")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), healthTimeout)
	defer cancel()
	if err := a.db.PingContext(ctx); err != nil {
		writeAPIError(w, http.StatusServiceUnavailable, "DB_UNAVAILABLE", "database is unreachable")
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
			writeAPIError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "tenant auth service is not configured")
			return
		}

		plainAPIKey := strings.TrimSpace(r.Header.Get("X-API-Key"))
		if plainAPIKey == "" {
			writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "missing X-API-Key header")
			return
		}

		tenantValue, err := a.tenantAuthService.ResolveAuthorizedTenant(r.Context(), plainAPIKey)
		if err != nil {
			if errors.Is(err, service.ErrInvalidAPIKey) {
				writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "invalid API key")
				return
			}
			if errors.Is(err, service.ErrTenantSuspended) {
				writeAPIError(w, http.StatusForbidden, "TENANT_SUSPENDED", "tenant is suspended")
				return
			}

			log.Printf("tenant resolution failed: %v", err)
			writeAPIError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to resolve tenant")
			return
		}

		ctx := tenant.WithContext(r.Context(), tenantValue)
		next(w, r.WithContext(ctx))
	}
}

// handleTransactionsPlaceholder is a protected placeholder until transaction flow is implemented.
func (a *LedgerAPI) handleTransactionsPlaceholder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only POST is allowed")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	writeJSON(w, http.StatusNotImplemented, map[string]string{
		"message":   "transactions endpoint will be implemented in next step",
		"tenant_id": tenantValue.TenantID,
	})
}

// handleBalancePlaceholder is a protected placeholder until balance query is implemented.
func (a *LedgerAPI) handleBalancePlaceholder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	writeJSON(w, http.StatusNotImplemented, map[string]string{
		"message":   "balance endpoint will be implemented in next step",
		"tenant_id": tenantValue.TenantID,
	})
}

// handleLedgerPlaceholder is a protected placeholder until ledger list is implemented.
func (a *LedgerAPI) handleLedgerPlaceholder(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}

	tenantValue, ok := tenant.FromContext(r.Context())
	if !ok {
		writeAPIError(w, http.StatusInternalServerError, "TENANT_CONTEXT_MISSING", "tenant context is missing")
		return
	}

	writeJSON(w, http.StatusNotImplemented, map[string]string{
		"message":   "ledger endpoint will be implemented in next step",
		"tenant_id": tenantValue.TenantID,
	})
}
