package main

import (
	"github.com/burakoner/go-ledger-service/internal/config"
	"github.com/burakoner/go-ledger-service/internal/worker"
)

// main starts the worker entrypoint and runs the current env-check behavior.
func main() {
	cfg := config.LoadLedgerWorkerConfigFromEnv()
	worker.RunEnvCheck(cfg)
}

