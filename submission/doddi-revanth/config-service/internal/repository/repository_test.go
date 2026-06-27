package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

func newInMemory() *repository.InMemory {
	return repository.NewInMemory()
}

func TestInMemory_GetNotFound(t *testing.T) {
	repo := newInMemory()
	_, err := repo.Get(context.Background(), "missing")
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestInMemory_UpsertAndGet(t *testing.T) {
	repo := newInMemory()
	cfg := &models.Config{
		ID:       "r1",
		Host:     "localhost",
		Port:     9000,
		AppName:  "test",
		LogLevel: "debug",
	}
	if err := repo.Upsert(context.Background(), cfg); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	got, err := repo.Get(context.Background(), "r1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Host != "localhost" {
		t.Errorf("expected localhost, got %q", got.Host)
	}
}

func TestInMemory_UpsertOverwrites(t *testing.T) {
	repo := newInMemory()

	cfg1 := &models.Config{ID: "x", Host: "old", Port: 80, AppName: "app", LogLevel: "info"}
	cfg2 := &models.Config{ID: "x", Host: "new", Port: 443, AppName: "app", LogLevel: "debug"}

	_ = repo.Upsert(context.Background(), cfg1)
	_ = repo.Upsert(context.Background(), cfg2)

	got, err := repo.Get(context.Background(), "x")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Host != "new" {
		t.Errorf("expected host new after overwrite, got %q", got.Host)
	}
	if got.Port != 443 {
		t.Errorf("expected port 443 after overwrite, got %d", got.Port)
	}
}

func TestInMemory_Concurrent(t *testing.T) {
	repo := newInMemory()
	ctx := context.Background()

	done := make(chan struct{})
	for i := 0; i < 50; i++ {
		go func(n int) {
			cfg := &models.Config{
				ID:       "concurrent",
				Host:     "host",
				Port:     8000 + n,
				AppName:  "app",
				LogLevel: "info",
			}
			_ = repo.Upsert(ctx, cfg)
			_, _ = repo.Get(ctx, "concurrent")
			done <- struct{}{}
		}(i)
	}
	for i := 0; i < 50; i++ {
		<-done
	}
}

func TestInMemory_UpdatedAtSet(t *testing.T) {
	repo := newInMemory()
	cfg := &models.Config{ID: "ts", Host: "h", Port: 80, AppName: "a", LogLevel: "info"}
	_ = repo.Upsert(context.Background(), cfg)

	got, _ := repo.Get(context.Background(), "ts")
	if got.UpdatedAt.IsZero() {
		t.Error("expected UpdatedAt to be set")
	}
	if got.UpdatedAt.After(time.Now().Add(time.Second)) {
		t.Error("UpdatedAt is in the future")
	}
}

// Ensure Metrics don't panic with in-memory repo.
func TestMetrics_NoPanic(t *testing.T) {
	metrics := telemetry.NewMetrics()
	_ = metrics // basic init check
}
