package repository

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

// Postgres is a PostgreSQL-backed Repository.
type Postgres struct {
	pool    *pgxpool.Pool
	metrics *telemetry.Metrics
}

// NewPostgres creates a Postgres repository.
func NewPostgres(pool *pgxpool.Pool, metrics *telemetry.Metrics) *Postgres {
	return &Postgres{pool: pool, metrics: metrics}
}

// Get retrieves a Config by ID. Returns ErrNotFound when absent.
func (r *Postgres) Get(ctx context.Context, id string) (*models.Config, error) {
	defer r.metrics.ObserveDBQuery("get")()

	const q = `
		SELECT id, host, port, app_name, log_level, created_at, updated_at
		FROM configs
		WHERE id = $1`

	var cfg models.Config
	row := r.pool.QueryRow(ctx, q, id)
	err := row.Scan(
		&cfg.ID, &cfg.Host, &cfg.Port,
		&cfg.AppName, &cfg.LogLevel,
		&cfg.CreatedAt, &cfg.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("query config %q: %w", id, err)
	}

	r.metrics.IncConfigReads()
	return &cfg, nil
}

// Upsert inserts or updates a Config record using PostgreSQL ON CONFLICT.
func (r *Postgres) Upsert(ctx context.Context, cfg *models.Config) error {
	defer r.metrics.ObserveDBQuery("upsert")()

	now := time.Now().UTC()

	const q = `
		INSERT INTO configs (id, host, port, app_name, log_level, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, COALESCE((SELECT created_at FROM configs WHERE id = $1), $6), $7)
		ON CONFLICT (id) DO UPDATE SET
			host       = EXCLUDED.host,
			port       = EXCLUDED.port,
			app_name   = EXCLUDED.app_name,
			log_level  = EXCLUDED.log_level,
			updated_at = EXCLUDED.updated_at`

	_, err := r.pool.Exec(ctx, q,
		cfg.ID, cfg.Host, cfg.Port,
		cfg.AppName, cfg.LogLevel,
		now, now,
	)
	if err != nil {
		return fmt.Errorf("upsert config %q: %w", cfg.ID, err)
	}

	cfg.UpdatedAt = now
	if cfg.CreatedAt.IsZero() {
		cfg.CreatedAt = now
	}

	r.metrics.IncConfigUpserts()
	return nil
}
