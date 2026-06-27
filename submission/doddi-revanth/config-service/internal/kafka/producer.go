package kafka

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/IBM/sarama"
	"go.uber.org/zap"
)

// Producer defines the Kafka publishing contract.
type Producer interface {
	PublishConfigEvent(ctx context.Context, event ConfigEvent) error
	Ping(ctx context.Context) error
	Close() error
}

// ConfigEvent is the payload published to the config-events topic.
type ConfigEvent struct {
	EventType string    `json:"event_type"`
	ConfigID  string    `json:"config_id"`
	Timestamp time.Time `json:"timestamp"`
	AppName   string    `json:"app_name"`
}

// SaramaProducer is a Kafka producer backed by IBM/sarama.
type SaramaProducer struct {
	producer sarama.SyncProducer
	client   sarama.Client
	logger   *zap.Logger
	topic    string
}

// NewSaramaProducer creates a synchronous Kafka producer.
func NewSaramaProducer(brokers []string, logger *zap.Logger) (*SaramaProducer, error) {
	cfg := sarama.NewConfig()
	cfg.Producer.Return.Successes = true
	cfg.Producer.Return.Errors = true
	cfg.Producer.RequiredAcks = sarama.WaitForAll
	cfg.Producer.Retry.Max = 3
	cfg.Producer.Retry.Backoff = 250 * time.Millisecond
	cfg.Version = sarama.V2_8_0_0
	cfg.Net.DialTimeout = 5 * time.Second
	cfg.Net.ReadTimeout = 10 * time.Second
	cfg.Net.WriteTimeout = 10 * time.Second

	client, err := sarama.NewClient(brokers, cfg)
	if err != nil {
		return nil, fmt.Errorf("create kafka client: %w", err)
	}

	producer, err := sarama.NewSyncProducerFromClient(client)
	if err != nil {
		client.Close() //nolint:errcheck
		return nil, fmt.Errorf("create sync producer: %w", err)
	}

	return &SaramaProducer{
		producer: producer,
		client:   client,
		logger:   logger,
		topic:    "config-events",
	}, nil
}

// PublishConfigEvent publishes a ConfigEvent to the config-events topic.
func (p *SaramaProducer) PublishConfigEvent(_ context.Context, event ConfigEvent) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	msg := &sarama.ProducerMessage{
		Topic: p.topic,
		Key:   sarama.StringEncoder(event.ConfigID),
		Value: sarama.ByteEncoder(payload),
	}

	partition, offset, err := p.producer.SendMessage(msg)
	if err != nil {
		return fmt.Errorf("send kafka message: %w", err)
	}

	p.logger.Debug("kafka message published",
		zap.String("topic", p.topic),
		zap.String("config_id", event.ConfigID),
		zap.Int32("partition", partition),
		zap.Int64("offset", offset),
	)

	return nil
}

// Ping checks Kafka broker connectivity by refreshing metadata.
func (p *SaramaProducer) Ping(_ context.Context) error {
	if err := p.client.RefreshMetadata(); err != nil {
		return fmt.Errorf("kafka ping: %w", err)
	}
	return nil
}

// Close shuts down the producer and client cleanly.
func (p *SaramaProducer) Close() error {
	if err := p.producer.Close(); err != nil {
		_ = p.client.Close()
		return fmt.Errorf("close producer: %w", err)
	}
	if err := p.client.Close(); err != nil {
		return fmt.Errorf("close client: %w", err)
	}
	return nil
}
