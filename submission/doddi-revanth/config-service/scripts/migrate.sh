#!/usr/bin/env bash
# migrate.sh — Run golang-migrate against the configured PostgreSQL instance
# Usage: DATABASE_URL="postgres://..." ./scripts/migrate.sh
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgres://configuser:configpass@localhost:5432/configdb?sslmode=disable}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-migrations}"

green() { echo -e "\033[32m▶ $*\033[0m"; }
red()   { echo -e "\033[31m✗ $*\033[0m"; }

# Check for migrate CLI
if ! command -v migrate &>/dev/null; then
  echo "golang-migrate not found. Installing..."
  go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest
fi

green "Running migrations from: ${MIGRATIONS_DIR}"
green "Target database: ${DATABASE_URL//:*@/:***@}"  # redact password

migrate \
  -path "${MIGRATIONS_DIR}" \
  -database "${DATABASE_URL}" \
  up

green "Migrations applied successfully"
