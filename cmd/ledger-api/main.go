package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

// main is the entry point of the API process.
func main() {
	// Read the HTTP port from environment; use 8080 as a safe default.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Read dependency connection info from environment variables.
	// These values are intentionally not logged to avoid leaking credentials.
	_ = os.Getenv("REDIS_ADDR")
	_ = os.Getenv("DATABASE_URL")
	_ = os.Getenv("RABBITMQ_URL")

	// Create the root router for all HTTP endpoints.
	mux := http.NewServeMux()

	// Root endpoint for a quick sanity check.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "Go Ledger Service API")
	})

	// Health endpoint used by local checks and container health probes.
	mux.HandleFunc("/api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "OK")
	})

	// Start the HTTP server and fail fast if startup/runtime errors occur.
	addr := ":" + port
	log.Printf("Tenant Ledger API is starting on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Tenant Ledger API stopped: %v", err)
	}
}
