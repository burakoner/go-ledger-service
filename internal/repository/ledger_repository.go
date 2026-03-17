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

const ledgerTimeout = 2 * time.Second

type BalanceRow struct {
	AvailableBalance int64
	UpdatedAt        time.Time
}

type LedgerEntryRow struct {
	ID              int64
	TransactionID   string
	Reference       string
	ChangeAmount    int64
	PreviousBalance int64
	NewBalance      int64
	CreatedAt       time.Time
}

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

type PostgresLedgerRepository struct {
	db *sql.DB
}

type LedgerRepository interface {
	GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error)
	ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error)
	GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error)
	ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error)
}

func NewPostgresLedgerRepository(db *sql.DB) *PostgresLedgerRepository {
	return &PostgresLedgerRepository{db: db}
}

func (r *PostgresLedgerRepository) GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error) {
	if r == nil || r.db == nil {
		return BalanceRow{}, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return BalanceRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTimeout)
	defer cancel()

	query := fmt.Sprintf(`SELECT balance, updated_at FROM %s.balances WHERE id = 1`, pq.QuoteIdentifier(tenantSchema))

	var row BalanceRow
	err := r.db.QueryRowContext(queryCtx, query).Scan(&row.AvailableBalance, &row.UpdatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return BalanceRow{AvailableBalance: 0}, nil
		}
		return BalanceRow{}, fmt.Errorf("get balance from schema %q: %w", tenantSchema, err)
	}

	return row, nil
}

func (r *PostgresLedgerRepository) ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTimeout)
	defer cancel()

	query := fmt.Sprintf(
		`SELECT id, transaction_id::text, reference, change_amount, previous_balance, new_balance, created_at
		FROM %s.ledger_entries
		ORDER BY id DESC
		LIMIT $1 OFFSET $2`,
		pq.QuoteIdentifier(tenantSchema),
	)

	rows, err := r.db.QueryContext(queryCtx, query, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list ledger entries from schema %q: %w", tenantSchema, err)
	}
	defer func() {
		_ = rows.Close()
	}()

	entries := make([]LedgerEntryRow, 0, limit)
	for rows.Next() {
		var entry LedgerEntryRow
		if err := rows.Scan(
			&entry.ID,
			&entry.TransactionID,
			&entry.Reference,
			&entry.ChangeAmount,
			&entry.PreviousBalance,
			&entry.NewBalance,
			&entry.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan ledger entry: %w", err)
		}
		entries = append(entries, entry)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate ledger entries: %w", err)
	}

	return entries, nil
}

func (r *PostgresLedgerRepository) GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (TransactionRow, error) {
	if r == nil || r.db == nil {
		return TransactionRow{}, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return TransactionRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTimeout)
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

func (r *PostgresLedgerRepository) ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]TransactionRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("transaction read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerTimeout)
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
