package handlers

import (
	"encoding/json"
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/health"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

// HealthHandler handles /ping, /live, /ready, /metrics endpoints.
type HealthHandler struct {
	checker *health.Checker
	metrics *telemetry.Metrics
	logger  *zap.Logger
}

// NewHealthHandler creates a HealthHandler.
func NewHealthHandler(checker *health.Checker, metrics *telemetry.Metrics, logger *zap.Logger) *HealthHandler {
	return &HealthHandler{checker: checker, metrics: metrics, logger: logger}
}

// Ping handles GET /ping — basic liveness indicator.
func (h *HealthHandler) Ping(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("pong"))
}

// Live handles GET /live — Kubernetes liveness probe.
func (h *HealthHandler) Live(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"alive"}`))
}

// Ready handles GET /ready — Kubernetes readiness probe.
// Returns 200 if all dependencies are healthy, 503 otherwise.
func (h *HealthHandler) Ready(w http.ResponseWriter, r *http.Request) {
	report := h.checker.Check(r.Context())

	status := http.StatusOK
	for _, healthy := range report {
		if !healthy {
			status = http.StatusServiceUnavailable
			break
		}
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status": map[bool]string{true: "ready", false: "not ready"}[status == http.StatusOK],
		"checks": report,
	})
}

// Metrics handles GET /metrics — Prometheus metrics exposition.
func (h *HealthHandler) Metrics(w http.ResponseWriter, r *http.Request) {
	promhttp.Handler().ServeHTTP(w, r)
}
