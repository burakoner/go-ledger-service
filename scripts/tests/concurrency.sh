#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker curl python3

PARALLEL_REQUESTS="${PARALLEL_REQUESTS:-12}"
TX_AMOUNT="${TX_AMOUNT:-1500}"
TX_WAIT_TIMEOUT="${TX_WAIT_TIMEOUT:-120}"

if (( PARALLEL_REQUESTS < 2 )); then
  fail "PARALLEL_REQUESTS must be at least 2"
fi
if (( TX_AMOUNT <= 0 )); then
  fail "TX_AMOUNT must be greater than 0"
fi

log "Running concurrency test."
ensure_stack_ready

IFS='|' read -r tenant_id tenant_schema api_key tenant_code <<<"$(create_test_tenant "conc")"
log "Created isolated tenant for concurrency test: ${tenant_id} (${tenant_schema})"

initial_balance="$(get_balance "$api_key")"
reference="conc-${tenant_code}-$(date +%s)-${RANDOM}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

payload="$(cat <<EOF
{"reference":"${reference}","type":"credit","amount":${TX_AMOUNT},"description":"Concurrency test","metadata":{"test":"concurrency"}}
EOF
)"

log "Sending ${PARALLEL_REQUESTS} parallel requests with the same reference."
for i in $(seq 1 "$PARALLEL_REQUESTS"); do
  (
    status_code="$(curl -sS -o "${tmp_dir}/body_${i}.json" -D "${tmp_dir}/headers_${i}.txt" -w '%{http_code}' \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-API-Key: ${api_key}" \
      -d "$payload" \
      "${LEDGER_API_URL}/api/v1/transactions" || true)"

    if [[ -z "$status_code" ]]; then
      status_code="000"
    fi
    printf '%s\n' "$status_code" > "${tmp_dir}/status_${i}.txt"
  ) &
done
wait

success_count=0
status_200_count=0
status_202_count=0
conflict_count=0
unexpected_count=0
replayed_true_count=0
tx_ids_file="${tmp_dir}/tx_ids.txt"
: > "$tx_ids_file"

for i in $(seq 1 "$PARALLEL_REQUESTS"); do
  status_code="$(cat "${tmp_dir}/status_${i}.txt")"
  case "$status_code" in
    200|202)
      success_count=$((success_count + 1))
      if [[ "$status_code" == "200" ]]; then
        status_200_count=$((status_200_count + 1))
      else
        status_202_count=$((status_202_count + 1))
      fi
      tx_id="$(json_get "${tmp_dir}/body_${i}.json" "transaction.id")"
      if [[ -z "$tx_id" ]]; then
        cat "${tmp_dir}/body_${i}.json" >&2
        fail "HTTP ${status_code} response without transaction.id"
      fi
      printf '%s\n' "$tx_id" >> "$tx_ids_file"
      if grep -qi '^Idempotency-Replayed: true' "${tmp_dir}/headers_${i}.txt"; then
        replayed_true_count=$((replayed_true_count + 1))
      fi
      ;;
    409)
      conflict_count=$((conflict_count + 1))
      ;;
    *)
      unexpected_count=$((unexpected_count + 1))
      cat "${tmp_dir}/body_${i}.json" >&2 || true
      ;;
  esac
done

if (( success_count < 1 )); then
  fail "No request succeeded with HTTP 200/202"
fi
if (( unexpected_count > 0 )); then
  fail "Found ${unexpected_count} unexpected HTTP responses"
fi

unique_tx_id_count="$(sort -u "$tx_ids_file" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$unique_tx_id_count" != "1" ]]; then
  fail "Expected exactly one unique transaction id across accepted responses, got ${unique_tx_id_count}"
fi

transaction_id="$(sort -u "$tx_ids_file" | sed '/^$/d' | head -n 1)"
reference_count="$(psql_query "SELECT count(*) FROM ${tenant_schema}.transactions WHERE reference='${reference}';")"
if [[ "$reference_count" != "1" ]]; then
  fail "Expected one row for reference ${reference}, got ${reference_count}"
fi

terminal_status="$(wait_transaction_terminal_status "$api_key" "$transaction_id" "$TX_WAIT_TIMEOUT")"
if [[ "$terminal_status" != "completed" ]]; then
  fail "Expected terminal status completed for credit transaction, got ${terminal_status}"
fi

final_balance="$(get_balance "$api_key")"
expected_balance=$((initial_balance + TX_AMOUNT))
if [[ "$final_balance" != "$expected_balance" ]]; then
  fail "Balance mismatch. Expected ${expected_balance}, got ${final_balance}"
fi

log "Concurrency test passed. status200=${status_200_count}, status202=${status_202_count}, conflict=${conflict_count}, replayed_true=${replayed_true_count}"
