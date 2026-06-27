package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/config"
	"github.com/doddi-revanth/config-service/internal/database"
	"github.com/doddi-revanth/config-service/internal/handlers"
	"github.com/doddi-revanth/config-service/internal/health"
	"github.com/doddi-revanth/config-service/internal/kafka"
	"github.com/doddi-revanth/config-service/internal/middleware"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/service"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to load config: %v\n", err)
		os.Exit(1)
	}

	logger, err := telemetry.NewLogger(cfg.LogLevel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Sync() //nolint:errcheck

	logger.Info("starting config-service",
		zap.String("version", "1.0.0"),
		zap.String("port", cfg.Port),
		zap.String("log_level", cfg.LogLevel),
		zap.Bool("kafka_enabled", cfg.EnableKafka),
		zap.Bool("metrics_enabled", cfg.EnableMetrics),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	tp, mp, err := telemetry.Init(ctx, cfg)
	if err != nil {
		logger.Warn("failed to init telemetry, continuing without traces", zap.Error(err))
	} else {
		defer func() {
			shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer shutCancel()
			if err := tp.Shutdown(shutCtx); err != nil {
				logger.Error("failed to shutdown trace provider", zap.Error(err))
			}
			if err := mp.Shutdown(shutCtx); err != nil {
				logger.Error("failed to shutdown metric provider", zap.Error(err))
			}
		}()
	}

	metrics := telemetry.NewMetrics()

	db, err := database.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		logger.Fatal("failed to connect to database", zap.Error(err))
	}
	defer db.Close()
	logger.Info("database connection established")

	if err := database.RunMigrations(cfg.DatabaseURL); err != nil {
		logger.Fatal("failed to run migrations", zap.Error(err))
	}
	logger.Info("database migrations applied")

	var producer kafka.Producer
	if cfg.EnableKafka {
		kp, err := kafka.NewSaramaProducer(cfg.KafkaBrokers, logger)
		if err != nil {
			logger.Warn("kafka unavailable, continuing without kafka", zap.Error(err))
			producer = kafka.NewNoopProducer()
		} else {
			producer = kp
			defer func() {
				if err := kp.Close(); err != nil {
					logger.Error("failed to close kafka producer", zap.Error(err))
				}
			}()
			logger.Info("kafka producer connected", zap.Strings("brokers", cfg.KafkaBrokers))
		}
	} else {
		producer = kafka.NewNoopProducer()
		logger.Info("kafka disabled via feature flag")
	}

	repo := repository.NewPostgres(db, metrics)
	svc := service.New(repo, producer, metrics, logger)
	healthChecker := health.New(db, producer, cfg.EnableKafka)

	configHandler := handlers.NewConfigHandler(svc, logger)
	healthHandler := handlers.NewHealthHandler(healthChecker, metrics, logger)

	r := chi.NewRouter()
	r.Use(chimiddleware.RealIP)
	r.Use(middleware.RequestID)
	r.Use(middleware.Recovery(logger))
	r.Use(middleware.Logging(logger, metrics))
	r.Use(middleware.Timeout(14 * time.Second)) // must be < server WriteTimeout (15s)

	r.Get("/ping", healthHandler.Ping)
	r.Get("/live", healthHandler.Live)
	r.Get("/ready", healthHandler.Ready)
	r.Get("/metrics", healthHandler.Metrics)
	r.Get("/configs/{id}", configHandler.GetConfig)
	r.Post("/configs", configHandler.UpsertConfig)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(quit)

	go func() {
		logger.Info("server listening", zap.String("addr", srv.Addr))
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("server error", zap.Error(err))
		}
	}()

	<-quit
	logger.Info("shutdown signal received")

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()

	if err := srv.Shutdown(shutCtx); err != nil {
		logger.Error("server forced shutdown", zap.Error(err))
	}
	logger.Info("server exited cleanly")
}
