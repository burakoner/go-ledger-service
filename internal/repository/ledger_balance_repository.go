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

const ledgerBalanceTimeout = 2 * time.Second

type BalanceRow struct {
	AvailableBalance int64
	UpdatedAt        time.Time
}

type PostgresLedgerBalanceRepository struct {
	db *sql.DB
}

type LedgerBalanceRepository interface {
	GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error)
}

func NewPostgresLedgerBalanceRepository(db *sql.DB) *PostgresLedgerBalanceRepository {
	return &PostgresLedgerBalanceRepository{db: db}
}

func (r *PostgresLedgerBalanceRepository) GetBalance(ctx context.Context, tenantSchema string) (BalanceRow, error) {
	if r == nil || r.db == nil {
		return BalanceRow{}, errors.New("ledger read repository is not initialized")
	}
	if !tenant.IsValidSchemaName(tenantSchema) {
		return BalanceRow{}, errors.New("invalid tenant schema name")
	}

	queryCtx, cancel := context.WithTimeout(ctx, ledgerBalanceTimeout)
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
