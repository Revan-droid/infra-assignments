#!/usr/bin/env bash
# minikube-setup.sh — Full stack deployment on Minikube
#
# WHY Minikube over Kind on corporate/proxy networks:
#   Kind nodes are Linux containers with their own cert store — quay.io, registry.k8s.io
#   fail TLS. Minikube with --driver=docker uses your Mac's Docker Desktop daemon via
#   `eval $(minikube docker-env)`, so images pulled on the host are immediately available
#   to pods with NO kind-load step and NO multi-arch manifest issues.
#
# What this deploys:
#   PostgreSQL · Kafka · Prometheus · Grafana · Jaeger · OTel Collector · Loki · Promtail · config-service
#
# Prerequisites:
#   minikube  kubectl  helm  docker
#   Install: brew install minikube kubectl helm
#
# Usage:
#   ./scripts/minikube-setup.sh
#   PROFILE=my-cluster ./scripts/minikube-setup.sh

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
PROFILE="${PROFILE:-config-service}"
NAMESPACE="${NAMESPACE:-config-service}"
DB_PASSWORD="${DB_PASSWORD:-configpass}"
IMAGE_TAG="${IMAGE_TAG:-local}"
MEMORY="${MEMORY:-6144}"   # MB — increase if you have more RAM
CPUS="${CPUS:-4}"

# ─── Pinned chart versions ───────────────────────────────────────────────────
KAFKA_CHART_VERSION="29.3.14"
POSTGRES_CHART_VERSION="15.5.0"
PROM_STACK_CHART_VERSION="60.3.0"
JAEGER_CHART_VERSION="3.3.1"
LOKI_CHART_VERSION="6.6.2"
PROMTAIL_CHART_VERSION="6.15.5"
OTEL_CHART_VERSION="0.97.1"

# ─── Helpers ─────────────────────────────────────────────────────────────────
green()  { echo -e "\033[32m✅  $*\033[0m"; }
yellow() { echo -e "\033[33m⏳  $*\033[0m"; }
red()    { echo -e "\033[31m❌  $*\033[0m"; }
header() {
  echo ""
  echo -e "\033[1;36m════════════════════════════════════════════════\033[0m"
  echo -e "\033[1;36m  $*\033[0m"
  echo -e "\033[1;36m════════════════════════════════════════════════\033[0m"
}

enable_minikube_docker_env() {
  eval "$(minikube docker-env --profile "${PROFILE}")"
}

use_host_docker() {
  eval "$(minikube docker-env --profile "${PROFILE}" --unset)" 2>/dev/null || true
}

helm_clean() {
  local release=$1
  if helm status "$release" --namespace "${NAMESPACE}" &>/dev/null; then
    yellow "Removing stale release: $release"
    helm uninstall "$release" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
  fi
}

# Create vendor/ directory with corporate CA injection.
#
# WHY this approach?
#   Corporate TLS proxies intercept HTTPS and replace certificates with their own CA.
#   Docker build containers (golang:1.22-alpine) only trust the standard CA bundle,
#   not the corporate CA. This causes go mod download to fail with:
#     "tls: failed to verify certificate: x509: certificate signed by unknown authority"
#
#   On macOS, the corporate CA is in the system keychain. We export ALL trusted certs
#   from the keychain and inject them into a golang:1.22 (Debian) container.
#   With corporate CA trusted, go mod vendor runs successfully.
#   After this step, Docker build uses -mod=vendor — ZERO network access.
create_vendor_dir() {
  if [ -d "vendor" ]; then
    green "vendor/ already exists — skipping go mod vendor"
    return 0
  fi

  yellow "Creating vendor/ directory (injecting macOS CA certs for corporate network)..."
  local tmp_certs
  tmp_certs=$(mktemp /tmp/macos-certs-XXXXXX.pem)

  # Export all trusted certificates from macOS keychains (includes corporate CA)
  security find-certificate -a -p /Library/Keychains/System.keychain >> "${tmp_certs}" 2>/dev/null || true
  security find-certificate -a -p "${HOME}/Library/Keychains/login.keychain-db" >> "${tmp_certs}" 2>/dev/null || true

  local mount_args=()
  local ca_update_cmd=""
  if [ -s "${tmp_certs}" ]; then
    yellow "Found macOS certificates — injecting into go mod vendor container"
    mount_args=(-v "${tmp_certs}:/usr/local/share/ca-certificates/macos-extra.crt:ro")
    ca_update_cmd="update-ca-certificates >/dev/null 2>&1 &&"
  else
    yellow "No macOS certificates found — trying without CA injection"
  fi

  # Use golang:1.22 (Debian) — handles multi-cert PEM via update-ca-certificates.
  # Use host Docker (not minikube's) since minikube hasn't started yet / we need certs.
  use_host_docker
  docker run --rm \
    -v "$(pwd):/workspace" \
    "${mount_args[@]}" \
    -w /workspace \
    golang:1.22 \
    sh -c "${ca_update_cmd} GONOSUMDB='*' go mod vendor"

  rm -f "${tmp_certs}"
  green "vendor/ created successfully"
}

