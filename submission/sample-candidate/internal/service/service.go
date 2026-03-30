package service

import (
	"context"

	"config-service/internal/domain"
	"config-service/internal/repository"
)

// Service implements business logic for Config operations.
type Service struct {
	repo repository.Repository
}

// New creates a Service backed by the given repository.
func New(repo repository.Repository) *Service {
	return &Service{repo: repo}
}

// GetConfig retrieves a Config by ID.
func (s *Service) GetConfig(ctx context.Context, id string) (*domain.Config, error) {
	return s.repo.Get(ctx, id)
}

// UpsertConfig creates or updates a Config record.
func (s *Service) UpsertConfig(ctx context.Context, cfg *domain.Config) error {
	return s.repo.Upsert(ctx, cfg)
}
