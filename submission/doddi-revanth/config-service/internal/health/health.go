package health

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/doddi-revanth/config-service/internal/kafka"
)

// Checker performs dependency health checks.
type Checker struct {
	pool        *pgxpool.Pool
	producer    kafka.Producer
	kafkaActive bool
}

// New creates a Checker.
func New(pool *pgxpool.Pool, producer kafka.Producer, kafkaActive bool) *Checker {
	return &Checker{pool: pool, producer: producer, kafkaActive: kafkaActive}
}

// Check runs all dependency checks and returns a map of check name → healthy.
func (c *Checker) Check(ctx context.Context) map[string]bool {
	result := make(map[string]bool, 2)

	dbCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	result["database"] = c.pool.Ping(dbCtx) == nil
	cancel()

	if c.kafkaActive {
		kCtx, kCancel := context.WithTimeout(ctx, 2*time.Second)
		result["kafka"] = c.producer.Ping(kCtx) == nil
		kCancel()
	}

	return result
}
