# Go Ledger Service

Multi-tenant ledger project in Go.

Current phase:
- containerized services
- public schema migration
- tenant registration API with automatic API key creation

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

3. Apply shared/public migration:

```bash
docker compose exec -T postgres psql -U "${POSTGRES_USER:-ledger}" -d "${POSTGRES_DB:-ledger}" < migrations/0001_init_public.sql
```

4. Verify health:

```bash
curl http://localhost:8080/api/v1/health
curl http://localhost:8081/api/v1/health
```

## 3. Services

1. `ledger-api` (`cmd/ledger-api`, port `8080`)
- `/`
- `/api/v1/health`

2. `ledger-admin` (`cmd/ledger-admin`, port `8081`)
- `/`
- `/api/v1/health`
- `POST /api/v1/tenants/register`

`ledger-admin` register endpoint requires admin key via `X-Admin-Key` header.

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
1. Inserts tenant record into `public.tenant_accounts`.
2. Creates first API key in `public.tenant_api_keys`.
3. Stores config values in `public.tenant_configs`.
4. Creates tenant schema/tables by executing SQL template:
   `migrations/0002_init_tenant_schema.sql`

The plaintext API key is returned once in the register response.
Supported currencies for this phase: `GBP`, `EUR`, `USD`, `TRY`.

## 5. Migration Model

- `migrations/0001_init_public.sql`
  - applied manually once per environment
  - creates shared `public` tables:
    - `tenant_accounts`
    - `tenant_api_keys`
    - `tenant_configs`
    - `tenant_idempotency_keys`
    - `tenant_transaction_jobs`
    - `tenant_webhook_outbox`

- `migrations/0002_init_tenant_schema.sql`
  - template migration
  - executed by `ledger-admin` during register
  - `__TENANT_SCHEMA__` placeholder is replaced with generated tenant schema name

## 6. Project Structure

```text
/cmd
  /ledger-api
  /ledger-admin
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
