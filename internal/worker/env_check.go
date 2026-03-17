package worker

import (
	"log"

	"github.com/burakoner/go-ledger-service/internal/config"
)

// RunEnvCheck prints configured dependency env values and exits.
func RunEnvCheck(cfg config.LedgerWorkerConfig) {
	log.Printf("Ledger worker env check started.")
	log.Printf("DATABASE_URL=%q", cfg.DatabaseURL)
	log.Printf("REDIS_ADDR=%q", cfg.RedisAddr)
	log.Printf("RABBITMQ_URL=%q", cfg.RabbitMQURL)
	log.Printf("RABBITMQ_USER=%q", cfg.RabbitMQUser)
	log.Printf("RABBITMQ_PASSWORD=%q", cfg.RabbitMQPassword)
	log.Printf("Ledger worker env check completed. Exiting.")
}

