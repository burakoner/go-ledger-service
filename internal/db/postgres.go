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

type PoolConfig struct {
	MaxOpenConns    int
	MaxIdleConns    int
	ConnMaxLifetime time.Duration
}

func OpenPostgres(databaseURL string, poolConfig PoolConfig) (*sql.DB, error) {
	if databaseURL == "" {
		return nil, errors.New("database URL is required")
	}
	if poolConfig.MaxOpenConns <= 0 {
		return nil, errors.New("pool max open conns must be greater than 0")
	}
	if poolConfig.MaxIdleConns < 0 {
		return nil, errors.New("pool max idle conns must be >= 0")
	}
	if poolConfig.ConnMaxLifetime <= 0 {
		return nil, errors.New("pool conn max lifetime must be greater than 0")
	}

	maxIdle := poolConfig.MaxIdleConns
	if maxIdle > poolConfig.MaxOpenConns {
		maxIdle = poolConfig.MaxOpenConns
	}

	conn, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open postgres connection: %w", err)
	}

	conn.SetMaxOpenConns(poolConfig.MaxOpenConns)
	conn.SetMaxIdleConns(maxIdle)
	conn.SetConnMaxLifetime(poolConfig.ConnMaxLifetime)

	return conn, nil
}

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
