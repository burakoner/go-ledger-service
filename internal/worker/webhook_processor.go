package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const (
	webhookProcessTimeout      = 15 * time.Second
	webhookRequestTimeout      = 5 * time.Second
	webhookEnabledConfigKey    = "webhook_enabled"
	webhookURLConfigKey        = "webhook_url"
	webhookHTTPStatusFailStart = 400
)

type webhookConfig struct {
	Enabled bool
	URL     string
}

func (r *runtime) dispatchTransactionWebhookNow(ctx context.Context, tenantID, transactionID, reference, status string, amount int64) error {
	if r == nil || r.db == nil {
		return errors.New("worker runtime is not initialized")
	}
	if r.httpClient == nil {
		return errors.New("worker runtime http client is not initialized")
	}

	dispatchCtx, cancel := context.WithTimeout(ctx, webhookProcessTimeout)
	defer cancel()

	cfg, err := r.loadWebhookConfigForDelivery(dispatchCtx, tenantID)
	if err != nil {
		return err
	}
	if !cfg.Enabled {
		return nil
	}
	if strings.TrimSpace(cfg.URL) == "" {
		return nil
	}

	payload, err := json.Marshal(map[string]interface{}{
		"transaction_id": transactionID,
		"reference":      reference,
		"status":         status,
		"amount":         amount,
		"timestamp":      time.Now().UTC(),
	})
	if err != nil {
		return fmt.Errorf("marshal webhook payload: %w", err)
	}

	sendCtx, sendCancel := context.WithTimeout(dispatchCtx, webhookRequestTimeout)
	defer sendCancel()
	if err := sendWebhook(sendCtx, r.httpClient, cfg.URL, payload); err != nil {
		return fmt.Errorf("send webhook: %w", err)
	}

	return nil
}

func (r *runtime) loadWebhookConfigForDelivery(ctx context.Context, tenantID string) (webhookConfig, error) {
	const query = `
		SELECT key, value
		FROM public.tenant_configs
		WHERE tenant_id = $1::uuid
		  AND key IN ($2, $3)
	`

	cfg := webhookConfig{Enabled: false, URL: ""}

	rows, err := r.db.QueryContext(ctx, query, tenantID, webhookEnabledConfigKey, webhookURLConfigKey)
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
		}
	}
	if err := rows.Err(); err != nil {
		return webhookConfig{}, fmt.Errorf("iterate webhook config rows: %w", err)
	}

	return cfg, nil
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
