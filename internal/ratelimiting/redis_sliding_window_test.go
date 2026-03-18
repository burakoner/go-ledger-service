package ratelimiting

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	redis "github.com/redis/go-redis/v9"
)

func newTestSlidingLimiter(t *testing.T, limitPerMinute int) (*RedisSlidingWindowLimiter, *miniredis.Miniredis) {
	t.Helper()

	server, err := miniredis.Run()
	if err != nil {
		t.Fatalf("run miniredis: %v", err)
	}
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() {
		_ = client.Close()
		server.Close()
	})

	return NewRedisSlidingWindowLimiter(client, limitPerMinute), server
}

func TestSlidingWindowAllowsFirstNThenRejects(t *testing.T) {
	t.Parallel()

	limiter, _ := newTestSlidingLimiter(t, 2)
	ctx := context.Background()

	first, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-1")
	if err != nil {
		t.Fatalf("first allow failed: %v", err)
	}
	if !first.Allowed {
		t.Fatalf("first request must be allowed")
	}
	if first.Limit != 2 {
		t.Fatalf("limit mismatch on first request: got %d", first.Limit)
	}

	second, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-2")
	if err != nil {
		t.Fatalf("second allow failed: %v", err)
	}
	if !second.Allowed {
		t.Fatalf("second request must be allowed")
	}

	third, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-3")
	if err != nil {
		t.Fatalf("third allow failed: %v", err)
	}
	if third.Allowed {
		t.Fatalf("third request must be rejected")
	}
	if third.RetryAfter <= 0 {
		t.Fatalf("retry-after should be positive on rejection, got %s", third.RetryAfter)
	}
	if third.RetryAfter > time.Minute {
		t.Fatalf("retry-after should be <= 1m, got %s", third.RetryAfter)
	}
}

func TestSlidingWindowTenantIsolation(t *testing.T) {
	t.Parallel()

	limiter, _ := newTestSlidingLimiter(t, 1)
	ctx := context.Background()

	a1, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-1")
	if err != nil {
		t.Fatalf("tenant-a first request failed: %v", err)
	}
	if !a1.Allowed {
		t.Fatalf("tenant-a first request must be allowed")
	}

	a2, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-2")
	if err != nil {
		t.Fatalf("tenant-a second request failed: %v", err)
	}
	if a2.Allowed {
		t.Fatalf("tenant-a second request must be rejected")
	}

	b1, err := limiter.AllowTransactionSubmission(ctx, "tenant-b", "req-1")
	if err != nil {
		t.Fatalf("tenant-b first request failed: %v", err)
	}
	if !b1.Allowed {
		t.Fatalf("tenant-b should not be affected by tenant-a limit")
	}
}

func TestSlidingWindowRejectsEmptyTenantID(t *testing.T) {
	t.Parallel()

	limiter, _ := newTestSlidingLimiter(t, 5)
	_, err := limiter.AllowTransactionSubmission(context.Background(), "   ", "req-1")
	if err == nil {
		t.Fatalf("expected error for empty tenant id")
	}
}

func TestSlidingWindowInvalidLimitFallsBackToDefault(t *testing.T) {
	t.Parallel()

	limiter, _ := newTestSlidingLimiter(t, 0)
	ctx := context.Background()

	first, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-1")
	if err != nil {
		t.Fatalf("first request failed: %v", err)
	}
	if !first.Allowed {
		t.Fatalf("first request should be allowed with default limit")
	}
	if first.Limit != defaultLimitPerMinute {
		t.Fatalf("expected default limit %d, got %d", defaultLimitPerMinute, first.Limit)
	}

	second, err := limiter.AllowTransactionSubmission(ctx, "tenant-a", "req-2")
	if err != nil {
		t.Fatalf("second request failed: %v", err)
	}
	if second.Allowed {
		t.Fatalf("second request should be rejected with default limit 1")
	}
}
