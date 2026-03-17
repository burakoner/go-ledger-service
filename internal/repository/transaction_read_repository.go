package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/burakoner/go-ledger-service/internal/tenant"
	"github.com/lib/pq"
)

const transactionReadTimeout = 2 * time.Second

// TransactionRow represents one tenant-local transaction row.
type TransactionRow struct {
	ID           string
	Reference    string
	Type         string
	Amount       int64
	Description  string
	Metadata     []byte
	Status       string
	FailureCode  *string
	FailureReason *string
	CreatedAt    time.Time
	UpdatedAt    time.Time
	ProcessedAt  *time.Time
}

// TransactionReadRepository defines read operations from tenant-local transactions table.
type TransactionReadRepository interface {
	GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error)
	ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error)
}

// PostgresTransactionReadRepository reads tenant-local transactions from PostgreSQL.
type PostgresTransactionReadRepository struct {
	db *sql.DB
}

// NewPostgresTransactionReadRepository creates a PostgreSQL-backed transaction read repository.
func NewPostgresTransactionReadRepository(db *sql.DB) *PostgresTransactionReadRepository {
	return &PostgresTransactionReadRepository{db: db}
}

// GetTransactionByID returns one transaction by ID from tenant-local schema.
func (r *PostgresTransactionReadRepository) GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error) {
	if r == nil || r.db == nil {
		return TransactionRow{}, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return TransactionRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, transactionReadTimeout)
	defer cancel()

	query := fmt.Sprintf(
		`SELECT
			id::text,
			reference,
			type,
			amount,
			description,
			metadata,
			status,
			failure_code,
			failure_reason,
			created_at,
			updated_at,
			processed_at
		FROM %s.transactions
		WHERE id::text = $1
		LIMIT 1`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var row TransactionRow
	var failureCode sql.NullString
	var failureReason sql.NullString
	var processedAt sql.NullTime

	err := r.db.QueryRowContext(queryCtx, query, transactionID).Scan(
		&row.ID,
		&row.Reference,
		&row.Type,
		&row.Amount,
		&row.Description,
		&row.Metadata,
		&row.Status,
		&failureCode,
		&failureReason,
		&row.CreatedAt,
		&row.UpdatedAt,
		&processedAt,
	)
	if err != nil {
		return TransactionRow{}, fmt.Errorf("get transaction from schema %q: %w", tenantSchema, err)
	}

	if failureCode.Valid {
		value := failureCode.String
		row.FailureCode = &value
	}
	if failureReason.Valid {
		value := failureReason.String
		row.FailureReason = &value
	}
	if processedAt.Valid {
		value := processedAt.Time
		row.ProcessedAt = &value
	}

	return row, nil
}

// ListTransactions returns transaction rows ordered by newest first.
func (r *PostgresTransactionReadRepository) ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, transactionReadTimeout)
	defer cancel()

	baseQuery := fmt.Sprintf(
		`SELECT
			id::text,
			reference,
			type,
			amount,
			description,
			metadata,
			status,
			failure_code,
			failure_reason,
			created_at,
			updated_at,
			processed_at
		FROM %s.transactions`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var rows *sql.Rows
	var err error
	if status == "" {
		query := baseQuery + `
			ORDER BY created_at DESC, id DESC
			LIMIT $1 OFFSET $2`
		rows, err = r.db.QueryContext(queryCtx, query, limit, offset)
	} else {
		query := baseQuery + `
			WHERE status = $1
			ORDER BY created_at DESC, id DESC
			LIMIT $2 OFFSET $3`
		rows, err = r.db.QueryContext(queryCtx, query, status, limit, offset)
	}
	if err != nil {
		return nil, fmt.Errorf("list transactions from schema %q: %w", tenantSchema, err)
	}
	defer func() {
		_ = rows.Close()
	}()

	result := make([]TransactionRow, 0, limit)
	for rows.Next() {
		var row TransactionRow
		var failureCode sql.NullString
		var failureReason sql.NullString
		var processedAt sql.NullTime

		if err := rows.Scan(
			&row.ID,
			&row.Reference,
			&row.Type,
			&row.Amount,
			&row.Description,
			&row.Metadata,
			&row.Status,
			&failureCode,
			&failureReason,
			&row.CreatedAt,
			&row.UpdatedAt,
			&processedAt,
		); err != nil {
			return nil, fmt.Errorf("scan transaction row: %w", err)
		}

		if failureCode.Valid {
			value := failureCode.String
			row.FailureCode = &value
		}
		if failureReason.Valid {
			value := failureReason.String
			row.FailureReason = &value
		}
		if processedAt.Valid {
			value := processedAt.Time
			row.ProcessedAt = &value
		}

		result = append(result, row)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate transaction rows: %w", err)
	}

	return result, nil
}

