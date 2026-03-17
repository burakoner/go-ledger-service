package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/burakoner/go-ledger-service/internal/tenant"
	"github.com/lib/pq"
)

const ledgerTransactionTimeout = 2 * time.Second

var ErrTransactionReferenceAlreadyExists = errors.New("transaction reference already exists")

type TransactionRow struct {
	ID            string
	Reference     string
	Type          string
	Amount        int64
	Description   string
	Metadata      []byte
	Status        string
	FailureCode   *string
	FailureReason *string
	CreatedAt     time.Time
	UpdatedAt     time.Time
	ProcessedAt   *time.Time
}

type CreatePendingTransactionParams struct {
	Reference   string
	Type        string
	Amount      int64
	Description string
	Metadata    []byte
}

type PostgresLedgerTransactionRepository struct {
	db *sql.DB
}

type LedgerTransactionRepository interface {
	GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error)
	GetTransactionByReference(ctx context.Context, tenantSchema, reference string) (TransactionRow, error)
	ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error)
	CreatePendingTransaction(ctx context.Context, tenantSchema string, params CreatePendingTransactionParams) (TransactionRow, error)
}

func NewPostgresLedgerTransactionRepository(db *sql.DB) *PostgresLedgerTransactionRepository {
	return &PostgresLedgerTransactionRepository{db: db}
}

func (r *PostgresLedgerTransactionRepository) GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error) {
	if r == nil || r.db == nil {
		return TransactionRow{}, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return TransactionRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTransactionTimeout)
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

func (r *PostgresLedgerTransactionRepository) GetTransactionByReference(ctx context.Context, tenantSchema, reference string) (TransactionRow, error) {
	if r == nil || r.db == nil {
		return TransactionRow{}, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return TransactionRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTransactionTimeout)
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
		WHERE reference = $1
		ORDER BY created_at DESC, id DESC
		LIMIT 1`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var row TransactionRow
	var failureCode sql.NullString
	var failureReason sql.NullString
	var processedAt sql.NullTime

	err := r.db.QueryRowContext(queryCtx, query, reference).Scan(
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
		return TransactionRow{}, fmt.Errorf("get transaction by reference from schema %q: %w", tenantSchema, err)
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

func (r *PostgresLedgerTransactionRepository) ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTransactionTimeout)
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

func (r *PostgresLedgerTransactionRepository) CreatePendingTransaction(ctx context.Context, tenantSchema string, params CreatePendingTransactionParams) (TransactionRow, error) {
	if r == nil || r.db == nil {
		return TransactionRow{}, errors.New("transaction write repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return TransactionRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTransactionTimeout)
	defer cancel()

	query := fmt.Sprintf(
		`INSERT INTO %s.transactions (
			reference,
			type,
			amount,
			description,
			metadata,
			status
		)
		VALUES ($1, $2, $3, $4, $5::jsonb, 'pending')
		RETURNING
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
			processed_at`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var row TransactionRow
	var failureCode sql.NullString
	var failureReason sql.NullString
	var processedAt sql.NullTime

	err := r.db.QueryRowContext(
		queryCtx,
		query,
		params.Reference,
		params.Type,
		params.Amount,
		params.Description,
		params.Metadata,
	).Scan(
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
		if isReferenceUniqueViolation(err) {
			return TransactionRow{}, ErrTransactionReferenceAlreadyExists
		}
		return TransactionRow{}, fmt.Errorf("create pending transaction in schema %q: %w", tenantSchema, err)
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

func isReferenceUniqueViolation(err error) bool {
	var pqErr *pq.Error
	if !errors.As(err, &pqErr) {
		return false
	}
	if pqErr.Code != "23505" {
		return false
	}
	// The migration creates idx_transactions_reference_unique.
	// Keeping a name check avoids masking unrelated unique-constraint errors.
	return strings.Contains(pqErr.Constraint, "transactions_reference")
}
