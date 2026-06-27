package repository

import (
	"context"
	"sync"
	"time"

	"github.com/doddi-revanth/config-service/internal/models"
)

// InMemory is a thread-safe, in-memory Repository implementation.
// Used for unit tests and local development without a database.
type InMemory struct {
	mu   sync.RWMutex
	data map[string]*models.Config
}

// NewInMemory returns an initialised InMemory repository.
func NewInMemory() *InMemory {
	return &InMemory{data: make(map[string]*models.Config)}
}

// Get retrieves a Config by ID. Returns ErrNotFound when absent.
func (r *InMemory) Get(_ context.Context, id string) (*models.Config, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	cfg, ok := r.data[id]
	if !ok {
		return nil, ErrNotFound
	}
	// Return a copy to prevent external mutation
	copy := *cfg
	return &copy, nil
}

// Upsert creates or replaces a Config record, setting UpdatedAt automatically.
func (r *InMemory) Upsert(_ context.Context, cfg *models.Config) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now().UTC()
	existing, ok := r.data[cfg.ID]
	if ok {
		cfg.CreatedAt = existing.CreatedAt
	} else {
		cfg.CreatedAt = now
	}
	cfg.UpdatedAt = now

	// Store a copy
	copy := *cfg
	r.data[cfg.ID] = &copy
	return nil
}
