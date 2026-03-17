-- 0002_init_tenant_schema.sql
-- Template migration for tenant-local schema creation.
-- The service replaces __TENANT_SCHEMA__ with a validated schema name.

CREATE SCHEMA IF NOT EXISTS __TENANT_SCHEMA__;

CREATE TABLE IF NOT EXISTS __TENANT_SCHEMA__.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reference TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('credit', 'debit')),
    amount BIGINT NOT NULL CHECK (amount > 0),
    description TEXT NOT NULL DEFAULT '',
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
    failure_code TEXT NULL,
    failure_reason TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ NULL
);

CREATE TABLE IF NOT EXISTS __TENANT_SCHEMA__.balances (
    id SMALLINT PRIMARY KEY,
    available_balance BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO __TENANT_SCHEMA__.balances (id, available_balance)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS __TENANT_SCHEMA__.ledger_entries (
    id BIGSERIAL PRIMARY KEY,
    transaction_id UUID NOT NULL REFERENCES __TENANT_SCHEMA__.transactions(id),
    reference TEXT NOT NULL,
    change_amount BIGINT NOT NULL,
    previous_balance BIGINT NOT NULL,
    new_balance BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
