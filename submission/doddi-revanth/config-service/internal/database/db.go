package database

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// NewPool creates a pgxpool connection pool with sensible defaults.
// It retries up to 10 times waiting for the database to be ready.
func NewPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}

	cfg.MaxConns = 20
	cfg.MinConns = 2
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = time.Minute

	var (
		pool    *pgxpool.Pool
		lastErr error
	)
	for attempt := 1; attempt <= 10; attempt++ {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("connect to postgres: %w", ctx.Err())
		}

		pool, err = pgxpool.NewWithConfig(ctx, cfg)
		if err == nil {
			pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			lastErr = pool.Ping(pingCtx)
			cancel()
			if lastErr == nil {
				return pool, nil
			}
			pool.Close()
		} else {
			lastErr = err
		}

		if attempt < 10 {
			select {
			case <-ctx.Done():
				return nil, fmt.Errorf("connect to postgres: %w", ctx.Err())
			case <-time.After(time.Duration(attempt) * time.Second):
			}
		}
	}

	return nil, fmt.Errorf("connect to postgres after 10 attempts: %w", lastErr)
}
