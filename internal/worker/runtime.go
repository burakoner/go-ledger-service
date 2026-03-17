package worker

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/burakoner/go-ledger-service/internal/config"
	"github.com/burakoner/go-ledger-service/internal/db"
	"github.com/burakoner/go-ledger-service/internal/tenant"
)

const (
	tenantRefreshInterval  = 15 * time.Second
	tenantDispatchInterval = 2 * time.Second
	tenantQueryTimeout     = 5 * time.Second
	jobQueueMultiplier     = 8
)

type activeTenant struct {
	TenantID     string
	TenantSchema string
}

type runtime struct {
	db          *sql.DB
	workerCount int

	mu      sync.RWMutex
	tenants []activeTenant
}

func Run(ctx context.Context, cfg config.LedgerWorkerConfig) error {
	if cfg.WorkerCount <= 0 {
		return errors.New("worker count must be greater than 0")
	}

	postgresDB, err := db.OpenPostgres(cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("open database connection: %w", err)
	}
	defer func() {
		if closeErr := postgresDB.Close(); closeErr != nil {
			log.Printf("failed to close database connection: %v", closeErr)
		}
	}()

	if err := db.Ping(ctx, postgresDB, 5*time.Second); err != nil {
		return fmt.Errorf("ping database: %w", err)
	}

	r := &runtime{
		db:          postgresDB,
		workerCount: cfg.WorkerCount,
	}
	return r.run(ctx)
}

func (r *runtime) run(ctx context.Context) error {
	if err := r.refreshActiveTenants(ctx); err != nil {
		return fmt.Errorf("initial tenant refresh: %w", err)
	}

	queueSize := r.workerCount * jobQueueMultiplier
	if queueSize < 1 {
		queueSize = 1
	}

	tenantJobs := make(chan activeTenant, queueSize)

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		r.tenantRefreshLoop(ctx)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		r.dispatchLoop(ctx, tenantJobs)
	}()

	for i := 0; i < r.workerCount; i++ {
		workerID := i + 1
		wg.Add(1)
		go func() {
			defer wg.Done()
			r.transactionWorkerLoop(ctx, workerID, tenantJobs)
		}()
	}

	<-ctx.Done()
	log.Printf("ledger-worker shutdown signal received. Waiting for in-flight work.")
	wg.Wait()
	log.Printf("ledger-worker stopped gracefully.")
	return nil
}

func (r *runtime) tenantRefreshLoop(ctx context.Context) {
	ticker := time.NewTicker(tenantRefreshInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := r.refreshActiveTenants(ctx); err != nil {
				log.Printf("tenant refresh failed: %v", err)
			}
		}
	}
}

func (r *runtime) dispatchLoop(ctx context.Context, jobs chan activeTenant) {
	defer close(jobs)

	ticker := time.NewTicker(tenantDispatchInterval)
	defer ticker.Stop()

	// Run once immediately so the worker can start processing without waiting for ticker.
	r.enqueueTenantJobs(ctx, jobs)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.enqueueTenantJobs(ctx, jobs)
		}
	}
}

func (r *runtime) transactionWorkerLoop(ctx context.Context, workerID int, jobs <-chan activeTenant) {
	log.Printf("transaction worker-%d started.", workerID)
	defer log.Printf("transaction worker-%d stopped.", workerID)

	for {
		select {
		case <-ctx.Done():
			return
		case tenantValue, ok := <-jobs:
			if !ok {
				return
			}

			processed, err := r.processNextPendingTransaction(ctx, tenantValue)
			if err != nil {
				log.Printf("worker-%d failed for tenant=%s schema=%s: %v", workerID, tenantValue.TenantID, tenantValue.TenantSchema, err)
				continue
			}
			if processed == nil {
				continue
			}

			log.Printf(
				"worker-%d processed transaction id=%s reference=%s status=%s tenant=%s schema=%s",
				workerID,
				processed.TransactionID,
				processed.Reference,
				processed.Status,
				processed.TenantID,
				processed.TenantSchema,
			)
		}
	}
}

func (r *runtime) refreshActiveTenants(ctx context.Context) error {
	if r == nil || r.db == nil {
		return errors.New("worker runtime is not initialized")
	}

	queryCtx, cancel := context.WithTimeout(ctx, tenantQueryTimeout)
	defer cancel()

	rows, err := r.db.QueryContext(
		queryCtx,
		`SELECT id::text, schema
		FROM public.tenant_accounts
		WHERE status = 'active'
		ORDER BY created_at ASC`,
	)
	if err != nil {
		return fmt.Errorf("query active tenants: %w", err)
	}
	defer func() {
		_ = rows.Close()
	}()

	tenants := make([]activeTenant, 0, 16)
	for rows.Next() {
		var row activeTenant
		if err := rows.Scan(&row.TenantID, &row.TenantSchema); err != nil {
			return fmt.Errorf("scan active tenant row: %w", err)
		}

		if !tenant.IsValidSchemaName(row.TenantSchema) {
			log.Printf("active tenant skipped because of invalid schema name tenant=%s schema=%q", row.TenantID, row.TenantSchema)
			continue
		}

		tenants = append(tenants, row)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate active tenant rows: %w", err)
	}

	r.mu.Lock()
	r.tenants = tenants
	r.mu.Unlock()

	log.Printf("active tenant list refreshed. count=%d", len(tenants))
	return nil
}

func (r *runtime) snapshotTenants() []activeTenant {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if len(r.tenants) == 0 {
		return nil
	}

	result := make([]activeTenant, len(r.tenants))
	copy(result, r.tenants)
	return result
}

func (r *runtime) enqueueTenantJobs(ctx context.Context, jobs chan<- activeTenant) {
	tenants := r.snapshotTenants()
	if len(tenants) == 0 {
		return
	}

	for _, tenantValue := range tenants {
		select {
		case <-ctx.Done():
			return
		case jobs <- tenantValue:
		default:
			// Queue is full, worker goroutines are still busy.
			return
		}
	}
}
