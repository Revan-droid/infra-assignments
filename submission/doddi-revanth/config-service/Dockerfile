# ─── Build Stage ───────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /build

# vendor/ is pre-created by the setup scripts (scripts/kind-setup.sh or
# scripts/minikube-setup.sh) using a go mod vendor step that injects the macOS
# system CA certificate bundle to handle corporate TLS proxies. This means the
# Docker build never needs network access — pure compilation only.
COPY go.mod go.sum ./
COPY vendor/ vendor/

# Copy source and build a statically linked binary
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -mod=vendor \
    -ldflags="-w -s -X main.version=1.0.0" \
    -trimpath \
    -o /config-service \
    ./cmd/server

# ─── Runtime Stage ─────────────────────────────────────────────────────────────
FROM docker.io/alpine:3.19

RUN apk --no-cache add ca-certificates tzdata && \
    addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /config-service /config-service

EXPOSE 8080

USER appuser

ENTRYPOINT ["/config-service"]
