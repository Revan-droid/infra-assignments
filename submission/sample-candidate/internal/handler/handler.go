package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"config-service/internal/domain"
	"config-service/internal/repository"
	"config-service/internal/service"
)

// Handler wires HTTP routes to service calls.
type Handler struct {
	svc *service.Service
}

// New creates a Handler backed by the given service.
func New(svc *service.Service) *Handler {
	return &Handler{svc: svc}
}

// RegisterRoutes attaches all routes to mux.
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /ping", h.ping)
	mux.HandleFunc("GET /configs/{id}", h.getConfig)
	mux.HandleFunc("POST /configs", h.upsertConfig)
}

func (h *Handler) ping(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("pong"))
}

func (h *Handler) getConfig(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	cfg, err := h.svc.GetConfig(r.Context(), id)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			http.Error(w, "config not found", http.StatusNotFound)
			return
		}
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(cfg)
}

func (h *Handler) upsertConfig(w http.ResponseWriter, r *http.Request) {
	var cfg domain.Config
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if cfg.ID == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}

	if err := h.svc.UpsertConfig(r.Context(), &cfg); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(cfg)
}
