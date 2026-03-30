# Config Service — Sample Candidate Submission

A minimal Kubernetes config management service written in Go.

## Architecture

```
cmd/main.go                 — entrypoint, wires dependencies
internal/handler/           — HTTP layer (thin, delegates to service)
internal/service/           — business logic
internal/repository/        — storage interface + in-memory implementation
internal/domain/            — shared data types
infra/terraform/            — IaC (namespace / cluster bootstrap)
k8s/                        — Kubernetes manifests
```

## API

| Method | Path           | Description                  |
|--------|----------------|------------------------------|
| GET    | /ping          | Liveness check, returns pong |
| GET    | /configs/:id   | Retrieve config by ID        |
| POST   | /configs       | Create or update a config    |

### POST /configs — example body

```json
{
  "id": "cfg_1",
  "host": "localhost",
  "port": 8080,
  "app_name": "config-service",
  "log_level": "INFO"
}
```

## Local setup

### Prerequisites

- Go 1.22+
- Docker
- kind or minikube
- kubectl
- Terraform >= 1.8

### Run tests

```bash
go test ./... -race
```

### Build image

```bash
docker build -t config-service:latest .
```

### Deploy to kind

```bash
# 1. Create cluster
kind create cluster --name config-service

# 2. Load image
kind load docker-image config-service:latest --name config-service

# 3. Apply manifests
kubectl apply -f k8s/

# 4. Verify
kubectl -n config-service rollout status deploy/config-service
kubectl -n config-service port-forward svc/config-service 8080:8080 &
curl http://localhost:8080/ping
```

### Terraform

Terraform manages namespace/bootstrap metadata. To run:

```bash
cd infra/terraform
terraform init
terraform apply
```

## Configuration

| Variable     | Source    | Description                 |
|--------------|-----------|-----------------------------|
| APP_PORT     | ConfigMap | HTTP listen port (default 8080) |
| LOG_LEVEL    | ConfigMap | Application log level       |
| DATABASE_URL | Secret    | PostgreSQL connection string |

`DATABASE_URL` is optional (`optional: true`). When absent the service uses the
in-memory repository.

## Known limitations

- In-memory storage is not persistent; a full submission would wire in a
  postgres repository behind the same `Repository` interface.
- Terraform manages only bootstrap metadata; a full submission would provision
  the PostgreSQL StatefulSet or RDS-equivalent via Helm/TF.
- No migrations automation — a full submission would run `golang-migrate` or
  equivalent as an init container.
