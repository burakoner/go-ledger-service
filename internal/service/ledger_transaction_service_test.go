package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

type stubLedgerTransactionRepo struct {
	getByIDFn            func(ctx context.Context, tenantSchema, transactionID string) (repository.TransactionRow, error)
	getByReferenceFn     func(ctx context.Context, tenantSchema, reference string) (repository.TransactionRow, error)
	listFn               func(ctx context.Context, tenantSchema, status string, limit, offset int) ([]repository.TransactionRow, error)
	countFn              func(ctx context.Context, tenantSchema, status string) (int64, error)
	createPendingTxnFn   func(ctx context.Context, tenantSchema string, params repository.CreatePendingTransactionParams) (repository.TransactionRow, error)
}

func (s *stubLedgerTransactionRepo) GetTransactionByID(ctx context.Context, tenantSchema, transactionID string) (repository.TransactionRow, error) {
	if s.getByIDFn == nil {
		return repository.TransactionRow{}, nil
	}
	return s.getByIDFn(ctx, tenantSchema, transactionID)
}

func (s *stubLedgerTransactionRepo) GetTransactionByReference(ctx context.Context, tenantSchema, reference string) (repository.TransactionRow, error) {
	if s.getByReferenceFn == nil {
		return repository.TransactionRow{}, nil
	}
	return s.getByReferenceFn(ctx, tenantSchema, reference)
}

func (s *stubLedgerTransactionRepo) ListTransactions(ctx context.Context, tenantSchema, status string, limit, offset int) ([]repository.TransactionRow, error) {
	if s.listFn == nil {
		return nil, nil
	}
	return s.listFn(ctx, tenantSchema, status, limit, offset)
}

func (s *stubLedgerTransactionRepo) CountTransactions(ctx context.Context, tenantSchema, status string) (int64, error) {
	if s.countFn == nil {
		return 0, nil
	}
	return s.countFn(ctx, tenantSchema, status)
}

func (s *stubLedgerTransactionRepo) CreatePendingTransaction(ctx context.Context, tenantSchema string, params repository.CreatePendingTransactionParams) (repository.TransactionRow, error) {
	if s.createPendingTxnFn == nil {
		return repository.TransactionRow{}, nil
	}
	return s.createPendingTxnFn(ctx, tenantSchema, params)
}

func TestNormalizeCreatePendingTransactionInput(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		input       CreatePendingTransactionInput
		want        repository.CreatePendingTransactionParams
		wantErrIs   error
		errContains string
	}{
		{
			name: "valid credit input is normalized",
			input: CreatePendingTransactionInput{
				Reference:   "  ref-001  ",
				Type:        "  CREDIT  ",
				Amount:      1500,
				Description: "  invoice  ",
			},
			want: repository.CreatePendingTransactionParams{
				Reference:   "ref-001",
				Type:        "credit",
				Amount:      1500,
				Description: "invoice",
				Metadata:    []byte(`{}`),
			},
		},
		{
			name: "valid debit input with metadata",
			input: CreatePendingTransactionInput{
				Reference:   "ref-002",
				Type:        "debit",
				Amount:      20,
				Description: "payment",
				Metadata:    json.RawMessage(`{"channel":"mobile"}`),
			},
			want: repository.CreatePendingTransactionParams{
				Reference:   "ref-002",
				Type:        "debit",
				Amount:      20,
				Description: "payment",
				Metadata:    []byte(`{"channel":"mobile"}`),
			},
		},
		{
			name: "empty reference is rejected",
			input: CreatePendingTransactionInput{
				Reference: "   ",
				Type:      "credit",
				Amount:    10,
			},
			wantErrIs:   ErrInvalidTransactionInput,
			errContains: "reference is required",
		},
		{
			name: "invalid type is rejected",
			input: CreatePendingTransactionInput{
				Reference: "ref-003",
				Type:      "refund",
				Amount:    10,
			},
			wantErrIs:   ErrInvalidTransactionInput,
			errContains: "type must be credit or debit",
		},
		{
			name: "non-positive amount is rejected",
			input: CreatePendingTransactionInput{
				Reference: "ref-004",
				Type:      "credit",
				Amount:    0,
			},
			wantErrIs:   ErrInvalidTransactionInput,
			errContains: "amount must be greater than 0",
		},
		{
			name: "invalid metadata JSON is rejected",
			input: CreatePendingTransactionInput{
				Reference: "ref-005",
				Type:      "credit",
				Amount:    10,
				Metadata:  json.RawMessage(`{"bad"`),
			},
			wantErrIs:   ErrInvalidTransactionInput,
			errContains: "metadata must be valid JSON",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := normalizeCreatePendingTransactionInput(tt.input)
			if tt.wantErrIs != nil {
				if !errors.Is(err, tt.wantErrIs) {
					t.Fatalf("expected error %v, got %v", tt.wantErrIs, err)
				}
				if tt.errContains != "" && (err == nil || !strings.Contains(err.Error(), tt.errContains)) {
					t.Fatalf("expected error to contain %q, got %v", tt.errContains, err)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if got.Reference != tt.want.Reference {
				t.Fatalf("reference mismatch: got %q want %q", got.Reference, tt.want.Reference)
			}
			if got.Type != tt.want.Type {
				t.Fatalf("type mismatch: got %q want %q", got.Type, tt.want.Type)
			}
			if got.Amount != tt.want.Amount {
				t.Fatalf("amount mismatch: got %d want %d", got.Amount, tt.want.Amount)
			}
			if got.Description != tt.want.Description {
				t.Fatalf("description mismatch: got %q want %q", got.Description, tt.want.Description)
			}
			if string(got.Metadata) != string(tt.want.Metadata) {
				t.Fatalf("metadata mismatch: got %s want %s", string(got.Metadata), string(tt.want.Metadata))
			}
		})
	}
}

