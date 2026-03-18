#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker curl python3

log "Running smoke test."
ensure_stack_ready

log "Checking PostgreSQL and Redis container health."
compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -h localhost -p 5432 >/dev/null
compose exec -T redis redis-cli ping | grep -qx "PONG"

log "Checking seeded tenant metadata existence."
tenant_count="$(psql_query "SELECT count(*) FROM public.tenant_accounts;")"
api_key_count="$(psql_query "SELECT count(*) FROM public.tenant_api_keys;")"
revoked_key_count="$(psql_query "SELECT count(*) FROM public.tenant_api_keys WHERE status='revoked';")"

if [[ "${EXPECT_SEED_DATA:-0}" == "1" ]]; then
  if (( tenant_count < 10 )); then
    fail "Expected at least 10 seeded tenants, got ${tenant_count}"
  fi
  if (( api_key_count < 10 )); then
    fail "Expected at least 10 seeded API keys, got ${api_key_count}"
  fi
  if (( revoked_key_count < 2 )); then
    fail "Expected at least 2 revoked API keys, got ${revoked_key_count}"
  fi
fi

log "Smoke test passed."
