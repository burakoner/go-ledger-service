package ratelimiting

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

const (
	defaultWindowDuration   = time.Minute
	defaultRateLimitPrefix  = "rate_limit:tx_submit"
	defaultLimitPerMinute   = 1
	slidingWindowRateScript = `
local key = KEYS[1]
local now_ms = tonumber(ARGV[1])
local window_ms = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local member = ARGV[4]

redis.call('ZREMRANGEBYSCORE', key, '-inf', now_ms - window_ms)

local current = redis.call('ZCARD', key)
if current >= limit then
    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_ms = window_ms
    if oldest ~= nil and #oldest >= 2 then
        local oldest_score = tonumber(oldest[2])
        retry_ms = window_ms - (now_ms - oldest_score)
        if retry_ms < 1 then
            retry_ms = 1
        end
    end
    redis.call('PEXPIRE', key, window_ms)
    return {0, retry_ms, current}
end

redis.call('ZADD', key, now_ms, member)
redis.call('PEXPIRE', key, window_ms)

local remaining = limit - (current + 1)
return {1, 0, remaining}
`
)

type TransactionSubmissionDecision struct {
	Allowed    bool
	RetryAfter time.Duration
	Remaining  int64
	Limit      int
}

type TransactionSubmissionLimiter interface {
	AllowTransactionSubmission(ctx context.Context, tenantID, requestID string) (TransactionSubmissionDecision, error)
}

type RedisSlidingWindowLimiter struct {
	client         redis.Cmdable
	windowDuration time.Duration
	limitPerMinute int
	keyPrefix      string
	script         *redis.Script
}

func NewRedisSlidingWindowLimiter(client redis.Cmdable, limitPerMinute int) *RedisSlidingWindowLimiter {
	if limitPerMinute <= 0 {
		limitPerMinute = defaultLimitPerMinute
	}

	return &RedisSlidingWindowLimiter{
		client:         client,
		windowDuration: defaultWindowDuration,
		limitPerMinute: limitPerMinute,
		keyPrefix:      defaultRateLimitPrefix,
		script:         redis.NewScript(slidingWindowRateScript),
	}
}

func (l *RedisSlidingWindowLimiter) AllowTransactionSubmission(ctx context.Context, tenantID, requestID string) (TransactionSubmissionDecision, error) {
	if l == nil || l.client == nil || l.script == nil {
		return TransactionSubmissionDecision{}, errors.New("rate limiter is not initialized")
	}

	tenantID = strings.TrimSpace(tenantID)
	if tenantID == "" {
		return TransactionSubmissionDecision{}, errors.New("tenant id is required for rate limiting")
	}

	now := time.Now().UTC()
	nowMillis := now.UnixMilli()
	windowMillis := l.windowDuration.Milliseconds()
	if windowMillis <= 0 {
		windowMillis = defaultWindowDuration.Milliseconds()
	}

	member := fmt.Sprintf("%d-%s", now.UnixNano(), strings.TrimSpace(requestID))
	key := fmt.Sprintf("%s:%s", l.keyPrefix, tenantID)

	result, err := l.script.Run(
		ctx,
		l.client,
		[]string{key},
		nowMillis,
		windowMillis,
		l.limitPerMinute,
		member,
	).Result()
	if err != nil {
		return TransactionSubmissionDecision{}, fmt.Errorf("run redis sliding window script: %w", err)
	}

	values, ok := result.([]interface{})
	if !ok || len(values) < 3 {
		return TransactionSubmissionDecision{}, fmt.Errorf("unexpected redis script result: %T", result)
	}

	allowedInt, err := toInt64(values[0])
	if err != nil {
		return TransactionSubmissionDecision{}, fmt.Errorf("parse allowed flag: %w", err)
	}

	retryAfterMillis, err := toInt64(values[1])
	if err != nil {
		return TransactionSubmissionDecision{}, fmt.Errorf("parse retry-after milliseconds: %w", err)
	}
	if retryAfterMillis < 0 {
		retryAfterMillis = 0
	}

	remaining, err := toInt64(values[2])
	if err != nil {
		return TransactionSubmissionDecision{}, fmt.Errorf("parse remaining count: %w", err)
	}

	return TransactionSubmissionDecision{
		Allowed:    allowedInt == 1,
		RetryAfter: time.Duration(retryAfterMillis) * time.Millisecond,
		Remaining:  remaining,
		Limit:      l.limitPerMinute,
	}, nil
}

func toInt64(value interface{}) (int64, error) {
	switch v := value.(type) {
	case int64:
		return v, nil
	case int32:
		return int64(v), nil
	case int:
		return int64(v), nil
	case float64:
		return int64(v), nil
	case string:
		parsed, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return 0, err
		}
		return parsed, nil
	default:
		return 0, fmt.Errorf("unsupported numeric value type %T", value)
	}
}
