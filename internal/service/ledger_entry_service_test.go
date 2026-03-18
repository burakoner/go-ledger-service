package service

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

type stubLedgerEntryRepo struct {
	listFn     func(ctx context.Context, tenantSchema string, limit, offset int) ([]repository.LedgerEntryRow, error)
	countFn    func(ctx context.Context, tenantSchema string) (int64, error)
	lastSchema string
	lastLimit  int
	lastOffset int
}

func (s *stubLedgerEntryRepo) ListLedgerEntries(ctx context.Context, tenantSchema string, limit, offset int) ([]repository.LedgerEntryRow, error) {
	s.lastSchema = tenantSchema
	s.lastLimit = limit
	s.lastOffset = offset
	if s.listFn == nil {
		return nil, nil
	}
	return s.listFn(ctx, tenantSchema, limit, offset)
}

func (s *stubLedgerEntryRepo) CountLedgerEntries(ctx context.Context, tenantSchema string) (int64, error) {
	if s.countFn == nil {
		return 0, nil
	}
	return s.countFn(ctx, tenantSchema)
}

func TestNormalizeLedgerPagination(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		limit       int
		offset      int
		wantLimit   int
		wantOffset  int
		wantErrIs   error
		errContains string
	}{
		{
			name:       "default limit applies when zero",
			limit:      0,
			offset:     0,
			wantLimit:  defaultLedgerPageLimit,
			wantOffset: 0,
		},
		{
			name:       "explicit valid pagination",
			limit:      10,
			offset:     5,
			wantLimit:  10,
			wantOffset: 5,
		},
		{
			name:        "negative limit rejected",
			limit:       -1,
			offset:      0,
			wantErrIs:   ErrInvalidPagination,
			errContains: "limit must be >= 0",
		},
		{
			name:        "limit above max rejected",
			limit:       maxLedgerPageLimit + 1,
			offset:      0,
			wantErrIs:   ErrInvalidPagination,
			errContains: "limit must be <=",
		},
		{
			name:        "negative offset rejected",
			limit:       10,
			offset:      -1,
			wantErrIs:   ErrInvalidPagination,
			errContains: "offset must be >= 0",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			limit, offset, err := normalizeLedgerPagination(tt.limit, tt.offset)
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
			if limit != tt.wantLimit {
				t.Fatalf("limit mismatch: got %d want %d", limit, tt.wantLimit)
			}
			if offset != tt.wantOffset {
				t.Fatalf("offset mismatch: got %d want %d", offset, tt.wantOffset)
			}
		})
	}
}

func TestListLedgerEntriesMapsRowsAndTotalCount(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC().Truncate(time.Second)
	repo := &stubLedgerEntryRepo{
		listFn: func(ctx context.Context, tenantSchema string, limit, offset int) ([]repository.LedgerEntryRow, error) {
			return []repository.LedgerEntryRow{
				{
					ID:              2,
					TransactionID:   "txn-2",
					Reference:       "ref-2",
					ChangeAmount:    -100,
					PreviousBalance: 500,
					NewBalance:      400,
					CreatedAt:       now,
				},
				{
					ID:              1,
					TransactionID:   "txn-1",
					Reference:       "ref-1",
					ChangeAmount:    500,
					PreviousBalance: 0,
					NewBalance:      500,
					CreatedAt:       now.Add(-time.Minute),
				},
			}, nil
		},
		countFn: func(ctx context.Context, tenantSchema string) (int64, error) {
			return 9, nil
		},
	}

	svc := NewLedgerEntryService(repo)
	results, normalizedLimit, normalizedOffset, totalCount, err := svc.ListLedgerEntries(
		context.Background(),
		tenant.ContextValue{TenantSchema: "tenant_alpha"},
		0,
		3,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if normalizedLimit != defaultLedgerPageLimit {
		t.Fatalf("normalized limit mismatch: got %d want %d", normalizedLimit, defaultLedgerPageLimit)
	}
	if normalizedOffset != 3 {
		t.Fatalf("normalized offset mismatch: got %d want %d", normalizedOffset, 3)
	}
	if totalCount != 9 {
		t.Fatalf("total count mismatch: got %d want %d", totalCount, 9)
	}
	if repo.lastSchema != "tenant_alpha" {
		t.Fatalf("repo schema mismatch: got %q", repo.lastSchema)
	}
	if repo.lastLimit != defaultLedgerPageLimit {
		t.Fatalf("repo limit mismatch: got %d want %d", repo.lastLimit, defaultLedgerPageLimit)
	}
	if repo.lastOffset != 3 {
		t.Fatalf("repo offset mismatch: got %d want %d", repo.lastOffset, 3)
	}

	if len(results) != 2 {
		t.Fatalf("result length mismatch: got %d want 2", len(results))
	}
	if results[0].ID != 2 || results[0].Reference != "ref-2" || results[0].NewBalance != 400 {
		t.Fatalf("first row mapping mismatch: %+v", results[0])
	}
	if results[1].ID != 1 || results[1].Reference != "ref-1" || results[1].NewBalance != 500 {
		t.Fatalf("second row mapping mismatch: %+v", results[1])
	}
}
