package idempotency

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

const (
	pendingValuePrefix   = "pending:" // legacy format support
	completedValuePrefix = "done:"    // legacy format support
	defaultReferenceTTL  = 24 * time.Hour
	keyPrefix            = "idempotency:txn"
	statePending         = "pending"
	stateCompleted       = "completed"
)

// CachedResponse stores the original HTTP response for exact idempotent replay.
type CachedResponse struct {
	StatusCode int             `json:"status_code"`
	Body       json.RawMessage `json:"body"`
}

// BeginResult describes lock state for a tenant+reference combination.
type BeginResult struct {
	Acquired               bool
	CompletedTransactionID string
	CompletedResponse      *CachedResponse
	InProgress             bool
}

// ReferenceStore provides idempotency control for transaction references.
type ReferenceStore interface {
	Begin(ctx context.Context, tenantID, reference, requestID string, ttl time.Duration) (BeginResult, error)
	Peek(ctx context.Context, tenantID, reference string) (BeginResult, error)
	MarkCompleted(ctx context.Context, tenantID, reference, transactionID string, cachedResponse CachedResponse, ttl time.Duration) error
	Clear(ctx context.Context, tenantID, reference string) error
}

type RedisReferenceStore struct {
	client redis.Cmdable
}

type referenceStateRecord struct {
	State         string          `json:"state"`
	RequestID     string          `json:"request_id,omitempty"`
	TransactionID string          `json:"transaction_id,omitempty"`
	StatusCode    int             `json:"status_code,omitempty"`
	Body          json.RawMessage `json:"body,omitempty"`
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
	pendingRecord := referenceStateRecord{
		State:     statePending,
		RequestID: requestID,
	}
	pendingValueRaw, err := json.Marshal(pendingRecord)
	if err != nil {
		return BeginResult{}, fmt.Errorf("marshal pending idempotency state: %w", err)
	}

	acquired, err := s.client.SetNX(ctx, key, pendingValueRaw, ttl).Result()
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

	return decodeStateValue(currentValue), nil
}

// Peek reads the current idempotency key state without trying to acquire a new lock.
func (s *RedisReferenceStore) Peek(ctx context.Context, tenantID, reference string) (BeginResult, error) {
	if s == nil || s.client == nil {
		return BeginResult{}, errors.New("idempotency redis store is not initialized")
	}

	tenantID = strings.TrimSpace(tenantID)
	reference = strings.TrimSpace(reference)
	if tenantID == "" || reference == "" {
		return BeginResult{}, errors.New("tenant id and reference are required")
	}

	key := buildKey(tenantID, reference)
	currentValue, err := s.client.Get(ctx, key).Result()
	if err != nil {
		if err == redis.Nil {
			return BeginResult{}, nil
		}
		return BeginResult{}, fmt.Errorf("get idempotency key: %w", err)
	}

	return decodeStateValue(currentValue), nil
}

// MarkCompleted stores created transaction id for replay responses.
func (s *RedisReferenceStore) MarkCompleted(
	ctx context.Context,
	tenantID,
	reference,
	transactionID string,
	cachedResponse CachedResponse,
	ttl time.Duration,
) error {
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
	bodyCopy := append([]byte(nil), cachedResponse.Body...)
	completedRecord := referenceStateRecord{
		State:         stateCompleted,
		TransactionID: transactionID,
		StatusCode:    cachedResponse.StatusCode,
		Body:          bodyCopy,
	}
	valueRaw, err := json.Marshal(completedRecord)
	if err != nil {
		return fmt.Errorf("marshal completed idempotency state: %w", err)
	}

	if err := s.client.Set(ctx, key, valueRaw, ttl).Err(); err != nil {
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

func parseStateRecord(raw string) (referenceStateRecord, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return referenceStateRecord{}, false
	}

	var record referenceStateRecord
	if err := json.Unmarshal([]byte(raw), &record); err != nil {
		return referenceStateRecord{}, false
	}
	if record.State == "" {
		return referenceStateRecord{}, false
	}

	return record, true
}

func decodeStateValue(raw string) BeginResult {
	if parsedRecord, ok := parseStateRecord(raw); ok {
		switch parsedRecord.State {
		case stateCompleted:
			result := BeginResult{
				CompletedTransactionID: strings.TrimSpace(parsedRecord.TransactionID),
			}
			if parsedRecord.StatusCode > 0 && len(parsedRecord.Body) > 0 {
				bodyCopy := append([]byte(nil), parsedRecord.Body...)
				result.CompletedResponse = &CachedResponse{
					StatusCode: parsedRecord.StatusCode,
					Body:       bodyCopy,
				}
			}
			return result
		case statePending:
			return BeginResult{InProgress: true}
		}
	}

	if strings.HasPrefix(raw, completedValuePrefix) {
		transactionID := strings.TrimPrefix(raw, completedValuePrefix)
		if transactionID != "" {
			return BeginResult{
				CompletedTransactionID: transactionID,
			}
		}
	}

	if raw == "" {
		return BeginResult{}
	}

	return BeginResult{InProgress: true}
}
