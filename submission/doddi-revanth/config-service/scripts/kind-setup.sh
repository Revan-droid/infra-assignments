#!/usr/bin/env bash
# kind-setup.sh — Full stack deployment on Kind (idempotent, run anytime)
#
# What this deploys:
#   PostgreSQL · Kafka · Prometheus · Grafana · Jaeger · OTel Collector · Loki · Promtail · config-service
#
# Prerequisites:
#   kind  kubectl  helm  docker
#   Install: brew install kind kubectl helm
#
# Usage:
#   ./scripts/kind-setup.sh                        # fresh or re-run
#   CLUSTER_NAME=my-cluster ./scripts/kind-setup.sh
#
# Why --platform linux/amd64?
#   Kind nodes run linux/amd64. On Apple Silicon (M1/M2/M3) Docker pulls multi-arch
#   manifests by default which kind load docker-image cannot import. We force amd64.
#
# Why bitnamilegacy?
#   Bitnami removed images >= certain versions from Docker Hub free tier.
#   bitnamilegacy/* is the publicly available mirror with the same content.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-config-service}"
NAMESPACE="${NAMESPACE:-config-service}"
DB_PASSWORD="${DB_PASSWORD:-configpass}"
IMAGE_TAG="${IMAGE_TAG:-local}"

# ─── Pinned versions (update here if charts change) ──────────────────────────
KAFKA_CHART_VERSION="29.3.14"
KAFKA_IMAGE="bitnamilegacy/kafka:3.7.1"

POSTGRES_CHART_VERSION="15.5.0"
POSTGRES_IMAGE="bitnamilegacy/postgresql:16.3.0-debian-12-r10"

PROM_STACK_CHART_VERSION="60.3.0"
# prom/prometheus and grafana are on Docker Hub.
# prometheus-operator images are quay.io only (Docker Hub mirror is outdated at v0.37.0).
# crane on Mac host can pull quay.io fine (system CA handles TLS).
PROM_IMAGE="docker.io/prom/prometheus:v2.53.0"
PROM_OPERATOR_IMAGE="quay.io/prometheus-operator/prometheus-operator:v0.74.0"
PROM_CONFIG_RELOADER_IMAGE="quay.io/prometheus-operator/prometheus-config-reloader:v0.74.0"
GRAFANA_IMAGE="docker.io/grafana/grafana:10.4.3"
JAEGER_CHART_VERSION="3.3.1"
JAEGER_IMAGE="docker.io/jaegertracing/all-in-one:1.53.0"

LOKI_CHART_VERSION="6.6.2"
LOKI_IMAGE="docker.io/grafana/loki:3.0.0"

PROMTAIL_CHART_VERSION="6.15.5"
PROMTAIL_IMAGE="docker.io/grafana/promtail:2.9.3"

OTEL_CHART_VERSION="0.97.1"
# OTel collector releases are on ghcr.io only; Docker Hub has no stable tags.
# crane on Mac host can pull ghcr.io fine (system CA handles TLS).
OTEL_IMAGE="ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s:0.104.0"

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

# Uninstall a helm release only if it exists (prevents "release not found" errors)
helm_clean() {
  local release=$1
  if helm status "$release" --namespace "${NAMESPACE}" &>/dev/null; then
    yellow "Removing old release: $release"
    helm uninstall "$release" --namespace "${NAMESPACE}" --wait 2>/dev/null || true
  fi
}

