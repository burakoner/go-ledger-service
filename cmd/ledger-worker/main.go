package main

import (
	"github.com/burakoner/go-ledger-service/internal/config"
	"github.com/burakoner/go-ledger-service/internal/worker"
)

func main() {
	cfg := config.LoadLedgerWorkerConfigFromEnv()
	worker.RunEnvCheck(cfg)
}
