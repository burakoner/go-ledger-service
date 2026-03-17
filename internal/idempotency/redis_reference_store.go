package idempotency

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

const (
	pendingValuePrefix   = "pending:"
	completedValuePrefix = "done:"
	defaultReferenceTTL  = 24 * time.Hour
	keyPrefix            = "idempotency:txn"
)

// BeginResult describes lock state for a tenant+reference combination.
type BeginResult struct {
	Acquired               bool
	CompletedTransactionID string
	InProgress             bool
}

// ReferenceStore provides idempotency control for transaction references.
type ReferenceStore interface {
	Begin(ctx context.Context, tenantID, reference, requestID string, ttl time.Duration) (BeginResult, error)
	MarkCompleted(ctx context.Context, tenantID, reference, transactionID string, ttl time.Duration) error
	Clear(ctx context.Context, tenantID, reference string) error
}

type RedisReferenceStore struct {
	client redis.Cmdable
}

// NewRedisReferenceStore builds a redis-backed reference idempotency store.
func NewRedisReferenceStore(client redis.Cmdable) *RedisReferenceStore {
	return &RedisReferenceStore{client: client}
}

// Begin acquires idempotency key if missing, otherwise returns existing state.
func (s *RedisReferenceStore) Begin(ctx context.Context, tenantID, reference, requestID string, ttl time.Duration) (BeginResult, error) {
	if s == nil || s.client == nil {
		return BeginResult{}, errors.New("idempotency redis store is not initialized")
	}

	tenantID = strings.TrimSpace(tenantID)
	reference = strings.TrimSpace(reference)
	requestID = strings.TrimSpace(requestID)
	if tenantID == "" || reference == "" {
		return BeginResult{}, errors.New("tenant id and reference are required")
	}
	if requestID == "" {
		requestID = "unknown"
	}
	if ttl <= 0 {
		ttl = defaultReferenceTTL
	}

	key := buildKey(tenantID, reference)
	pendingValue := pendingValuePrefix + requestID

	acquired, err := s.client.SetNX(ctx, key, pendingValue, ttl).Result()
	if err != nil {
		return BeginResult{}, fmt.Errorf("set idempotency key: %w", err)
	}
	if acquired {
		return BeginResult{Acquired: true}, nil
	}

	currentValue, err := s.client.Get(ctx, key).Result()
	if err != nil && err != redis.Nil {
		return BeginResult{}, fmt.Errorf("get idempotency key: %w", err)
	}

	if strings.HasPrefix(currentValue, completedValuePrefix) {
		transactionID := strings.TrimPrefix(currentValue, completedValuePrefix)
		if transactionID != "" {
			return BeginResult{
				CompletedTransactionID: transactionID,
			}, nil
		}
	}

	return BeginResult{InProgress: true}, nil
}

// MarkCompleted stores created transaction id for replay responses.
func (s *RedisReferenceStore) MarkCompleted(ctx context.Context, tenantID, reference, transactionID string, ttl time.Duration) error {
	if s == nil || s.client == nil {
		return errors.New("idempotency redis store is not initialized")
	}

	tenantID = strings.TrimSpace(tenantID)
	reference = strings.TrimSpace(reference)
	transactionID = strings.TrimSpace(transactionID)
	if tenantID == "" || reference == "" || transactionID == "" {
		return errors.New("tenant id, reference and transaction id are required")
	}
	if ttl <= 0 {
		ttl = defaultReferenceTTL
	}

	key := buildKey(tenantID, reference)
	value := completedValuePrefix + transactionID
	if err := s.client.Set(ctx, key, value, ttl).Err(); err != nil {
		return fmt.Errorf("store completed idempotency key: %w", err)
	}

	return nil
}

// Clear deletes idempotency key when transaction creation fails.
func (s *RedisReferenceStore) Clear(ctx context.Context, tenantID, reference string) error {
	if s == nil || s.client == nil {
		return errors.New("idempotency redis store is not initialized")
	}

	tenantID = strings.TrimSpace(tenantID)
	reference = strings.TrimSpace(reference)
	if tenantID == "" || reference == "" {
		return errors.New("tenant id and reference are required")
	}

	key := buildKey(tenantID, reference)
	if err := s.client.Del(ctx, key).Err(); err != nil {
		return fmt.Errorf("delete idempotency key: %w", err)
	}

	return nil
}

func buildKey(tenantID, reference string) string {
	return keyPrefix + ":" + tenantID + ":" + reference
}
