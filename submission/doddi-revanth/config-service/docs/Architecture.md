# Architecture

## Overview

Config Service follows **Clean Architecture** with strict layer separation. Each layer depends only inward — handlers know about the service, the service knows about the repository and kafka interfaces, the repository knows about the database.

```
┌────────────────────────────────────────────────┐
│  HTTP Layer  (internal/handlers)               │
│  - Thin: decode → validate → call service      │
│  - Writes JSON, sets status, propagates errors │
├────────────────────────────────────────────────┤
│  Service Layer  (internal/service)             │
│  - Business rules                              │
│  - Orchestrates repo + kafka (best-effort)     │
│  - OTel spans per operation                    │
├────────────────────────────────────────────────┤
│  Repository Interface  (internal/repository)   │
│  - Get(ctx, id) → *Config                      │
│  - Upsert(ctx, *Config) → error                │
│  Implementations:                              │
│    ├── Postgres  (pgxpool, ON CONFLICT)        │
│    └── InMemory  (sync.RWMutex map — tests)    │
├────────────────────────────────────────────────┤
│  Models  (internal/models)                     │
│  - Config struct (DB + JSON tags)              │
│  - UpsertRequest (validation built-in)         │
│  - ErrorResponse (standard error body)         │
└────────────────────────────────────────────────┘
```

## Dependency Injection

All dependencies are injected at `main()` — no global state. This makes unit testing straightforward: swap the Postgres repo for InMemory, swap SaramaProducer for NoopProducer.

```
main()
  └── config.Load()
  └── telemetry.Init()      → TracerProvider, MeterProvider
  └── telemetry.NewLogger() → *zap.Logger
  └── telemetry.NewMetrics()→ *Metrics (Prometheus counters/histograms)
  └── database.NewPool()    → *pgxpool.Pool
  └── database.RunMigrations()
  └── kafka.NewSaramaProducer() (or NoopProducer if disabled)
  └── repository.NewPostgres(pool, metrics)
  └── service.New(repo, producer, metrics, logger)
  └── handlers.NewConfigHandler(svc, logger)
  └── handlers.NewHealthHandler(health.Checker, metrics, logger)
  └── chi.Router (+ middleware chain)
  └── http.Server (graceful shutdown on SIGTERM/SIGINT)
```

## Middleware Chain

```
Request
  │
  ▼ chimiddleware.RealIP       — set RemoteAddr from X-Forwarded-For
  ▼ middleware.RequestID       — inject/propagate X-Request-ID
  ▼ middleware.Recovery        — panic → 500, stack trace logged
  ▼ middleware.Logging         — structured JSON log per request
  ▼ middleware.Timeout(30s)    — context deadline per request
  ▼
  Handler
```

## Data Flow: POST /configs

```
HTTP POST /configs
  │
  ▼ UpsertConfig handler
      decode JSON → UpsertRequest
      validate (id, host, port, app_name, log_level)
      │
      ▼ service.UpsertConfig(ctx, req)
          OTel span: service.UpsertConfig
          │
          ├──► repository.Upsert(ctx, cfg)
          │       INSERT ... ON CONFLICT (id) DO UPDATE SET ...
          │       ObserveDBQuery("upsert") — Prometheus histogram
          │
          └──► kafka.PublishConfigEvent(ctx, event)  [best-effort]
                  SaramaProducer.SendMessage()
                  OR NoopProducer (if ENABLE_KAFKA=false or unavailable)
      │
      ▼ 200 JSON response
```

## Database Schema

```sql
CREATE TABLE configs (
    id         TEXT PRIMARY KEY,
    host       TEXT        NOT NULL,
    port       INTEGER     NOT NULL CHECK (port >= 1 AND port <= 65535),
    app_name   TEXT        NOT NULL,
    log_level  TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_configs_app_name ON configs (app_name);
```

**Design decisions:**
- `TEXT PRIMARY KEY` — flexible, no sequence required, human-readable IDs
- `TIMESTAMPTZ` — timezone-aware, avoids DST edge cases
- `CHECK (port >= 1 AND port <= 65535)` — database-level port validation
- Index on `app_name` — anticipates future queries filtering by application
- `ON CONFLICT (id) DO UPDATE` — single query for upsert, no race conditions

## Kafka Event Schema

```json
{
  "event_type": "UPSERT",
  "config_id":  "cfg_1",
  "timestamp":  "2024-01-01T12:00:00Z",
  "app_name":   "my-service"
}
```

- Key = `config_id` — ensures ordered delivery per config within a partition
- Topic `config-events` — 3 partitions for parallelism
- Sync producer with `WaitForAll` acks — no message loss

## Graceful Shutdown

```
SIGTERM/SIGINT received
  │
  ▼ http.Server.Shutdown(ctx, 30s timeout)
      - Stop accepting new connections
      - Drain in-flight requests
  │
  ▼ Kafka producer Close()
  │
  ▼ pgxpool Close()
  │
  ▼ OTel TracerProvider/MeterProvider Shutdown(5s)
  │
  ▼ Process exits 0
```
