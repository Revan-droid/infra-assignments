package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/kafka"
	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

var tracer = otel.Tracer("config-service/service")

// ConfigService contains all business logic for Config operations.
type ConfigService struct {
	repo     repository.Repository
	producer kafka.Producer
	metrics  *telemetry.Metrics
	logger   *zap.Logger
}

// New creates a ConfigService with all required dependencies.
func New(repo repository.Repository, producer kafka.Producer, metrics *telemetry.Metrics, logger *zap.Logger) *ConfigService {
	return &ConfigService{
		repo:     repo,
		producer: producer,
		metrics:  metrics,
		logger:   logger,
	}
}

// GetConfig retrieves a configuration record by ID.
func (s *ConfigService) GetConfig(ctx context.Context, id string) (*models.Config, error) {
	ctx, span := tracer.Start(ctx, "service.GetConfig")
	defer span.End()

	span.SetAttributes(attribute.String("config.id", id))

	cfg, err := s.repo.Get(ctx, id)
	if err != nil {
		span.RecordError(err)
		return nil, err
	}

	return cfg, nil
}

// UpsertConfig creates or updates a configuration record and publishes a Kafka event.
func (s *ConfigService) UpsertConfig(ctx context.Context, req *models.UpsertRequest) (*models.Config, error) {
	ctx, span := tracer.Start(ctx, "service.UpsertConfig")
	defer span.End()

	span.SetAttributes(
		attribute.String("config.id", req.ID),
		attribute.String("config.app_name", req.AppName),
	)

	cfg := &models.Config{
		ID:       strings.TrimSpace(req.ID),
		Host:     strings.TrimSpace(req.Host),
		Port:     req.Port,
		AppName:  strings.TrimSpace(req.AppName),
		LogLevel: strings.ToLower(strings.TrimSpace(req.LogLevel)),
	}

	if err := s.repo.Upsert(ctx, cfg); err != nil {
		span.RecordError(err)
		return nil, fmt.Errorf("upsert config: %w", err)
	}

	event := kafka.ConfigEvent{
		EventType: "UPSERT",
		ConfigID:  cfg.ID,
		Timestamp: time.Now().UTC(),
		AppName:   cfg.AppName,
	}
	if err := s.producer.PublishConfigEvent(ctx, event); err != nil {
		s.logger.Warn("failed to publish kafka event, continuing",
			zap.String("config_id", cfg.ID),
			zap.Error(err),
		)
	} else {
		s.metrics.IncKafkaMessages()
	}

	return cfg, nil
}
