# Observability Guide

## Signals

Config Service emits three observability signals:

| Signal  | Library             | Backend    | Access                         |
|---------|---------------------|------------|--------------------------------|
| Logs    | Zap (JSON)          | stdout     | `kubectl logs` / log shipper   |
| Metrics | Prometheus          | Prometheus | `GET /metrics` → Grafana       |
| Traces  | OpenTelemetry SDK   | Jaeger     | `localhost:16686` (docker-compose) |

---

## Logs

Every request emits a structured JSON log line:

```json
{
  "level": "info",
  "timestamp": "2024-01-01T12:00:00.000Z",
  "caller": "middleware/logging.go:42",
  "msg": "request",
  "request_id": "550e8400-e29b-41d4-a716-446655440000",
  "method": "POST",
  "path": "/configs",
  "status": 200,
  "latency": "3.2ms",
  "remote_ip": "10.244.0.1:54321",
  "user_agent": "curl/8.1.2"
}
```

Startup logs include all resolved configuration (secrets redacted):

```json
{"level":"info","msg":"starting config-service","version":"1.0.0","port":"8080","log_level":"info","kafka_enabled":true,"metrics_enabled":true}
{"level":"info","msg":"database connection established"}
{"level":"info","msg":"database migrations applied"}
{"level":"info","msg":"kafka producer connected","brokers":["kafka:9092"]}
{"level":"info","msg":"server listening","addr":":8080"}
```

### Tail logs in Kubernetes

```bash
kubectl -n config-service logs -l app.kubernetes.io/name=config-service -f --tail=100
```

---

## Metrics

### Endpoint

```
GET /metrics
```

All metrics use the default Prometheus Go registry plus custom application metrics.

### Custom Metrics

| Metric                          | Type      | Labels                        |
|---------------------------------|-----------|-------------------------------|
| `http_requests_total`           | Counter   | `method`, `path`, `status`    |
| `request_duration_seconds`      | Histogram | `method`, `path`              |
| `db_queries_total`              | Counter   | `operation` (get/upsert)      |
| `db_query_duration_seconds`     | Histogram | `operation`                   |
| `kafka_messages_total`          | Counter   | —                             |
| `config_upserts_total`          | Counter   | —                             |
| `config_reads_total`            | Counter   | —                             |

### Example PromQL Queries

```promql
# Request rate (last 2 min)
rate(http_requests_total[2m])

# p95 latency by endpoint
histogram_quantile(0.95, sum(rate(request_duration_seconds_bucket[2m])) by (le, path))

# Error rate (5xx)
rate(http_requests_total{status=~"5.."}[2m])

# DB query rate
rate(db_queries_total[2m])

# Kafka publish rate
rate(kafka_messages_total[2m])
```

---

## Grafana Dashboard

Import `deployments/manifests/grafana-dashboard.json` via Grafana UI → Dashboards → Import.

Panels:
1. **HTTP Request Rate** — rate by method/path/status
2. **Request Latency p95/p99** — histogram quantiles per endpoint
3. **Config Upserts (5m)** — stat panel
4. **Config Reads (5m)** — stat panel
5. **Kafka Messages (5m)** — stat panel
6. **DB Query Latency p95** — by operation
7. **DB Query Rate** — by operation

---

## Tracing (OpenTelemetry)

Set `OTLP_ENDPOINT=otel-collector:4317` to enable trace export.

Spans are created for:
- `handler.GetConfig`
- `handler.UpsertConfig`
- `service.GetConfig`
- `service.UpsertConfig`

Each span includes attributes like `config.id` and `config.app_name`.

### View Traces (docker-compose)

```
http://localhost:16686
```

Select service `config-service` → Find Traces.

---

## Health Check Interpretation

```bash
# Readiness check with detail
curl -s localhost:8080/ready | jq .
```

```json
{
  "status": "ready",
  "checks": {
    "database": true,
    "kafka": true
  }
}
```

If `database: false` → pod will be removed from Service endpoints, no traffic routed.

---

## Prometheus ServiceMonitor

When deployed with `serviceMonitor.enabled: true` in Helm values and kube-prometheus-stack is present, the ServiceMonitor auto-registers the scrape target. No manual Prometheus config needed.

```bash
kubectl -n config-service get servicemonitor
```
