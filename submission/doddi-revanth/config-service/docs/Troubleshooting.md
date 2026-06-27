# Troubleshooting

Common issues and their resolutions.

---

## Application Won't Start

### `failed to connect to database after 10 attempts`

**Cause:** PostgreSQL is not reachable.

**Steps:**
1. Verify `DATABASE_URL` is set correctly
2. Check postgres pod: `kubectl -n config-service get pod -l app.kubernetes.io/name=postgresql`
3. Port-forward and test: `psql "$DATABASE_URL" -c "SELECT 1"`
4. Confirm secret exists: `kubectl -n config-service get secret config-service-db -o yaml`

---

### `failed to load config`

**Cause:** Viper can't unmarshal environment variables.

**Steps:**
1. Check env vars in pod: `kubectl -n config-service exec deploy/config-service -- env | grep -E 'PORT|DATABASE|KAFKA|LOG'`
2. Verify ConfigMap: `kubectl -n config-service get configmap config-service -o yaml`

---

## HTTP Errors

### `404 config not found`

Expected behavior. The `id` in `GET /configs/{id}` does not exist in the database. Seed via `POST /configs`.

---

### `400 Bad Request` on `POST /configs`

Common causes:
- Missing `id` field
- `port` out of range (must be 1–65535)
- Missing `app_name` or `log_level`
- Invalid JSON body

Check the `error` field in the response body for the exact validation message.

---

### `503 Service Unavailable` on `GET /ready`

The readiness check failed. Response body shows which dependency failed:

```json
{"status":"not ready","checks":{"database":false,"kafka":true}}
```

Fix the failing dependency (see above for database, see Kafka section for kafka).

---

## Metrics Not Appearing

### No metrics in Prometheus

1. Verify `ENABLE_METRICS=true` (default is true)
2. Test endpoint: `curl http://localhost:8080/metrics | grep http_requests`
3. If using ServiceMonitor: ensure `kube-prometheus-stack` is installed and the label selector matches

---

## Kafka Issues

### `kafka unavailable, continuing without kafka`

This is a warning, not a fatal error. The service operates normally without Kafka.

To resolve:
1. Check `ENABLE_KAFKA=true` is set
2. Verify `KAFKA_BROKERS` points to the correct address
3. Check the Kafka pod is running and healthy
4. Kafka events will resume automatically when the broker reconnects (producer retries on next request)

---

## Kind / Docker Issues

### `kind load` fails: image not found

```bash
docker images | grep config-service
# If missing:
make docker
make kind-load
```

### Port-forward drops

Port-forward connections are not persistent. Re-run:
```bash
kubectl -n config-service port-forward svc/config-service 8080:80 &
```

---

## Terraform Issues

### `Error: namespaces "config-service" already exists`

The namespace was created outside of Terraform. Import it:
```bash
terraform -chdir=terraform/local import module.app.kubernetes_namespace.this config-service
```

### `Error: Release already exists`

The Helm release exists but isn't tracked by Terraform state. Import:
```bash
terraform -chdir=terraform/local import 'module.app.helm_release.config_service' config-service/config-service
```

---

## Performance Debugging

### High p95 latency on `/configs/{id}`

1. Check `db_query_duration_seconds{operation="get"}` in Grafana
2. Verify PostgreSQL index: `\d configs` should show `idx_configs_app_name`
3. Check connection pool: `MaxConns=20` by default; increase if needed
4. Check `EXPLAIN ANALYZE SELECT ... FROM configs WHERE id = $1`

### Memory leak suspected

```bash
# Check Go memory metrics
curl -s localhost:8080/metrics | grep go_memstats

# Profile (if pprof enabled in future)
go tool pprof http://localhost:8080/debug/pprof/heap
```
