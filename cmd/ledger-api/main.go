package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/burakoner/go-ledger-service/internal/config"
	"github.com/burakoner/go-ledger-service/internal/db"
	httpapi "github.com/burakoner/go-ledger-service/internal/http"
	"github.com/burakoner/go-ledger-service/internal/repository"
	"github.com/burakoner/go-ledger-service/internal/service"
)

func main() {
	cfg, err := config.LoadLedgerAPIConfigFromEnv()
	if err != nil {
		log.Fatalf("failed to load ledger-api config: %v", err)
	}

	postgresDB, err := db.OpenPostgres(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("failed to open database connection: %v", err)
	}
	defer func() {
		if closeErr := postgresDB.Close(); closeErr != nil {
			log.Printf("failed to close database connection: %v", closeErr)
		}
	}()

	if err := db.Ping(context.Background(), postgresDB, 5*time.Second); err != nil {
		log.Fatalf("failed to ping database: %v", err)
	}

	// Repositories
	tenantRepo := repository.NewPostgresTenantRepository(postgresDB)
	ledgerBalanceRepo := repository.NewPostgresLedgerBalanceRepository(postgresDB)
	ledgerEntryRepo := repository.NewPostgresLedgerEntryRepository(postgresDB)
	ledgerTransactionRepo := repository.NewPostgresLedgerTransactionRepository(postgresDB)

	// Services
	tenantAuthService := service.NewTenantAuthService(tenantRepo)
	ledgerBalanceService := service.NewLedgerBalanceService(ledgerBalanceRepo)
	ledgerEntryService := service.NewLedgerEntryService(ledgerEntryRepo)
	transactionService := service.NewLedgerTransactionService(ledgerTransactionRepo)

	// HTTP API
	ledgerAPI := httpapi.NewLedgerAPI(
		postgresDB,
		tenantAuthService,
		ledgerBalanceService,
		ledgerEntryService,
		transactionService,
	)

	addr := ":" + cfg.Port
	log.Printf("Tenant Ledger API is starting on %s", addr)
	if err := http.ListenAndServe(addr, ledgerAPI.NewMux()); err != nil {
		log.Fatalf("Tenant Ledger API stopped: %v", err)
	}
}
