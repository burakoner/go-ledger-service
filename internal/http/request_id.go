package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strings"
)

const requestIDHeaderName = "X-Request-ID"

type requestIDContextKey struct{}

// withRequestIDContext stores request ID into context.
func withRequestIDContext(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, requestIDContextKey{}, requestID)
}

// requestIDFromContext reads request ID from context.
func requestIDFromContext(ctx context.Context) string {
	requestID, _ := ctx.Value(requestIDContextKey{}).(string)
	return requestID
}

// normalizeRequestID trims and validates inbound request ID value.
func normalizeRequestID(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if len(raw) > 128 {
		return ""
	}
	return raw
}

// generateRequestID creates a random UUID-like request ID.
func generateRequestID() string {
	// 16 random bytes are enough for high-entropy request IDs.
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		// Fallback keeps response deterministic even if random source fails.
		return "00000000-0000-0000-0000-000000000000"
	}

	// Set UUIDv4 + variant bits so format remains familiar in logs/tools.
	buffer[6] = (buffer[6] & 0x0f) | 0x40
	buffer[8] = (buffer[8] & 0x3f) | 0x80

	hexValue := hex.EncodeToString(buffer)
	return hexValue[0:8] + "-" + hexValue[8:12] + "-" + hexValue[12:16] + "-" + hexValue[16:20] + "-" + hexValue[20:32]
}
