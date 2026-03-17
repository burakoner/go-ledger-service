# Go Ledger Service

Multi-tenant ledger project in Go.

Current phase:
- containerized services
- public schema migration
- tenant registration API with automatic API key creation
- dummy `ledger-worker` service
- RabbitMQ infrastructure for inter-service messaging

## 1. Prerequisites

- Docker Desktop (Linux engine running)
- Docker Compose v2+

## 2. Run

1. Create env file:

```bash
cp .env.example .env
```

2. Start services:

```bash
docker compose up --build
```

3. Verify API health:

```bash
curl http://localhost:8080/api/v1/health
curl http://localhost:8081/api/v1/health
```

4. Open RabbitMQ management UI:

```text
http://localhost:15672
```

Default login is read from `.env`:
- `RABBITMQ_USER`
- `RABBITMQ_PASSWORD`

`migrations/0001_init_public.sql` is executed automatically by PostgreSQL on first initialization via `/docker-entrypoint-initdb.d`.
If `postgres_data` volume already exists, init scripts do not run again.

## 3. Services

1. `ledger-api` (`cmd/ledger-api`, port `8080`)
- `/`
- `/api/v1/health`
- future: transaction submit/query endpoints

2. `ledger-admin` (`cmd/ledger-admin`, port `8081`)
- `/`
- `/api/v1/health`
- `POST /api/v1/tenants/register`

`ledger-admin` register endpoint requires `X-Admin-Key`.

3. `ledger-worker` (`cmd/ledger-worker`, internal only)
- dummy background process for now
- prints env values for verification and exits
- will consume RabbitMQ messages in next phase

4. `rabbitmq` (ports `5672`, `15672`)
- AMQP broker for async communication between services
- management UI enabled for local development

5. `postgres` and `redis`
- PostgreSQL remains source of truth for financial correctness
- Redis remains support cache layer (rate-limit/idempotency acceleration)

## 4. Register Tenant

```bash
curl -X POST http://localhost:8081/api/v1/tenants/register \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: ${TENANT_ADMIN_KEY}" \
  -d '{
    "tenant_code": "acme",
    "name": "Acme Ltd",
    "currency": "USD",
    "configs": {
      "webhook_url": "http://localhost:9000/webhook",
      "rate_limit_per_minute": 60
    }
  }'
```

Register flow:
1. Insert tenant into `public.tenant_accounts`.
2. Create tenant schema/tables via `migrations/0002_init_tenant_schema.sql`.
3. Create first API key in `public.tenant_api_keys`.
4. Save optional config values in `public.tenant_configs`.

The plaintext API key is returned once.
Supported currencies: `GBP`, `EUR`, `USD`, `TRY`.

## 5. Dummy Ledger-Worker Plan

Current dummy behavior:
1. `ledger-worker` starts and prints runtime env values:
   `DATABASE_URL`, `REDIS_ADDR`, `RABBITMQ_URL`, `RABBITMQ_USER`, `RABBITMQ_PASSWORD`.
2. Process exits immediately after printing logs.
3. No queue consumption yet (intentional).

Next implementation steps:
1. `ledger-api` publishes transaction events to RabbitMQ exchange.
2. `ledger-worker` consumes queue messages and processes jobs.
3. Worker writes results into PostgreSQL and updates outbox state.
4. Webhook delivery + retry/backoff runs in worker flow.

## 6. Messaging Plan (RabbitMQ)

Initial target topology:
1. Exchange: `ledger.events` (`topic`)
2. Queue: `ledger.transactions.process`
3. Queue: `ledger.webhooks.dispatch`
4. Routing keys:
- `transaction.created`
- `webhook.dispatch`

This remains a plan for the next coding phase; only infrastructure is active now.

## 7. Migration Model

- `migrations/0001_init_public.sql`
  - auto-applied at first PostgreSQL initialization
  - creates shared `public` tables:
    - `tenant_accounts`
    - `tenant_api_keys`
    - `tenant_configs`
    - `tenant_idempotency_keys`
    - `tenant_transaction_jobs`
    - `tenant_webhook_outbox`

- `migrations/0002_init_tenant_schema.sql`
  - template migration
  - executed by `ledger-admin` during tenant register
  - `__TENANT_SCHEMA__` placeholder is replaced by generated schema name

## 8. Project Structure

```text
/cmd
  /ledger-api
  /ledger-admin
  /ledger-worker
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
