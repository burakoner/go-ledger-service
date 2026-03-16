# Build stage: compile the Go binary in a clean environment.
FROM golang:1.26-alpine AS builder

# Set the working directory inside the builder container.
WORKDIR /app

# Copy module files first to leverage Docker layer caching.
COPY go.mod ./
RUN go mod download

# Copy the full source code after dependencies are cached.
COPY . .

# Build the API binary from cmd/server.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/ledger-api ./cmd/server

# Runtime stage: run only the compiled binary in a minimal image.
FROM alpine:3.21

# Create a non-root user for safer runtime execution.
RUN adduser -D -g "" appuser

WORKDIR /app
# Copy the binary built in the previous stage.
COPY --from=builder /out/ledger-api /app/ledger-api

USER appuser

# Expose the HTTP port used by the API.
EXPOSE 8080

# Start the API process.
ENTRYPOINT ["/app/ledger-api"]
