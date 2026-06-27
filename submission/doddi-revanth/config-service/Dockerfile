# ─── Build Stage ───────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Copy vendor dir + source — no network access needed during build
# Run `go mod vendor` locally before building this image
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
# Using alpine (docker.io) instead of gcr.io/distroless — gcr.io may be blocked
# on corporate networks. Alpine gives us a shell for debugging too.
FROM docker.io/alpine:3.19

RUN apk --no-cache add ca-certificates tzdata && \
    addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /config-service /config-service

EXPOSE 8080

USER appuser

ENTRYPOINT ["/config-service"]
