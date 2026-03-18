#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker curl python3

PARALLEL_DEBITS="${PARALLEL_DEBITS:-20}"
INITIAL_CREDIT_AMOUNT="${INITIAL_CREDIT_AMOUNT:-5000}"
DEBIT_AMOUNT="${DEBIT_AMOUNT:-700}"
TX_WAIT_TIMEOUT="${TX_WAIT_TIMEOUT:-180}"

if (( PARALLEL_DEBITS < 2 )); then
  fail "PARALLEL_DEBITS must be at least 2"
fi
if (( INITIAL_CREDIT_AMOUNT <= 0 )); then
  fail "INITIAL_CREDIT_AMOUNT must be greater than 0"
fi
if (( DEBIT_AMOUNT <= 0 )); then
  fail "DEBIT_AMOUNT must be greater than 0"
fi

log "Running overdraw concurrency test."
ensure_stack_ready

IFS='|' read -r tenant_id tenant_schema api_key tenant_code <<<"$(create_test_tenant "odrw")"
log "Created isolated tenant for overdraw test: ${tenant_id} (${tenant_schema})"

initial_balance="$(get_balance "$api_key")"
if [[ "$initial_balance" != "0" ]]; then
  fail "Expected initial balance 0 for new tenant, got ${initial_balance}"
fi

credit_reference="overdraw-credit-${tenant_code}-$(date +%s)-${RANDOM}"
credit_payload="$(cat <<EOF
{"reference":"${credit_reference}","type":"credit","amount":${INITIAL_CREDIT_AMOUNT},"description":"Overdraw credit seed","metadata":{"test":"concurrency_overdraw"}}
EOF
)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

credit_status="$(curl -sS -o "${tmp_dir}/credit.json" -w '%{http_code}' \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-API-Key: ${api_key}" \
  -d "$credit_payload" \
  "${LEDGER_API_URL}/api/v1/transactions")"
if [[ "$credit_status" != "202" ]]; then
  cat "${tmp_dir}/credit.json" >&2
  fail "Expected 202 for seed credit transaction, got ${credit_status}"
fi

credit_tx_id="$(json_get "${tmp_dir}/credit.json" "transaction.id")"
if [[ -z "$credit_tx_id" ]]; then
  fail "Seed credit transaction id is missing"
fi

credit_terminal_status="$(wait_transaction_terminal_status "$api_key" "$credit_tx_id" "$TX_WAIT_TIMEOUT")"
if [[ "$credit_terminal_status" != "completed" ]]; then
  fail "Expected seed credit to be completed, got ${credit_terminal_status}"
fi

balance_after_credit="$(get_balance "$api_key")"
if [[ "$balance_after_credit" != "$INITIAL_CREDIT_AMOUNT" ]]; then
  fail "Expected balance ${INITIAL_CREDIT_AMOUNT} after seed credit, got ${balance_after_credit}"
fi

reference_prefix="overdraw-${tenant_code}-$(date +%s)-${RANDOM}"
tx_ids_file="${tmp_dir}/debit_tx_ids.txt"
: > "$tx_ids_file"

log "Submitting ${PARALLEL_DEBITS} parallel debit requests (amount=${DEBIT_AMOUNT})."
for i in $(seq 1 "$PARALLEL_DEBITS"); do
  (
    reference="${reference_prefix}-${i}"
    payload="$(cat <<EOF
{"reference":"${reference}","type":"debit","amount":${DEBIT_AMOUNT},"description":"Overdraw debit ${i}","metadata":{"test":"concurrency_overdraw","index":${i}}}
EOF
)"

    status_code="$(curl -sS -o "${tmp_dir}/debit_body_${i}.json" -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-API-Key: ${api_key}" \
      -d "$payload" \
      "${LEDGER_API_URL}/api/v1/transactions" || true)"

    if [[ "$status_code" != "202" ]]; then
      cat "${tmp_dir}/debit_body_${i}.json" >&2 || true
      echo "INVALID_STATUS_${status_code}" > "${tmp_dir}/debit_tx_${i}.txt"
      exit 0
    fi

    tx_id="$(json_get "${tmp_dir}/debit_body_${i}.json" "transaction.id")"
    if [[ -z "$tx_id" ]]; then
      echo "MISSING_TX_ID" > "${tmp_dir}/debit_tx_${i}.txt"
      exit 0
    fi
    echo "$tx_id" > "${tmp_dir}/debit_tx_${i}.txt"
  ) &
done
wait

for i in $(seq 1 "$PARALLEL_DEBITS"); do
  value="$(cat "${tmp_dir}/debit_tx_${i}.txt")"
  if [[ "$value" == INVALID_STATUS_* ]]; then
    fail "Debit request ${i} failed to create pending transaction (${value})"
  fi
  if [[ "$value" == "MISSING_TX_ID" ]]; then
    fail "Debit request ${i} returned 202 without transaction id"
  fi
  printf '%s\n' "$value" >> "$tx_ids_file"
done

while IFS= read -r tx_id; do
  wait_transaction_terminal_status "$api_key" "$tx_id" "$TX_WAIT_TIMEOUT" >/dev/null
done < "$tx_ids_file"

submitted_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE reference LIKE '${reference_prefix}-%';")"
completed_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE reference LIKE '${reference_prefix}-%' AND status='completed';")"
failed_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE reference LIKE '${reference_prefix}-%' AND status='failed';")"
bad_failure_code_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE reference LIKE '${reference_prefix}-%' AND status='failed' AND COALESCE(failure_code,'') <> 'INSUFFICIENT_BALANCE';")"
ledger_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.ledger_entries;")"

if [[ "$submitted_count" != "$PARALLEL_DEBITS" ]]; then
  fail "Expected ${PARALLEL_DEBITS} submitted debit rows, got ${submitted_count}"
fi

if (( completed_count + failed_count != PARALLEL_DEBITS )); then
  fail "Completed + failed debit rows mismatch. completed=${completed_count}, failed=${failed_count}, expected=${PARALLEL_DEBITS}"
fi

if [[ "$bad_failure_code_count" != "0" ]]; then
  fail "Found failed debit rows without INSUFFICIENT_BALANCE failure code"
fi

max_completed=$((INITIAL_CREDIT_AMOUNT / DEBIT_AMOUNT))
if (( completed_count > max_completed )); then
  fail "Too many completed debits. completed=${completed_count}, max_possible=${max_completed}"
fi

final_balance="$(get_balance "$api_key")"
expected_balance=$((INITIAL_CREDIT_AMOUNT - completed_count * DEBIT_AMOUNT))
if [[ "$final_balance" != "$expected_balance" ]]; then
  fail "Final balance mismatch. expected=${expected_balance}, got=${final_balance}"
fi

if (( final_balance < 0 )); then
  fail "Final balance cannot be negative. got=${final_balance}"
fi

expected_ledger_count=$((completed_count + 1))
if [[ "$ledger_count" != "$expected_ledger_count" ]]; then
  fail "Ledger row count mismatch. expected=${expected_ledger_count}, got=${ledger_count}"
fi

log "Overdraw concurrency test passed. completed=${completed_count}, failed=${failed_count}, final_balance=${final_balance}"
