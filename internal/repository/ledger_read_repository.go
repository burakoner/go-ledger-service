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

const ledgerReadTimeout = 2 * time.Second

// BalanceRow represents current balance state for one tenant.
type BalanceRow struct {
	AvailableBalance int64
	UpdatedAt        time.Time
}

// LedgerEntryRow represents one immutable ledger row.
type LedgerEntryRow struct {
	ID              int64
	TransactionID   string
	Reference       string
	ChangeAmount    int64
	PreviousBalance int64
	NewBalance      int64
	CreatedAt       time.Time
}

// LedgerReadRepository defines read operations from tenant-local ledger tables.
type LedgerReadRepository interface {
	GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error)
	ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error)
}

// PostgresLedgerReadRepository reads tenant-local ledger data from PostgreSQL.
type PostgresLedgerReadRepository struct {
	db *sql.DB
}

// NewPostgresLedgerReadRepository creates a PostgreSQL-backed ledger read repository.
func NewPostgresLedgerReadRepository(db *sql.DB) *PostgresLedgerReadRepository {
	return &PostgresLedgerReadRepository{db: db}
}

// GetBalance returns current available balance from tenant-local balances table.
func (r *PostgresLedgerReadRepository) GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error) {
	if r == nil || r.db == nil {
		return BalanceRow{}, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return BalanceRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerReadTimeout)
	defer cancel()

	query := fmt.Sprintf(
		`SELECT balance, updated_at FROM %s.balances WHERE id = 1`,
		pq.QuoteIdentifier(tenantSchema),
	)

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

// ListLedgerEntries returns ledger entries ordered by newest first.
func (r *PostgresLedgerReadRepository) ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerReadTimeout)
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