func TestNormalizeTransactionListQuery(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		status      string
		limit       int
		offset      int
		wantStatus  string
		wantLimit   int
		wantOffset  int
		wantErrIs   error
		errContains string
	}{
		{
			name:       "default limit applies when limit is zero",
			status:     "",
			limit:      0,
			offset:     0,
			wantStatus: "",
			wantLimit:  defaultTransactionPageLimit,
			wantOffset: 0,
		},
		{
			name:       "status is normalized",
			status:     "  Completed ",
			limit:      10,
			offset:     3,
			wantStatus: "completed",
			wantLimit:  10,
			wantOffset: 3,
		},
		{
			name:        "invalid status rejected",
			status:      "done",
			limit:       10,
			offset:      0,
			wantErrIs:   ErrInvalidTransactionQuery,
			errContains: "status must be one of pending, completed, failed",
		},
		{
			name:        "negative limit rejected",
			status:      "",
			limit:       -1,
			offset:      0,
			wantErrIs:   ErrInvalidTransactionQuery,
			errContains: "limit must be >= 0",
		},
		{
			name:        "limit above max rejected",
			status:      "",
			limit:       maxTransactionPageLimit + 1,
			offset:      0,
			wantErrIs:   ErrInvalidTransactionQuery,
			errContains: "limit must be <=",
		},
		{
			name:        "negative offset rejected",
			status:      "",
			limit:       10,
			offset:      -1,
			wantErrIs:   ErrInvalidTransactionQuery,
			errContains: "offset must be >= 0",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			status, limit, offset, err := normalizeTransactionListQuery(tt.status, tt.limit, tt.offset)
			if tt.wantErrIs != nil {
				if !errors.Is(err, tt.wantErrIs) {
					t.Fatalf("expected error %v, got %v", tt.wantErrIs, err)
				}
				if tt.errContains != "" && (err == nil || !strings.Contains(err.Error(), tt.errContains)) {
					t.Fatalf("expected error to contain %q, got %v", tt.errContains, err)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if status != tt.wantStatus {
				t.Fatalf("status mismatch: got %q want %q", status, tt.wantStatus)
			}
			if limit != tt.wantLimit {
				t.Fatalf("limit mismatch: got %d want %d", limit, tt.wantLimit)
			}
			if offset != tt.wantOffset {
				t.Fatalf("offset mismatch: got %d want %d", offset, tt.wantOffset)
			}
		})
	}
}

func TestCreatePendingTransactionMapsDuplicateReferenceError(t *testing.T) {
	t.Parallel()

	repo := &stubLedgerTransactionRepo{
		createPendingTxnFn: func(ctx context.Context, tenantSchema string, params repository.CreatePendingTransactionParams) (repository.TransactionRow, error) {
			return repository.TransactionRow{}, repository.ErrTransactionReferenceAlreadyExists
		},
	}

	svc := NewLedgerTransactionService(repo)
	_, err := svc.CreatePendingTransaction(
		context.Background(),
		tenant.ContextValue{TenantSchema: "tenant_alpha"},
		CreatePendingTransactionInput{
			Reference: "ref-dup",
			Type:      "credit",
			Amount:    100,
		},
	)
	if !errors.Is(err, ErrTransactionReferenceAlreadyExists) {
		t.Fatalf("expected %v, got %v", ErrTransactionReferenceAlreadyExists, err)
	}
}

func TestGetTransactionByIDMapsNotFound(t *testing.T) {
	t.Parallel()

	repo := &stubLedgerTransactionRepo{
		getByIDFn: func(ctx context.Context, tenantSchema, transactionID string) (repository.TransactionRow, error) {
			return repository.TransactionRow{}, sql.ErrNoRows
		},
	}

	svc := NewLedgerTransactionService(repo)
	_, err := svc.GetTransactionByID(context.Background(), tenant.ContextValue{TenantSchema: "tenant_alpha"}, "txn-1")
	if !errors.Is(err, ErrTransactionNotFound) {
		t.Fatalf("expected %v, got %v", ErrTransactionNotFound, err)
	}
}

func TestGetTransactionByReferenceMapsNotFound(t *testing.T) {
	t.Parallel()

	repo := &stubLedgerTransactionRepo{
		getByReferenceFn: func(ctx context.Context, tenantSchema, reference string) (repository.TransactionRow, error) {
			return repository.TransactionRow{}, sql.ErrNoRows
		},
	}

	svc := NewLedgerTransactionService(repo)
	_, err := svc.GetTransactionByReference(context.Background(), tenant.ContextValue{TenantSchema: "tenant_alpha"}, "ref-1")
	if !errors.Is(err, ErrTransactionNotFound) {
		t.Fatalf("expected %v, got %v", ErrTransactionNotFound, err)
	}
}

func TestMapTransactionRowToResultDefaultsEmptyMetadata(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	row := repository.TransactionRow{
		ID:        "txn-1",
		Reference: "ref-1",
		Type:      "credit",
		Amount:    42,
		Status:    "pending",
		CreatedAt: now,
		UpdatedAt: now,
	}

	result := mapTransactionRowToResult(row)
	if string(result.Metadata) != "{}" {
		t.Fatalf("expected default metadata {}, got %s", string(result.Metadata))
	}
}
