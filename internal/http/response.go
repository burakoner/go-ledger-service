package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
)

type errorResponse struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// writeJSON writes a JSON response with status code.
func writeJSON(w http.ResponseWriter, statusCode int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("failed to encode JSON response: %v", err)
	}
}

// writeText writes a plain text response with status code.
func writeText(w http.ResponseWriter, statusCode int, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(statusCode)
	if _, err := w.Write([]byte(text)); err != nil {
		log.Printf("failed to write text response: %v", err)
	}
}

// writeAPIError writes a standardized API error payload.
func writeAPIError(w http.ResponseWriter, statusCode int, code, message string) {
	resp := errorResponse{}
	resp.Error.Code = code
	resp.Error.Message = message
	writeJSON(w, statusCode, resp)
}

