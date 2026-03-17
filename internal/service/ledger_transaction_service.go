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
	ErrInvalidTransactionQuery           = errors.New("invalid transaction query")
	ErrTransactionNotFound               = errors.New("transaction not found")
	ErrInvalidTransactionInput           = errors.New("invalid transaction input")
	ErrTransactionReferenceAlreadyExists = errors.New("transaction reference already exists")
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

type CreatePendingTransactionInput struct {
	Reference   string
	Type        string
	Amount      int64
	Description string
	Metadata    json.RawMessage
}

type LedgerTransactionService interface {
	GetTransactionByID(ctx context.Context, tenantValue tenant.ContextValue, transactionID string) (TransactionResult, error)
	GetTransactionByReference(ctx context.Context, tenantValue tenant.ContextValue, reference string) (TransactionResult, error)
	ListTransactions(ctx context.Context, tenantValue tenant.ContextValue, status string, limit, offset int) ([]TransactionResult, string, int, int, error)
	CreatePendingTransaction(ctx context.Context, tenantValue tenant.ContextValue, input CreatePendingTransactionInput) (TransactionResult, error)
}

type ledgerTransactionService struct {
	ledgerRepo repository.LedgerTransactionRepository
}

func NewLedgerTransactionService(ledgerRepo repository.LedgerTransactionRepository) LedgerTransactionService {
	return &ledgerTransactionService{ledgerRepo: ledgerRepo}
}

func (s *ledgerTransactionService) GetTransactionByID(ctx context.Context, tenantValue tenant.ContextValue, transactionID string) (TransactionResult, error) {
	transactionID = strings.TrimSpace(transactionID)
	if transactionID == "" {
		return TransactionResult{}, fmt.Errorf("%w: transaction id is required", ErrInvalidTransactionQuery)
	}

	row, err := s.ledgerRepo.GetTransactionByID(ctx, tenantValue.TenantSchema, transactionID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TransactionResult{}, ErrTransactionNotFound
		}
		return TransactionResult{}, fmt.Errorf("get transaction by id: %w", err)
	}

	return mapTransactionRowToResult(row), nil
}

func (s *ledgerTransactionService) GetTransactionByReference(ctx context.Context, tenantValue tenant.ContextValue, reference string) (TransactionResult, error) {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return TransactionResult{}, fmt.Errorf("%w: reference is required", ErrInvalidTransactionQuery)
	}

	row, err := s.ledgerRepo.GetTransactionByReference(ctx, tenantValue.TenantSchema, reference)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return TransactionResult{}, ErrTransactionNotFound
		}
		return TransactionResult{}, fmt.Errorf("get transaction by reference: %w", err)
	}

	return mapTransactionRowToResult(row), nil
}

func (s *ledgerTransactionService) ListTransactions(ctx context.Context, tenantValue tenant.ContextValue, status string, limit, offset int) ([]TransactionResult, string, int, int, error) {
	normalizedStatus, normalizedLimit, normalizedOffset, err := normalizeTransactionListQuery(status, limit, offset)
	if err != nil {
		return nil, "", 0, 0, err
	}

	rows, err := s.ledgerRepo.ListTransactions(ctx, tenantValue.TenantSchema, normalizedStatus, normalizedLimit, normalizedOffset)
	if err != nil {
		return nil, "", 0, 0, fmt.Errorf("list transactions: %w", err)
	}

	results := make([]TransactionResult, 0, len(rows))
	for _, row := range rows {
		results = append(results, mapTransactionRowToResult(row))
	}

	return results, normalizedStatus, normalizedLimit, normalizedOffset, nil
}

func (s *ledgerTransactionService) CreatePendingTransaction(ctx context.Context, tenantValue tenant.ContextValue, input CreatePendingTransactionInput) (TransactionResult, error) {
	params, err := normalizeCreatePendingTransactionInput(input)
	if err != nil {
		return TransactionResult{}, err
	}

	row, err := s.ledgerRepo.CreatePendingTransaction(ctx, tenantValue.TenantSchema, params)
	if err != nil {
		if errors.Is(err, repository.ErrTransactionReferenceAlreadyExists) {
			return TransactionResult{}, ErrTransactionReferenceAlreadyExists
		}
		return TransactionResult{}, fmt.Errorf("create pending transaction: %w", err)
	}

	// TODO: Notify worker loop to pick this pending transaction faster (LISTEN/NOTIFY or similar).
	return mapTransactionRowToResult(row), nil
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

func normalizeCreatePendingTransactionInput(input CreatePendingTransactionInput) (repository.CreatePendingTransactionParams, error) {
	reference := strings.TrimSpace(input.Reference)
	if reference == "" {
		return repository.CreatePendingTransactionParams{}, fmt.Errorf("%w: reference is required", ErrInvalidTransactionInput)
	}

	transactionType := strings.TrimSpace(strings.ToLower(input.Type))
	switch transactionType {
	case "credit", "debit":
		// valid
	default:
		return repository.CreatePendingTransactionParams{}, fmt.Errorf("%w: type must be credit or debit", ErrInvalidTransactionInput)
	}

	if input.Amount <= 0 {
		return repository.CreatePendingTransactionParams{}, fmt.Errorf("%w: amount must be greater than 0", ErrInvalidTransactionInput)
	}

	description := strings.TrimSpace(input.Description)
	metadata := input.Metadata
	if len(metadata) == 0 {
		metadata = []byte(`{}`)
	}
	if !json.Valid(metadata) {
		return repository.CreatePendingTransactionParams{}, fmt.Errorf("%w: metadata must be valid JSON", ErrInvalidTransactionInput)
	}

	return repository.CreatePendingTransactionParams{
		Reference:   reference,
		Type:        transactionType,
		Amount:      input.Amount,
		Description: description,
		Metadata:    metadata,
	}, nil
}
