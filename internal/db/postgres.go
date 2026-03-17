package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "github.com/lib/pq"
)

const defaultPingTimeout = 5 * time.Second

// OpenPostgres opens a PostgreSQL connection pool.
func OpenPostgres(databaseURL string) (*sql.DB, error) {
	if databaseURL == "" {
		return nil, errors.New("database URL is required")
	}

	conn, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open postgres connection: %w", err)
	}

	return conn, nil
}

// Ping checks whether PostgreSQL is reachable with a bounded timeout.
func Ping(ctx context.Context, conn *sql.DB, timeout time.Duration) error {
	if conn == nil {
		return errors.New("database connection is nil")
	}
	if timeout <= 0 {
		timeout = defaultPingTimeout
	}

	pingCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if err := conn.PingContext(pingCtx); err != nil {
		return fmt.Errorf("ping postgres: %w", err)
	}

	return nil
}

