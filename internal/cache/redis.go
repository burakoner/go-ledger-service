package cache

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

const defaultPingTimeout = 3 * time.Second

// OpenRedis creates a redis client using the given address.
func OpenRedis(addr string) (*redis.Client, error) {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return nil, errors.New("redis address is required")
	}

	client := redis.NewClient(&redis.Options{
		Addr: addr,
	})

	return client, nil
}

// Ping verifies redis reachability with timeout.
func Ping(ctx context.Context, client *redis.Client, timeout time.Duration) error {
	if client == nil {
		return errors.New("redis client is nil")
	}
	if timeout <= 0 {
		timeout = defaultPingTimeout
	}

	pingCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if err := client.Ping(pingCtx).Err(); err != nil {
		return fmt.Errorf("ping redis: %w", err)
	}

	return nil
}
