package worker

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	webhookProcessTimeout      = 15 * time.Second
	webhookRequestTimeout      = 5 * time.Second
	webhookMinRetry            = 1
	webhookMaxRetry            = 10
	webhookDefaultRetry        = 3
	webhookBaseBackoff         = 5 * time.Second
	webhookMaxBackoff          = 5 * time.Minute
	webhookEnabledConfigKey    = "webhook_enabled"
	webhookURLConfigKey        = "webhook_url"
	webhookRetryConfigKey      = "webhook_retry"
	webhookHTTPStatusFailStart = 400
)

type pendingWebhook struct {
	OutboxID      int64
	Payload       []byte
	AttemptCount  int
	TenantID      string
	TransactionID string
}

type webhookConfig struct {
	Enabled bool
	URL     string
	Retry   int
}

type processedWebhook struct {
	OutboxID      int64
	Status        string
	AttemptCount  int
	NextAttemptAt *time.Time
}

func (r *runtime) processNextPendingWebhook(ctx context.Context, tenantValue activeTenant) (*processedWebhook, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("worker runtime is not initialized")
	}
	if r.httpClient == nil {
		return nil, errors.New("worker runtime http client is not initialized")
	}

	processCtx, cancel := context.WithTimeout(ctx, webhookProcessTimeout)
	defer cancel()

	tx, err := r.db.BeginTx(processCtx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, fmt.Errorf("begin webhook transaction: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	row, found, err := claimPendingWebhook(processCtx, tx, tenantValue.TenantID)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}

	cfg, err := loadWebhookConfig(processCtx, tx, tenantValue.TenantID)
	if err != nil {
		return nil, err
	}

	if !cfg.Enabled {
		if err := markWebhookDead(processCtx, tx, row.OutboxID, row.AttemptCount, "webhook is disabled for tenant"); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit webhook dead update: %w", err)
		}
		return &processedWebhook{
			OutboxID:     row.OutboxID,
			Status:       "dead",
			AttemptCount: row.AttemptCount,
		}, nil
	}

	if strings.TrimSpace(cfg.URL) == "" {
		if err := markWebhookDead(processCtx, tx, row.OutboxID, row.AttemptCount, "webhook url is missing"); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit webhook dead update: %w", err)
		}
		return &processedWebhook{
			OutboxID:     row.OutboxID,
			Status:       "dead",
			AttemptCount: row.AttemptCount,
		}, nil
	}

	sendCtx, sendCancel := context.WithTimeout(processCtx, webhookRequestTimeout)
	deliveryErr := sendWebhook(sendCtx, r.httpClient, cfg.URL, row.Payload)
	sendCancel()
	newAttemptCount := row.AttemptCount + 1

	if deliveryErr == nil {
		if err := markWebhookSent(processCtx, tx, row.OutboxID, newAttemptCount); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit webhook sent update: %w", err)
		}
		return &processedWebhook{
			OutboxID:     row.OutboxID,
			Status:       "sent",
			AttemptCount: newAttemptCount,
		}, nil
	}

	if newAttemptCount >= cfg.Retry {
		if err := markWebhookDead(processCtx, tx, row.OutboxID, newAttemptCount, deliveryErr.Error()); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit webhook dead retry update: %w", err)
		}
		return &processedWebhook{
			OutboxID:     row.OutboxID,
			Status:       "dead",
			AttemptCount: newAttemptCount,
		}, nil
	}

	nextAttemptAt := time.Now().UTC().Add(calculateWebhookBackoff(newAttemptCount))
	if err := rescheduleWebhook(processCtx, tx, row.OutboxID, newAttemptCount, nextAttemptAt, deliveryErr.Error()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit webhook reschedule update: %w", err)
	}

	return &processedWebhook{
		OutboxID:      row.OutboxID,
		Status:        "pending",
		AttemptCount:  newAttemptCount,
		NextAttemptAt: &nextAttemptAt,
	}, nil
}

func claimPendingWebhook(ctx context.Context, tx *sql.Tx, tenantID string) (pendingWebhook, bool, error) {
	const query = `
		SELECT id, payload, attempt_count, tenant_id::text, transaction_id::text
		FROM public.tenant_webhook_outbox
		WHERE tenant_id = $1::uuid
		  AND status = 'pending'
		  AND next_attempt_at <= now()
		ORDER BY next_attempt_at ASC, id ASC
		FOR UPDATE SKIP LOCKED
		LIMIT 1
	`

	var row pendingWebhook
	err := tx.QueryRowContext(ctx, query, tenantID).Scan(
		&row.OutboxID,
		&row.Payload,
		&row.AttemptCount,
		&row.TenantID,
		&row.TransactionID,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return pendingWebhook{}, false, nil
	}
	if err != nil {
		return pendingWebhook{}, false, fmt.Errorf("claim pending webhook for tenant %s: %w", tenantID, err)
	}

	return row, true, nil
}

