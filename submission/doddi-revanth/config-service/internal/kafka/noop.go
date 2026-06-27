package kafka

import "context"

// NoopProducer is a no-op Producer used when Kafka is disabled.
type NoopProducer struct{}

// NewNoopProducer returns a NoopProducer.
func NewNoopProducer() *NoopProducer { return &NoopProducer{} }

func (n *NoopProducer) PublishConfigEvent(_ context.Context, _ ConfigEvent) error { return nil }
func (n *NoopProducer) Ping(_ context.Context) error                              { return nil }
func (n *NoopProducer) Close() error                                              { return nil }
