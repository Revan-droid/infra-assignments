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

disable_minikube_docker_env() {
  eval "$(minikube docker-env --profile "${PROFILE}" --unset)"
}

helm_clean() {
  local release=$1
  if helm status "$release" --namespace "${NAMESPACE}" &>/dev/null; then
    yellow "Removing stale release: $release"
    helm uninstall "$release" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
  fi
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

# ─── Step 2: Point Docker to Minikube's daemon ───────────────────────────────
# This is the KEY advantage over Kind:
#   Images built/pulled after this line are inside Minikube directly.
#   Pods find them immediately with pullPolicy=IfNotPresent — no load step needed.
header "Step 2: Switch Docker to Minikube daemon"
enable_minikube_docker_env
green "Docker now talking to Minikube's daemon"

# ─── Step 3: Vendor dependencies (for offline Docker build) ──────────────────
header "Step 3: Go mod vendor"
if [ ! -d "vendor" ]; then
  yellow "vendor/ not found — running go mod vendor inside Docker..."
  # Reset to host Docker temporarily so the golang:1.22 Debian image can run go mod vendor.
  disable_minikube_docker_env
  if ! docker run --rm \
    -e GONOSUMDB='*' \
    -e GOFLAGS='-mod=mod' \
    -e GOPROXY='direct' \
    -v "$(pwd)":/workspace \
    -w /workspace \
    golang:1.22 \
    go mod vendor; then
    enable_minikube_docker_env
    red "go mod vendor failed"
    exit 1
  fi
  # Re-enable the Minikube Docker daemon for all remaining image pulls/builds.
  enable_minikube_docker_env
  green "vendor/ created"
else
  green "vendor/ found — skipping"
fi

# ─── Step 4: Build app image directly inside Minikube ────────────────────────
header "Step 4: Build App Image"
# Building inside Minikube's Docker daemon means the image is instantly available
# to pods — no kind load, no crane, no multi-arch issues.
yellow "Building config-service:${IMAGE_TAG} inside Minikube..."
docker build -t "config-service:${IMAGE_TAG}" .
green "App image built inside Minikube"

# ─── Step 5: Namespace + Helm repos ──────────────────────────────────────────
header "Step 5: Namespace & Helm Repos"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
green "Namespace: ${NAMESPACE}"

helm repo add bitnami        https://charts.bitnami.com/bitnami                         2>/dev/null || true
helm repo add prometheus     https://prometheus-community.github.io/helm-charts         2>/dev/null || true
helm repo add grafana        https://grafana.github.io/helm-charts                      2>/dev/null || true
helm repo add jaeger         https://jaegertracing.github.io/helm-charts                2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update --fail-on-repo-update-fail 2>/dev/null || helm repo update
green "Helm repos ready"

# ─── Step 6: Secrets ─────────────────────────────────────────────────────────
header "Step 6: Secrets"
kubectl create secret generic config-service-db \
  --namespace "${NAMESPACE}" \
  --from-literal=DATABASE_URL="postgres://configuser:${DB_PASSWORD}@postgres-postgresql.${NAMESPACE}.svc.cluster.local:5432/configdb?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic config-service-kafka \
  --namespace "${NAMESPACE}" \
  --from-literal=KAFKA_BROKERS="kafka.${NAMESPACE}.svc.cluster.local:9092" \
  --dry-run=client -o yaml | kubectl apply -f -
green "Secrets applied"

# ─── Step 7: PostgreSQL ───────────────────────────────────────────────────────
header "Step 7: PostgreSQL  (chart ${POSTGRES_CHART_VERSION})"
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

# ─── Step 8: Kafka ────────────────────────────────────────────────────────────
header "Step 8: Kafka  (chart ${KAFKA_CHART_VERSION})"
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

# ─── Step 9: Prometheus + Grafana ─────────────────────────────────────────────
header "Step 9: Prometheus + Grafana  (chart ${PROM_STACK_CHART_VERSION})"

yellow "Pulling Prometheus stack images into Minikube..."
docker pull --platform linux/amd64 prom/prometheus:v2.53.0
docker pull --platform linux/amd64 prometheusoperator/prometheus-operator:v0.74.0
docker pull --platform linux/amd64 prometheusoperator/prometheus-config-reloader:v0.74.0
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
  --set "prometheusOperator.image.registry=docker.io" \
  --set "prometheusOperator.image.repository=prometheusoperator/prometheus-operator" \
  --set "prometheusOperator.image.tag=v0.74.0" \
  --set "prometheusOperator.image.pullPolicy=IfNotPresent" \
  --set "prometheusOperator.prometheusConfigReloader.image.registry=docker.io" \
  --set "prometheusOperator.prometheusConfigReloader.image.repository=prometheusoperator/prometheus-config-reloader" \
  --set "prometheusOperator.prometheusConfigReloader.image.tag=v0.74.0" \
  --set "prometheusOperator.prometheusConfigReloader.image.pullPolicy=IfNotPresent" \
  --set "grafana.image.repository=grafana/grafana" \
  --set "grafana.image.tag=10.4.3" \
  --set "grafana.image.pullPolicy=IfNotPresent" \
  --values deployments/manifests/grafana-provisioning.yaml \
  --wait --timeout=5m
green "Prometheus + Grafana ready  (admin / admin)"

# ─── Step 10: Jaeger ──────────────────────────────────────────────────────────
header "Step 10: Jaeger  (chart ${JAEGER_CHART_VERSION})"
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
  --wait --timeout=3m
green "Jaeger ready"

# ─── Step 11: OpenTelemetry Collector ─────────────────────────────────────────
header "Step 11: OpenTelemetry Collector  (chart ${OTEL_CHART_VERSION})"
docker pull --platform linux/amd64 otel/opentelemetry-collector-k8s:0.97.0

helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --version "${OTEL_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set mode=deployment \
  --set image.repository=otel/opentelemetry-collector-k8s \
  --set image.tag=0.97.0 \
  --set image.pullPolicy=IfNotPresent \
  --set "config.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317" \
  --set "config.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318" \
  --set "config.exporters.otlp/jaeger.endpoint=jaeger.${NAMESPACE}.svc.cluster.local:4317" \
  --set "config.exporters.otlp/jaeger.tls.insecure=true" \
  --set "config.service.pipelines.traces.receivers[0]=otlp" \
  --set "config.service.pipelines.traces.exporters[0]=otlp/jaeger" \
  --wait --timeout=3m
green "OTel Collector ready"

# ─── Step 12: Loki ────────────────────────────────────────────────────────────
header "Step 12: Loki  (chart ${LOKI_CHART_VERSION})"
docker pull --platform linux/amd64 grafana/loki:3.0.0

helm upgrade --install loki grafana/loki \
  --version "${LOKI_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set singleBinary.replicas=1 \
  --set singleBinary.image.registry=docker.io \
  --set singleBinary.image.repository=grafana/loki \
  --set singleBinary.image.tag=3.0.0 \
  --set singleBinary.image.pullPolicy=IfNotPresent \
  --set "read.replicas=0" \
  --set "write.replicas=0" \
  --set "backend.replicas=0" \
  --wait --timeout=3m
green "Loki ready"

# ─── Step 13: Promtail ────────────────────────────────────────────────────────
header "Step 13: Promtail  (chart ${PROMTAIL_CHART_VERSION})"
docker pull --platform linux/amd64 grafana/promtail:2.9.3

helm upgrade --install promtail grafana/promtail \
  --version "${PROMTAIL_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set image.registry=docker.io \
  --set image.repository=grafana/promtail \
  --set image.tag=2.9.3 \
  --set image.pullPolicy=IfNotPresent \
  --set "config.clients[0].url=http://loki.${NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push" \
  --wait --timeout=3m
green "Promtail ready"

# ─── Step 14: config-service ──────────────────────────────────────────────────
header "Step 14: config-service app"
helm upgrade --install config-service deployments/helm/config-service \
  --namespace "${NAMESPACE}" \
  --set image.repository=config-service \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy=Never \
  --set config.enableKafka=true \
  --set config.logLevel=debug \
  --set "config.otlpEndpoint=otel-collector-opentelemetry-collector.${NAMESPACE}.svc.cluster.local:4317" \
  --set serviceMonitor.enabled=true \
  --wait --timeout=3m
green "config-service deployed"

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
