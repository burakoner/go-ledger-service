# Build stage: compile the Go binary in a clean environment.
FROM golang:1.26-alpine AS builder

# Set the working directory inside the builder container.
WORKDIR /app

# Select which cmd entrypoint should be built (e.g., ./cmd/ledger-api or ./cmd/ledger-admin).
ARG APP_PATH=./cmd/ledger-api

# Copy module files first to leverage Docker layer caching.
COPY go.mod go.sum ./
RUN go mod download

# Copy the full source code after dependencies are cached.
COPY . .

# Build the selected service binary.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/service "${APP_PATH}"

# Runtime stage: run only the compiled binary in a minimal image.
FROM alpine:3.21

# Create a non-root user for safer runtime execution.
RUN adduser -D -g "" appuser

WORKDIR /app
# Copy the binary built in the previous stage.
COPY --from=builder /out/service /app/service
# Copy migration files so runtime services can execute SQL templates.
COPY --from=builder /app/migrations /app/migrations

USER appuser

# Expose the HTTP port used by the API.
EXPOSE 8080

# Start the API process.
ENTRYPOINT ["/app/service"]
