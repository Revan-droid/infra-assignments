# ─── Build Stage ───────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /build

# vendor/ is pre-created by the setup scripts using go mod vendor with macOS CA
# injection to handle corporate TLS proxies. Docker build has zero network access.
COPY go.mod go.sum ./
COPY vendor/ vendor/

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -mod=vendor \
    -ldflags="-w -s -X main.version=1.0.0" \
    -trimpath \
    -o /config-service \
    ./cmd/server

# ─── Runtime Stage ─────────────────────────────────────────────────────────────
# distroless/static has no package manager — zero network calls needed at build time.
# Includes ca-certificates and tzdata. Runs as nonroot (uid 65532) by default.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /config-service /config-service

EXPOSE 8080

USER nonroot

ENTRYPOINT ["/config-service"]