# ─── Step 0: Prerequisites ────────────────────────────────────────────────────
header "Checking prerequisites"
for cmd in minikube kubectl helm docker; do
  command -v "$cmd" &>/dev/null \
    && green "$cmd found" \
    || { red "$cmd not installed. Install: brew install $cmd"; exit 1; }
done

# ─── Step 1: Minikube cluster ─────────────────────────────────────────────────
header "Step 1: Minikube Cluster"
if minikube status --profile "${PROFILE}" 2>/dev/null | grep -q "Running"; then
  green "Minikube profile '${PROFILE}' already running — reusing"
else
  yellow "Starting Minikube profile '${PROFILE}'..."
  minikube start \
    --profile "${PROFILE}" \
    --driver=docker \
    --memory="${MEMORY}" \
    --cpus="${CPUS}" \
    --kubernetes-version=v1.29.0
  green "Minikube started"
fi
kubectl config use-context "${PROFILE}"

# Enable metrics-server for HPA (CPU/memory autoscaling)
yellow "Enabling metrics-server addon..."
minikube addons enable metrics-server --profile "${PROFILE}" 2>/dev/null || true
green "metrics-server enabled"

# ─── Step 2: Build app image on HOST docker then load into Minikube ──────────
# vendor/ must exist before docker build (-mod=vendor Dockerfile).
# create_vendor_dir uses golang:1.22 (Debian) with macOS CA injection.
# After vendor/ is created, docker build never hits the network.
header "Step 2: Build App Image (vendor → build → load into Minikube)"
use_host_docker
create_vendor_dir
yellow "Building config-service:${IMAGE_TAG} (linux/amd64, -mod=vendor)..."
docker build --platform linux/amd64 -t "config-service:${IMAGE_TAG}" .
yellow "Loading image into Minikube..."
minikube image load "config-service:${IMAGE_TAG}" --profile "${PROFILE}"
green "App image ready in Minikube"

# ─── Step 3: Switch to Minikube docker for infra image pulls ─────────────────
header "Step 3: Switch Docker to Minikube daemon for infra pulls"
enable_minikube_docker_env
green "Docker now talking to Minikube's daemon"

header "Step 4: Namespace & Helm Repos"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
green "Namespace: ${NAMESPACE}"

helm repo add bitnami        https://charts.bitnami.com/bitnami                         2>/dev/null || true
helm repo add prometheus     https://prometheus-community.github.io/helm-charts         2>/dev/null || true
helm repo add grafana        https://grafana.github.io/helm-charts                      2>/dev/null || true
helm repo add jaeger         https://jaegertracing.github.io/helm-charts                2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update --fail-on-repo-update-fail 2>/dev/null || helm repo update
green "Helm repos ready"

# ─── Step 5: Secrets ─────────────────────────────────────────────────────────
header "Step 5: Secrets"
kubectl create secret generic config-service-db \
  --namespace "${NAMESPACE}" \
  --from-literal=DATABASE_URL="postgres://configuser:${DB_PASSWORD}@postgres-postgresql.${NAMESPACE}.svc.cluster.local:5432/configdb?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic config-service-kafka \
  --namespace "${NAMESPACE}" \
  --from-literal=KAFKA_BROKERS="kafka.${NAMESPACE}.svc.cluster.local:9092" \
  --dry-run=client -o yaml | kubectl apply -f -
green "Secrets applied"

# ─── Step 6: PostgreSQL ───────────────────────────────────────────────────────
header "Step 6: PostgreSQL  (chart ${POSTGRES_CHART_VERSION})"
helm_clean postgres

