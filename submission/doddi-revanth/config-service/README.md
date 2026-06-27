# Config Service

> A production-style Go service for storing application config in PostgreSQL, emitting Kafka events, and exposing traces, metrics, and logs.

## Architecture

```text
                    +-------------------------------+
                    |           Clients             |
                    | curl / smoke-test / Grafana   |
                    +---------------+---------------+
                                    |
                                    v
                      +-------------+-------------+
                      |       config-service      |
                      | chi + middleware + OTel   |
                      +------+------+------+------+
                             |      |      |
                             |      |      +--------------------+
                             |      |                           |
                             v      v                           v
                    +-----------+  +----------------+   +---------------+
                    | PostgreSQL |  |     Kafka      |   | OTel Collector|
                    | configs    |  | config-events  |   +-------+-------+
                    +-----------+  +----------------+           |
                                                                 v
                                             +-------------------+-------------------+
                                             | Jaeger | Prometheus | Loki | Grafana |
                                             +---------------------------------------+
```

## Quick Start

### Option 1: Docker Compose (5 min) — Recommended for local dev

**Prerequisites**
- Docker Desktop

**Start the full stack**

```bash
cd submission/doddi-revanth/config-service

docker compose up -d --build
```

**Verify the stack**

```bash
docker compose ps
curl http://localhost:8080/ping
curl http://localhost:8080/ready
./scripts/smoke-test.sh http://localhost:8080
```

**Create and read a config**

```bash
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"cfg_1","host":"db.internal","port":5432,"app_name":"my-app","log_level":"INFO"}'

curl http://localhost:8080/configs/cfg_1
```

**Dashboard and service URLs**

| Service | URL | Notes |
|---|---|---|
| App API | http://localhost:8080 | `GET /ping`, `POST /configs` |
| Grafana | http://localhost:3000 | login `admin / admin` |
| Prometheus | http://localhost:9090 | metrics queries |
| Jaeger | http://localhost:16686 | traces |
| Loki | http://localhost:3100/ready | direct readiness endpoint |

**Stop the stack**

```bash
docker compose down
docker compose down -v
```

### Option 2: Minikube (15 min) — Kubernetes experience

**Prerequisites**

```bash
brew install minikube kubectl helm crane
```

**Deploy everything**

```bash
cd submission/doddi-revanth/config-service

./scripts/minikube-setup.sh
```

The script vendors Go modules with `golang:1.22`, builds `config-service:local` directly inside the Minikube Docker daemon, deploys the app with `image.pullPolicy=Never`, and installs infra charts with `IfNotPresent`.

**Port-forward the services**

```bash
kubectl -n config-service port-forward svc/config-service 8080:80
kubectl -n config-service port-forward svc/prometheus-grafana 3000:80
kubectl -n config-service port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
kubectl -n config-service port-forward svc/jaeger 16686:16686
kubectl -n config-service port-forward svc/loki 3100:3100
```

**Verify the deployment**

```bash
kubectl -n config-service get pods
curl http://localhost:8080/ping
curl http://localhost:8080/ready
./scripts/smoke-test.sh http://localhost:8080
```

### Option 3: Kind (Advanced — requires corporate network workarounds)

Use Minikube unless you specifically want to inspect the Kind flow. `scripts/kind-setup.sh` is included, but it assumes `brew install kind kubectl helm crane` and uses `linux/amd64` image pulls plus `crane` archives to work around Apple Silicon and corporate-network registry issues.

## Go Application — Code Walkthrough

### Project Structure

```text
.
├── .github/workflows/ci.yml                 # CI pipeline: vet, lint, tests, build, helm, terraform, YAML
├── .github/workflows/cd.yml                 # CD-shaped pipeline: validate, push image, helm dry-run
├── cmd/server/main.go                       # Application bootstrap, dependency wiring, routes, graceful shutdown
├── config.yaml.example                      # Optional file-based config example for local runs
├── deployments/helm/config-service/         # Helm chart for the application deployment
├── deployments/manifests/                   # Compose/Grafana/Prometheus/OTel/Kind support manifests
├── docker-compose.yml                       # One-command local platform stack
├── Dockerfile                               # Multi-stage image build for the Go service
├── docs/                                    # Supporting notes and assignment artifacts
├── internal/                                # Application code: config, handlers, service, repo, telemetry
├── migrations/                              # Embedded SQL schema migrations
├── scripts/                                 # Setup, migration, and smoke-test automation
├── terraform/                               # Local-cluster Terraform validation modules
├── go.mod                                   # Go module definition
├── go.sum                                   # Module checksums
├── Makefile                                 # Convenience targets for build/test/deploy flows
└── README.md                                # Reviewer guide
```

