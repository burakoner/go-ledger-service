package config

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

type LedgerAPIConfig struct {
	Port        string
	DatabaseURL string
	RedisAddr   string
}

type LedgerWorkerConfig struct {
	DatabaseURL string
	WorkerCount int
}

func LoadLedgerAPIConfigFromEnv() (LedgerAPIConfig, error) {
	port := os.Getenv("LEDGER_API_PORT")
	if port == "" {
		port = "8080"
	}

	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		return LedgerAPIConfig{}, errors.New("DATABASE_URL is required")
	}

	return LedgerAPIConfig{
		Port:        port,
		DatabaseURL: databaseURL,
		RedisAddr:   os.Getenv("REDIS_ADDR"),
	}, nil
}

func LoadLedgerWorkerConfigFromEnv() (LedgerWorkerConfig, error) {
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

	return LedgerWorkerConfig{
		DatabaseURL: databaseURL,
		WorkerCount: workerCount,
	}, nil
}
