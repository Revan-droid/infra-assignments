#!/usr/bin/env bash
# smoke-test.sh — End-to-end smoke test for config-service
# Usage: ./scripts/smoke-test.sh [BASE_URL]
# Exits non-zero on any failure.
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
PASS=0
FAIL=0

green() { echo -e "\033[32m✓ $*\033[0m"; }
red()   { echo -e "\033[31m✗ $*\033[0m"; }

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    green "$name"
    ((PASS++))
  else
    red "$name — expected '$expected', got '$actual'"
    ((FAIL++))
  fi
}

echo ""
echo "═══════════════════════════════════════════"
echo "  Config Service Smoke Test"
echo "  Target: $BASE_URL"
echo "═══════════════════════════════════════════"
echo ""

# ─── /ping ───────────────────────────────────────────────────────────────────
echo "▶ Health checks"

body=$(curl -sf "$BASE_URL/ping" || echo "FAILED")
check "GET /ping returns pong" "pong" "$body"

body=$(curl -sf "$BASE_URL/live" || echo "FAILED")
check "GET /live returns alive" "alive" "$body"

status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ready")
check "GET /ready returns 2xx" "2" "${status:0:1}"

# ─── /configs — Create ───────────────────────────────────────────────────────
echo ""
echo "▶ Config CRUD"

PAYLOAD='{"id":"smoke-cfg-1","host":"smoke.internal","port":8080,"app_name":"smoke-app","log_level":"INFO"}'
body=$(curl -sf -X POST "$BASE_URL/configs" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" || echo "FAILED")
check "POST /configs creates config" "smoke-cfg-1" "$body"

# ─── /configs — Read ─────────────────────────────────────────────────────────
body=$(curl -sf "$BASE_URL/configs/smoke-cfg-1" || echo "FAILED")
check "GET /configs/smoke-cfg-1 returns config" "smoke-cfg-1" "$body"
check "GET /configs/smoke-cfg-1 has correct host" "smoke.internal" "$body"
check "GET /configs/smoke-cfg-1 has correct app_name" "smoke-app" "$body"

# ─── /configs — Update (idempotent upsert) ───────────────────────────────────
UPDATED='{"id":"smoke-cfg-1","host":"smoke-updated.internal","port":9090,"app_name":"smoke-app","log_level":"DEBUG"}'
body=$(curl -sf -X POST "$BASE_URL/configs" \
  -H "Content-Type: application/json" \
  -d "$UPDATED" || echo "FAILED")
check "POST /configs updates existing config" "smoke-updated.internal" "$body"

body=$(curl -sf "$BASE_URL/configs/smoke-cfg-1" || echo "FAILED")
check "GET /configs/smoke-cfg-1 reflects update" "smoke-updated.internal" "$body"

# ─── 404 handling ─────────────────────────────────────────────────────────────
status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/configs/does-not-exist")
check "GET /configs/does-not-exist returns 404" "404" "$status"

# ─── Validation ───────────────────────────────────────────────────────────────
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/configs" \
  -H "Content-Type: application/json" \
  -d '{"host":"h","port":80}')
check "POST /configs without id returns 400" "400" "$status"

# ─── /metrics ─────────────────────────────────────────────────────────────────
echo ""
echo "▶ Metrics"

body=$(curl -sf "$BASE_URL/metrics" || echo "FAILED")
check "GET /metrics exposes http_requests_total" "http_requests_total" "$body"
check "GET /metrics exposes config_upserts_total" "config_upserts_total" "$body"
check "GET /metrics exposes db_queries_total" "db_queries_total" "$body"

# ─── Request ID propagation ───────────────────────────────────────────────────
echo ""
echo "▶ Request ID propagation"
headers=$(curl -sf -D - "$BASE_URL/ping" -o /dev/null -H "X-Request-ID: smoke-test-rid" || echo "")
check "X-Request-ID echoed in response" "smoke-test-rid" "$headers"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════"
echo ""

if [[ $FAIL -gt 0 ]]; then
  red "Smoke tests FAILED"
  exit 1
fi
green "All smoke tests PASSED"
