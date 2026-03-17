package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const (
	defaultTransactionPageLimit = 20
	maxTransactionPageLimit     = 100
)

var (
	ErrInvalidTransactionQuery = errors.New("invalid transaction query")
	ErrTransactionNotFound     = errors.New("transaction not found")
)

type TransactionResult struct {
	ID            string          `json:"id"`
	Reference     string          `json:"reference"`
	Type          string          `json:"type"`
	Amount        int64           `json:"amount"`
	Description   string          `json:"description"`
	Metadata      json.RawMessage `json:"metadata"`
	Status        string          `json:"status"`
	FailureCode   *string         `json:"failure_code,omitempty"`
	FailureReason *string         `json:"failure_reason,omitempty"`
	CreatedAt     time.Time       `json:"created_at"`
	UpdatedAt     time.Time       `json:"updated_at"`
	ProcessedAt   *time.Time      `json:"processed_at,omitempty"`
}

type TransactionQueryService interface {
	GetTransactionByID(ctx context.Context, tenantValue tenant.ContextValue, transactionID string) (TransactionResult, error)
	ListTransactions(ctx context.Context, tenantValue tenant.ContextValue, status string, limit, offset int) ([]TransactionResult, string, int, int, error)
}

type transactionQueryService struct {
	transactionReadRepo repository.LedgerRepository
}

func NewTransactionQueryService(transactionReadRepo repository.LedgerRepository) TransactionQueryService {
	return &transactionQueryService{transactionReadRepo: transactionReadRepo}
}

func (s *transactionQueryService) GetTransactionByID(ctx context.Context, tenantValue tenant.ContextValue, transactionID string) (TransactionResult, error) {
	transactionID = strings.TrimSpace(transactionID)
	if transactionID == "" {
		return TransactionResult{}, fmt.Errorf("%w: transaction id is required", ErrInvalidTransactionQuery)
	}

	row, err := s.transactionReadRepo.GetTransactionByID(ctx, tenantValue.TenantSchema, transactionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TransactionResult{}, ErrTransactionNotFound
		}
		return TransactionResult{}, fmt.Errorf("get transaction by id: %w", err)
	}

	return mapTransactionRowToResult(row), nil
}

func (s *transactionQueryService) ListTransactions(ctx context.Context, tenantValue tenant.ContextValue, status string, limit, offset int) ([]TransactionResult, string, int, int, error) {
	normalizedStatus, normalizedLimit, normalizedOffset, err := normalizeTransactionListQuery(status, limit, offset)
	if err != nil {
		return nil, "", 0, 0, err
	}

	rows, err := s.transactionReadRepo.ListTransactions(ctx, tenantValue.TenantSchema, normalizedStatus, normalizedLimit, normalizedOffset)
	if err != nil {
		return nil, "", 0, 0, fmt.Errorf("list transactions: %w", err)
	}

	results := make([]TransactionResult, 0, len(rows))
	for _, row := range rows {
		results = append(results, mapTransactionRowToResult(row))
	}

	return results, normalizedStatus, normalizedLimit, normalizedOffset, nil
}

func normalizeTransactionListQuery(status string, limit, offset int) (string, int, int, error) {
	status = strings.TrimSpace(strings.ToLower(status))
	if status != "" {
		switch status {
		case "pending", "completed", "failed":
			// valid
		default:
			return "", 0, 0, fmt.Errorf("%w: status must be one of pending, completed, failed", ErrInvalidTransactionQuery)
		}
	}

	if limit == 0 {
		limit = defaultTransactionPageLimit
	}
	if limit < 0 {
		return "", 0, 0, fmt.Errorf("%w: limit must be >= 0", ErrInvalidTransactionQuery)
	}
	if limit > maxTransactionPageLimit {
		return "", 0, 0, fmt.Errorf("%w: limit must be <= %d", ErrInvalidTransactionQuery, maxTransactionPageLimit)
	}
	if offset < 0 {
		return "", 0, 0, fmt.Errorf("%w: offset must be >= 0", ErrInvalidTransactionQuery)
	}

	return status, limit, offset, nil
}

func mapTransactionRowToResult(row repository.TransactionRow) TransactionResult {
	metadata := row.Metadata
	if len(metadata) == 0 {
		metadata = []byte(`{}`)
	}

	return TransactionResult{
		ID:            row.ID,
		Reference:     row.Reference,
		Type:          row.Type,
		Amount:        row.Amount,
		Description:   row.Description,
		Metadata:      metadata,
		Status:        row.Status,
		FailureCode:   row.FailureCode,
		FailureReason: row.FailureReason,
		CreatedAt:     row.CreatedAt,
		UpdatedAt:     row.UpdatedAt,
		ProcessedAt:   row.ProcessedAt,
	}
}