# Pull an image for linux/amd64 and load it into Kind.
#
# WHY crane?
#   On Apple Silicon (M1/M2/M3), `docker pull --platform linux/amd64` fetches the
#   correct layer but Docker Desktop stores a multi-arch manifest reference.
#   When `kind load docker-image` internally runs `docker save <tag>`, Docker tries
#   to serialize the full manifest index and fails:
#     "unable to create manifests file: NotFound: content digest ..."
#   `crane pull --platform linux/amd64` always produces a correct single-platform
#   OCI tar that `kind load image-archive` accepts without issues.
#
# Install crane: brew install crane
kind_load() {
  local image=$1
  local tmp_tar
  tmp_tar=$(mktemp /tmp/kind-XXXXXX.tar)
  yellow "Pulling $image (linux/amd64 via crane)..."
  crane pull --platform linux/amd64 "$image" "$tmp_tar"
  yellow "Loading $image into Kind..."
  kind load image-archive "$tmp_tar" --name "${CLUSTER_NAME}"
  rm -f "$tmp_tar"
  green "$image ready in Kind"
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
#   from the keychain and inject them into a golang:1.22 (Debian) container — Debian
#   handles multi-certificate PEM files correctly via update-ca-certificates.
#   With corporate CA trusted, go mod vendor runs successfully.
#
#   After this step, Docker build uses -mod=vendor and NEVER needs network access.
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
  if [ -s "${tmp_certs}" ]; then
    yellow "Found macOS certificates ($(wc -l < "${tmp_certs}") lines) — injecting into container"
    mount_args=(-v "${tmp_certs}:/usr/local/share/ca-certificates/macos-extra.crt:ro")
    ca_update_cmd="update-ca-certificates >/dev/null 2>&1 &&"
  else
    yellow "No macOS certificates found — trying without CA injection"
    ca_update_cmd=""
  fi

  # Use golang:1.22 (Debian) — it has update-ca-certificates and handles multi-cert PEM.
  # GONOSUMDB=* skips sum.golang.org (also TLS-blocked on corporate networks).
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
for cmd in kind kubectl helm docker crane; do
  command -v "$cmd" &>/dev/null \
    && green "$cmd found" \
    || { red "$cmd not installed. Install: brew install $cmd"; exit 1; }
done

# ─── Step 1: Kind cluster ─────────────────────────────────────────────────────
header "Step 1: Kind Cluster"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  green "Cluster '${CLUSTER_NAME}' already exists — reusing"
else
  yellow "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" \
    --config deployments/manifests/kind-config.yaml
  green "Cluster '${CLUSTER_NAME}' created"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# ─── Step 2: Namespace + Helm repos ──────────────────────────────────────────
header "Step 2: Namespace & Helm Repos"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
green "Namespace: ${NAMESPACE}"

helm repo add bitnami        https://charts.bitnami.com/bitnami                         2>/dev/null || true
helm repo add prometheus     https://prometheus-community.github.io/helm-charts         2>/dev/null || true
helm repo add grafana        https://grafana.github.io/helm-charts                      2>/dev/null || true
helm repo add jaeger         https://jaegertracing.github.io/helm-charts                2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update --fail-on-repo-update-fail 2>/dev/null || helm repo update
green "Helm repos ready"

# ─── Step 3: Secrets ─────────────────────────────────────────────────────────
header "Step 3: Secrets"
kubectl create secret generic config-service-db \
  --namespace "${NAMESPACE}" \
  --from-literal=DATABASE_URL="postgres://configuser:${DB_PASSWORD}@postgres-postgresql.${NAMESPACE}.svc.cluster.local:5432/configdb?sslmode=disable" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic config-service-kafka \
  --namespace "${NAMESPACE}" \
  --from-literal=KAFKA_BROKERS="kafka.${NAMESPACE}.svc.cluster.local:9092" \
  --dry-run=client -o yaml | kubectl apply -f -
green "Secrets applied"

# ─── Step 4: Pre-load images into Kind ───────────────────────────────────────
# We load these images locally BEFORE helm installs them.
# This means the cluster nodes never need internet access for these images.
header "Step 4: Build App Image & Pre-load all images into Kind"

# ── vendor/ step ───────────────────────────────────────────────────────────────
# Must run before docker build. Exports macOS system CAs so go mod vendor
# trusts the corporate TLS proxy inside the golang:1.22 container.
create_vendor_dir

# ── App image ──────────────────────────────────────────────────────────────────
# vendor/ is now present. Docker build uses -mod=vendor — ZERO network access.
# We save as a single-platform tar (linux/amd64) so kind load works reliably.
yellow "Building config-service:${IMAGE_TAG} (linux/amd64, -mod=vendor)..."
docker build --platform linux/amd64 -t "config-service:${IMAGE_TAG}" .
yellow "Saving image tar and loading into Kind..."
docker save "config-service:${IMAGE_TAG}" -o /tmp/config-service-app.tar
kind load image-archive /tmp/config-service-app.tar --name "${CLUSTER_NAME}"
rm -f /tmp/config-service-app.tar
green "App image ready in Kind"

# Infra images (bitnamilegacy = same content as bitnami, publicly accessible)
kind_load "${POSTGRES_IMAGE}"
kind_load "${KAFKA_IMAGE}"

# Prometheus stack images
# Pre-loading is required because quay.io TLS verification fails inside Kind nodes
# when running behind a corporate proxy/VPN. Pulling on the host works fine.
kind_load "${PROM_IMAGE}"
kind_load "${PROM_OPERATOR_IMAGE}"
kind_load "${PROM_CONFIG_RELOADER_IMAGE}"
kind_load "${GRAFANA_IMAGE}"
kind_load "${OTEL_IMAGE}"
kind_load "${JAEGER_IMAGE}"
kind_load "${LOKI_IMAGE}"
kind_load "${PROMTAIL_IMAGE}"

# ─── Step 5: PostgreSQL ───────────────────────────────────────────────────────
header "Step 5: PostgreSQL  (chart ${POSTGRES_CHART_VERSION} · image ${POSTGRES_IMAGE})"

# Clean stale release so image override takes effect
helm_clean postgres

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

# ─── Step 6: Kafka ────────────────────────────────────────────────────────────
header "Step 6: Kafka  (chart ${KAFKA_CHART_VERSION} · image ${KAFKA_IMAGE})"

helm_clean kafka

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
green "Kafka ready (topic: config-events)"

# ─── Step 7: config-service ──────────────────────────────────────────────────
header "Step 7: config-service app"
helm upgrade --install config-service deployments/helm/config-service \
  --namespace "${NAMESPACE}" \
  --set image.repository=config-service \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy=IfNotPresent \
  --set config.enableKafka=true \
  --set config.logLevel=debug \
  --set "config.otlpEndpoint=otel-collector-opentelemetry-collector.${NAMESPACE}.svc.cluster.local:4317" \
  --set serviceMonitor.enabled=true \
  --wait --timeout=3m
green "config-service deployed"

# ─── Step 8: Loki ────────────────────────────────────────────────────────────
header "Step 8: Loki  (chart ${LOKI_CHART_VERSION})"
helm upgrade --install loki grafana/loki \
  --version "${LOKI_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
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
  --wait --timeout=3m
green "Loki ready"

# ─── Step 9: Promtail ────────────────────────────────────────────────────────
header "Step 9: Promtail  (chart ${PROMTAIL_CHART_VERSION})"
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

# ─── Step 10: Jaeger ──────────────────────────────────────────────────────────
header "Step 10: Jaeger  (chart ${JAEGER_CHART_VERSION})"
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
green "Jaeger ready  → http://localhost:16686 after port-forward"

# ─── Step 11: OpenTelemetry Collector ─────────────────────────────────────────
# Image lives at ghcr.io only (Docker Hub has no stable tags for this image).
# crane on Mac host can pull ghcr.io fine (system CA handles TLS), so this
# image is pre-loaded into Kind like all others.
header "Step 11: OpenTelemetry Collector  (chart ${OTEL_CHART_VERSION})"
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


# ─── Step 12: Prometheus + Grafana ───────────────────────────────────────────
# Installed AFTER the app so ServiceMonitor resources exist before the operator
# scrapes for them — avoids a reconcile delay on first deploy.
header "Step 12: Prometheus + Grafana  (chart ${PROM_STACK_CHART_VERSION})"
helm upgrade --install prometheus prometheus/kube-prometheus-stack \
  --version "${PROM_STACK_CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set grafana.adminPassword=admin \
  --set grafana.persistence.enabled=false \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set kubeStateMetrics.enabled=false \
  --set nodeExporter.enabled=false \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --set "prometheus.prometheusSpec.image.registry=docker.io" \
  --set "prometheus.prometheusSpec.image.repository=prom/prometheus" \
  --set "prometheus.prometheusSpec.image.tag=v2.53.0" \
  --set "prometheus.prometheusSpec.image.pullPolicy=IfNotPresent" \
  --set "prometheusOperator.image.registry=quay.io" \
  --set "prometheusOperator.image.repository=prometheus-operator/prometheus-operator" \
  --set "prometheusOperator.image.tag=v0.74.0" \
  --set "prometheusOperator.image.pullPolicy=IfNotPresent" \
  --set "prometheusOperator.prometheusConfigReloader.image.registry=quay.io" \
  --set "prometheusOperator.prometheusConfigReloader.image.repository=prometheus-operator/prometheus-config-reloader" \
  --set "prometheusOperator.prometheusConfigReloader.image.tag=v0.74.0" \
  --set "prometheusOperator.prometheusConfigReloader.image.pullPolicy=IfNotPresent" \
  --set "grafana.image.repository=grafana/grafana" \
  --set "grafana.image.tag=10.4.3" \
  --set "grafana.image.pullPolicy=IfNotPresent" \
  --values deployments/manifests/grafana-provisioning.yaml \
  --wait --timeout=5m
green "Prometheus + Grafana ready  (admin / admin)"

# ─── Done ─────────────────────────────────────────────────────────────────────
header "All pods"
kubectl -n "${NAMESPACE}" get pods -o wide

echo ""
echo -e "\033[1;32m🎉  Stack is UP!\033[0m"
echo ""
echo "Run these port-forwards in separate terminal tabs:"
echo ""
echo "  kubectl -n ${NAMESPACE} port-forward svc/config-service                        8080:80    # App API"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-grafana                    3000:80    # Grafana (admin/admin)"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090  # Prometheus"
echo "  kubectl -n ${NAMESPACE} port-forward svc/jaeger                               16686:16686 # Jaeger traces"
echo "  kubectl -n ${NAMESPACE} port-forward svc/loki                                  3100:3100  # Loki logs"
echo ""
echo "Quick smoke test (after port-forwarding app):"
echo "  curl http://localhost:8080/ping"
echo "  ./scripts/smoke-test.sh http://localhost:8080"
echo ""
echo "Tear down everything:"
echo "  kind delete cluster --name ${CLUSTER_NAME}"
echo ""