### internal/ — The Go Application

- `internal/config/` — Viper config loading with precedence **env vars > config.yaml > defaults**.
- `internal/models/` — Domain structs: `Config`, `UpsertRequest`, `ErrorResponse`.
- `internal/database/` — `pgxpool` connection factory plus startup migrations; DB connect retries up to 10 times.
- `internal/repository/` — `Repository` interface, PostgreSQL implementation, and in-memory repository for tests.
- `internal/service/` — Business logic for `GetConfig` and `UpsertConfig`; publishes Kafka events after successful upserts.
- `internal/handlers/` — HTTP endpoints: `GET /configs/{id}` and `POST /configs` plus health endpoints.
- `internal/health/` — Readiness checks for PostgreSQL and Kafka.
- `internal/kafka/` — Producer abstraction: real `SaramaProducer` and fallback `NoopProducer` when `ENABLE_KAFKA=false`.
- `internal/middleware/` — Request ID propagation, JSON request logging, panic recovery, and per-request timeout.
- `internal/telemetry/` — OpenTelemetry setup, Prometheus metrics registration, and Zap logger construction.

### migrations/ — SQL Migrations

- `000001_create_configs.up.sql` — creates the `configs` table and `idx_configs_app_name` index.
- `000001_create_configs.down.sql` — drops the `configs` table.
- `embed.go` — `//go:embed *.sql` compiles the SQL files into the binary.
- **Why embed?** The migration runner should not depend on loose runtime files. Embedding makes startup self-contained and is especially useful for distroless-style containers where shipping extra filesystem assets is awkward.
- `RunMigrations()` is called automatically during process startup in `cmd/server/main.go`.

### Request Flow (POST /configs)

```text
HTTP Request
  → middleware (RequestID → Logging → Recovery → Timeout)
  → ConfigHandler.UpsertConfig
  → service.UpsertConfig (OTel span)
  → repository.Upsert (pgx ON CONFLICT upsert)
  → kafka.PublishConfigEvent (best-effort, warn on failure)
  → HTTP 200 + JSON response
```

## API Reference

| Method | Path | Purpose | Example |
|---|---|---|---|
| GET | `/ping` | Basic liveness check | `curl http://localhost:8080/ping` |
| GET | `/live` | Kubernetes liveness probe | `curl http://localhost:8080/live` |
| GET | `/ready` | Readiness check for DB + Kafka | `curl http://localhost:8080/ready` |
| GET | `/metrics` | Prometheus scrape endpoint | `curl http://localhost:8080/metrics` |
| GET | `/configs/{id}` | Fetch one config | `curl http://localhost:8080/configs/cfg_1` |
| POST | `/configs` | Create or update config | see below |

**POST /configs**

```bash
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"cfg_1","host":"db.internal","port":5432,"app_name":"my-app","log_level":"INFO"}'
```

**Success response**

```json
{
  "id": "cfg_1",
  "host": "db.internal",
  "port": 5432,
  "app_name": "my-app",
  "log_level": "info",
  "created_at": "2026-06-27T00:00:00Z",
  "updated_at": "2026-06-27T00:00:00Z"
}
```

**Error response**

```json
{
  "error": "port must be between 1 and 65535",
  "code": 400,
  "trace_id": "req-123"
}
```

## Observability

### Jaeger (Distributed Tracing)

Generate traffic:

```bash
curl http://localhost:8080/configs/cfg_1
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"trace-demo","host":"trace.internal","port":8081,"app_name":"trace-app","log_level":"INFO"}'
```

Open Jaeger at **http://localhost:16686**, choose service `config-service`, then inspect `handler.GetConfig` or `handler.UpsertConfig` traces.

### Grafana Dashboard (Metrics + Logs)

- URL: **http://localhost:3000**
- Credentials: **admin / admin**
- The dashboard shows request rate, error rate, p99 latency, config upserts, config reads, Kafka events, DB query rate/latency, and live logs.
- Generate data with:

```bash
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:8080/configs \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"bulk-$i\",\"host\":\"10.0.0.$i\",\"port\":808$i,\"app_name\":\"svc-$i\",\"log_level\":\"INFO\"}" >/dev/null
  curl -s http://localhost:8080/configs/bulk-$i >/dev/null
done
```

