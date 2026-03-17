package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

const (
	defaultTenantSchemaMigrationPath = "migrations/0002_init_tenant_schema.sql"
	tenantSchemaPlaceholder          = "__TENANT_SCHEMA__"
	apiKeyAlphabet                   = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
)

var tenantSchemaPattern = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

type registerTenantRequest struct {
	TenantCode string                 `json:"tenant_code"`
	Name       string                 `json:"name"`
	Currency   string                 `json:"currency"`
	Configs    map[string]interface{} `json:"configs"`
}

type registerTenantResponse struct {
	TenantID     string `json:"id"`
	TenantSchema string `json:"schema"`
	APIKeyID     string `json:"api_key_id"`
	APIKey       string `json:"api_key"`
}

type errorResponse struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

type tenantAdminAPI struct {
	db                    *sql.DB
	tenantSchemaMigration string
	adminKey              string
}

// main starts the ledger-admin API process.
func main() {
	// Get service port
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}

	// Get database connection URL
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	// Get tenant schema migration SQL file path
	tenantSchemaMigrationPath := os.Getenv("TENANT_SCHEMA_MIGRATION_PATH")
	if tenantSchemaMigrationPath == "" {
		tenantSchemaMigrationPath = defaultTenantSchemaMigrationPath
	}

	// Get tenant admin API key for authentication
	adminKey := os.Getenv("TENANT_ADMIN_KEY")
	if adminKey == "" {
		log.Fatal("TENANT_ADMIN_KEY is required")
	}

	// Load tenant schema SQL template from migrations.
	tenantSchemaMigration, err := loadTenantSchemaMigrationSQL(tenantSchemaMigrationPath)
	if err != nil {
		log.Fatalf("failed to load tenant migration SQL: %v", err)
	}

	// PostgreSQL connection pool.
	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		log.Fatalf("failed to open database connection: %v", err)
	}
	defer func() {
		if closeErr := db.Close(); closeErr != nil {
			log.Printf("failed to close database connection: %v", closeErr)
		}
	}()

	// Verify DB connectivity
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		log.Fatalf("failed to ping database: %v", err)
	}

	api := &tenantAdminAPI{
		db:                    db,
		tenantSchemaMigration: tenantSchemaMigration,
		adminKey:              adminKey,
	}

	// Configure HTTP routes.
	mux := http.NewServeMux()
	mux.HandleFunc("/", api.handleRoot)
	mux.HandleFunc("/api/v1/health", api.handleHealth)
	mux.HandleFunc("/api/v1/tenants/register", api.handleRegisterTenant)

	addr := ":" + port
	log.Printf("Tenant Admin API is starting on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Tenant Admin API stopped: %v", err)
	}
}

// loadTenantSchemaMigrationSQL reads the SQL template used for tenant schema creation.
func loadTenantSchemaMigrationSQL(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read migration file %q: %w", path, err)
	}

	sqlText := strings.TrimSpace(string(content))
	if sqlText == "" {
		return "", errors.New("tenant schema migration SQL file is empty")
	}
	if !strings.Contains(sqlText, tenantSchemaPlaceholder) {
		return "", fmt.Errorf("tenant schema placeholder %q is missing", tenantSchemaPlaceholder)
	}

	return sqlText, nil
}

// handleRoot returns a plain text readiness message.
func (a *tenantAdminAPI) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}

	writeText(w, http.StatusOK, "Ready")
}

// handleHealth checks service and database availability.
func (a *tenantAdminAPI) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only GET is allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	if err := a.db.PingContext(ctx); err != nil {
		writeAPIError(w, http.StatusServiceUnavailable, "DB_UNAVAILABLE", "database is unreachable")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"service": "ledger-admin-api",
		"status":  "HEALTHY",
	})
}

// handleRegisterTenant registers a tenant and creates the first API key.
func (a *tenantAdminAPI) handleRegisterTenant(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only POST is allowed")
		return
	}
	if !a.isAdminAuthorized(r) {
		writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "invalid or missing X-Admin-Key")
		return
	}

	var req registerTenantRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}

	if err := validateRegisterTenantRequest(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
		return
	}

	resp, err := a.registerTenant(r.Context(), req)
	if err != nil {
		if isUniqueViolation(err) {
			writeAPIError(w, http.StatusConflict, "TENANT_EXISTS", "tenant_code already exists")
			return
		}
		log.Printf("register tenant failed: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to register tenant")
		return
	}

	writeJSON(w, http.StatusCreated, resp)
}