func loadWebhookConfig(ctx context.Context, tx *sql.Tx, tenantID string) (webhookConfig, error) {
	const query = `
		SELECT key, value
		FROM public.tenant_configs
		WHERE tenant_id = $1::uuid
		  AND key IN ($2, $3, $4)
	`

	cfg := webhookConfig{
		Enabled: false,
		URL:     "",
		Retry:   webhookDefaultRetry,
	}

	rows, err := tx.QueryContext(ctx, query, tenantID, webhookEnabledConfigKey, webhookURLConfigKey, webhookRetryConfigKey)
	if err != nil {
		return webhookConfig{}, fmt.Errorf("query webhook configs for tenant %s: %w", tenantID, err)
	}
	defer func() {
		_ = rows.Close()
	}()

	for rows.Next() {
		var key string
		var raw []byte
		if err := rows.Scan(&key, &raw); err != nil {
			return webhookConfig{}, fmt.Errorf("scan webhook config row: %w", err)
		}

		switch key {
		case webhookEnabledConfigKey:
			if len(raw) == 0 || string(raw) == "null" {
				cfg.Enabled = false
				continue
			}
			var value bool
			if err := json.Unmarshal(raw, &value); err != nil {
				return webhookConfig{}, fmt.Errorf("parse webhook_enabled config: %w", err)
			}
			cfg.Enabled = value
		case webhookURLConfigKey:
			if len(raw) == 0 || string(raw) == "null" {
				cfg.URL = ""
				continue
			}
			var value string
			if err := json.Unmarshal(raw, &value); err != nil {
				return webhookConfig{}, fmt.Errorf("parse webhook_url config: %w", err)
			}
			cfg.URL = strings.TrimSpace(value)
		case webhookRetryConfigKey:
			if len(raw) == 0 || string(raw) == "null" {
				cfg.Retry = webhookDefaultRetry
				continue
			}

			parsedRetry, err := parseWebhookRetryJSON(raw)
			if err != nil {
				return webhookConfig{}, err
			}
			cfg.Retry = parsedRetry
		}
	}
	if err := rows.Err(); err != nil {
		return webhookConfig{}, fmt.Errorf("iterate webhook config rows: %w", err)
	}

	if cfg.Retry < webhookMinRetry {
		cfg.Retry = webhookMinRetry
	}
	if cfg.Retry > webhookMaxRetry {
		cfg.Retry = webhookMaxRetry
	}

	return cfg, nil
}

func parseWebhookRetryJSON(raw []byte) (int, error) {
	var asInt int
	if err := json.Unmarshal(raw, &asInt); err == nil {
		return asInt, nil
	}

	var asFloat float64
	if err := json.Unmarshal(raw, &asFloat); err == nil {
		if asFloat != float64(int(asFloat)) {
			return 0, errors.New("webhook_retry config must be integer")
		}
		return int(asFloat), nil
	}

	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		parsed, parseErr := strconv.Atoi(strings.TrimSpace(asString))
		if parseErr != nil {
			return 0, errors.New("webhook_retry config must be integer")
		}
		return parsed, nil
	}

	return 0, errors.New("webhook_retry config must be integer")
}

func sendWebhook(ctx context.Context, client *http.Client, endpoint string, payload []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build webhook request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("execute webhook request: %w", err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()

	if resp.StatusCode >= webhookHTTPStatusFailStart {
		return fmt.Errorf("webhook endpoint responded with status %d", resp.StatusCode)
	}

	return nil
}

func markWebhookSent(ctx context.Context, tx *sql.Tx, outboxID int64, attemptCount int) error {
	const query = `
		UPDATE public.tenant_webhook_outbox
		SET
			status = 'sent',
			attempt_count = $2,
			last_error = NULL,
			updated_at = now()
		WHERE id = $1
	`
	if _, err := tx.ExecContext(ctx, query, outboxID, attemptCount); err != nil {
		return fmt.Errorf("mark webhook as sent (outbox_id=%d): %w", outboxID, err)
	}
	return nil
}

func markWebhookDead(ctx context.Context, tx *sql.Tx, outboxID int64, attemptCount int, lastError string) error {
	const query = `
		UPDATE public.tenant_webhook_outbox
		SET
			status = 'dead',
			attempt_count = $2,
			last_error = $3,
			updated_at = now()
		WHERE id = $1
	`
	if _, err := tx.ExecContext(ctx, query, outboxID, attemptCount, truncateError(lastError)); err != nil {
		return fmt.Errorf("mark webhook as dead (outbox_id=%d): %w", outboxID, err)
	}
	return nil
}

func rescheduleWebhook(ctx context.Context, tx *sql.Tx, outboxID int64, attemptCount int, nextAttemptAt time.Time, lastError string) error {
	const query = `
		UPDATE public.tenant_webhook_outbox
		SET
			status = 'pending',
			attempt_count = $2,
			next_attempt_at = $3,
			last_error = $4,
			updated_at = now()
		WHERE id = $1
	`
	if _, err := tx.ExecContext(ctx, query, outboxID, attemptCount, nextAttemptAt, truncateError(lastError)); err != nil {
		return fmt.Errorf("reschedule webhook (outbox_id=%d): %w", outboxID, err)
	}
	return nil
}

func calculateWebhookBackoff(attemptCount int) time.Duration {
	if attemptCount < 1 {
		attemptCount = 1
	}

	backoff := webhookBaseBackoff
	for i := 1; i < attemptCount; i++ {
		backoff *= 2
		if backoff >= webhookMaxBackoff {
			return webhookMaxBackoff
		}
	}

	if backoff > webhookMaxBackoff {
		return webhookMaxBackoff
	}
	return backoff
}

func truncateError(message string) string {
	const maxLength = 800
	message = strings.TrimSpace(message)
	if len(message) <= maxLength {
		return message
	}
	return message[:maxLength]
}
