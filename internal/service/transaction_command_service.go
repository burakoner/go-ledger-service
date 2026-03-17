package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

var ErrInvalidTransactionInput = errors.New("invalid transaction input")

type CreatePendingTransactionInput struct {
	Reference   string
	Type        string
	Amount      int64
	Description string
	Metadata    json.RawMessage
}

type TransactionCommandService interface {
	CreatePendingTransaction(ctx context.Context, tenantValue tenant.ContextValue, input CreatePendingTransactionInput) (TransactionResult, error)
}

type transactionCommandService struct {
	ledgerRepo repository.LedgerRepository
}

func NewTransactionCommandService(ledgerRepo repository.LedgerRepository) TransactionCommandService {
	return &transactionCommandService{ledgerRepo: ledgerRepo}
}

func (s *transactionCommandService) CreatePendingTransaction(ctx context.Context, tenantValue tenant.ContextValue, input CreatePendingTransactionInput) (TransactionResult, error) {
	params, err := normalizeCreatePendingTransactionInput(input)
	if err != nil {
		return TransactionResult{}, err
	}

	row, err := s.ledgerRepo.CreatePendingTransaction(ctx, tenantValue.TenantSchema, params)
	if err != nil {
		return TransactionResult{}, fmt.Errorf("create pending transaction: %w", err)
	}

	// TODO: Publish transaction-created event to RabbitMQ in next step.
	return mapTransactionRowToResult(row), nil
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

