# Deployment Guide

## Prerequisites

| Tool       | Min Version | Install                                      |
|------------|-------------|----------------------------------------------|
| Go         | 1.22        | https://go.dev/dl/                           |
| Docker     | 24.0        | https://docs.docker.com/get-docker/          |
| Kind       | 0.23        | `brew install kind`                          |
| kubectl    | 1.29        | `brew install kubectl`                       |
| Helm       | 3.15        | `brew install helm`                          |
| Terraform  | 1.8         | `brew install terraform`                     |
| migrate    | 4.17        | `go install github.com/golang-migrate/migrate/v4/cmd/migrate@latest` |

---

## Option A — docker-compose (Fastest)

```bash
docker-compose up -d
./scripts/smoke-test.sh
```

All services start in order (postgres → kafka → app). The app waits for postgres to be healthy before starting.

---

## Option B — Kind + Helm + Terraform (Production-like)

### Step 1: Create cluster

```bash
make cluster
# or
kind create cluster --name config-service --config deployments/manifests/kind-config.yaml
```

### Step 2: Build and load image

```bash
make docker kind-load
```

### Step 3: Provision infrastructure (Terraform)

```bash
# Sets TF_VAR_db_password for you:
export TF_VAR_db_password=your-secure-password

make terraform
# This creates:
#   - kubernetes_namespace/config-service
#   - kubernetes_secret/config-service-db (DATABASE_URL)
#   - kubernetes_secret/config-service-kafka (KAFKA_BROKERS)
#   - helm_release/postgres (Bitnami)
#   - helm_release/kafka (Bitnami KRaft)
#   - helm_release/prometheus (kube-prometheus-stack)
```

### Step 4: Run migrations

```bash
make migrate
# or
kubectl -n config-service port-forward svc/postgres-postgresql 5432:5432 &
DATABASE_URL="postgres://configuser:${TF_VAR_db_password}@localhost:5432/configdb?sslmode=disable" \
  ./scripts/migrate.sh
```

### Step 5: Deploy application

```bash
make deploy
# or
helm upgrade --install config-service deployments/helm/config-service \
  --namespace config-service --wait --timeout 5m
```

### Step 6: Verify

```bash
kubectl -n config-service get pods
kubectl -n config-service port-forward svc/config-service 8080:80 &
make smoke
```

---

## Helm Chart Configuration

Key `values.yaml` overrides:

```yaml
# Production-like values
image:
  repository: ghcr.io/yourorg/config-service
  tag: "1.2.3"

config:
  enableKafka: "true"
  logLevel: "warn"

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

Apply with:
```bash
helm upgrade --install config-service deployments/helm/config-service \
  -f my-production-values.yaml \
  --namespace config-service
```

---

## Rolling Updates

The Deployment uses:
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

This ensures zero downtime: a new pod must be Ready before any old pod is terminated.

Readiness probe (`/ready`) gates traffic — new pods only receive traffic once PostgreSQL and Kafka are reachable.

---

## Teardown

```bash
make destroy
# Deletes Kind cluster and all resources
```

Or selectively:
```bash
helm uninstall config-service -n config-service
make terraform-destroy
kind delete cluster --name config-service
```
