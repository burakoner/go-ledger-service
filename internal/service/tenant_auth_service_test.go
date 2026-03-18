package service

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"github.com/burakoner/go-ledger-service/internal/tenant"
)

type stubTenantRepo struct {
	findByAPIKeyHashFn func(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error)
	callCount          int
	lastHash           string
}

func (s *stubTenantRepo) FindByAPIKeyHash(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error) {
	s.callCount++
	s.lastHash = apiKeyHash
	if s.findByAPIKeyHashFn == nil {
		return tenant.ContextValue{}, nil
	}
	return s.findByAPIKeyHashFn(ctx, apiKeyHash)
}

func TestResolveAuthorizedTenantValidKey(t *testing.T) {
	t.Parallel()

	plainAPIKey := "TK_ValidKey123"
	expectedTenant := tenant.ContextValue{
		TenantID:     "tenant-id",
		TenantCode:   "merchant-alpha",
		TenantSchema: "tenant_alpha",
		Currency:     "USD",
		Status:       "active",
	}

	repo := &stubTenantRepo{
		findByAPIKeyHashFn: func(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error) {
			if apiKeyHash != tenant.HashAPIKey(plainAPIKey) {
				t.Fatalf("api key hash mismatch: got %q", apiKeyHash)
			}
			return expectedTenant, nil
		},
	}

	svc := NewTenantAuthService(repo)
	got, err := svc.ResolveAuthorizedTenant(context.Background(), plainAPIKey)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != expectedTenant {
		t.Fatalf("tenant mismatch: got %+v want %+v", got, expectedTenant)
	}
	if repo.callCount != 1 {
		t.Fatalf("repository call count mismatch: got %d want 1", repo.callCount)
	}
}

func TestResolveAuthorizedTenantInvalidKey(t *testing.T) {
	t.Parallel()

	repo := &stubTenantRepo{
		findByAPIKeyHashFn: func(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error) {
			return tenant.ContextValue{}, sql.ErrNoRows
		},
	}

	svc := NewTenantAuthService(repo)
	_, err := svc.ResolveAuthorizedTenant(context.Background(), "TK_Missing")
	if !errors.Is(err, ErrInvalidAPIKey) {
		t.Fatalf("expected %v, got %v", ErrInvalidAPIKey, err)
	}
}

func TestResolveAuthorizedTenantSuspendedTenant(t *testing.T) {
	t.Parallel()

	repo := &stubTenantRepo{
		findByAPIKeyHashFn: func(ctx context.Context, apiKeyHash string) (tenant.ContextValue, error) {
			return tenant.ContextValue{
				TenantID:     "tenant-id",
				TenantCode:   "merchant-beta",
				TenantSchema: "tenant_beta",
				Currency:     "EUR",
				Status:       "suspended",
			}, nil
		},
	}

	svc := NewTenantAuthService(repo)
	_, err := svc.ResolveAuthorizedTenant(context.Background(), "TK_Suspended")
	if !errors.Is(err, ErrTenantSuspended) {
		t.Fatalf("expected %v, got %v", ErrTenantSuspended, err)
	}
}

func TestResolveAuthorizedTenantEmptyKey(t *testing.T) {
	t.Parallel()

	repo := &stubTenantRepo{}
	svc := NewTenantAuthService(repo)
	_, err := svc.ResolveAuthorizedTenant(context.Background(), "   ")
	if !errors.Is(err, ErrInvalidAPIKey) {
		t.Fatalf("expected %v, got %v", ErrInvalidAPIKey, err)
	}
	if repo.callCount != 0 {
		t.Fatalf("repository should not be called for empty key, got %d calls", repo.callCount)
	}
}