# Pull into Minikube's Docker first so Kubernetes doesn't hit the network
yellow "Pulling PostgreSQL image into Minikube..."
docker pull --platform linux/amd64 bitnami/postgresql:16.3.0 2>/dev/null || \
docker pull --platform linux/amd64 bitnamilegacy/postgresql:16.3.0-debian-12-r10

helm install postgres bitnami/postgresql \
  --version "${POSTGRES_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set auth.username=configuser \
  --set auth.password="${DB_PASSWORD}" \
  --set auth.database=configdb \
  --set primary.persistence.size=1Gi \
  --set primary.resources.requests.cpu=100m \
  --set primary.resources.requests.memory=256Mi \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/postgresql \
  --set image.tag=16.3.0-debian-12-r10 \
  --set image.pullPolicy=IfNotPresent \
  --wait --timeout=4m
green "PostgreSQL ready"

# ─── Step 7: Kafka ────────────────────────────────────────────────────────────
header "Step 7: Kafka  (chart ${KAFKA_CHART_VERSION})"
helm_clean kafka

yellow "Pulling Kafka image into Minikube..."
docker pull --platform linux/amd64 bitnamilegacy/kafka:3.7.1

helm install kafka bitnami/kafka \
  --version "${KAFKA_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/kafka \
  --set image.tag=3.7.1 \
  --set image.pullPolicy=IfNotPresent \
  --set replicaCount=1 \
  --set kraft.enabled=true \
  --set listeners.client.protocol=PLAINTEXT \
  --set persistence.size=1Gi \
  --set resources.requests.cpu=200m \
  --set resources.requests.memory=512Mi \
  --set provisioning.enabled=true \
  --set "provisioning.topics[0].name=config-events" \
  --set "provisioning.topics[0].partitions=3" \
  --set "provisioning.topics[0].replicationFactor=1" \
  --wait --timeout=5m
green "Kafka ready"

# ─── Step 8: config-service ──────────────────────────────────────────────────
header "Step 8: config-service app"
helm upgrade --install config-service deployments/helm/config-service \
  --namespace "${NAMESPACE}" \
  --set image.repository=config-service \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy=Never \
  --set config.enableKafka=true \
  --set config.logLevel=debug \
  --set "config.otlpEndpoint=otel-collector-opentelemetry-collector.${NAMESPACE}.svc.cluster.local:4317" \
  --set serviceMonitor.enabled=false \
  --wait --timeout=3m
green "config-service deployed"

# ─── Step 9: Loki ────────────────────────────────────────────────────────────
header "Step 9: Loki  (chart ${LOKI_CHART_VERSION})"
docker pull --platform linux/amd64 grafana/loki:3.0.0

helm upgrade --install loki grafana/loki \
  --version "${LOKI_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set deploymentMode=SingleBinary \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.useTestSchema=true \
  --set singleBinary.replicas=1 \
  --set singleBinary.image.registry=docker.io \
  --set singleBinary.image.repository=grafana/loki \
  --set singleBinary.image.tag=3.0.0 \
  --set singleBinary.image.pullPolicy=IfNotPresent \
  --set "read.replicas=0" \
  --set "write.replicas=0" \
  --set "backend.replicas=0" \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --wait --timeout=3m
green "Loki ready"

# ─── Step 10: Promtail ───────────────────────────────────────────────────────
header "Step 10: Promtail  (chart ${PROMTAIL_CHART_VERSION})"
docker pull --platform linux/amd64 grafana/promtail:2.9.3

helm upgrade --install promtail grafana/promtail \
  --version "${PROMTAIL_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set image.registry=docker.io \
  --set image.repository=grafana/promtail \
  --set image.tag=2.9.3 \
  --set image.pullPolicy=IfNotPresent \
  --set "config.clients[0].url=http://loki-gateway.${NAMESPACE}.svc.cluster.local/loki/api/v1/push" \
  --wait --timeout=3m
green "Promtail ready"

# ─── Step 11: Jaeger ─────────────────────────────────────────────────────────
header "Step 11: Jaeger  (chart ${JAEGER_CHART_VERSION})"
docker pull --platform linux/amd64 jaegertracing/all-in-one:1.53.0

helm upgrade --install jaeger jaeger/jaeger \
  --version "${JAEGER_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set allInOne.enabled=true \
  --set allInOne.image.repository=jaegertracing/all-in-one \
  --set allInOne.image.tag=1.53.0 \
  --set allInOne.image.pullPolicy=IfNotPresent \
  --set collector.enabled=false \
  --set query.enabled=false \
  --set agent.enabled=false \
  --set storage.type=memory \
  --set cassandra.enabled=false \
  --wait --timeout=3m
