package telemetry

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds all Prometheus counters and histograms.
type Metrics struct {
	httpRequestsTotal  *prometheus.CounterVec
	requestDuration    *prometheus.HistogramVec
	dbQueriesTotal     *prometheus.CounterVec
	dbQueryDuration    *prometheus.HistogramVec
	kafkaMessagesTotal prometheus.Counter
	configUpsertsTotal prometheus.Counter
	configReadsTotal   prometheus.Counter
}

// NewMetrics registers and returns all Prometheus metrics.
func NewMetrics() *Metrics {
	return &Metrics{
		httpRequestsTotal: promauto.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		}, []string{"method", "path", "status"}),

		requestDuration: promauto.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "request_duration_seconds",
			Help:    "HTTP request latency",
			Buckets: prometheus.DefBuckets,
		}, []string{"method", "path"}),

		dbQueriesTotal: promauto.NewCounterVec(prometheus.CounterOpts{
			Name: "db_queries_total",
			Help: "Total number of database queries",
		}, []string{"operation"}),

		dbQueryDuration: promauto.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "db_query_duration_seconds",
			Help:    "Database query latency",
			Buckets: prometheus.DefBuckets,
		}, []string{"operation"}),

		kafkaMessagesTotal: promauto.NewCounter(prometheus.CounterOpts{
			Name: "kafka_messages_total",
			Help: "Total number of Kafka messages published",
		}),

		configUpsertsTotal: promauto.NewCounter(prometheus.CounterOpts{
			Name: "config_upserts_total",
			Help: "Total number of config upsert operations",
		}),

		configReadsTotal: promauto.NewCounter(prometheus.CounterOpts{
			Name: "config_reads_total",
			Help: "Total number of config read operations",
		}),
	}
}

// ObserveHTTPRequest records HTTP request metrics.
func (m *Metrics) ObserveHTTPRequest(method, path string, status int, duration time.Duration) {
	m.httpRequestsTotal.WithLabelValues(method, path, strconv.Itoa(status)).Inc()
	m.requestDuration.WithLabelValues(method, path).Observe(duration.Seconds())
}

// ObserveDBQuery returns a function that records DB query duration when called.
func (m *Metrics) ObserveDBQuery(op string) func() {
	start := time.Now()
	m.dbQueriesTotal.WithLabelValues(op).Inc()
	return func() {
		m.dbQueryDuration.WithLabelValues(op).Observe(time.Since(start).Seconds())
	}
}

// IncKafkaMessages increments the Kafka messages counter.
func (m *Metrics) IncKafkaMessages() { m.kafkaMessagesTotal.Inc() }

// IncConfigUpserts increments the config upserts counter.
func (m *Metrics) IncConfigUpserts() { m.configUpsertsTotal.Inc() }

// IncConfigReads increments the config reads counter.
func (m *Metrics) IncConfigReads() { m.configReadsTotal.Inc() }

// HTTPStatusClass returns the 2xx/4xx/5xx class label.
func HTTPStatusClass(code int) string {
	switch {
	case code < 300:
		return "2xx"
	case code < 400:
		return "3xx"
	case code < 500:
		return "4xx"
	default:
		return "5xx"
	}
}

var _ = http.StatusOK
