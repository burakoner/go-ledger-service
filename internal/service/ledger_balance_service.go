package service

import (
	"context"
	"fmt"
	"time"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

type BalanceResult struct {
	AvailableBalance int64     `json:"balance"`
	UpdatedAt        time.Time `json:"updated_at"`
}

type LedgerBalanceService interface {
	GetBalance(ctx context.Context, tenantValue tenant.ContextValue) (BalanceResult, error)
}

type ledgerBalanceService struct {
	ledgerReadRepo repository.LedgerBalanceRepository
}

func NewLedgerBalanceService(ledgerReadRepo repository.LedgerBalanceRepository) LedgerBalanceService {
	return &ledgerBalanceService{ledgerReadRepo: ledgerReadRepo}
}

func (s *ledgerBalanceService) GetBalance(ctx context.Context, tenantValue tenant.ContextValue) (BalanceResult, error) {
	row, err := s.ledgerReadRepo.GetBalance(ctx, tenantValue.TenantSchema)
	if err != nil {
		return BalanceResult{}, fmt.Errorf("get tenant balance: %w", err)
	}

	return BalanceResult{
		AvailableBalance: row.AvailableBalance,
		UpdatedAt:        row.UpdatedAt,
	}, nil
}
