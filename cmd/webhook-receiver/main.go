package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

const maxWebhookBodyBytes = 1 << 20 // 1 MB

func main() {
	port := strings.TrimSpace(os.Getenv("WEBHOOK_RECEIVER_PORT"))
	if port == "" {
		port = strings.TrimSpace(os.Getenv("PORT"))
	}
	if port == "" {
		port = "8088"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/webhooks/transactions", handleTransactionWebhook)

	addr := ":" + port
	log.Printf("Webhook receiver is starting on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("Webhook receiver stopped: %v", err)
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"error": map[string]string{
				"code":    "METHOD_NOT_ALLOWED",
				"message": "Only GET is allowed",
			},
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"service": "webhook-receiver",
		"status":  "HEALTHY",
	})
}

func handleTransactionWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"error": map[string]string{
				"code":    "METHOD_NOT_ALLOWED",
				"message": "Only POST is allowed",
			},
		})
		return
	}
	defer func() {
		_ = r.Body.Close()
	}()

	log.Printf("Received webhook request. method=%s path=%s remote=%s", r.Method, r.URL.Path, r.RemoteAddr)

	body, err := io.ReadAll(io.LimitReader(r.Body, maxWebhookBodyBytes))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error": map[string]string{
				"code":    "INVALID_BODY",
				"message": "failed to read request body",
			},
		})
		return
	}

	payload := strings.TrimSpace(string(body))
	if payload == "" {
		payload = "{}"
	}

	log.Printf("Webhook received. method=%s path=%s remote=%s payload=%s", r.Method, r.URL.Path, r.RemoteAddr, payload)

	writeJSON(w, http.StatusAccepted, map[string]string{
		"status": "accepted",
	})
}

func writeJSON(w http.ResponseWriter, statusCode int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode json response: %v", err)
	}
}
