package main

import (
	"context"
	"log"
	"os/signal"
	"syscall"

	"github.com/burakoner/go-ledger-service/internal/config"
	"github.com/burakoner/go-ledger-service/internal/worker"
)

func main() {
	cfg, err := config.LoadLedgerWorkerConfigFromEnv()
	if err != nil {
		log.Fatalf("failed to load ledger-worker config: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := worker.Run(ctx, cfg); err != nil {
		log.Fatalf("ledger-worker stopped with error: %v", err)
	}
}
