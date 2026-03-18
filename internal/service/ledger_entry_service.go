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

type LedgerEntryResult struct {
	ID              int64     `json:"id"`
	TransactionID   string    `json:"transaction_id"`
	Reference       string    `json:"reference"`
	ChangeAmount    int64     `json:"change_amount"`
	PreviousBalance int64     `json:"previous_balance"`
	NewBalance      int64     `json:"new_balance"`
	CreatedAt       time.Time `json:"created_at"`
}

type LedgerEntryService interface {
	ListLedgerEntries(ctx context.Context, tenantValue tenant.ContextValue, limit, offset int) ([]LedgerEntryResult, int, int, int64, error)
}

type ledgerEntryService struct {
	ledgerReadRepo repository.LedgerEntryRepository
}

func NewLedgerEntryService(ledgerReadRepo repository.LedgerEntryRepository) LedgerEntryService {
	return &ledgerEntryService{ledgerReadRepo: ledgerReadRepo}
}

func (s *ledgerEntryService) ListLedgerEntries(ctx context.Context, tenantValue tenant.ContextValue, limit, offset int) ([]LedgerEntryResult, int, int, int64, error) {
	normalizedLimit, normalizedOffset, err := normalizeLedgerPagination(limit, offset)
	if err != nil {
		return nil, 0, 0, 0, err
	}

	rows, err := s.ledgerReadRepo.ListLedgerEntries(ctx, tenantValue.TenantSchema, normalizedLimit, normalizedOffset)
	if err != nil {
		return nil, 0, 0, 0, fmt.Errorf("list tenant ledger entries: %w", err)
	}

	totalCount, err := s.ledgerReadRepo.CountLedgerEntries(ctx, tenantValue.TenantSchema)
	if err != nil {
		return nil, 0, 0, 0, fmt.Errorf("count tenant ledger entries: %w", err)
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

	return results, normalizedLimit, normalizedOffset, totalCount, nil
}

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