green "Jaeger ready  → http://localhost:16686 after port-forward"

# ─── Step 12: OpenTelemetry Collector ────────────────────────────────────────
# Image lives at ghcr.io only (Docker Hub otel/opentelemetry-collector-k8s has
# no stable tags). Minikube's Docker daemon pulls via macOS networking → ghcr.io works.
header "Step 12: OpenTelemetry Collector  (chart ${OTEL_CHART_VERSION})"
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --version "${OTEL_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set mode=deployment \
  --set "image.repository=ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s" \
  --set image.tag=0.104.0 \
  --set image.pullPolicy=IfNotPresent \
  --set "config.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317" \
  --set "config.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318" \
  --set "config.exporters.otlp/jaeger.endpoint=jaeger.${NAMESPACE}.svc.cluster.local:4317" \
  --set "config.exporters.otlp/jaeger.tls.insecure=true" \
  --set "config.service.pipelines.traces.receivers[0]=otlp" \
  --set "config.service.pipelines.traces.exporters[0]=otlp/jaeger" \
  --wait --timeout=3m
green "OTel Collector ready"

# ─── Step 13: Prometheus + Grafana ───────────────────────────────────────────
# Installed AFTER the app so ServiceMonitor resources exist before the operator
# scrapes for them — avoids a reconcile delay on first deploy.
header "Step 13: Prometheus + Grafana  (chart ${PROM_STACK_CHART_VERSION})"

# Pre-pull images that are reliably hosted on Docker Hub.
# prometheus-operator images only exist at quay.io — let helm pull those
# directly (minikube's Docker daemon has full network access via macOS and
# trusts quay.io without issue).
yellow "Pre-pulling Prometheus + Grafana images into Minikube..."
docker pull --platform linux/amd64 prom/prometheus:v2.53.0
docker pull --platform linux/amd64 grafana/grafana:10.4.3

helm upgrade --install prometheus prometheus/kube-prometheus-stack \
  --version "${PROM_STACK_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set grafana.adminPassword=admin \
  --set grafana.persistence.enabled=false \
  --set alertmanager.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set nodeExporter.enabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set "prometheus.prometheusSpec.image.registry=docker.io" \
  --set "prometheus.prometheusSpec.image.repository=prom/prometheus" \
  --set "prometheus.prometheusSpec.image.tag=v2.53.0" \
  --set "prometheus.prometheusSpec.image.pullPolicy=IfNotPresent" \
  --set "grafana.image.repository=grafana/grafana" \
  --set "grafana.image.tag=10.4.3" \
  --set "grafana.image.pullPolicy=IfNotPresent" \
  --values deployments/manifests/grafana-provisioning.yaml \
  --wait --timeout=5m
green "Prometheus + Grafana ready  (admin / admin)"

# Enable ServiceMonitor now that the CRD exists (installed by kube-prometheus-stack above)
yellow "Enabling ServiceMonitor for config-service..."
helm upgrade config-service deployments/helm/config-service \
  --namespace "${NAMESPACE}" \
  --reuse-values \
  --set serviceMonitor.enabled=true \
  --wait --timeout=2m
green "ServiceMonitor enabled — Prometheus will now scrape config-service"

# ─── Done ─────────────────────────────────────────────────────────────────────
header "All pods"
kubectl -n "${NAMESPACE}" get pods -o wide

echo ""
echo -e "\033[1;32m🎉  Stack is UP on Minikube!\033[0m"
echo ""
echo "Option A — minikube tunnel (recommended, run in separate terminal):"
echo "  minikube tunnel --profile ${PROFILE}"
echo ""
echo "Option B — port-forward each service:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/config-service                        8080:80"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-grafana                    3000:80"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  kubectl -n ${NAMESPACE} port-forward svc/jaeger                               16686:16686"
echo "  kubectl -n ${NAMESPACE} port-forward svc/loki                                  3100:3100"
echo ""
echo "Quick smoke test:"
echo "  curl http://localhost:8080/ping"
echo "  ./scripts/smoke-test.sh http://localhost:8080"
echo ""
echo "Tear down:"
echo "  minikube delete --profile ${PROFILE}"
echo ""