- Dashboard provisioning is automatic because Docker Compose mounts three files into Grafana:
  - `deployments/manifests/grafana-datasource.yml`
  - `deployments/manifests/grafana-dashboard-provisioning.yml`
  - `deployments/manifests/grafana-dashboard.json`

### Prometheus

- URL: **http://localhost:9090**
- Useful metrics:
  - `http_requests_total`
  - `request_duration_seconds`
  - `db_queries_total`
  - `db_query_duration_seconds`
  - `config_upserts_total`
  - `config_reads_total`
  - `kafka_messages_total`

### Loki (Logs)

Use Grafana Explore with datasource **Loki** and query:

```logql
{container="config-service"}
```

Useful filter example:

```logql
{container="config-service"} |= "error"
```

## CI/CD Pipelines

### CI Pipeline (.github/workflows/ci.yml)

The CI workflow runs on pushes to `main`/`develop` and PRs targeting `main` for this project path.

- `go-quality` — `go vet`, `gofmt` check, and `golangci-lint`.
- `unit-tests` — `go test ./... -race -count=1 -timeout 60s` plus coverage upload.
- `docker-build` — builds the container image with GitHub Actions layer caching.
- `helm-lint` — `helm lint` plus `helm template` dry-run.
- `terraform` — `terraform fmt -check` and `terraform validate` for `terraform/local`.
- `yaml-lint` — runs `yamllint` over the repository.

### CD Pipeline (.github/workflows/cd.yml)

- Triggers: `workflow_dispatch` or a successful CI completion on `main`.
- `validate` — `helm lint` and `helm template` with the new image tag.
- `docker-build-push` — builds the app image and pushes it to `ghcr.io` using the repository owner plus the commit SHA tag.
- `deploy-dry-run` — runs `helm upgrade --install --dry-run=client` with the freshly built image tag.
- This pipeline **does not deploy to a real cluster** because this assignment targets local Kind/Minikube environments.
- In a real environment, add a kubeconfig secret, cluster credentials, and a non-dry-run `helm upgrade --install` step.
- GitHub secret required: `GHCR_TOKEN` for pushing to GitHub Container Registry.
- Actual cluster deployment for this repository is done locally with `scripts/kind-setup.sh` or `scripts/minikube-setup.sh`.

## Testing

### What's tested

- `internal/handlers/handler_test.go` — HTTP handler behavior using the in-memory repo; no database required.
- `internal/repository/repository_test.go` — in-memory repository correctness and concurrency behavior.
- `internal/service/service_test.go` — service logic with mocked/fake dependencies.

### Run tests

```bash
cd submission/doddi-revanth/config-service

# Run all tests
docker run --rm -v "$(pwd)":/workspace -w /workspace golang:1.22 go test ./... -race -v

# With coverage
docker run --rm -v "$(pwd)":/workspace -w /workspace golang:1.22 go test ./... -race -coverprofile=coverage.out
```

### Smoke test

```bash
cd submission/doddi-revanth/config-service
./scripts/smoke-test.sh http://localhost:8080
```

## Configuration Reference

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `LOG_LEVEL` | `info` | Zap log verbosity |
| `DATABASE_URL` | `postgres://configuser:configpass@localhost:5432/configdb?sslmode=disable` | PostgreSQL connection string |
| `KAFKA_BROKERS` | `localhost:9092` | Comma-separated Kafka brokers |
| `ENABLE_KAFKA` | `false` | Enables real Kafka producer instead of noop |
| `ENABLE_METRICS` | `true` | Exposes Prometheus metrics |
| `OTLP_ENDPOINT` | `` | OTLP gRPC endpoint for trace export |

Config loading order is **environment variables first, then `config.yaml`, then hardcoded defaults**.

## Security

- Runs as non-root in Kubernetes (`runAsUser: 65532`, `runAsNonRoot: true`).
- Uses a read-only root filesystem in the Helm deployment.
- Drops all Linux capabilities and disallows privilege escalation.
- Includes a PodDisruptionBudget with `minAvailable: 1`.
- Includes a NetworkPolicy restricting egress to PostgreSQL, Kafka, DNS, and OTLP.

## Known Limitations

- No authentication or authorization layer.
- Only the latest config value is stored; there is no version history.
- Kafka publishing is best-effort and does not block successful writes.
- Jaeger and Loki are configured for local/demo usage, not durable production storage.
- The GitHub CD workflow demonstrates structure only; real deployment credentials are intentionally not wired in.
