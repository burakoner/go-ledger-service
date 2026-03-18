#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

LEDGER_API_PORT="${LEDGER_API_PORT:-8080}"
LEDGER_ADMIN_PORT="${LEDGER_ADMIN_PORT:-8090}"
WEBHOOK_RECEIVER_PORT="${WEBHOOK_RECEIVER_PORT:-8088}"

LEDGER_API_URL="${LEDGER_API_URL:-http://localhost:${LEDGER_API_PORT}}"
LEDGER_ADMIN_URL="${LEDGER_ADMIN_URL:-http://localhost:${LEDGER_ADMIN_PORT}}"
WEBHOOK_RECEIVER_URL="${WEBHOOK_RECEIVER_URL:-http://localhost:${WEBHOOK_RECEIVER_PORT}}"
RATE_LIMIT_PER_MINUTE="${RATE_LIMIT_PER_MINUTE:-10000}"
export RATE_LIMIT_PER_MINUTE

TENANT_ADMIN_KEY="${TENANT_ADMIN_KEY:-WX5TczRsQnCk7k8k9AXbsW5czRsQnCkg}"
POSTGRES_DB="${POSTGRES_DB:-ledger}"
POSTGRES_USER="${POSTGRES_USER:-ledger}"

SEED_API_KEY_ALPHA="${SEED_API_KEY_ALPHA:-TK_SeedAlphaA1B2C3D4E5F6G7H8J9K0L1M2N3}"
SEED_API_KEY_BETA="${SEED_API_KEY_BETA:-TK_SeedBetaB1C2D3E4F5G6H7J8K9L0M1N2P3}"
SEED_API_KEY_GAMMA="${SEED_API_KEY_GAMMA:-TK_SeedGammaC1D2E3F4G5H6J7K8L9M0N1P2Q3}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      fail "Required command is missing: ${cmd}"
    fi
  done
}

compose() {
  (cd "$ROOT_DIR" && docker compose "$@")
}

wait_http_ok() {
  local name="$1"
  local url="$2"
  local timeout="${3:-120}"
  local deadline=$((SECONDS + timeout))
  local code

  while ((SECONDS < deadline)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)"
    if [[ "$code" == "200" ]]; then
      return 0
    fi
    sleep 2
  done

  fail "${name} is not healthy on ${url} within ${timeout}s"
}

ensure_stack_ready() {
  log "Starting docker compose stack."
  compose up -d

  wait_http_ok "ledger-api" "${LEDGER_API_URL}/health" 180
  wait_http_ok "ledger-admin" "${LEDGER_ADMIN_URL}/health" 180
  wait_http_ok "webhook-receiver" "${WEBHOOK_RECEIVER_URL}/health" 180

  if ! compose ps --services --status running | grep -qx "ledger-worker"; then
    fail "ledger-worker is not running"
  fi
}

json_get() {
  local file_path="$1"
  local path="$2"
  python3 - "$file_path" "$path" <<'PY'
import json
import sys

file_path = sys.argv[1]
path = sys.argv[2].strip()

with open(file_path, "r", encoding="utf-8") as f:
    data = json.load(f)

if path:
    for part in path.split("."):
        if isinstance(data, list):
            try:
                idx = int(part)
            except ValueError:
                print("")
                sys.exit(0)
            if idx < 0 or idx >= len(data):
                print("")
                sys.exit(0)
            data = data[idx]
            continue

        if isinstance(data, dict):
            if part not in data:
                print("")
                sys.exit(0)
            data = data[part]
            continue

        print("")
        sys.exit(0)

if data is None:
    print("")
elif isinstance(data, (dict, list)):
    print(json.dumps(data, separators=(",", ":")))
else:
    print(str(data))
PY
}

psql_query() {
  local query="$1"
  compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$query"
}

get_balance() {
  local api_key="$1"
  local body_file
  local status_code
  body_file="$(mktemp)"

  status_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -H "X-API-Key: ${api_key}" \
    "${LEDGER_API_URL}/api/v1/balance")"

  if [[ "$status_code" != "200" ]]; then
    cat "$body_file" >&2
    rm -f "$body_file"
    fail "Failed to fetch balance. HTTP status: ${status_code}"
  fi

  json_get "$body_file" "balance"
  rm -f "$body_file"
}

wait_transaction_terminal_status() {
  local api_key="$1"
  local transaction_id="$2"
  local timeout="${3:-120}"
  local deadline=$((SECONDS + timeout))
  local body_file
  local status_code
  local tx_status

  body_file="$(mktemp)"

  while ((SECONDS < deadline)); do
    status_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
      -H "X-API-Key: ${api_key}" \
      "${LEDGER_API_URL}/api/v1/transactions/${transaction_id}" || true)"

    if [[ "$status_code" == "200" ]]; then
      tx_status="$(json_get "$body_file" "transaction.status")"
      if [[ "$tx_status" == "completed" || "$tx_status" == "failed" ]]; then
        echo "${tx_status}"
        rm -f "$body_file"
        return 0
      fi
    fi

    sleep 1
  done

  rm -f "$body_file"
  fail "Transaction ${transaction_id} did not reach terminal status in ${timeout}s"
}

create_test_tenant() {
  local prefix="${1:-test}"
  local tenant_code
  local tenant_name
  local payload
  local body_file
  local status_code
  local tenant_id
  local tenant_schema
  local api_key

  tenant_code="${prefix}$(date +%s)${RANDOM}"
  tenant_name="Tenant ${tenant_code}"
  payload="$(printf '{"tenant_code":"%s","name":"%s","currency":"USD","configs":{"webhook_enabled":false,"webhook_url":""}}' "$tenant_code" "$tenant_name")"
  body_file="$(mktemp)"

  status_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Admin-Key: ${TENANT_ADMIN_KEY}" \
    -d "$payload" \
    "${LEDGER_ADMIN_URL}/api/v1/tenants/register")"

  if [[ "$status_code" != "201" ]]; then
    cat "$body_file" >&2
    rm -f "$body_file"
    fail "Failed to create test tenant. HTTP status: ${status_code}"
  fi

  tenant_id="$(json_get "$body_file" "id")"
  tenant_schema="$(json_get "$body_file" "schema")"
  api_key="$(json_get "$body_file" "api_key")"
  rm -f "$body_file"

  if [[ -z "$tenant_id" || -z "$tenant_schema" || -z "$api_key" ]]; then
    fail "Tenant creation response is missing required fields"
  fi

  printf '%s|%s|%s|%s\n' "$tenant_id" "$tenant_schema" "$api_key" "$tenant_code"
}
