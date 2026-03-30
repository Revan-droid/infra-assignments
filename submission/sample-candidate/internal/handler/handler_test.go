package handler_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"config-service/internal/domain"
	"config-service/internal/handler"
	"config-service/internal/repository"
	"config-service/internal/service"
)

func newTestMux() *http.ServeMux {
	repo := repository.NewInMemory()
	svc := service.New(repo)
	h := handler.New(svc)
	mux := http.NewServeMux()
	h.RegisterRoutes(mux)
	return mux
}

func TestPing(t *testing.T) {
	mux := newTestMux()

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if rec.Body.String() != "pong" {
		t.Fatalf("expected body pong, got %q", rec.Body.String())
	}
}

func TestUpsertConfig(t *testing.T) {
	mux := newTestMux()

	cfg := domain.Config{
		ID:       "cfg_1",
		Host:     "localhost",
		Port:     8080,
		AppName:  "test-app",
		LogLevel: "INFO",
	}
	body, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestGetConfig(t *testing.T) {
	mux := newTestMux()

	cfg := domain.Config{
		ID:       "cfg_2",
		Host:     "db.internal",
		Port:     5432,
		AppName:  "my-app",
		LogLevel: "DEBUG",
	}
	body, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// seed via upsert
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("upsert: expected 200, got %d", rec.Code)
	}

	// retrieve
	req = httptest.NewRequest(http.MethodGet, "/configs/cfg_2", nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("get: expected 200, got %d", rec.Code)
	}

	var got domain.Config
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.ID != cfg.ID {
		t.Fatalf("expected id %q, got %q", cfg.ID, got.ID)
	}
	if got.Host != cfg.Host {
		t.Fatalf("expected host %q, got %q", cfg.Host, got.Host)
	}
}

func TestGetConfigNotFound(t *testing.T) {
	mux := newTestMux()

	req := httptest.NewRequest(http.MethodGet, "/configs/does-not-exist", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestUpsertConfigMissingID(t *testing.T) {
	mux := newTestMux()

	body := []byte(`{"host":"localhost","port":8080}`)
	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}

func TestUpsertConfigInvalidBody(t *testing.T) {
	mux := newTestMux()

	req := httptest.NewRequest(http.MethodPost, "/configs", bytes.NewReader([]byte("not-json")))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
}
