package config

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"time"
)

type LedgerAPIConfig struct {
	Port            string
	DatabaseURL     string
	RedisAddr       string
	IdempotencyTTL  time.Duration
	RateLimitPerMin int
	DBMaxOpenConns  int
	DBMaxIdleConns  int
	DBConnMaxLife   time.Duration
}

type LedgerWorkerConfig struct {
	DatabaseURL     string
	WorkerCount     int
	WebhookMaxRetry int
	DBMaxOpenConns  int
	DBMaxIdleConns  int
	DBConnMaxLife   time.Duration
}

func LoadLedgerAPIConfigFromEnv() (LedgerAPIConfig, error) {
	const (
		defaultIdempotencyTTL  = 24 * time.Hour
		defaultRateLimitPerMin = 5
	)

	port := os.Getenv("LEDGER_API_PORT")
	if port == "" {
		port = "8080"
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return LedgerAPIConfig{}, errors.New("DATABASE_URL is required")
	}

	idempotencyTTL := defaultIdempotencyTTL
	rawTTLSeconds := strings.TrimSpace(os.Getenv("IDEMPOTENCY_TTL_SECONDS"))
	if rawTTLSeconds != "" {
		parsedSeconds, err := strconv.Atoi(rawTTLSeconds)
		if err != nil {
			return LedgerAPIConfig{}, errors.New("IDEMPOTENCY_TTL_SECONDS must be a valid integer")
		}
		if parsedSeconds <= 0 {
			return LedgerAPIConfig{}, errors.New("IDEMPOTENCY_TTL_SECONDS must be greater than 0")
		}
		idempotencyTTL = time.Duration(parsedSeconds) * time.Second
	}

	rateLimitPerMin := defaultRateLimitPerMin
	rawRateLimitPerMin := strings.TrimSpace(os.Getenv("RATE_LIMIT_PER_MINUTE"))
	if rawRateLimitPerMin != "" {
		parsed, err := strconv.Atoi(rawRateLimitPerMin)
		if err != nil {
			return LedgerAPIConfig{}, errors.New("RATE_LIMIT_PER_MINUTE must be a valid integer")
		}
		if parsed <= 0 {
			return LedgerAPIConfig{}, errors.New("RATE_LIMIT_PER_MINUTE must be greater than 0")
		}
		rateLimitPerMin = parsed
	}

	maxOpenConns, maxIdleConns, connMaxLife, err := loadDBPoolSettingsFromEnv()
	if err != nil {
		return LedgerAPIConfig{}, err
	}

	return LedgerAPIConfig{
		Port:            port,
		DatabaseURL:     databaseURL,
		RedisAddr:       os.Getenv("REDIS_ADDR"),
		IdempotencyTTL:  idempotencyTTL,
		RateLimitPerMin: rateLimitPerMin,
		DBMaxOpenConns:  maxOpenConns,
		DBMaxIdleConns:  maxIdleConns,
		DBConnMaxLife:   connMaxLife,
	}, nil
}

func LoadLedgerWorkerConfigFromEnv() (LedgerWorkerConfig, error) {
	const defaultWebhookMaxRetry = 5

	databaseURL := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if databaseURL == "" {
		return LedgerWorkerConfig{}, errors.New("DATABASE_URL is required")
	}

	workerCount := 2
	rawWorkerCount := strings.TrimSpace(os.Getenv("WORKER_COUNT"))
	if rawWorkerCount != "" {
		parsed, err := strconv.Atoi(rawWorkerCount)
		if err != nil {
			return LedgerWorkerConfig{}, errors.New("WORKER_COUNT must be a valid integer")
		}
		if parsed <= 0 {
			return LedgerWorkerConfig{}, errors.New("WORKER_COUNT must be greater than 0")
		}
		workerCount = parsed
	}

	webhookMaxRetry := defaultWebhookMaxRetry
	rawWebhookMaxRetry := strings.TrimSpace(os.Getenv("WEBHOOK_MAX_RETRY"))
	if rawWebhookMaxRetry != "" {
		parsed, err := strconv.Atoi(rawWebhookMaxRetry)
		if err != nil {
			return LedgerWorkerConfig{}, errors.New("WEBHOOK_MAX_RETRY must be a valid integer")
		}
		if parsed <= 0 {
			return LedgerWorkerConfig{}, errors.New("WEBHOOK_MAX_RETRY must be greater than 0")
		}
		webhookMaxRetry = parsed
	}

	maxOpenConns, maxIdleConns, connMaxLife, err := loadDBPoolSettingsFromEnv()
	if err != nil {
		return LedgerWorkerConfig{}, err
	}

	return LedgerWorkerConfig{
		DatabaseURL:     databaseURL,
		WorkerCount:     workerCount,
		WebhookMaxRetry: webhookMaxRetry,
		DBMaxOpenConns:  maxOpenConns,
		DBMaxIdleConns:  maxIdleConns,
		DBConnMaxLife:   connMaxLife,
	}, nil
}

func loadDBPoolSettingsFromEnv() (int, int, time.Duration, error) {
	const (
		defaultDBMaxOpenConns    = 25
		defaultDBMaxIdleConns    = 10
		defaultDBConnMaxLifetime = 300 * time.Second
	)

	maxOpenConns := defaultDBMaxOpenConns
	rawMaxOpenConns := strings.TrimSpace(os.Getenv("POSTGRES_MAX_OPEN_CONNS"))
	if rawMaxOpenConns != "" {
		parsed, err := strconv.Atoi(rawMaxOpenConns)
		if err != nil {
			return 0, 0, 0, errors.New("POSTGRES_MAX_OPEN_CONNS must be a valid integer")
		}
		if parsed <= 0 {
			return 0, 0, 0, errors.New("POSTGRES_MAX_OPEN_CONNS must be greater than 0")
		}
		maxOpenConns = parsed
	}

	maxIdleConns := defaultDBMaxIdleConns
	rawMaxIdleConns := strings.TrimSpace(os.Getenv("POSTGRES_MAX_IDLE_CONNS"))
	if rawMaxIdleConns != "" {
		parsed, err := strconv.Atoi(rawMaxIdleConns)
		if err != nil {
			return 0, 0, 0, errors.New("POSTGRES_MAX_IDLE_CONNS must be a valid integer")
		}
		if parsed < 0 {
			return 0, 0, 0, errors.New("POSTGRES_MAX_IDLE_CONNS must be >= 0")
		}
		maxIdleConns = parsed
	}
	if maxIdleConns > maxOpenConns {
		maxIdleConns = maxOpenConns
	}

	connMaxLife := defaultDBConnMaxLifetime
	rawConnMaxLife := strings.TrimSpace(os.Getenv("POSTGRES_CONN_MAX_LIFETIME_SECONDS"))
	if rawConnMaxLife != "" {
		parsed, err := strconv.Atoi(rawConnMaxLife)
		if err != nil {
			return 0, 0, 0, errors.New("POSTGRES_CONN_MAX_LIFETIME_SECONDS must be a valid integer")
		}
		if parsed <= 0 {
			return 0, 0, 0, errors.New("POSTGRES_CONN_MAX_LIFETIME_SECONDS must be greater than 0")
		}
		connMaxLife = time.Duration(parsed) * time.Second
	}

	return maxOpenConns, maxIdleConns, connMaxLife, nil
}
