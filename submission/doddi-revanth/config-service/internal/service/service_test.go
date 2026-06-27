package service_test

import (
	"context"
	"errors"
	"testing"

	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/kafka"
	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/service"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

func newSvc(t *testing.T) *service.ConfigService {
	t.Helper()
	logger, _ := zap.NewDevelopment()
	return service.New(
		repository.NewInMemory(),
		kafka.NewNoopProducer(),
		telemetry.NewMetrics(),
		logger,
	)
}

func TestService_UpsertAndGet(t *testing.T) {
	svc := newSvc(t)
	ctx := context.Background()

	req := &models.UpsertRequest{
		ID: "svc_1", Host: "host", Port: 8080, AppName: "app", LogLevel: "info",
	}
	cfg, err := svc.UpsertConfig(ctx, req)
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if cfg.ID != "svc_1" {
		t.Errorf("id mismatch: %q", cfg.ID)
	}

	got, err := svc.GetConfig(ctx, "svc_1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Host != "host" {
		t.Errorf("host mismatch: %q", got.Host)
	}
}

func TestService_GetNotFound(t *testing.T) {
	svc := newSvc(t)
	_, err := svc.GetConfig(context.Background(), "unknown")
	if !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestService_UpsertIsIdempotent(t *testing.T) {
	svc := newSvc(t)
	ctx := context.Background()

	req := &models.UpsertRequest{
		ID: "idem", Host: "h1", Port: 80, AppName: "a", LogLevel: "info",
	}
	_, _ = svc.UpsertConfig(ctx, req)

	req.Host = "h2"
	req.Port = 443
	_, _ = svc.UpsertConfig(ctx, req)

	got, err := svc.GetConfig(ctx, "idem")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Host != "h2" {
		t.Errorf("expected h2, got %q", got.Host)
	}
}

// mockFailRepo simulates a repository that always fails.
type mockFailRepo struct{}

func (m *mockFailRepo) Get(_ context.Context, _ string) (*models.Config, error) {
	return nil, errors.New("db error")
}
func (m *mockFailRepo) Upsert(_ context.Context, _ *models.Config) error {
	return errors.New("db error")
}

func TestService_RepositoryError_Propagated(t *testing.T) {
	logger, _ := zap.NewDevelopment()
	svc := service.New(&mockFailRepo{}, kafka.NewNoopProducer(), telemetry.NewMetrics(), logger)

	_, err := svc.GetConfig(context.Background(), "x")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}
