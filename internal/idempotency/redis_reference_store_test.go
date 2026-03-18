package idempotency

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	redis "github.com/redis/go-redis/v9"
)

func newTestReferenceStore(t *testing.T) (*RedisReferenceStore, *miniredis.Miniredis) {
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

	return NewRedisReferenceStore(client), server
}

func TestBeginAcquireAndTenantIsolation(t *testing.T) {
	t.Parallel()

	store, _ := newTestReferenceStore(t)
	ctx := context.Background()

	first, err := store.Begin(ctx, "tenant-a", "ref-1", "req-1", time.Minute)
	if err != nil {
		t.Fatalf("unexpected error on first begin: %v", err)
	}
	if !first.Acquired {
		t.Fatalf("first begin must acquire lock")
	}

	second, err := store.Begin(ctx, "tenant-a", "ref-1", "req-2", time.Minute)
	if err != nil {
		t.Fatalf("unexpected error on second begin: %v", err)
	}
	if second.Acquired {
		t.Fatalf("second begin must not acquire lock")
	}
	if !second.InProgress {
		t.Fatalf("second begin must report in-progress")
	}

	otherTenant, err := store.Begin(ctx, "tenant-b", "ref-1", "req-3", time.Minute)
	if err != nil {
		t.Fatalf("unexpected error on isolated tenant begin: %v", err)
	}
	if !otherTenant.Acquired {
		t.Fatalf("same reference in different tenant should acquire lock")
	}
}

func TestMarkCompletedAndPeek(t *testing.T) {
	t.Parallel()

	store, _ := newTestReferenceStore(t)
	ctx := context.Background()

	if _, err := store.Begin(ctx, "tenant-a", "ref-2", "req-1", time.Minute); err != nil {
		t.Fatalf("begin failed: %v", err)
	}

	cached := CachedResponse{
		StatusCode: 202,
		Body:       []byte(`{"id":"txn-2","status":"pending"}`),
	}
	if err := store.MarkCompleted(ctx, "tenant-a", "ref-2", "txn-2", cached, time.Minute); err != nil {
		t.Fatalf("mark completed failed: %v", err)
	}

	got, err := store.Peek(ctx, "tenant-a", "ref-2")
	if err != nil {
		t.Fatalf("peek failed: %v", err)
	}
	if got.CompletedTransactionID != "txn-2" {
		t.Fatalf("transaction id mismatch: got %q", got.CompletedTransactionID)
	}
	if got.CompletedResponse == nil {
		t.Fatalf("completed response expected")
	}
	if got.CompletedResponse.StatusCode != 202 {
		t.Fatalf("status code mismatch: got %d", got.CompletedResponse.StatusCode)
	}
	if string(got.CompletedResponse.Body) != `{"id":"txn-2","status":"pending"}` {
		t.Fatalf("cached body mismatch: got %s", string(got.CompletedResponse.Body))
	}
}

func TestClearRemovesState(t *testing.T) {
	t.Parallel()

	store, _ := newTestReferenceStore(t)
	ctx := context.Background()

	if err := store.MarkCompleted(
		ctx,
		"tenant-a",
		"ref-3",
		"txn-3",
		CachedResponse{StatusCode: 202, Body: []byte(`{"ok":true}`)},
		time.Minute,
	); err != nil {
		t.Fatalf("mark completed failed: %v", err)
	}

	if err := store.Clear(ctx, "tenant-a", "ref-3"); err != nil {
		t.Fatalf("clear failed: %v", err)
	}

	got, err := store.Peek(ctx, "tenant-a", "ref-3")
	if err != nil {
		t.Fatalf("peek failed: %v", err)
	}
	if got.Acquired || got.InProgress || got.CompletedTransactionID != "" || got.CompletedResponse != nil {
		t.Fatalf("expected empty state after clear, got %+v", got)
	}
}

func TestBeginTTLExpiry(t *testing.T) {
	t.Parallel()

	store, server := newTestReferenceStore(t)
	ctx := context.Background()

	if _, err := store.Begin(ctx, "tenant-a", "ref-ttl", "req-ttl", time.Second); err != nil {
		t.Fatalf("begin failed: %v", err)
	}

	server.FastForward(2 * time.Second)

	got, err := store.Peek(ctx, "tenant-a", "ref-ttl")
	if err != nil {
		t.Fatalf("peek failed: %v", err)
	}
	if got.Acquired || got.InProgress || got.CompletedTransactionID != "" || got.CompletedResponse != nil {
		t.Fatalf("expected empty state after ttl expiry, got %+v", got)
	}
}
