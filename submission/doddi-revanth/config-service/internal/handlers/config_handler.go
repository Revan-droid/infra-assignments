package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/go-chi/chi/v5"
	"go.opentelemetry.io/otel"
	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/middleware"
	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/service"
)

var tracer = otel.Tracer("config-service/handlers")

// ConfigHandler handles HTTP requests for Config operations.
type ConfigHandler struct {
	svc    *service.ConfigService
	logger *zap.Logger
}

// NewConfigHandler creates a ConfigHandler.
func NewConfigHandler(svc *service.ConfigService, logger *zap.Logger) *ConfigHandler {
	return &ConfigHandler{svc: svc, logger: logger}
}

// GetConfig handles GET /configs/{id}.
func (h *ConfigHandler) GetConfig(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "handler.GetConfig")
	defer span.End()

	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, "id is required", http.StatusBadRequest, "")
		return
	}

	cfg, err := h.svc.GetConfig(ctx, id)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			writeError(w, "config not found", http.StatusNotFound, middleware.GetRequestID(r))
			return
		}
		h.logger.Error("get config failed",
			zap.String("request_id", middleware.GetRequestID(r)),
			zap.String("id", id),
			zap.Error(err),
		)
		writeError(w, "internal server error", http.StatusInternalServerError, middleware.GetRequestID(r))
		return
	}

	writeJSON(w, http.StatusOK, cfg)
}

// UpsertConfig handles POST /configs.
func (h *ConfigHandler) UpsertConfig(w http.ResponseWriter, r *http.Request) {
	ctx, span := tracer.Start(r.Context(), "handler.UpsertConfig")
	defer span.End()
	defer r.Body.Close()

	var req models.UpsertRequest
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest, middleware.GetRequestID(r))
		return
	}

	var extra json.RawMessage
	if err := decoder.Decode(&extra); err != io.EOF {
		writeError(w, "request body must contain a single JSON object", http.StatusBadRequest, middleware.GetRequestID(r))
		return
	}

	if msg := req.Validate(); msg != "" {
		writeError(w, msg, http.StatusBadRequest, middleware.GetRequestID(r))
		return
	}

	cfg, err := h.svc.UpsertConfig(ctx, &req)
	if err != nil {
		h.logger.Error("upsert config failed",
			zap.String("request_id", middleware.GetRequestID(r)),
			zap.String("id", req.ID),
			zap.Error(err),
		)
		writeError(w, "internal server error", http.StatusInternalServerError, middleware.GetRequestID(r))
		return
	}

	writeJSON(w, http.StatusOK, cfg)
}

// writeJSON writes a JSON response with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError writes a standard JSON error response.
func writeError(w http.ResponseWriter, msg string, status int, traceID string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(models.ErrorResponse{
		Error:   msg,
		Code:    status,
		TraceID: traceID,
	})
}
