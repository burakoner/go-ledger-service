-- 0001_init_public.sql
-- This migration creates shared tables in the public schema.
-- Tenant-specific business tables will be created in tenant schemas separately.

BEGIN;

-- Used for UUID generation via gen_random_uuid().
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Tenant registry table (required metadata table).
CREATE TABLE IF NOT EXISTS public.tenant_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    currency CHAR(3) NOT NULL CHECK (currency IN ('GBP', 'EUR', 'USD', 'TRY')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
    schema TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tenant_accounts_status
    ON public.tenant_accounts (status);

-- Tenant API keys table (required metadata table, 1-to-N from tenant to keys).
-- One tenant can have many API keys.
CREATE TABLE IF NOT EXISTS public.tenant_api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenant_accounts(id) ON DELETE CASCADE,
    api_key_hash TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NULL
);

CREATE INDEX IF NOT EXISTS idx_tenant_api_keys_hash_status
    ON public.tenant_api_keys (api_key_hash, status);

CREATE INDEX IF NOT EXISTS idx_tenant_api_keys_tenant_status
    ON public.tenant_api_keys (tenant_id, status);

-- Per-tenant configuration table (required metadata table).
CREATE TABLE IF NOT EXISTS public.tenant_configs (
    tenant_id UUID NOT NULL REFERENCES public.tenant_accounts(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    value JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, key)
);

COMMIT;
