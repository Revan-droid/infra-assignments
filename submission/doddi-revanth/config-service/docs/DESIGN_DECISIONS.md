# Design Decisions & Reviewer FAQ

## Why Kafka? (When the assignment says "optional")

The assignment says Kafka should be optional using feature flags — Kafka **is** optional here.
`ENABLE_KAFKA=false` (the default) swaps in a `NoopProducer` so the service works with zero
Kafka dependency. In Docker Compose and Minikube, `ENABLE_KAFKA=true` is set via env/configmap.

**Why I added it at all:**

1. **Event-driven architecture pattern** — Config changes are a classic fan-out scenario. Any
   downstream service (audit logger, cache invalidator, feature-flag reloader) can subscribe
   to `config-events` without coupling to the config-service HTTP API. This is the standard
   pattern in microservice platforms.

2. **Producer abstraction (`kafka.Producer` interface)** — The codebase shows the interface
   pattern: `SaramaProducer` for real Kafka, `NoopProducer` as fallback. This is exactly how
   production services handle optional integrations — no `if kafka != nil` scattered through
   business logic, just swap the implementation.

3. **Observability integration** — `kafka_messages_total` metric gives visibility into event
   publishing. If Kafka is down, the service logs a warn and continues — the write to Postgres
   always succeeds. This is "best-effort" publishing, the right pattern for non-critical
   side-effects.

4. **Topic: `config-events`** — Keyed by `config_id` (Sarama `StringEncoder`), which ensures
   all events for the same config land on the same partition → ordered processing per config.

## Why Vendor Directory?

Corporate Mac environments run Docker Desktop with a Linux VM. The Linux Go builder
(`golang:1.22`) does not inherit macOS system certificates, causing TLS failures when
`go mod download` tries to fetch modules through a corporate HTTPS proxy.

Vendoring (`go mod vendor`) eliminates all network access during `docker build`. The
`-mod=vendor` flag in the Dockerfile Dockerfile makes this explicit. The vendor dir is
committed so reviewers can build the image without Go or internet access.

## What I Added Beyond the Assignment

The assignment spec is in `INFRA_ASSIGNMENT.md`. Everything below was added on top:

| Addition | Why |
|---|---|
| `vendor/` directory | Corporate TLS proxy blocks go module downloads in Linux containers |
| `VISUALISE.md` | Reviewers can see all outputs without running the stack |
| `docs/Architecture.md` | Explains clean-arch layers and data flow |
| `docs/Runbook.md` | Operational procedures (scale, rollback, DB backup) |
| `docs/Troubleshooting.md` | Common failure modes and debug steps |
| `docs/Observability.md` | How to use Grafana/Jaeger/Loki together |
| `docs/Deployment.md` | Step-by-step Helm + Terraform deployment |
| Grafana dashboard auto-provisioning | Both docker-compose and Minikube auto-import the dashboard — no manual clicking |
| `RETURNING created_at` in upsert query | Ensures update response returns original `created_at`, not current time |
| `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout`, `IdleTimeout` | HTTP server hardening — prevents Slowloris attacks |
| `io.LimitReader(r.Body, 1<<20)` in handler | 1 MB request body cap — prevents memory exhaustion |
| `decoder.DisallowUnknownFields()` | Rejects typos in JSON field names — better DX |
| Double-decode check for extra JSON | Rejects requests with trailing garbage after valid JSON |
| `PodDisruptionBudget` | Ensures rolling upgrades never take all pods offline |
| `NetworkPolicy` | Restricts egress to only Postgres, Kafka, DNS, OTLP — defence in depth |
| `HorizontalPodAutoscaler` | Scales 2→5 replicas on CPU >70% |
| `metrics-server` addon in minikube script | Required for HPA to read CPU metrics |
| OTel Collector + Jaeger | Traces across handler → service → DB → Kafka layers |
| Loki + Promtail | Structured log aggregation — matches assignment's "Operational readiness" |
| `make port-forward` | Forwards all 4 services at once — one command for reviewers |

## Architecture Decisions

### Clean Architecture Layers

```
cmd/server/main.go     ← Wiring only, no business logic
internal/handlers/     ← HTTP concerns only (decode, validate, encode)
internal/service/      ← Business logic, OTel spans, metric increments
internal/repository/   ← DB access only, ErrNotFound sentinel
internal/kafka/        ← Producer interface + two implementations
internal/telemetry/    ← OTel + Prometheus + Zap setup
internal/health/       ← Dependency checks (DB ping, Kafka metadata refresh)
internal/middleware/   ← Cross-cutting: RequestID, Logging, Recovery, Timeout
```

### Why `pgxpool` not `database/sql`?

`pgxpool` is the idiomatic PostgreSQL driver for Go. It supports connection pooling,
prepared statements, and PostgreSQL-native types. `database/sql` is generic and loses
Postgres-specific features. `pgxpool` also exposes `QueryRow` that returns `pgx.ErrNoRows`
(not `sql.ErrNoRows`), making error handling more explicit.

### Why Sarama (IBM/sarama) not confluent-kafka-go?

`confluent-kafka-go` requires CGO and a librdkafka system library — that breaks
`CGO_ENABLED=0` cross-compilation and makes the Docker image larger. Sarama is pure Go,
compiles to a static binary, and works with `-mod=vendor`.

### Why chi not gin/echo?

`chi` uses the stdlib `net/http` interface exactly — no framework-specific context, no
middleware lock-in. Every middleware is a `func(http.Handler) http.Handler`. The OTel and
Prometheus integrations plug in without adapters. Gin and Echo use their own context types
which adds indirection.
