package config

import (
	"errors"
	"os"
)

// LedgerAPIConfig holds runtime settings for ledger-api service.
type LedgerAPIConfig struct {
	Port        string
	DatabaseURL string
	RedisAddr   string
	RabbitMQURL string
}

// LedgerWorkerConfig holds runtime settings for ledger-worker service.
type LedgerWorkerConfig struct {
	DatabaseURL      string
	RedisAddr        string
	RabbitMQURL      string
	RabbitMQUser     string
	RabbitMQPassword string
}

// LoadLedgerAPIConfigFromEnv loads and validates ledger-api configuration from env vars.
func LoadLedgerAPIConfigFromEnv() (LedgerAPIConfig, error) {
	port := os.Getenv("PORT")
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
		RabbitMQURL: os.Getenv("RABBITMQ_URL"),
	}, nil
}

// LoadLedgerWorkerConfigFromEnv loads ledger-worker configuration from env vars.
func LoadLedgerWorkerConfigFromEnv() LedgerWorkerConfig {
	return LedgerWorkerConfig{
		DatabaseURL:      os.Getenv("DATABASE_URL"),
		RedisAddr:        os.Getenv("REDIS_ADDR"),
		RabbitMQURL:      os.Getenv("RABBITMQ_URL"),
		RabbitMQUser:     os.Getenv("RABBITMQ_USER"),
		RabbitMQPassword: os.Getenv("RABBITMQ_PASSWORD"),
	}
}

