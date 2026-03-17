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

const ledgerEntryTimeout = 2 * time.Second

type LedgerEntryRow struct {
	ID              int64
	TransactionID   string
	Reference       string
	ChangeAmount    int64
	PreviousBalance int64
	NewBalance      int64
	CreatedAt       time.Time
}

type PostgresLedgerEntryRepository struct {
	db *sql.DB
}

type LedgerEntryRepository interface {
	ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error)
}

func NewPostgresLedgerEntryRepository(db *sql.DB) *PostgresLedgerEntryRepository {
	return &PostgresLedgerEntryRepository{db: db}
}

func (r *PostgresLedgerEntryRepository) ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]LedgerEntryRow, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return nil, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerEntryTimeout)
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
