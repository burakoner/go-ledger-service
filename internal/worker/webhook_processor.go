package worker

import (
	"bytes"
	"context"
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
	webhookConfigLoadTimeout     = 5 * time.Second
	webhookRequestTimeout        = 5 * time.Second
	webhookEnabledConfigKey      = "webhook_enabled"
	webhookURLConfigKey          = "webhook_url"
	webhookRetryConfigKey        = "webhook_retry"
	webhookDelaySecondsConfigKey = "webhook_delay_seconds"
	webhookDefaultRetry          = 3
	webhookMinRetry              = 1
	webhookMaxRetry              = 10
	webhookDefaultDelaySeconds   = 5
	webhookMinDelaySeconds       = 1
	webhookMaxDelaySeconds       = 300
	webhookHTTPStatusFailStart   = 400
)

type webhookConfig struct {
	Enabled      bool
	URL          string
	Retry        int
	DelaySeconds int
}

func (r *runtime) dispatchTransactionWebhookNow(
	ctx context.Context,
	tenantID,
	transactionID,
	reference,
	status string,
	amount int64,
) error {
	if r == nil || r.db == nil {
		return errors.New("worker runtime is not initialized")
	}
	if r.httpClient == nil {
		return errors.New("worker runtime http client is not initialized")
	}

	configCtx, cancel := context.WithTimeout(ctx, webhookConfigLoadTimeout)
	defer cancel()

	cfg, err := r.loadWebhookConfigForDelivery(configCtx, tenantID)
	if err != nil {
		return err
	}
	if !cfg.Enabled {
		return nil
	}
	if strings.TrimSpace(cfg.URL) == "" {
		return nil
	}

	payloadMap := map[string]interface{}{
		"transaction_id": transactionID,
		"reference":      reference,
		"status":         status,
		"amount":         amount,
		"timestamp":      time.Now().UTC(),
	}

	payload, err := json.Marshal(payloadMap)
	if err != nil {
		return fmt.Errorf("marshal webhook payload: %w", err)
	}

	delayBetweenRetries := time.Duration(cfg.DelaySeconds) * time.Second
	var lastErr error

	for attempt := 1; attempt <= cfg.Retry; attempt++ {
		sendCtx, sendCancel := context.WithTimeout(ctx, webhookRequestTimeout)
		err := sendWebhook(sendCtx, r.httpClient, cfg.URL, payload)
		sendCancel()
		if err == nil {
			return nil
		}

		lastErr = err
		if attempt == cfg.Retry {
			break
		}

		if waitErr := waitWithContext(ctx, delayBetweenRetries); waitErr != nil {
			return fmt.Errorf("wait before webhook retry: %w", waitErr)
		}
	}

	return fmt.Errorf("send webhook failed after %d attempts: %w", cfg.Retry, lastErr)
}

func (r *runtime) loadWebhookConfigForDelivery(ctx context.Context, tenantID string) (webhookConfig, error) {
	const query = `
		SELECT key, value
		FROM public.tenant_configs
		WHERE tenant_id = $1::uuid
		  AND key IN ($2, $3, $4, $5)
	`

	cfg := webhookConfig{
		Enabled:      false,
		URL:          "",
		Retry:        webhookDefaultRetry,
		DelaySeconds: webhookDefaultDelaySeconds,
	}

	rows, err := r.db.QueryContext(
		ctx,
		query,
		tenantID,
		webhookEnabledConfigKey,
		webhookURLConfigKey,
		webhookRetryConfigKey,
		webhookDelaySecondsConfigKey,
	)
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
			parsedRetry, err := parseWebhookIntegerConfig(raw, webhookRetryConfigKey)
			if err != nil {
				return webhookConfig{}, err
			}
			cfg.Retry = parsedRetry
		case webhookDelaySecondsConfigKey:
			if len(raw) == 0 || string(raw) == "null" {
				cfg.DelaySeconds = webhookDefaultDelaySeconds
				continue
			}
			parsedDelay, err := parseWebhookIntegerConfig(raw, webhookDelaySecondsConfigKey)
			if err != nil {
				return webhookConfig{}, err
			}
			cfg.DelaySeconds = parsedDelay
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
	if cfg.DelaySeconds < webhookMinDelaySeconds {
		cfg.DelaySeconds = webhookMinDelaySeconds
	}
	if cfg.DelaySeconds > webhookMaxDelaySeconds {
		cfg.DelaySeconds = webhookMaxDelaySeconds
	}

	return cfg, nil
}

func parseWebhookIntegerConfig(raw []byte, key string) (int, error) {
	var asInt int
	if err := json.Unmarshal(raw, &asInt); err == nil {
		return asInt, nil
	}

	var asFloat float64
	if err := json.Unmarshal(raw, &asFloat); err == nil {
		if asFloat != float64(int(asFloat)) {
			return 0, fmt.Errorf("%s config must be integer", key)
		}
		return int(asFloat), nil
	}

	var asString string
	if err := json.Unmarshal(raw, &asString); err == nil {
		parsed, parseErr := strconv.Atoi(strings.TrimSpace(asString))
		if parseErr != nil {
			return 0, fmt.Errorf("%s config must be integer", key)
		}
		return parsed, nil
	}

	return 0, fmt.Errorf("%s config must be integer", key)
}

func sendWebhook(ctx context.Context, client *http.Client, endpoint string, payload []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build webhook request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	fmt.Printf("sending webhook to %s with payload: %s\n", endpoint, string(payload))
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

func waitWithContext(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return nil
	}

	timer := time.NewTimer(duration)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