// isAdminAuthorized validates the admin key provided in request headers.
func (a *tenantAdminAPI) isAdminAuthorized(r *http.Request) bool {
	return r.Header.Get("X-Admin-Key") == a.adminKey
}

// registerTenant creates tenant metadata, tenant schema/tables, and first API key atomically.
func (a *tenantAdminAPI) registerTenant(ctx context.Context, req registerTenantRequest) (registerTenantResponse, error) {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return registerTenantResponse{}, fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	// Create a tenant UUID in DB and derive a safe schema name from it.
	var tenantID string
	if err := tx.QueryRowContext(ctx, "SELECT gen_random_uuid()::text").Scan(&tenantID); err != nil {
		return registerTenantResponse{}, fmt.Errorf("generate tenant id: %w", err)
	}

	tenantSchema := makeTenantSchemaName(tenantID)
	if !isValidSchemaName(tenantSchema) {
		return registerTenantResponse{}, fmt.Errorf("invalid schema name generated: %s", tenantSchema)
	}

	// Insert tenant account metadata.
	const insertTenantSQL = `
		INSERT INTO public.tenant_accounts (id, code, name, currency, status, schema)
		VALUES ($1, $2, $3, $4, 'active', $5)
	`
	if _, err := tx.ExecContext(ctx, insertTenantSQL, tenantID, req.TenantCode, req.Name, req.Currency, tenantSchema); err != nil {
		return registerTenantResponse{}, fmt.Errorf("insert tenant account: %w", err)
	}

	// Create tenant schema and tenant-local tables from migration SQL file.
	if err := applyTenantSchemaMigration(ctx, tx, tenantSchema, a.tenantSchemaMigration); err != nil {
		return registerTenantResponse{}, fmt.Errorf("apply tenant schema migration: %w", err)
	}

	// Store optional tenant config values.
	if err := upsertTenantConfigs(ctx, tx, tenantID, req.Configs); err != nil {
		return registerTenantResponse{}, fmt.Errorf("upsert tenant configs: %w", err)
	}

	// Create the initial API key and store only its hash.
	apiKeyID, plainAPIKey, err := insertTenantAPIKey(ctx, tx, tenantID)
	if err != nil {
		return registerTenantResponse{}, fmt.Errorf("insert first api key: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return registerTenantResponse{}, fmt.Errorf("commit tx: %w", err)
	}

	return registerTenantResponse{
		TenantID:     tenantID,
		TenantSchema: tenantSchema,
		APIKeyID:     apiKeyID,
		APIKey:       plainAPIKey,
	}, nil
}

// applyTenantSchemaMigration runs the tenant schema migration template for one tenant schema.
func applyTenantSchemaMigration(ctx context.Context, tx *sql.Tx, tenantSchema, migrationTemplate string) error {
	if strings.TrimSpace(migrationTemplate) == "" {
		return errors.New("tenant migration template is empty")
	}
	if !isValidSchemaName(tenantSchema) {
		return fmt.Errorf("invalid tenant schema name: %s", tenantSchema)
	}

	// Replace placeholder with validated schema identifier before execution.
	migrationSQL := strings.ReplaceAll(migrationTemplate, tenantSchemaPlaceholder, tenantSchema)
	if _, err := tx.ExecContext(ctx, migrationSQL); err != nil {
		return fmt.Errorf("execute tenant schema migration SQL: %w", err)
	}

	return nil
}

// upsertTenantConfigs stores provided config values for the given tenant.
func upsertTenantConfigs(ctx context.Context, tx *sql.Tx, tenantID string, configs map[string]interface{}) error {
	if len(configs) == 0 {
		return nil
	}

	const upsertConfigSQL = `
		INSERT INTO public.tenant_configs (tenant_id, key, value, updated_at)
		VALUES ($1, $2, $3::jsonb, now())
		ON CONFLICT (tenant_id, key)
		DO UPDATE SET value = EXCLUDED.value, updated_at = now()
	`

	for key, value := range configs {
		rawValue, err := json.Marshal(value)
		if err != nil {
			return fmt.Errorf("marshal config %q: %w", key, err)
		}

		if _, err := tx.ExecContext(ctx, upsertConfigSQL, tenantID, key, string(rawValue)); err != nil {
			return fmt.Errorf("upsert config %q: %w", key, err)
		}
	}

	return nil
}

// insertTenantAPIKey creates a new API key row and returns its public and secret parts.
func insertTenantAPIKey(ctx context.Context, tx *sql.Tx, tenantID string) (string, string, error) {
	plainAPIKey, err := generatePlainAPIKey()
	if err != nil {
		return "", "", fmt.Errorf("generate plain api key: %w", err)
	}
	hashedAPIKey := hashAPIKey(plainAPIKey)

	const insertAPIKeySQL = `
		INSERT INTO public.tenant_api_keys (tenant_id, api_key_hash, status)
		VALUES ($1, $2, 'active')
		RETURNING id::text
	`

	var apiKeyID string
	if err := tx.QueryRowContext(ctx, insertAPIKeySQL, tenantID, hashedAPIKey).Scan(&apiKeyID); err != nil {
		return "", "", fmt.Errorf("insert tenant api key row: %w", err)
	}

	return apiKeyID, plainAPIKey, nil
}

// validateRegisterTenantRequest validates tenant registration payload fields.
func validateRegisterTenantRequest(req *registerTenantRequest) error {
	req.TenantCode = strings.TrimSpace(req.TenantCode)
	req.Name = strings.TrimSpace(req.Name)
	req.Currency = strings.TrimSpace(strings.ToUpper(req.Currency))

	if req.TenantCode == "" {
		return errors.New("tenant_code is required")
	}
	if req.Name == "" {
		return errors.New("name is required")
	}

	switch req.Currency {
	case "GBP", "EUR", "USD", "TRY":
		return nil
	default:
		return errors.New("currency must be one of GBP, EUR, USD, TRY")
	}
}

// decodeJSONBody decodes JSON request body and rejects unknown fields.
func decodeJSONBody(r *http.Request, dst interface{}) error {
	defer func() {
		_ = r.Body.Close()
	}()

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}

	return nil
}

