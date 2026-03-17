package tenant

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
)

// ContextValue stores tenant metadata that travels in request context.
type ContextValue struct {
	TenantID     string
	TenantCode   string
	TenantSchema string
	Currency     string
	Status       string
}

type contextKey struct{}

// WithContext stores tenant metadata into a context.
func WithContext(ctx context.Context, tenant ContextValue) context.Context {
	return context.WithValue(ctx, contextKey{}, tenant)
}

// FromContext reads tenant metadata from a context.
func FromContext(ctx context.Context) (ContextValue, bool) {
	value, ok := ctx.Value(contextKey{}).(ContextValue)
	return value, ok
}

// HashAPIKey hashes a plain API key for deterministic DB lookups.
func HashAPIKey(plainAPIKey string) string {
	sum := sha256.Sum256([]byte(plainAPIKey))
	return hex.EncodeToString(sum[:])
}

