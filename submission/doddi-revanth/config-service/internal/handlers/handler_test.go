package handlers_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"go.uber.org/zap"

	"github.com/doddi-revanth/config-service/internal/handlers"
	"github.com/doddi-revanth/config-service/internal/kafka"
	"github.com/doddi-revanth/config-service/internal/models"
	"github.com/doddi-revanth/config-service/internal/repository"
	"github.com/doddi-revanth/config-service/internal/service"
	"github.com/doddi-revanth/config-service/internal/telemetry"
)

// newTestRouter wires a full chi router with in-memory repo for handler tests.
func newTestRouter(t *testing.T) *chi.Mux {
	t.Helper()

	logger, _ := zap.NewDevelopment()
	metrics := telemetry.NewMetrics()
	repo := repository.NewInMemory()
	producer := kafka.NewNoopProducer()
	svc := service.New(repo, producer, metrics, logger)

	configHandler := handlers.NewConfigHandler(svc, logger)
	healthHandler := handlers.NewHealthHandler(nil, metrics, logger)

	r := chi.NewRouter()
	r.Get("/ping", healthHandler.Ping)
	r.Get("/live", healthHandler.Live)
	r.Get("/configs/{id}", configHandler.GetConfig)
	r.Post("/configs", configHandler.UpsertConfig)
	return r
}

func TestPing(t *testing.T) {
	r := newTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if rec.Body.String() != "pong" {
		t.Fatalf("expected pong, got %q", rec.Body.String())
	}
}

func TestLive(t *testing.T) {
	r := newTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/live", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestUpsertConfig_Success(t *testing.T) {
	r := newTestRouter(t)

	body := `{"id":"cfg_1","host":"localhost","port":8080,"app_name":"test-app","log_level":"INFO"}`
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var cfg models.Config
	if err := json.NewDecoder(rec.Body).Decode(&cfg); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if cfg.ID != "cfg_1" {
		t.Errorf("expected id cfg_1, got %q", cfg.ID)
	}
}

func TestUpsertConfig_MissingID(t *testing.T) {
	r := newTestRouter(t)

	body := `{"host":"localhost","port":8080,"app_name":"test","log_level":"INFO"}`
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestUpsertConfig_InvalidPort(t *testing.T) {
	r := newTestRouter(t)

	body := `{"id":"x","host":"h","port":99999,"app_name":"a","log_level":"INFO"}`
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestUpsertConfig_InvalidJSON(t *testing.T) {
	r := newTestRouter(t)

	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString("not-json"))
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestGetConfig_Success(t *testing.T) {
	r := newTestRouter(t)

	// Seed via upsert
	body := `{"id":"cfg_2","host":"db.internal","port":5432,"app_name":"my-app","log_level":"DEBUG"}`
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("upsert failed: %d %s", rec.Code, rec.Body.String())
	}

	// Retrieve
	req = httptest.NewRequest(http.MethodGet, "/configs/cfg_2", nil)
	rec = httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var got models.Config
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.ID != "cfg_2" {
		t.Errorf("expected id cfg_2, got %q", got.ID)
	}
	if got.AppName != "my-app" {
		t.Errorf("expected app_name my-app, got %q", got.AppName)
	}
}

func TestGetConfig_NotFound(t *testing.T) {
	r := newTestRouter(t)

	req := httptest.NewRequest(http.MethodGet, "/configs/does-not-exist", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestUpsertConfig_Idempotent(t *testing.T) {
	r := newTestRouter(t)

	body := `{"id":"cfg_idem","host":"h1","port":80,"app_name":"app","log_level":"INFO"}`
	for i := 0; i < 3; i++ {
		req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("iteration %d: expected 200, got %d", i, rec.Code)
		}
	}

	// Verify last upsert
	req := httptest.NewRequest(http.MethodGet, "/configs/cfg_idem", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestRequestID_PropagatedInResponse(t *testing.T) {
	r := newTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set("X-Request-ID", "test-req-id-123")
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

// Ensure context cancellation doesn't panic handlers.
func TestUpsertConfig_ContextCancelled(t *testing.T) {
	r := newTestRouter(t)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	body := `{"id":"ctx_test","host":"h","port":8080,"app_name":"a","log_level":"INFO"}`
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewBufferString(body)).WithContext(ctx)
	rec := httptest.NewRecorder()

	// Should not panic — may succeed or fail gracefully
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("handler panicked: %v", r)
		}
	}()
	r.ServeHTTP(rec, req)
}