// writeJSON serializes payload as JSON with proper headers and status.
func writeJSON(w http.ResponseWriter, statusCode int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode json response: %v", err)
	}
}

// writeText writes a plain text response with the given status code.
func writeText(w http.ResponseWriter, statusCode int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(statusCode)
	if _, err := w.Write([]byte(text)); err != nil {
		log.Printf("failed to write text response: %v", err)
	}
}

// writeAPIError writes a standardized error response body.
func writeAPIError(w http.ResponseWriter, statusCode int, code, message string) {
	resp := errorResponse{}
	resp.Error.Code = code
	resp.Error.Message = message
	writeJSON(w, statusCode, resp)
}

// generatePlainAPIKey creates a random API key value shown only once to caller.
func generatePlainAPIKey() (string, error) {
	randomPart, err := generateRandomString(48)
	if err != nil {
		return "", fmt.Errorf("generate random api key part: %w", err)
	}
	return "TK_" + randomPart, nil
}

// generateRandomString generates a cryptographically secure random string using a-zA-Z0-9 characters.
func generateRandomString(length int) (string, error) {
	if length <= 0 {
		return "", errors.New("length must be greater than 0")
	}

	result := make([]byte, length)
	max := big.NewInt(int64(len(apiKeyAlphabet)))

	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", fmt.Errorf("generate random index: %w", err)
		}
		result[i] = apiKeyAlphabet[n.Int64()]
	}

	return string(result), nil
}

// hashAPIKey creates a deterministic SHA-256 hash used for secure DB storage.
func hashAPIKey(plainAPIKey string) string {
	sum := sha256.Sum256([]byte(plainAPIKey))
	return hex.EncodeToString(sum[:])
}

// makeTenantSchemaName creates a deterministic tenant schema name from tenant UUID.
func makeTenantSchemaName(tenantID string) string {
	return "tenant_" + strings.ReplaceAll(strings.ToLower(tenantID), "-", "")
}

// isValidSchemaName validates schema identifier format before dynamic SQL usage.
func isValidSchemaName(schemaName string) bool {
	return tenantSchemaPattern.MatchString(schemaName)
}

// isUniqueViolation checks PostgreSQL unique-violation SQLSTATE in an error string.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "(23505)")
}
