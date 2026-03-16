# Go Ledger Service

Multi-tenant payment ledger service in Go, built for the take-home task requirements.

Current status: **Work in progress**.  
Containerization and project skeleton are in place. Core ledger features are being implemented in the defined priority order.

## 1. How To Run

## Prerequisites

- Docker Desktop (with Linux engine running)
- Docker Compose v2+

## Environment

1. Copy env template:

```bash
cp .env.example .env
```

2. Update values in `.env` if needed.

## Start

```bash
docker compose up --build
```

## Verify

```bash
curl http://localhost:8080/api/v1/health
```

Expected response: `OK`

## Stop

```bash
docker compose down
```

## 2. Architecture Overview

The service follows a clean layered architecture:

- `http` layer: routing, request parsing, auth middleware, response mapping
- `service` layer: business rules (transaction lifecycle, idempotency decisions, rate-limit orchestration)
- `repository` layer: PostgreSQL access and transactional data updates
- `worker` layer: asynchronous processing for transaction jobs and webhook delivery

The intended runtime flow:

1. API accepts a transaction request and stores it as `pending`.
2. A background worker picks jobs asynchronously.
3. Worker applies balance changes atomically and writes immutable ledger entries.
4. Worker updates final transaction state and triggers webhook delivery via outbox flow.

## 3. Schema-Per-Tenant Isolation

Tenant isolation is implemented with PostgreSQL schemas.

## Shared `public` schema

Mandatory metadata tables:

- `tenant_accounts` (tenant registry)
- `tenant_api_keys` (N-to-N API key mapping)
- `configs` (tenant configuration)

Operational tables in `public`:

- `idempotency_keys`
- `transaction_jobs`
- `webhook_outbox`

## Tenant schemas

Each tenant has its own schema (example: `tenant_<tenant_account_id>`) containing:

- `transactions`
- `balances`
- `ledger_entries`

## Isolation mechanism

1. Tenant is resolved early from `X-API-Key`.
2. Repository operations run in a DB transaction.
3. `SET LOCAL search_path = <tenant_schema>, public` is used within transaction scope.
4. This prevents cross-tenant data access when querying tenant tables.

## 4. Redis Usage (Why Redis Is Used)

Redis is included and used as a supporting layer for:

- tenant-based rate limiting (token bucket)
- idempotency replay cache (fast repeated response retrieval)

PostgreSQL remains the source of truth for financial correctness (balance, ledger, transaction state).  
If Redis is unavailable, correctness must still be protected via database-backed logic.

## 5. Design Decisions And Trade-Offs

1. **Clean layers over monolithic handlers**  
Pro: easier testing and maintenance.  
Trade-off: more files and interfaces.

2. **Schema-per-tenant isolation**  
Pro: strong data isolation boundary.  
Trade-off: migration/orchestration complexity increases.

3. **Asynchronous worker pipeline**  
Pro: non-blocking API (`202 Accepted`) and better throughput control.  
Trade-off: eventual consistency and operational complexity.

4. **Redis for performance, PostgreSQL for correctness**  
Pro: better latency for replay/rate-limit operations.  
Trade-off: extra infrastructure dependency.

## 6. What I Would Improve With More Time

1. Add complete migration tooling and migration test suite.
2. Add stronger observability (metrics, traces, structured dashboards).
3. Add chaos/failure testing for Redis and worker crash scenarios.
4. Add full end-to-end tests for tenant onboarding and webhook retries.
5. Add stricter security hardening (secrets management, key rotation flow, mTLS-ready webhook options).

## 7. Project Structure

```text
/cmd
  /server
/internal
  /config
  /http
  /service
  /repository
  /worker
  /tenant
  /idempotency
  /cache
  /db
/migrations
```

## 8. API Status

## Available now

- `GET /`
- `GET /api/v1/health`

## Planned (task scope)

- `POST /api/v1/tenants/register`
- `POST /api/v1/transactions`
- `GET /api/v1/transactions/:id`
- `GET /api/v1/transactions`
- `GET /api/v1/balance`
- `GET /api/v1/ledger`

## 9. Development Notes

- Coding progression follows this fixed order:
1. Containerization
2. Database architecture + migrations
3. Tenant registration
4. Transactions + ledger + async processing
5. Idempotency
6. Rate limiting
7. Webhook notifications

- Detailed analysis and decisions are documented in:
[docs/ledger-service-analysis.md](/mnt/e/Github/go-ledger-service/docs/ledger-service-analysis.md)
