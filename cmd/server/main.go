package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "Go Ledger Service API")
	})
	mux.HandleFunc("/api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "OK")
	})

	addr := ":" + port
	log.Printf("Server is starting on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Server stopped: %v", err)
	}
}
