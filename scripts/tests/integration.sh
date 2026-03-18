#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker curl python3

TX_WAIT_TIMEOUT="${TX_WAIT_TIMEOUT:-120}"

log "Running integration test."
ensure_stack_ready

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

log "Checking suspended tenant rejection."
IFS='|' read -r suspended_tenant_id _ suspended_api_key _ <<<"$(create_test_tenant "susp")"
psql_query "UPDATE public.tenant_accounts SET status='suspended', updated_at=now() WHERE id='${suspended_tenant_id}';" >/dev/null

suspended_payload='{"reference":"suspended-check","type":"credit","amount":1000,"description":"suspended","metadata":{"test":"integration"}}'
suspended_status="$(curl -sS -o "${tmp_dir}/suspended.json" -w '%{http_code}' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${suspended_api_key}" \
  -d "$suspended_payload" \
  "${LEDGER_API_URL}/api/v1/transactions")"

if [[ "$suspended_status" != "403" ]]; then
  cat "${tmp_dir}/suspended.json" >&2
  fail "Expected 403 for suspended tenant, got ${suspended_status}"
fi

suspended_error_code="$(json_get "${tmp_dir}/suspended.json" "error.code")"
if [[ "$suspended_error_code" != "TENANT_SUSPENDED" ]]; then
  fail "Expected TENANT_SUSPENDED error code, got ${suspended_error_code}"
fi

log "Checking revoked API key rejection."
IFS='|' read -r revoked_tenant_id _ revoked_api_key _ <<<"$(create_test_tenant "revk")"
psql_query "UPDATE public.tenant_api_keys SET status='revoked' WHERE tenant_id='${revoked_tenant_id}';" >/dev/null

revoked_payload='{"reference":"revoked-check","type":"credit","amount":1000,"description":"revoked","metadata":{"test":"integration"}}'
revoked_status="$(curl -sS -o "${tmp_dir}/revoked.json" -w '%{http_code}' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${revoked_api_key}" \
  -d "$revoked_payload" \
  "${LEDGER_API_URL}/api/v1/transactions")"

if [[ "$revoked_status" != "401" ]]; then
  cat "${tmp_dir}/revoked.json" >&2
  fail "Expected 401 for revoked API key, got ${revoked_status}"
fi

revoked_error_code="$(json_get "${tmp_dir}/revoked.json" "error.code")"
if [[ "$revoked_error_code" != "UNAUTHORIZED" ]]; then
  fail "Expected UNAUTHORIZED error code, got ${revoked_error_code}"
fi

IFS='|' read -r tenant_id tenant_schema api_key tenant_code <<<"$(create_test_tenant "integ")"
log "Created isolated tenant for integration test: ${tenant_id} (${tenant_schema})"

initial_balance="$(get_balance "$api_key")"
if [[ "$initial_balance" != "0" ]]; then
  fail "Expected initial balance 0 for new tenant, got ${initial_balance}"
fi

credit_reference="integ-credit-${tenant_code}-${RANDOM}"
credit_amount=2400
credit_payload="$(cat <<EOF
{"reference":"${credit_reference}","type":"credit","amount":${credit_amount},"description":"Integration credit","metadata":{"test":"integration"}}
EOF
)"

credit_status="$(curl -sS -o "${tmp_dir}/credit.json" -w '%{http_code}' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${api_key}" \
  -d "$credit_payload" \
  "${LEDGER_API_URL}/api/v1/transactions")"

if [[ "$credit_status" != "202" ]]; then
  cat "${tmp_dir}/credit.json" >&2
  fail "Expected 202 for credit transaction creation, got ${credit_status}"
fi

credit_transaction_id="$(json_get "${tmp_dir}/credit.json" "transaction.id")"
if [[ -z "$credit_transaction_id" ]]; then
  fail "Missing credit transaction id"
fi

credit_terminal_status="$(wait_transaction_terminal_status "$api_key" "$credit_transaction_id" "$TX_WAIT_TIMEOUT")"
if [[ "$credit_terminal_status" != "completed" ]]; then
  fail "Expected completed status for credit transaction, got ${credit_terminal_status}"
fi

post_credit_balance="$(get_balance "$api_key")"
if [[ "$post_credit_balance" != "$credit_amount" ]]; then
  fail "Expected balance ${credit_amount} after credit, got ${post_credit_balance}"
fi

debit_reference="integ-debit-${tenant_code}-${RANDOM}"
debit_amount=999999
debit_payload="$(cat <<EOF
{"reference":"${debit_reference}","type":"debit","amount":${debit_amount},"description":"Integration debit fail","metadata":{"test":"integration"}}
EOF
)"

debit_status="$(curl -sS -o "${tmp_dir}/debit.json" -w '%{http_code}' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${api_key}" \
  -d "$debit_payload" \
  "${LEDGER_API_URL}/api/v1/transactions")"

if [[ "$debit_status" != "202" ]]; then
  cat "${tmp_dir}/debit.json" >&2
  fail "Expected 202 for debit transaction creation, got ${debit_status}"
fi

debit_transaction_id="$(json_get "${tmp_dir}/debit.json" "transaction.id")"
if [[ -z "$debit_transaction_id" ]]; then
  fail "Missing debit transaction id"
fi

debit_terminal_status="$(wait_transaction_terminal_status "$api_key" "$debit_transaction_id" "$TX_WAIT_TIMEOUT")"
if [[ "$debit_terminal_status" != "failed" ]]; then
  fail "Expected failed status for debit transaction, got ${debit_terminal_status}"
fi

get_debit_status="$(curl -sS -o "${tmp_dir}/debit_get.json" -w '%{http_code}' \
  -H "X-API-Key: ${api_key}" \
  "${LEDGER_API_URL}/api/v1/transactions/${debit_transaction_id}")"
if [[ "$get_debit_status" != "200" ]]; then
  cat "${tmp_dir}/debit_get.json" >&2
  fail "Expected 200 when fetching debit transaction, got ${get_debit_status}"
fi

debit_failure_code="$(json_get "${tmp_dir}/debit_get.json" "transaction.failure_code")"
if [[ "$debit_failure_code" != "INSUFFICIENT_BALANCE" ]]; then
  fail "Expected INSUFFICIENT_BALANCE failure code, got ${debit_failure_code}"
fi

post_debit_balance="$(get_balance "$api_key")"
if [[ "$post_debit_balance" != "$credit_amount" ]]; then
  fail "Balance changed after failed debit. Expected ${credit_amount}, got ${post_debit_balance}"
fi

tx_row_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions;")"
ledger_row_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.ledger_entries;")"
failed_row_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE status='failed';")"

if [[ "$tx_row_count" != "2" ]]; then
  fail "Expected 2 transactions in tenant schema, got ${tx_row_count}"
fi
if [[ "$ledger_row_count" != "1" ]]; then
  fail "Expected 1 ledger entry in tenant schema, got ${ledger_row_count}"
fi
if [[ "$failed_row_count" != "1" ]]; then
  fail "Expected 1 failed transaction in tenant schema, got ${failed_row_count}"
fi

log "Integration test passed."
