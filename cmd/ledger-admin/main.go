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
	"net/url"
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
	webhookEnabledConfigKey          = "webhook_enabled"
	webhookURLConfigKey              = "webhook_url"
)

var tenantSchemaPattern = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

type tenantRegisterRequest struct {
	TenantCode string         `json:"tenant_code"`
	Name       string         `json:"name"`
	Currency   string         `json:"currency"`
	Configs    map[string]any `json:"configs"`
}

type tenantRegisterResponse struct {
	TenantID     string `json:"id"`
	TenantSchema string `json:"schema"`
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

func main() {
	// Get service port
	port := os.Getenv("LEDGER_ADMIN_PORT")
	if port == "" {
		port = "8090"
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
	mux.HandleFunc("/health", api.handleHealth)
	mux.HandleFunc("/api/v1/tenants/register", api.handleRegisterTenant)

	addr := ":" + port
	log.Printf("Tenant Admin API is starting on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Tenant Admin API stopped: %v", err)
	}
}

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

func (a *tenantAdminAPI) isAuthorized(r *http.Request) bool {
	return r.Header.Get("X-Admin-Key") == a.adminKey
}

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

func (a *tenantAdminAPI) handleRegisterTenant(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "Only POST is allowed")
		return
	}
	if !a.isAuthorized(r) {
		writeAPIError(w, http.StatusUnauthorized, "UNAUTHORIZED", "invalid or missing X-Admin-Key")
		return
	}

	var req tenantRegisterRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "INVALID_REQUEST", err.Error())
		return
	}

	if err := validateTenantRegisterRequest(&req); err != nil {
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

func (a *tenantAdminAPI) registerTenant(ctx context.Context, req tenantRegisterRequest) (tenantRegisterResponse, error) {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	var tenantID string
	if err := tx.QueryRowContext(ctx, "SELECT gen_random_uuid()::text").Scan(&tenantID); err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("generate tenant id: %w", err)
	}

	tenantSchema := tenantSchemaName(tenantID)
	if !isValidSchemaName(tenantSchema) {
		return tenantRegisterResponse{}, fmt.Errorf("invalid schema name generated: %s", tenantSchema)
	}

	const insertTenantSQL = `
		INSERT INTO public.tenant_accounts (id, code, name, currency, status, schema)
		VALUES ($1, $2, $3, $4, 'active', $5)
	`
	if _, err := tx.ExecContext(ctx, insertTenantSQL, tenantID, req.TenantCode, req.Name, req.Currency, tenantSchema); err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("insert tenant account: %w", err)
	}

	if err := applyTenantSchemaMigration(ctx, tx, tenantSchema, a.tenantSchemaMigration); err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("apply tenant schema migration: %w", err)
	}

	if err := upsertTenantConfigs(ctx, tx, tenantID, req.Configs); err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("upsert tenant configs: %w", err)
	}

	_, plainAPIKey, err := insertTenantAPIKey(ctx, tx, tenantID)
	if err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("insert first api key: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return tenantRegisterResponse{}, fmt.Errorf("commit tx: %w", err)
	}

	return tenantRegisterResponse{
		TenantID:     tenantID,
		TenantSchema: tenantSchema,
		APIKey:       plainAPIKey,
	}, nil
}

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

func upsertTenantConfigs(ctx context.Context, tx *sql.Tx, tenantID string, configs map[string]any) error {
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

func validateTenantRegisterRequest(req *tenantRegisterRequest) error {
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
	default:
		return errors.New("currency must be one of GBP, EUR, USD, TRY")
	}

	normalizedConfigs, err := normalizeTenantConfigs(req.Configs)
	if err != nil {
		return err
	}
	req.Configs = normalizedConfigs

	return nil
}

func normalizeTenantConfigs(input map[string]any) (map[string]any, error) {
	configs := make(map[string]any, len(input)+2)
	for key, value := range input {
		configs[key] = value
	}

	webhookEnabled := false
	if raw, ok := configs[webhookEnabledConfigKey]; ok {
		value, err := parseBooleanConfig(raw, webhookEnabledConfigKey)
		if err != nil {
			return nil, err
		}
		webhookEnabled = value
	}

	webhookURL := ""
	if raw, ok := configs[webhookURLConfigKey]; ok {
		value, err := parseStringConfig(raw, webhookURLConfigKey)
		if err != nil {
			return nil, err
		}
		webhookURL = strings.TrimSpace(value)
	}

	if webhookEnabled && webhookURL == "" {
		return nil, errors.New("configs.webhook_url is required when configs.webhook_enabled is true")
	}
	if webhookURL != "" {
		if err := validateWebhookURL(webhookURL); err != nil {
			return nil, err
		}
	}

	configs[webhookEnabledConfigKey] = webhookEnabled
	configs[webhookURLConfigKey] = webhookURL

	return configs, nil
}

func parseBooleanConfig(raw any, fieldName string) (bool, error) {
	value, ok := raw.(bool)
	if !ok {
		return false, fmt.Errorf("configs.%s must be a boolean", fieldName)
	}
	return value, nil
}

func parseStringConfig(raw any, fieldName string) (string, error) {
	if raw == nil {
		return "", nil
	}
	value, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("configs.%s must be a string", fieldName)
	}
	return value, nil
}

func validateWebhookURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("configs.%s must be a valid URL", webhookURLConfigKey)
	}

	scheme := strings.ToLower(strings.TrimSpace(parsed.Scheme))
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("configs.%s must start with http:// or https://", webhookURLConfigKey)
	}
	if strings.TrimSpace(parsed.Host) == "" {
		return fmt.Errorf("configs.%s must include a host", webhookURLConfigKey)
	}

	return nil
}

func decodeJSONBody(r *http.Request, dst any) error {
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

func writeJSON(w http.ResponseWriter, statusCode int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode json response: %v", err)
	}
}

func writeAPIError(w http.ResponseWriter, statusCode int, code, message string) {
	resp := errorResponse{}
	resp.Error.Code = code
	resp.Error.Message = message
	writeJSON(w, statusCode, resp)
}

func generatePlainAPIKey() (string, error) {
	randomPart, err := generateRandomString(48)
	if err != nil {
		return "", fmt.Errorf("generate random api key part: %w", err)
	}
	return "TK_" + randomPart, nil
}

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

func hashAPIKey(plainAPIKey string) string {
	sum := sha256.Sum256([]byte(plainAPIKey))
	return hex.EncodeToString(sum[:])
}

func tenantSchemaName(tenantID string) string {
	return "tenant_" + strings.ReplaceAll(strings.ToLower(tenantID), "-", "")
}

func isValidSchemaName(schemaName string) bool {
	return tenantSchemaPattern.MatchString(schemaName)
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "(23505)")
}
