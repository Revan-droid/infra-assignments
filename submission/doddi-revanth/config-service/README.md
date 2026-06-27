# Config Service

> Production-grade Configuration Service — Go 1.22 · PostgreSQL 16 · Kafka · Kubernetes (Kind) · Terraform · OpenTelemetry · Jaeger · Loki · Prometheus · Grafana

---

## Table of Contents

1. [Quick Start — docker-compose](#1-quick-start--docker-compose-5-minutes)
2. [Quick Start — Kind (Kubernetes)](#2-quick-start--kind-kubernetes-15-minutes)
3. [How the Go Application Works](#3-how-the-go-application-works)
4. [API Reference](#4-api-reference)
5. [Observability: Jaeger, Prometheus, Loki, Grafana](#5-observability-jaeger-prometheus-loki-grafana)
6. [Infrastructure Design](#6-infrastructure-design)
7. [Configuration & Secrets](#7-configuration--secrets)
8. [Security](#8-security)
9. [CI/CD](#9-cicd)
10. [Known Limitations & Future Work](#10-known-limitations--future-work)

---

## 1. Quick Start — docker-compose (5 minutes)

**Everything runs locally in Docker — no Kubernetes needed.**

### Prerequisites
- Docker Desktop (any recent version)

### Start all services

```bash
cd submission/doddi-revanth/config-service

docker compose up -d
```

This starts **9 containers** in dependency order:

```
postgres ──► app ──► (metrics scraped by) prometheus ──► grafana
zookeeper ──► kafka ──► app
otel-collector ◄── app (traces) ──► jaeger
loki ◄── promtail (scrapes docker logs)
grafana ◄── loki + prometheus
```

### Watch the app start

```bash
docker compose logs -f app
```

Expected output:
```json
{"msg":"starting config-service","port":"8080","kafka_enabled":true}
{"msg":"database connection established"}
{"msg":"database migrations applied"}
{"msg":"kafka producer connected","brokers":["kafka:9092"]}
{"msg":"server listening","addr":":8080"}
```

### Check all containers are running

```bash
docker compose ps
```

All should show `Up` or `Up (healthy)`.

### Test all endpoints

```bash
# 1. Liveness
curl http://localhost:8080/ping
# → pong

# 2. Readiness (checks DB + Kafka)
curl http://localhost:8080/ready
# → {"status":"ready","checks":{"database":true,"kafka":true}}

# 3. Create a config
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"cfg_1","host":"db.internal","port":5432,"app_name":"my-app","log_level":"INFO"}'

# 4. Read it back
curl http://localhost:8080/configs/cfg_1

# 5. Update (upsert — same id, different values)
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"cfg_1","host":"updated.internal","port":9090,"app_name":"my-app","log_level":"DEBUG"}'

# 6. 404 case
curl http://localhost:8080/configs/does-not-exist

# 7. Validation error (missing id)
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"host":"localhost","port":8080}'

# 8. Metrics
curl http://localhost:8080/metrics | grep -E "^(config_|http_requests_total|kafka_)"
```

### Run automated smoke test

```bash
./scripts/smoke-test.sh
# → All 13 checks pass ✅
```

### Check Kafka event was published

```bash
docker exec -it config-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic config-events \
  --from-beginning
```

You'll see:
```json
{"event_type":"UPSERT","config_id":"cfg_1","timestamp":"2024-...","app_name":"my-app"}
```

### Check database directly

```bash
docker exec -it config-postgres psql -U configuser -d configdb \
  -c "SELECT id, host, port, app_name, log_level, updated_at FROM configs;"
```

### Access dashboards

| Service    | URL                      | Login         |
|------------|--------------------------|---------------|
| Grafana    | http://localhost:3000     | admin / admin |
| Prometheus | http://localhost:9090     | —             |
| Jaeger     | http://localhost:16686    | —             |

### Stop everything

```bash
docker compose down        # keep data
docker compose down -v     # wipe all data (postgres, prometheus, etc.)
```

---

## 2. Quick Start — Kind (Kubernetes) (15 minutes)

**Full production-like deployment on a local Kubernetes cluster.**

### Prerequisites

| Tool      | Install                          |
|-----------|----------------------------------|
| Docker    | Already installed                |
| Kind      | `brew install kind`              |
| kubectl   | `brew install kubectl`           |
| Helm      | `brew install helm`              |

### Option A — Automated (one script)

```bash
cd submission/doddi-revanth/config-service

./scripts/kind-setup.sh
```

This script does everything:
1. Creates a 3-node Kind cluster
2. Builds and loads the Docker image
3. Deploys PostgreSQL (Bitnami Helm)
4. Deploys Kafka (Bitnami Helm)
5. Deploys Prometheus + Grafana (kube-prometheus-stack)
6. Deploys Jaeger
7. Deploys OpenTelemetry Collector
8. Deploys Loki + Promtail
9. Deploys config-service via Helm

Total time: ~10-15 minutes (mostly waiting for images).

### Option B — Step by step

```bash
# 1. Create cluster
kind create cluster --name config-service \
  --config deployments/manifests/kind-config.yaml

# 2. Build & load image
docker build -t config-service:local .
kind load docker-image config-service:local --name config-service

# 3. Add Helm repos
helm repo add bitnami    https://charts.bitnami.com/bitnami
helm repo add prometheus https://prometheus-community.github.io/helm-charts
helm repo add grafana    https://grafana.github.io/helm-charts
helm repo add jaeger     https://jaegertracing.github.io/helm-charts
helm repo update

# 4. Create namespace
kubectl create namespace config-service

# 5. Create secrets
kubectl create secret generic config-service-db \
  --namespace config-service \
  --from-literal=DATABASE_URL="postgres://configuser:configpass@postgres-postgresql.config-service.svc.cluster.local:5432/configdb?sslmode=disable"

kubectl create secret generic config-service-kafka \
  --namespace config-service \
  --from-literal=KAFKA_BROKERS="kafka.config-service.svc.cluster.local:9092"

# 6. Deploy PostgreSQL
helm upgrade --install postgres bitnami/postgresql \
  --namespace config-service \
  --set auth.username=configuser \
  --set auth.password=configpass \
  --set auth.database=configdb \
  --wait --timeout=3m

# 7. Deploy Kafka
helm upgrade --install kafka bitnami/kafka \
  --namespace config-service \
  --set replicaCount=1 \
  --set kraft.enabled=true \
  --set listeners.client.protocol=PLAINTEXT \
  --wait --timeout=5m

# 8. Deploy Prometheus + Grafana
helm upgrade --install prometheus prometheus/kube-prometheus-stack \
  --namespace config-service \
  --set grafana.adminPassword=admin \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout=5m

# 9. Deploy Jaeger
helm upgrade --install jaeger jaeger/jaeger \
  --namespace config-service \
  --set allInOne.enabled=true \
  --set storage.type=memory \
  --wait --timeout=3m

# 10. Deploy Loki
helm upgrade --install loki grafana/loki \
  --namespace config-service \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set singleBinary.replicas=1 \
  --set "read.replicas=0" --set "write.replicas=0" --set "backend.replicas=0" \
  --wait --timeout=3m

helm upgrade --install promtail grafana/promtail \
  --namespace config-service \
  --set config.clients[0].url="http://loki.config-service.svc.cluster.local:3100/loki/api/v1/push" \
  --wait --timeout=3m

# 11. Deploy config-service
helm upgrade --install config-service deployments/helm/config-service \
  --namespace config-service \
  --set image.repository=config-service \
  --set image.tag=local \
  --set image.pullPolicy=IfNotPresent \
  --set config.enableKafka=true \
  --set serviceMonitor.enabled=true \
  --wait --timeout=3m
```

### Access services (port-forward)

Run each in a separate terminal:

```bash
# App
kubectl -n config-service port-forward svc/config-service 8080:80

# Grafana (admin / admin)
kubectl -n config-service port-forward svc/prometheus-grafana 3000:80

# Prometheus
kubectl -n config-service port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090

# Jaeger
kubectl -n config-service port-forward svc/jaeger-allInOne 16686:16686
```

### Verify deployment

```bash
# Check all pods running
kubectl -n config-service get pods

# Check app logs
kubectl -n config-service logs -l app.kubernetes.io/name=config-service -f

# Smoke test
./scripts/smoke-test.sh http://localhost:8080
```

### Tear down

```bash
kind delete cluster --name config-service
```

---

## 3. How the Go Application Works

### Layer Architecture

```
HTTP Request
     │
     ▼
┌─────────────────────────────────────────────────┐
│  Middleware Chain (runs on every request)        │
│  RequestID → Recovery → Logging → Timeout        │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────┐
│  handlers/  — HTTP layer                         │
│  Decodes JSON, validates input, calls service    │
│  Writes JSON response or error                   │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────┐
│  service/  — Business logic                      │
│  Calls repository to save/read data              │
│  Publishes Kafka event after every upsert        │
│  Creates OTel trace spans                        │
└──────────────────────┬──────────────────────────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
┌─────────────────┐   ┌─────────────────────────┐
│ repository/     │   │ kafka/                   │
│ PostgreSQL SQL  │   │ Publishes config-events  │
│ ON CONFLICT     │   │ (best-effort: won't fail │
│ (upsert)        │   │  if Kafka is down)       │
└─────────────────┘   └─────────────────────────┘
        │
   PostgreSQL
```

### What happens on POST /configs

```
1. Request arrives → RequestID middleware assigns "req-abc123"
2. Recovery middleware wraps handler (catches panics → 500)
3. Logging middleware starts timer
4. handler.UpsertConfig() decodes JSON body
5. UpsertRequest.Validate() checks id/host/port/app_name/log_level
6. service.UpsertConfig() called:
   a. repository.Upsert() → INSERT ... ON CONFLICT (id) DO UPDATE SET ...
   b. kafka.PublishConfigEvent() → sends to topic "config-events"
7. Response: 200 JSON with created_at/updated_at from DB
8. Logging middleware records: method=POST path=/configs status=200 latency=3ms
9. Prometheus counter incremented: config_upserts_total++
```

### Graceful Shutdown

```
SIGTERM received (Kubernetes sends this before pod deletion)
     │
     ▼
http.Server.Shutdown(30s timeout) — drains in-flight requests
     │
     ▼
Kafka producer.Close() — flushes pending messages
     │
     ▼
pgxpool.Close() — closes DB connections
     │
     ▼
OTel TracerProvider.Shutdown() — flushes pending spans
     │
     ▼
Process exits 0 ✅
```

---

## 4. API Reference

| Method | Path             | Description                          |
|--------|------------------|--------------------------------------|
| GET    | `/ping`          | Always returns `pong`                |
| GET    | `/live`          | Kubernetes liveness probe            |
| GET    | `/ready`         | Readiness — checks DB + Kafka        |
| GET    | `/metrics`       | Prometheus metrics                   |
| GET    | `/configs/{id}`  | Get config by ID (404 if not found)  |
| POST   | `/configs`       | Create or update config (upsert)     |

### POST /configs — Request

```json
{
  "id":        "cfg_1",
  "host":      "db.internal",
  "port":      5432,
  "app_name":  "my-app",
  "log_level": "INFO"
}
```

### GET /configs/{id} — Response

```json
{
  "id":         "cfg_1",
  "host":       "db.internal",
  "port":       5432,
  "app_name":   "my-app",
  "log_level":  "INFO",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-01T12:00:00Z"
}
```

Returns `{"error":"config not found","code":404}` when absent.

### Error Response Format

```json
{
  "error":    "port must be between 1 and 65535",
  "code":     400,
  "trace_id": "req-abc123"
}
```

---

## 5. Observability: Jaeger, Prometheus, Loki, Grafana

### 🔍 Jaeger — Distributed Tracing

**What is Jaeger?**
Jaeger tracks a single request as it flows through your system. Every function call (handler → service → DB → Kafka) becomes a "span". All spans for one request form a "trace". This lets you answer: *"Why did this request take 300ms? Which step was slow?"*

**How it works in this app:**
```
User Request
     │
     ▼
OTel SDK creates a Trace ID (e.g., abc123)
     │
     ├── Span: handler.GetConfig (5ms total)
     │       └── Span: service.GetConfig (3ms)
     │               └── Span: repository.Get → SQL query (2ms)
     │
     ▼
All spans sent via gRPC to OTel Collector → forwarded to Jaeger
```

**How to verify Jaeger:**

1. Start docker-compose and make some requests:
```bash
curl http://localhost:8080/configs/cfg_1
curl -X POST http://localhost:8080/configs \
  -H "Content-Type: application/json" \
  -d '{"id":"test","host":"h","port":80,"app_name":"a","log_level":"info"}'
```

2. Open Jaeger UI: **http://localhost:16686**

3. In the search form:
   - **Service**: select `config-service`
   - **Operation**: select `handler.GetConfig` or `handler.UpsertConfig`
   - Click **Find Traces**

4. Click any trace to see the full span tree:
```
handler.UpsertConfig  [12ms]
  └── service.UpsertConfig  [10ms]
        ├── repository.Upsert  [8ms]   ← DB query
        └── kafka.PublishConfigEvent  [2ms]
```

5. Click a span to see attributes:
   - `config.id = "test"`
   - `config.app_name = "a"`
   - `db.system = "postgresql"`

**What to look for:**
- 🟢 All spans green → everything healthy
- 🔴 Red span → that step failed (click to see error)
- Slow DB span → check PostgreSQL query plan

---

### 📊 Prometheus + Grafana — Metrics

**Prometheus** scrapes `/metrics` every 15s. **Grafana** visualizes it.

**Key queries to run in Prometheus (http://localhost:9090):**
```promql
# Request rate
rate(http_requests_total[2m])

# p95 latency
histogram_quantile(0.95, sum(rate(request_duration_seconds_bucket[2m])) by (le, path))

# Error rate (5xx)
rate(http_requests_total{status=~"5.."}[2m])

# Total configs created
config_upserts_total

# Kafka publish rate
rate(kafka_messages_total[2m])

# DB query latency
histogram_quantile(0.95, sum(rate(db_query_duration_seconds_bucket[2m])) by (le, operation))
```

**Grafana Dashboard — Auto-provisioned:**

The dashboard loads **automatically** when docker-compose starts. No manual import needed.

**How it works:**
```
docker-compose mounts 3 files into Grafana:
  grafana-datasource.yml              → tells Grafana about Prometheus + Loki
  grafana-dashboard-provisioning.yml  → tells Grafana WHERE to find dashboard JSONs
  grafana-dashboard.json              → the actual dashboard (11 panels)
```

**How to open it:**
1. Start stack: `docker compose up -d`
2. Open **http://localhost:3000** → login `admin / admin`
3. Left sidebar → **Dashboards** → **Config Service — Full Observability**

**Dashboard panels:**

| Panel | Metric |
|---|---|
| Request Rate | `rate(http_requests_total[1m])` |
| Error Rate % | 5xx / total × 100 |
| P99 Latency | `histogram_quantile(0.99, ...)` |
| Config Upserts | `increase(config_upserts_total[5m])` |
| Config Reads | `increase(config_reads_total[5m])` |
| Kafka Events | `increase(kafka_messages_total[5m])` |
| Request Rate by Method+Status | breakdown per endpoint |
| Latency p50/p95/p99 curves | percentile comparison |
| DB Query Rate by operation | upsert vs get |
| DB Query Latency p95 | DB performance |
| App Logs | Loki live logs — `{container="config-app"}` |

**Generate data to see graphs:**
```bash
# Create a few configs
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:8080/configs \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"app-$i\",\"host\":\"10.0.0.$i\",\"port\":808$i,\"app_name\":\"service-$i\",\"log_level\":\"info\"}"
done

# Read them back
for i in 1 2 3 4 5; do curl -s http://localhost:8080/configs/app-$i; done
```

**If dashboard is missing** (volume cached from old run):
```bash
# Restart Grafana to pick up provisioning
docker compose restart grafana

# OR manually import via API
curl -s -X POST http://admin:admin@localhost:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\": $(cat deployments/manifests/grafana-dashboard.json), \"overwrite\": true, \"folderId\": 0}"
```

---

### 📜 Loki + Promtail — Log Aggregation

**What is Loki?**
Loki is like Prometheus but for logs. Promtail ships logs from containers to Loki. Grafana queries Loki to search/filter logs.

**How to verify logs in Grafana:**
1. Open Grafana → **Explore** (compass icon on left)
2. Select datasource: **Loki**
3. Enter query:
```logql
{container="config-service"}
```
4. You'll see all JSON logs from your app.

**Useful LogQL queries:**
```logql
# All logs from the app
{container="config-service"}

# Only errors
{container="config-service"} |= "error"

# Only POST /configs requests
{container="config-service"} | json | method="POST"

# Slow requests (latency > 100ms)
{container="config-service"} | json | latency > 0.1

# All 5xx responses
{container="config-service"} | json | status >= 500
```

---

## 6. Infrastructure Design

### docker-compose vs Kind

| Component       | docker-compose       | Kind (Kubernetes)              |
|-----------------|----------------------|--------------------------------|
| PostgreSQL      | `postgres:16-alpine` | Bitnami Helm chart             |
| Kafka           | `cp-kafka:7.6.1`     | Bitnami Kafka Helm chart       |
| Prometheus      | `prom/prometheus`    | kube-prometheus-stack Helm     |
| Grafana         | `grafana/grafana`    | Included in kube-prometheus    |
| Jaeger          | `jaegertracing/all-in-one` | jaeger Helm chart        |
| Loki            | `grafana/loki`       | grafana/loki Helm chart        |
| Promtail        | `grafana/promtail`   | grafana/promtail Helm chart    |
| OTel Collector  | `otelcol-contrib`    | opentelemetry-collector Helm   |
| App             | Built from Dockerfile| Helm chart (this repo)         |

### Terraform (for Kind)

Terraform manages infrastructure state: namespace, secrets, and Helm releases.

```bash
cd terraform/local
terraform init
TF_VAR_db_password=configpass terraform apply
```

### Kubernetes Security Model

```yaml
# Every pod runs with:
runAsNonRoot: true
runAsUser: 65532          # distroless nonroot UID
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop: [ALL]
```

NetworkPolicy restricts egress to only: PostgreSQL (5432), Kafka (9092), DNS (53), OTel (4317).

---

## 7. Configuration & Secrets

All config loaded via Viper. Priority: **env vars > config.yaml > defaults**.

| Variable        | Default       | How it's set in K8s          |
|-----------------|---------------|-------------------------------|
| `PORT`          | `8080`        | ConfigMap                     |
| `LOG_LEVEL`     | `info`        | ConfigMap                     |
| `DATABASE_URL`  | (local dev)   | Secret `config-service-db`    |
| `KAFKA_BROKERS` | `localhost:9092` | Secret `config-service-kafka` |
| `ENABLE_KAFKA`  | `false`       | ConfigMap (set `true` in K8s) |
| `ENABLE_METRICS`| `true`        | ConfigMap                     |
| `OTLP_ENDPOINT` | (empty)       | ConfigMap                     |

**Secrets are never committed to git.** In docker-compose they're in environment variables. In Kubernetes they're in `kubernetes_secret` managed by Terraform.

---

## 8. Security

- **Non-root**: runs as UID 65532 (distroless nonroot)
- **Read-only filesystem**: `readOnlyRootFilesystem: true`
- **No capabilities**: all Linux capabilities dropped
- **PodDisruptionBudget**: `minAvailable: 1` (safe during node drains)
- **NetworkPolicy**: whitelist-only egress
- **Graceful shutdown**: 30s drain window on SIGTERM

---

## 9. CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on every push:

```
push to main
  │
  ├── go vet + golangci-lint
  ├── unit tests (race detector)
  ├── docker build
  ├── helm lint
  └── terraform validate
```

**Deployment** is done via Helm:
```bash
helm upgrade --install config-service deployments/helm/config-service \
  --namespace config-service --wait
```

ArgoCD manifest is provided in `deployments/argocd/application.yaml` as a bonus for GitOps-style CD, but GitHub Actions + Helm is the primary deployment path.

---

## 10. Known Limitations & Future Work

| Area                | Current                        | Production improvement               |
|---------------------|--------------------------------|--------------------------------------|
| Auth                | None                           | JWT middleware or mTLS               |
| Secrets             | K8s Secret / env vars          | HashiCorp Vault + External Secrets   |
| Kafka consumer      | Producer only                  | Consumer for config change events    |
| Config versioning   | Latest record only             | Audit log / history table            |
| Loki persistence    | In-memory (Kind) / volume (DC) | S3/GCS backend for production        |
| Jaeger persistence  | In-memory                      | Elasticsearch/Cassandra backend      |
| CI image push       | Build only                     | Push to GHCR on tag                  |
| Multi-region        | Single cluster                 | Cross-region replication via Kafka   |

---

## Responsible AI Usage

Built with GitHub Copilot assistance for scaffolding and boilerplate. All architecture decisions, error handling, security contexts, observability design, and debugging (migrations embed fix, Dockerfile ARM fix, ServiceMonitor CRD fix) were personally verified and corrected.
