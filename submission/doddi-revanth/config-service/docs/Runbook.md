# Runbook

Operational procedures for config-service in production.

---

## Deployment Checklist

Before each deployment:
- [ ] `go test ./... -race` passes
- [ ] `helm lint deployments/helm/config-service` passes
- [ ] Docker image built and pushed to registry
- [ ] DB migration tested against a copy of production schema
- [ ] Readiness probe `/ready` returns 200 after migration

---

## Rollout Procedure

```bash
# Deploy new version
helm upgrade config-service deployments/helm/config-service \
  --namespace config-service \
  --set image.tag=NEW_TAG \
  --wait --timeout 5m

# Verify
kubectl -n config-service rollout status deployment/config-service
kubectl -n config-service get pods

# Smoke test
./scripts/smoke-test.sh http://localhost:8080
```

---

## Rollback Procedure

```bash
# Immediate rollback to previous Helm release
helm rollback config-service 0 --namespace config-service --wait

# Verify rollback
kubectl -n config-service rollout status deployment/config-service
./scripts/smoke-test.sh
```

---

## Scale Operations

```bash
# Manual scale (bypass HPA temporarily)
kubectl -n config-service scale deployment/config-service --replicas=5

# Check HPA status
kubectl -n config-service get hpa config-service

# Resume HPA control
kubectl -n config-service patch hpa config-service \
  --patch '{"spec":{"minReplicas":2}}'
```

---

## Database Operations

### Check connectivity

```bash
kubectl -n config-service port-forward svc/postgres-postgresql 5432:5432 &
psql "$DATABASE_URL" -c "SELECT COUNT(*) FROM configs;"
```

### Run manual migration

```bash
DATABASE_URL="..." migrate -path migrations -database "$DATABASE_URL" up
```

### Rollback migration

```bash
DATABASE_URL="..." migrate -path migrations -database "$DATABASE_URL" down 1
```

---

## Kafka Operations

### Check topic exists

```bash
kubectl -n config-service exec -it deploy/kafka -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --list
```

### Consume events (debug)

```bash
kubectl -n config-service exec -it deploy/kafka -- \
  kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic config-events \
    --from-beginning
```

---

## Incident Response

### Service not responding

1. Check pod status: `kubectl -n config-service get pods`
2. Check logs: `kubectl -n config-service logs -l app=config-service --tail=50`
3. Check events: `kubectl -n config-service describe pod <pod-name>`
4. Restart: `kubectl -n config-service rollout restart deployment/config-service`

### Database connection failures

Symptoms: `/ready` returns `"database": false`, `5xx` on all `/configs` requests.

1. Check DB pod: `kubectl -n config-service get pod -l app.kubernetes.io/name=postgresql`
2. Check DB secret exists: `kubectl -n config-service get secret config-service-db`
3. Test DSN manually (port-forward + psql)
4. If pod is crashed: `kubectl -n config-service describe pod <postgres-pod>`

### High error rate

1. Check Grafana dashboard → HTTP error rate panel
2. Check Prometheus: `rate(http_requests_total{status=~"5.."}[5m])`
3. Examine logs for stack traces
4. If OOM: check `kubectl top pods -n config-service`, increase memory limits

### Kafka producer failing

Symptoms: `kafka unavailable` warning in logs, `kafka_messages_total` not increasing.

This is a **non-critical warning**. Config reads and writes still work.

1. Check Kafka pod: `kubectl -n config-service get pod -l app.kubernetes.io/name=kafka`
2. Check `ENABLE_KAFKA` flag is correct
3. The service continues operating — Kafka failure does not block the API
