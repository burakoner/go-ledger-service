package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
)

type errorResponse struct {
	Error struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		RequestID string `json:"request_id"`
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

// writeAPIError writes a standardized API error payload.
func writeAPIError(w http.ResponseWriter, r *http.Request, statusCode int, code, message string) {
	requestID := requestIDFromContext(r.Context())
	if requestID == "" {
		requestID = generateRequestID()
	}
	w.Header().Set(requestIDHeaderName, requestID)

	resp := errorResponse{}
	resp.Error.Code = code
	resp.Error.Message = message
	resp.Error.RequestID = requestID
	writeJSON(w, statusCode, resp)
}
