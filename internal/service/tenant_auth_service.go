package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

var (
	ErrInvalidAPIKey   = errors.New("invalid API key")
	ErrTenantSuspended = errors.New("tenant is suspended")
)

// TenantAuthService defines tenant authentication and authorization operations.
type TenantAuthService interface {
	ResolveAuthorizedTenant(ctx context.Context, plainAPIKey string) (tenant.ContextValue, error)
}

type tenantAuthService struct {
	tenantRepo repository.TenantRepository
}

// NewTenantAuthService creates tenant auth service with repository dependency.
func NewTenantAuthService(tenantRepo repository.TenantRepository) TenantAuthService {
	return &tenantAuthService{tenantRepo: tenantRepo}
}

// ResolveAuthorizedTenant resolves tenant from API key and validates active status.
func (s *tenantAuthService) ResolveAuthorizedTenant(ctx context.Context, plainAPIKey string) (tenant.ContextValue, error) {
	plainAPIKey = strings.TrimSpace(plainAPIKey)
	if plainAPIKey == "" {
		return tenant.ContextValue{}, ErrInvalidAPIKey
	}

	apiKeyHash := tenant.HashAPIKey(plainAPIKey)
	tenantValue, err := s.tenantRepo.FindByAPIKeyHash(ctx, apiKeyHash)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return tenant.ContextValue{}, ErrInvalidAPIKey
		}
		return tenant.ContextValue{}, fmt.Errorf("resolve tenant by API key: %w", err)
	}

	if tenantValue.Status != "active" {
		return tenant.ContextValue{}, ErrTenantSuspended
	}

	return tenantValue, nil
}
