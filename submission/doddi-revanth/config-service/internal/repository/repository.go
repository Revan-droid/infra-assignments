package repository

import (
	"context"
	"errors"

	"github.com/doddi-revanth/config-service/internal/models"
)

// ErrNotFound is returned when a config record cannot be found.
var ErrNotFound = errors.New("config not found")

// Repository defines the storage contract for Config records.
// All implementations must be safe for concurrent use.
type Repository interface {
	Get(ctx context.Context, id string) (*models.Config, error)
	Upsert(ctx context.Context, cfg *models.Config) error
}
