package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const (
	defaultLedgerPageLimit = 20
	maxLedgerPageLimit     = 100
)

var ErrInvalidPagination = errors.New("invalid pagination")

// BalanceResult represents tenant current balance payload.
type BalanceResult struct {
	AvailableBalance int64     `json:"balance"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// LedgerEntryResult represents one ledger entry payload.
type LedgerEntryResult struct {
	ID              int64     `json:"id"`
	TransactionID   string    `json:"transaction_id"`
	Reference       string    `json:"reference"`
	ChangeAmount    int64     `json:"change_amount"`
	PreviousBalance int64     `json:"previous_balance"`
	NewBalance      int64     `json:"new_balance"`
	CreatedAt       time.Time `json:"created_at"`
}

// LedgerQueryService defines read-only ledger endpoints behavior.
type LedgerQueryService interface {
	GetBalance(ctx context.Context, tenantValue tenant.ContextValue) (BalanceResult, error)
	ListLedgerEntries(ctx context.Context, tenantValue tenant.ContextValue, limit, offset int) ([]LedgerEntryResult, int, int, error)
}

type ledgerQueryService struct {
	ledgerReadRepo repository.LedgerReadRepository
}

// NewLedgerQueryService creates read-only ledger query service.
func NewLedgerQueryService(ledgerReadRepo repository.LedgerReadRepository) LedgerQueryService {
	return &ledgerQueryService{ledgerReadRepo: ledgerReadRepo}
}

// GetBalance reads current tenant balance.
func (s *ledgerQueryService) GetBalance(ctx context.Context, tenantValue tenant.ContextValue) (BalanceResult, error) {
	row, err := s.ledgerReadRepo.GetBalance(ctx, tenantValue.TenantSchema)
	if err != nil {
		return BalanceResult{}, fmt.Errorf("get tenant balance: %w", err)
	}

	return BalanceResult{
		AvailableBalance: row.AvailableBalance,
		UpdatedAt:        row.UpdatedAt,
	}, nil
}

// ListLedgerEntries reads tenant ledger entries with normalized pagination.
func (s *ledgerQueryService) ListLedgerEntries(ctx context.Context, tenantValue tenant.ContextValue, limit, offset int) ([]LedgerEntryResult, int, int, error) {
	normalizedLimit, normalizedOffset, err := normalizeLedgerPagination(limit, offset)
	if err != nil {
		return nil, 0, 0, err
	}

	rows, err := s.ledgerReadRepo.ListLedgerEntries(ctx, tenantValue.TenantSchema, normalizedLimit, normalizedOffset)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("list tenant ledger entries: %w", err)
	}

	results := make([]LedgerEntryResult, 0, len(rows))
	for _, row := range rows {
		results = append(results, LedgerEntryResult{
			ID:              row.ID,
			TransactionID:   row.TransactionID,
			Reference:       row.Reference,
			ChangeAmount:    row.ChangeAmount,
			PreviousBalance: row.PreviousBalance,
			NewBalance:      row.NewBalance,
			CreatedAt:       row.CreatedAt,
		})
	}

	return results, normalizedLimit, normalizedOffset, nil
}

// normalizeLedgerPagination validates and defaults limit/offset values.
func normalizeLedgerPagination(limit, offset int) (int, int, error) {
	if limit == 0 {
		limit = defaultLedgerPageLimit
	}
	if limit < 0 {
		return 0, 0, fmt.Errorf("%w: limit must be >= 0", ErrInvalidPagination)
	}
	if limit > maxLedgerPageLimit {
		return 0, 0, fmt.Errorf("%w: limit must be <= %d", ErrInvalidPagination, maxLedgerPageLimit)
	}
	if offset < 0 {
		return 0, 0, fmt.Errorf("%w: offset must be >= 0", ErrInvalidPagination)
	}

	return limit, offset, nil
}
