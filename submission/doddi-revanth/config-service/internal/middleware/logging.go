package middleware

import (
	"net/http"
	"time"

	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/telemetry"
)

// responseWriter wraps http.ResponseWriter to capture status code.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.status = code
	rw.ResponseWriter.WriteHeader(code)
}

// Logging is structured request/response logging middleware using zap.
func Logging(logger *zap.Logger, metrics *telemetry.Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}

			next.ServeHTTP(rw, r)

			latency := time.Since(start)
			metrics.ObserveHTTPRequest(r.Method, r.URL.Path, rw.status, latency)

			logger.Info("request",
				zap.String("request_id", GetRequestID(r)),
				zap.String("method", r.Method),
				zap.String("path", r.URL.Path),
				zap.Int("status", rw.status),
				zap.Duration("latency", latency),
				zap.String("remote_ip", r.RemoteAddr),
				zap.String("user_agent", r.UserAgent()),
			)
		})
	}
}
