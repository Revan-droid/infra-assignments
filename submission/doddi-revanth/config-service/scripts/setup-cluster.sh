#!/usr/bin/env bash
# setup-cluster.sh — Bootstrap local Kind cluster with all dependencies
# Usage: ./scripts/setup-cluster.sh
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-config-service}"
NAMESPACE="${NAMESPACE:-config-service}"

green() { echo -e "\033[32m▶ $*\033[0m"; }
yellow() { echo -e "\033[33m⚠ $*\033[0m"; }

# ─── Prerequisites check ──────────────────────────────────────────────────────
for cmd in kind kubectl helm terraform docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed."
    exit 1
  fi
done
green "All prerequisites found"

# ─── Kind cluster ─────────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  yellow "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
  green "Creating Kind cluster: ${CLUSTER_NAME}"
  kind create cluster --name "${CLUSTER_NAME}" \
    --config deployments/manifests/kind-config.yaml
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ─── Build and load image ─────────────────────────────────────────────────────
green "Building Docker image"
docker build -t config-service:latest .

green "Loading image into Kind"
kind load docker-image config-service:latest --name "${CLUSTER_NAME}"

# ─── Terraform (namespace + secrets) ─────────────────────────────────────────
green "Applying Terraform"
cd terraform/local
terraform init -input=false
terraform apply -auto-approve \
  -var="db_password=${DB_PASSWORD:-configpass}" \
  -var="namespace=${NAMESPACE}"
cd ../..

# ─── Run migrations ───────────────────────────────────────────────────────────
green "Waiting for PostgreSQL..."
kubectl -n "${NAMESPACE}" wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  --timeout=120s 2>/dev/null || true

./scripts/migrate.sh

# ─── Deploy via Helm ──────────────────────────────────────────────────────────
green "Deploying config-service via Helm"
helm upgrade --install config-service deployments/helm/config-service \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait \
  --timeout 5m

# ─── Verify ───────────────────────────────────────────────────────────────────
green "Verifying rollout"
kubectl -n "${NAMESPACE}" rollout status deployment/config-service --timeout=120s

green "Setup complete!"
echo ""
echo "To access the service:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/config-service 8080:80 &"
echo "  curl http://localhost:8080/ping"
echo ""
echo "To run smoke tests:"
echo "  ./scripts/smoke-test.sh"
