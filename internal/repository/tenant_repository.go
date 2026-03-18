package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const tenantLookupTimeout = 2 * time.Second

// TenantRepository defines tenant lookup persistence operations.
type TenantRepository interface {
	FindByAPIKeyHash(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error)
}

// PostgresTenantRepository reads tenant metadata from PostgreSQL.
type PostgresTenantRepository struct {
	db *sql.DB
}

// NewPostgresTenantRepository creates a PostgreSQL-backed tenant repository.
func NewPostgresTenantRepository(db *sql.DB) *PostgresTenantRepository {
	return &PostgresTenantRepository{db: db}
}

// FindByAPIKeyHash resolves tenant metadata using a hashed API key.
func (r *PostgresTenantRepository) FindByAPIKeyHash(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error) {
	if r == nil || r.db == nil {
		return tenant.ContextValue{}, errors.New("tenant repository is not initialized")
	}

	const query = `
		SELECT
			ta.id::text,
			ta.code,
			ta.schema,
			ta.currency,
			ta.status
		FROM public.tenant_api_keys AS tak
		INNER JOIN public.tenant_accounts AS ta
			ON ta.id = tak.tenant_id
		WHERE
			tak.api_key_hash = $1
			AND tak.status = 'active'
			AND (tak.expires_at IS NULL OR tak.expires_at > now())
		LIMIT 1
	`

	queryCtx, cancel := context.WithTimeout(ctx, tenantLookupTimeout)
	defer cancel()

	var tenantValue tenant.ContextValue
	err := r.db.QueryRowContext(queryCtx, query, apiKeyHash).Scan(
		&tenantValue.TenantID,
		&tenantValue.TenantCode,
		&tenantValue.TenantSchema,
		&tenantValue.Currency,
		&tenantValue.Status,
	)
	if err != nil {
		return tenant.ContextValue{}, fmt.Errorf("find tenant by api key hash: %w", err)
	}

	return tenantValue, nil
}
