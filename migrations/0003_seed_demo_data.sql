-- 0003_seed_demo_data.sql
-- Demo seed data for local development.
-- This script is executed by PostgreSQL init only on first DB bootstrap.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TEMP TABLE seed_tenants (
    tenant_order INTEGER PRIMARY KEY,
    tenant_id UUID NOT NULL,
    code TEXT NOT NULL,
    name TEXT NOT NULL,
    currency CHAR(3) NOT NULL,
    status TEXT NOT NULL,
    schema_name TEXT NOT NULL,
    api_key_plain TEXT NOT NULL,
    api_key_status TEXT NOT NULL,
    webhook_enabled BOOLEAN NOT NULL,
    transaction_count INTEGER NOT NULL
) ON COMMIT DROP;

INSERT INTO seed_tenants (
    tenant_order,
    tenant_id,
    code,
    name,
    currency,
    status,
    schema_name,
    api_key_plain,
    api_key_status,
    webhook_enabled,
    transaction_count
)
VALUES
    (1, '00000000-0000-0000-0000-000000000101', 'alpha', 'Alpha Market', 'USD', 'active', 'tenant_00000000000000000000000000000101', 'TK_SeedAlphaA1B2C3D4E5F6G7H8J9K0L1M2N3', 'active', TRUE, 20),
    (2, '00000000-0000-0000-0000-000000000102', 'beta', 'Beta Store', 'EUR', 'active', 'tenant_00000000000000000000000000000102', 'TK_SeedBetaB1C2D3E4F5G6H7J8K9L0M1N2P3', 'revoked', FALSE, 0),
    (3, '00000000-0000-0000-0000-000000000103', 'gamma', 'Gamma Shop', 'GBP', 'suspended', 'tenant_00000000000000000000000000000103', 'TK_SeedGammaC1D2E3F4G5H6J7K8L9M0N1P2Q3', 'active', TRUE, 7),
    (4, '00000000-0000-0000-0000-000000000104', 'delta', 'Delta Bazaar', 'USD', 'active', 'tenant_00000000000000000000000000000104', 'TK_SeedDeltaD1E2F3G4H5J6K7L8M9N0P1Q2R3', 'active', FALSE, 13),
    (5, '00000000-0000-0000-0000-000000000105', 'epsilon', 'Epsilon Trade', 'EUR', 'active', 'tenant_00000000000000000000000000000105', 'TK_SeedEpsilonE1F2G3H4J5K6L7M8N9P0Q1R2S3', 'active', TRUE, 15),
    (6, '00000000-0000-0000-0000-000000000106', 'zeta', 'Zeta Commerce', 'GBP', 'active', 'tenant_00000000000000000000000000000106', 'TK_SeedZetaF1G2H3J4K5L6M7N8P9Q0R1S2T3U4', 'active', FALSE, 24),
    (7, '00000000-0000-0000-0000-000000000107', 'eta', 'Eta Supplies', 'USD', 'active', 'tenant_00000000000000000000000000000107', 'TK_SeedEtaG1H2J3K4L5M6N7P8Q9R0S1T2U3V4W5', 'active', TRUE, 40),
    (8, '00000000-0000-0000-0000-000000000108', 'theta', 'Theta Retail', 'EUR', 'active', 'tenant_00000000000000000000000000000108', 'TK_SeedThetaH1J2K3L4M5N6P7Q8R9S0T1U2V3W4X5', 'revoked', FALSE, 64),
    (9, '00000000-0000-0000-0000-000000000109', 'iota', 'Iota Outlet', 'GBP', 'active', 'tenant_00000000000000000000000000000109', 'TK_SeedIotaJ1K2L3M4N5P6Q7R8S9T0U1V2W3X4Y5', 'active', TRUE, 72),
    (10, '00000000-0000-0000-0000-000000000110', 'kappa', 'Kappa Wholesale', 'USD', 'active', 'tenant_00000000000000000000000000000110', 'TK_SeedKappaK1L2M3N4P5Q6R7S8T9U0V1W2X3Y4Z5', 'active', FALSE, 100);

INSERT INTO public.tenant_accounts (id, code, name, currency, status, schema, created_at, updated_at)
SELECT
    tenant_id,
    code,
    name,
    currency,
    status,
    schema_name,
    now(),
    now()
FROM seed_tenants
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.tenant_api_keys (tenant_id, api_key_hash, status, created_at)
SELECT
    tenant_id,
    encode(digest(api_key_plain, 'sha256'), 'hex'),
    api_key_status,
    now()
FROM seed_tenants
ON CONFLICT (api_key_hash) DO NOTHING;

INSERT INTO public.tenant_configs (tenant_id, key, value, updated_at)
SELECT
    st.tenant_id,
    cfg.key,
    cfg.value,
    now()
FROM seed_tenants AS st
CROSS JOIN LATERAL (
    VALUES
        ('webhook_enabled'::text, to_jsonb(st.webhook_enabled)),
        (
            'webhook_url'::text,
            to_jsonb(
                CASE
                    WHEN st.webhook_enabled THEN 'http://webhook-receiver:8088/webhooks/transactions'
                    ELSE ''
                END
            )
        )
) AS cfg(key, value)
ON CONFLICT (tenant_id, key)
DO UPDATE SET value = EXCLUDED.value, updated_at = now();

DO $$
DECLARE
    tenant_row RECORD;
BEGIN
    FOR tenant_row IN
        SELECT *
        FROM seed_tenants
        ORDER BY tenant_order ASC
    LOOP
        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', tenant_row.schema_name);

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.transactions (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                reference TEXT NOT NULL,
                type TEXT NOT NULL CHECK (type IN (''credit'', ''debit'')),
                amount BIGINT NOT NULL CHECK (amount > 0),
                description TEXT NOT NULL DEFAULT '''',
                metadata JSONB NOT NULL DEFAULT ''{}''::jsonb,
                status TEXT NOT NULL CHECK (status IN (''pending'', ''completed'', ''failed'')),
                failure_code TEXT NULL,
                failure_reason TEXT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                processed_at TIMESTAMPTZ NULL
            )',
            tenant_row.schema_name
        );

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS idx_transactions_pending_created_at
             ON %I.transactions (created_at ASC, id ASC)
             WHERE status = ''pending''',
            tenant_row.schema_name
        );

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS idx_transactions_reference_created_at
             ON %I.transactions (reference, created_at DESC, id DESC)',
            tenant_row.schema_name
        );

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.balances (
                id SMALLINT PRIMARY KEY,
                balance BIGINT NOT NULL DEFAULT 0,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )',
            tenant_row.schema_name
        );

        EXECUTE format(
            'INSERT INTO %I.balances (id, balance, updated_at)
             VALUES (1, 0, now())
             ON CONFLICT (id) DO NOTHING',
            tenant_row.schema_name
        );

        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.ledger_entries (
                id BIGSERIAL PRIMARY KEY,
                transaction_id UUID NOT NULL REFERENCES %I.transactions(id),
                reference TEXT NOT NULL,
                change_amount BIGINT NOT NULL,
                previous_balance BIGINT NOT NULL,
                new_balance BIGINT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )',
            tenant_row.schema_name,
            tenant_row.schema_name
        );
    END LOOP;
END
$$;

INSERT INTO tenant_00000000000000000000000000000101.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('4a13ccc8-df2e-5a3c-a3d6-35c423f04b11'::uuid, 'seed-alpha-001', 'credit', 1060, 'Seed transaction #1 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '25 minutes', now() - interval '25 minutes' + interval '2 seconds', now() - interval '25 minutes' + interval '5 seconds'),
        ('c2eda903-301e-5b33-8fa0-f89a4764e019'::uuid, 'seed-alpha-002', 'debit', 1594, 'Seed transaction #2 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":2,"scenario":"insufficient_balance_debit","available_before":1060}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1594 exceeds available balance of 1060', now() - interval '24 minutes', now() - interval '24 minutes' + interval '2 seconds', now() - interval '24 minutes' + interval '5 seconds'),
        ('2d5e7898-6a75-55b8-842b-e7255544c103'::uuid, 'seed-alpha-003', 'credit', 1322, 'Seed transaction #3 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '23 minutes', now() - interval '23 minutes' + interval '2 seconds', now() - interval '23 minutes' + interval '5 seconds'),
        ('41d5f758-17a2-50d3-a0f3-76f5ddec629c'::uuid, 'seed-alpha-004', 'credit', 1453, 'Seed transaction #4 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '22 minutes', now() - interval '22 minutes' + interval '2 seconds', now() - interval '22 minutes' + interval '5 seconds'),
        ('de8d1fac-f586-5935-ab6a-0a38c5dde26b'::uuid, 'seed-alpha-005', 'credit', 1584, 'Seed transaction #5 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '21 minutes', now() - interval '21 minutes' + interval '2 seconds', now() - interval '21 minutes' + interval '5 seconds'),
        ('971db9a0-ec37-5628-b057-fe563573d89b'::uuid, 'seed-alpha-006', 'debit', 845, 'Seed transaction #6 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '20 minutes', now() - interval '20 minutes' + interval '2 seconds', now() - interval '20 minutes' + interval '5 seconds'),
        ('f46a33f5-fa1e-52e4-bff3-cae0287aca1f'::uuid, 'seed-alpha-007', 'debit', 5193, 'Seed transaction #7 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":7,"scenario":"insufficient_balance_debit","available_before":4574}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 5193 exceeds available balance of 4574', now() - interval '19 minutes', now() - interval '19 minutes' + interval '2 seconds', now() - interval '19 minutes' + interval '5 seconds'),
        ('a3d0ce79-df5d-52cb-8295-9c09eba15921'::uuid, 'seed-alpha-008', 'credit', 1977, 'Seed transaction #8 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '18 minutes', now() - interval '18 minutes' + interval '2 seconds', now() - interval '18 minutes' + interval '5 seconds'),
        ('5d6a8b2d-25f7-593f-87a3-04ee59178f12'::uuid, 'seed-alpha-009', 'debit', 1112, 'Seed transaction #9 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '17 minutes', now() - interval '17 minutes' + interval '2 seconds', now() - interval '17 minutes' + interval '5 seconds'),
        ('69387f48-009d-59b4-a7ee-f286286eb655'::uuid, 'seed-alpha-010', 'credit', 1470, 'Seed transaction #10 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '16 minutes', now(), now()),
        ('f7269724-ff6c-5d29-a645-bbf69f5e2e6a'::uuid, 'seed-alpha-011', 'credit', 2370, 'Seed transaction #11 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '15 minutes', now() - interval '15 minutes' + interval '2 seconds', now() - interval '15 minutes' + interval '5 seconds'),
        ('f0d9824b-7040-57df-9f84-507bab6f7bc4'::uuid, 'seed-alpha-012', 'debit', 1379, 'Seed transaction #12 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '14 minutes', now() - interval '14 minutes' + interval '2 seconds', now() - interval '14 minutes' + interval '5 seconds'),
        ('bef4642f-08ba-5827-96ec-a2c2ea266482'::uuid, 'seed-alpha-013', 'credit', 2632, 'Seed transaction #13 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '13 minutes', now() - interval '13 minutes' + interval '2 seconds', now() - interval '13 minutes' + interval '5 seconds'),
        ('c448d76f-02fa-5da5-8345-6b0564aa693e'::uuid, 'seed-alpha-014', 'credit', 2763, 'Seed transaction #14 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '12 minutes', now() - interval '12 minutes' + interval '2 seconds', now() - interval '12 minutes' + interval '5 seconds'),
        ('a785cfaf-0a5f-5da7-9279-bbd3533c291e'::uuid, 'seed-alpha-015', 'debit', 12580, 'Seed transaction #15 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":15,"scenario":"insufficient_balance_debit","available_before":11825}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 12580 exceeds available balance of 11825', now() - interval '11 minutes', now() - interval '11 minutes' + interval '2 seconds', now() - interval '11 minutes' + interval '5 seconds'),
        ('6d43ad5f-76b7-51aa-bafe-c529fa551e09'::uuid, 'seed-alpha-016', 'credit', 3025, 'Seed transaction #16 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '10 minutes', now() - interval '10 minutes' + interval '2 seconds', now() - interval '10 minutes' + interval '5 seconds'),
        ('ae82cdd5-645c-56d2-90c4-c88315e4a4aa'::uuid, 'seed-alpha-017', 'credit', 3156, 'Seed transaction #17 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '9 minutes', now() - interval '9 minutes' + interval '2 seconds', now() - interval '9 minutes' + interval '5 seconds'),
        ('a4c028ac-4cf5-5899-8feb-dd577ef5840e'::uuid, 'seed-alpha-018', 'debit', 413, 'Seed transaction #18 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '8 minutes', now() - interval '8 minutes' + interval '2 seconds', now() - interval '8 minutes' + interval '5 seconds'),
        ('84aa570c-64a7-594c-9150-5b87fe0df0d7'::uuid, 'seed-alpha-019', 'credit', 3418, 'Seed transaction #19 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '7 minutes', now() - interval '7 minutes' + interval '2 seconds', now() - interval '7 minutes' + interval '5 seconds'),
        ('b37382dc-da12-5a99-b2ef-7ceb727df01e'::uuid, 'seed-alpha-020', 'credit', 3549, 'Seed transaction #20 for tenant alpha', '{"seed":true,"tenant_code":"alpha","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '6 minutes', now() - interval '6 minutes' + interval '2 seconds', now() - interval '6 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000101.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('4a13ccc8-df2e-5a3c-a3d6-35c423f04b11'::uuid, 'seed-alpha-001', 1060, 0, 1060, now() - interval '25 minutes' + interval '5 seconds'),
        ('2d5e7898-6a75-55b8-842b-e7255544c103'::uuid, 'seed-alpha-003', 1322, 1060, 2382, now() - interval '23 minutes' + interval '5 seconds'),
        ('41d5f758-17a2-50d3-a0f3-76f5ddec629c'::uuid, 'seed-alpha-004', 1453, 2382, 3835, now() - interval '22 minutes' + interval '5 seconds'),
        ('de8d1fac-f586-5935-ab6a-0a38c5dde26b'::uuid, 'seed-alpha-005', 1584, 3835, 5419, now() - interval '21 minutes' + interval '5 seconds'),
        ('971db9a0-ec37-5628-b057-fe563573d89b'::uuid, 'seed-alpha-006', -845, 5419, 4574, now() - interval '20 minutes' + interval '5 seconds'),
        ('a3d0ce79-df5d-52cb-8295-9c09eba15921'::uuid, 'seed-alpha-008', 1977, 4574, 6551, now() - interval '18 minutes' + interval '5 seconds'),
        ('5d6a8b2d-25f7-593f-87a3-04ee59178f12'::uuid, 'seed-alpha-009', -1112, 6551, 5439, now() - interval '17 minutes' + interval '5 seconds'),
        ('f7269724-ff6c-5d29-a645-bbf69f5e2e6a'::uuid, 'seed-alpha-011', 2370, 5439, 7809, now() - interval '15 minutes' + interval '5 seconds'),
        ('f0d9824b-7040-57df-9f84-507bab6f7bc4'::uuid, 'seed-alpha-012', -1379, 7809, 6430, now() - interval '14 minutes' + interval '5 seconds'),
        ('bef4642f-08ba-5827-96ec-a2c2ea266482'::uuid, 'seed-alpha-013', 2632, 6430, 9062, now() - interval '13 minutes' + interval '5 seconds'),
        ('c448d76f-02fa-5da5-8345-6b0564aa693e'::uuid, 'seed-alpha-014', 2763, 9062, 11825, now() - interval '12 minutes' + interval '5 seconds'),
        ('6d43ad5f-76b7-51aa-bafe-c529fa551e09'::uuid, 'seed-alpha-016', 3025, 11825, 14850, now() - interval '10 minutes' + interval '5 seconds'),
        ('ae82cdd5-645c-56d2-90c4-c88315e4a4aa'::uuid, 'seed-alpha-017', 3156, 14850, 18006, now() - interval '9 minutes' + interval '5 seconds'),
        ('a4c028ac-4cf5-5899-8feb-dd577ef5840e'::uuid, 'seed-alpha-018', -413, 18006, 17593, now() - interval '8 minutes' + interval '5 seconds'),
        ('84aa570c-64a7-594c-9150-5b87fe0df0d7'::uuid, 'seed-alpha-019', 3418, 17593, 21011, now() - interval '7 minutes' + interval '5 seconds'),
        ('b37382dc-da12-5a99-b2ef-7ceb727df01e'::uuid, 'seed-alpha-020', 3549, 21011, 24560, now() - interval '6 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000101.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('69387f48-009d-59b4-a7ee-f286286eb655'::uuid, 'seed-alpha-010', 1470, 24560, 26030, now());

UPDATE tenant_00000000000000000000000000000101.balances SET balance = 26030, updated_at = now() WHERE id = 1;

-- beta: no seeded transactions (0 rows).

-- beta: no seeded ledger entries (0 rows).

UPDATE tenant_00000000000000000000000000000102.balances SET balance = 0, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000103.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('39eb8b46-cf36-5c1e-a574-fa8814ef5133'::uuid, 'seed-gamma-001', 'credit', 1118, 'Seed transaction #1 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '22 minutes', now() - interval '22 minutes' + interval '2 seconds', now() - interval '22 minutes' + interval '5 seconds'),
        ('9237e7b1-eefe-5b24-a309-3f677915cb79'::uuid, 'seed-gamma-002', 'debit', 1652, 'Seed transaction #2 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":2,"scenario":"insufficient_balance_debit","available_before":1118}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1652 exceeds available balance of 1118', now() - interval '21 minutes', now() - interval '21 minutes' + interval '2 seconds', now() - interval '21 minutes' + interval '5 seconds'),
        ('ca446154-43cb-5778-920d-3aa31c3332f7'::uuid, 'seed-gamma-003', 'credit', 1380, 'Seed transaction #3 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '20 minutes', now() - interval '20 minutes' + interval '2 seconds', now() - interval '20 minutes' + interval '5 seconds'),
        ('c66ea07c-0f8e-58f1-9724-42b905a84185'::uuid, 'seed-gamma-004', 'credit', 1511, 'Seed transaction #4 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '19 minutes', now() - interval '19 minutes' + interval '2 seconds', now() - interval '19 minutes' + interval '5 seconds'),
        ('8a8372e3-9032-5a03-8eca-a34c0d79ccb4'::uuid, 'seed-gamma-005', 'credit', 1642, 'Seed transaction #5 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '18 minutes', now() - interval '18 minutes' + interval '2 seconds', now() - interval '18 minutes' + interval '5 seconds'),
        ('e90f3f51-3bf0-5a91-9f0d-077ce39ee51c'::uuid, 'seed-gamma-006', 'debit', 867, 'Seed transaction #6 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '17 minutes', now() - interval '17 minutes' + interval '2 seconds', now() - interval '17 minutes' + interval '5 seconds'),
        ('b288f229-7e7a-51de-8cad-b76d81c440e7'::uuid, 'seed-gamma-007', 'debit', 5403, 'Seed transaction #7 for tenant gamma', '{"seed":true,"tenant_code":"gamma","sequence":7,"scenario":"insufficient_balance_debit","available_before":4784}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 5403 exceeds available balance of 4784', now() - interval '16 minutes', now() - interval '16 minutes' + interval '2 seconds', now() - interval '16 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000103.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('39eb8b46-cf36-5c1e-a574-fa8814ef5133'::uuid, 'seed-gamma-001', 1118, 0, 1118, now() - interval '22 minutes' + interval '5 seconds'),
        ('ca446154-43cb-5778-920d-3aa31c3332f7'::uuid, 'seed-gamma-003', 1380, 1118, 2498, now() - interval '20 minutes' + interval '5 seconds'),
        ('c66ea07c-0f8e-58f1-9724-42b905a84185'::uuid, 'seed-gamma-004', 1511, 2498, 4009, now() - interval '19 minutes' + interval '5 seconds'),
        ('8a8372e3-9032-5a03-8eca-a34c0d79ccb4'::uuid, 'seed-gamma-005', 1642, 4009, 5651, now() - interval '18 minutes' + interval '5 seconds'),
        ('e90f3f51-3bf0-5a91-9f0d-077ce39ee51c'::uuid, 'seed-gamma-006', -867, 5651, 4784, now() - interval '17 minutes' + interval '5 seconds');

UPDATE tenant_00000000000000000000000000000103.balances SET balance = 4784, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000104.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('a6df6b05-22a0-5421-9145-52036b561d82'::uuid, 'seed-delta-001', 'credit', 1147, 'Seed transaction #1 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '33 minutes', now() - interval '33 minutes' + interval '2 seconds', now() - interval '33 minutes' + interval '5 seconds'),
        ('5a12b05e-b8b3-5e3a-8583-40b104f830e3'::uuid, 'seed-delta-002', 'debit', 1681, 'Seed transaction #2 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":2,"scenario":"insufficient_balance_debit","available_before":1147}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1681 exceeds available balance of 1147', now() - interval '32 minutes', now() - interval '32 minutes' + interval '2 seconds', now() - interval '32 minutes' + interval '5 seconds'),
        ('6886471b-3172-5e9b-91c8-86e5d3a96353'::uuid, 'seed-delta-003', 'credit', 1409, 'Seed transaction #3 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '31 minutes', now() - interval '31 minutes' + interval '2 seconds', now() - interval '31 minutes' + interval '5 seconds'),
        ('dad3e9e0-d9cb-5163-9bbf-c66001a775db'::uuid, 'seed-delta-004', 'credit', 1540, 'Seed transaction #4 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '30 minutes', now() - interval '30 minutes' + interval '2 seconds', now() - interval '30 minutes' + interval '5 seconds'),
        ('ddce4ffd-beaf-56dd-bad8-d1593a3fc278'::uuid, 'seed-delta-005', 'credit', 1671, 'Seed transaction #5 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '29 minutes', now() - interval '29 minutes' + interval '2 seconds', now() - interval '29 minutes' + interval '5 seconds'),
        ('a6509b41-150d-5dc3-8f7d-087876a44164'::uuid, 'seed-delta-006', 'debit', 878, 'Seed transaction #6 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '28 minutes', now() - interval '28 minutes' + interval '2 seconds', now() - interval '28 minutes' + interval '5 seconds'),
        ('39dd4317-75f2-5d2c-b273-e865a79e4703'::uuid, 'seed-delta-007', 'debit', 5508, 'Seed transaction #7 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":7,"scenario":"insufficient_balance_debit","available_before":4889}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 5508 exceeds available balance of 4889', now() - interval '27 minutes', now() - interval '27 minutes' + interval '2 seconds', now() - interval '27 minutes' + interval '5 seconds'),
        ('315a8c25-4390-5c86-92b7-4eafe595c76f'::uuid, 'seed-delta-008', 'credit', 2064, 'Seed transaction #8 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '26 minutes', now() - interval '26 minutes' + interval '2 seconds', now() - interval '26 minutes' + interval '5 seconds'),
        ('709167c5-38f1-589d-9f82-67e69e9e36e8'::uuid, 'seed-delta-009', 'debit', 1145, 'Seed transaction #9 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '25 minutes', now() - interval '25 minutes' + interval '2 seconds', now() - interval '25 minutes' + interval '5 seconds'),
        ('f7f7113b-4086-57d1-aa78-619031fa6949'::uuid, 'seed-delta-010', 'credit', 1470, 'Seed transaction #10 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '24 minutes', now(), now()),
        ('3a439456-11f7-5792-8356-d8cc152df3c0'::uuid, 'seed-delta-011', 'credit', 2457, 'Seed transaction #11 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '23 minutes', now() - interval '23 minutes' + interval '2 seconds', now() - interval '23 minutes' + interval '5 seconds'),
        ('1d6a2422-4307-5b2d-a854-c542d827a00b'::uuid, 'seed-delta-012', 'debit', 1412, 'Seed transaction #12 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '22 minutes', now() - interval '22 minutes' + interval '2 seconds', now() - interval '22 minutes' + interval '5 seconds'),
        ('f9c03380-bc72-55b8-82ff-90eeb716f56c'::uuid, 'seed-delta-013', 'credit', 2719, 'Seed transaction #13 for tenant delta', '{"seed":true,"tenant_code":"delta","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '21 minutes', now() - interval '21 minutes' + interval '2 seconds', now() - interval '21 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000104.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('a6df6b05-22a0-5421-9145-52036b561d82'::uuid, 'seed-delta-001', 1147, 0, 1147, now() - interval '33 minutes' + interval '5 seconds'),
        ('6886471b-3172-5e9b-91c8-86e5d3a96353'::uuid, 'seed-delta-003', 1409, 1147, 2556, now() - interval '31 minutes' + interval '5 seconds'),
        ('dad3e9e0-d9cb-5163-9bbf-c66001a775db'::uuid, 'seed-delta-004', 1540, 2556, 4096, now() - interval '30 minutes' + interval '5 seconds'),
        ('ddce4ffd-beaf-56dd-bad8-d1593a3fc278'::uuid, 'seed-delta-005', 1671, 4096, 5767, now() - interval '29 minutes' + interval '5 seconds'),
        ('a6509b41-150d-5dc3-8f7d-087876a44164'::uuid, 'seed-delta-006', -878, 5767, 4889, now() - interval '28 minutes' + interval '5 seconds'),
        ('315a8c25-4390-5c86-92b7-4eafe595c76f'::uuid, 'seed-delta-008', 2064, 4889, 6953, now() - interval '26 minutes' + interval '5 seconds'),
        ('709167c5-38f1-589d-9f82-67e69e9e36e8'::uuid, 'seed-delta-009', -1145, 6953, 5808, now() - interval '25 minutes' + interval '5 seconds'),
        ('3a439456-11f7-5792-8356-d8cc152df3c0'::uuid, 'seed-delta-011', 2457, 5808, 8265, now() - interval '23 minutes' + interval '5 seconds'),
        ('1d6a2422-4307-5b2d-a854-c542d827a00b'::uuid, 'seed-delta-012', -1412, 8265, 6853, now() - interval '22 minutes' + interval '5 seconds'),
        ('f9c03380-bc72-55b8-82ff-90eeb716f56c'::uuid, 'seed-delta-013', 2719, 6853, 9572, now() - interval '21 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000104.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('f7f7113b-4086-57d1-aa78-619031fa6949'::uuid, 'seed-delta-010', 1470, 9572, 11042, now());

UPDATE tenant_00000000000000000000000000000104.balances SET balance = 11042, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000105.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('d2a19237-a2b0-5151-81ba-758074d94ab7'::uuid, 'seed-epsilon-001', 'credit', 1176, 'Seed transaction #1 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '40 minutes', now() - interval '40 minutes' + interval '2 seconds', now() - interval '40 minutes' + interval '5 seconds'),
        ('a891ea5e-656e-57ba-b25f-e095fa279c20'::uuid, 'seed-epsilon-002', 'debit', 1710, 'Seed transaction #2 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":2,"scenario":"insufficient_balance_debit","available_before":1176}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1710 exceeds available balance of 1176', now() - interval '39 minutes', now() - interval '39 minutes' + interval '2 seconds', now() - interval '39 minutes' + interval '5 seconds'),
        ('b05c2964-c5a0-5bfd-a71f-af9da95be022'::uuid, 'seed-epsilon-003', 'credit', 1438, 'Seed transaction #3 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '38 minutes', now() - interval '38 minutes' + interval '2 seconds', now() - interval '38 minutes' + interval '5 seconds'),
        ('9cc59103-dfb0-5440-b191-6e216ca1798f'::uuid, 'seed-epsilon-004', 'credit', 1569, 'Seed transaction #4 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '37 minutes', now() - interval '37 minutes' + interval '2 seconds', now() - interval '37 minutes' + interval '5 seconds'),
        ('1acb9ea7-7529-529d-8ea2-4e129a8254a1'::uuid, 'seed-epsilon-005', 'credit', 1700, 'Seed transaction #5 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '36 minutes', now() - interval '36 minutes' + interval '2 seconds', now() - interval '36 minutes' + interval '5 seconds'),
        ('b01bfa3d-61a1-50bc-9e48-34e832103cf6'::uuid, 'seed-epsilon-006', 'debit', 889, 'Seed transaction #6 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '35 minutes', now() - interval '35 minutes' + interval '2 seconds', now() - interval '35 minutes' + interval '5 seconds'),
        ('b5272a7b-0d36-5e65-b048-1d5bb3e5e38c'::uuid, 'seed-epsilon-007', 'debit', 5613, 'Seed transaction #7 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":7,"scenario":"insufficient_balance_debit","available_before":4994}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 5613 exceeds available balance of 4994', now() - interval '34 minutes', now() - interval '34 minutes' + interval '2 seconds', now() - interval '34 minutes' + interval '5 seconds'),
        ('add97ae9-6496-5a78-82b3-3ff21f816bdc'::uuid, 'seed-epsilon-008', 'credit', 2093, 'Seed transaction #8 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '33 minutes', now() - interval '33 minutes' + interval '2 seconds', now() - interval '33 minutes' + interval '5 seconds'),
        ('9bb89910-8ff1-5286-aea9-fe2370ad4b12'::uuid, 'seed-epsilon-009', 'debit', 1156, 'Seed transaction #9 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '32 minutes', now() - interval '32 minutes' + interval '2 seconds', now() - interval '32 minutes' + interval '5 seconds'),
        ('83e277af-4799-596c-8a7e-9fa334757ddc'::uuid, 'seed-epsilon-010', 'credit', 1470, 'Seed transaction #10 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '31 minutes', now(), now()),
        ('dd085716-3d7a-59db-92ea-fd60e909c997'::uuid, 'seed-epsilon-011', 'credit', 2486, 'Seed transaction #11 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '30 minutes', now() - interval '30 minutes' + interval '2 seconds', now() - interval '30 minutes' + interval '5 seconds'),
        ('851778bf-a855-5d9d-8a2b-87d68c5a04ef'::uuid, 'seed-epsilon-012', 'debit', 1423, 'Seed transaction #12 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '29 minutes', now() - interval '29 minutes' + interval '2 seconds', now() - interval '29 minutes' + interval '5 seconds'),
        ('0d3fd15f-1138-51ac-90d7-e90bd218f095'::uuid, 'seed-epsilon-013', 'credit', 2748, 'Seed transaction #13 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '28 minutes', now() - interval '28 minutes' + interval '2 seconds', now() - interval '28 minutes' + interval '5 seconds'),
        ('719c7703-3af7-5072-8fb6-604ec7866726'::uuid, 'seed-epsilon-014', 'credit', 2879, 'Seed transaction #14 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '27 minutes', now() - interval '27 minutes' + interval '2 seconds', now() - interval '27 minutes' + interval '5 seconds'),
        ('4b77ab4d-74b6-51ce-b437-20e2493fb848'::uuid, 'seed-epsilon-015', 'debit', 13376, 'Seed transaction #15 for tenant epsilon', '{"seed":true,"tenant_code":"epsilon","sequence":15,"scenario":"insufficient_balance_debit","available_before":12621}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 13376 exceeds available balance of 12621', now() - interval '26 minutes', now() - interval '26 minutes' + interval '2 seconds', now() - interval '26 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000105.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('d2a19237-a2b0-5151-81ba-758074d94ab7'::uuid, 'seed-epsilon-001', 1176, 0, 1176, now() - interval '40 minutes' + interval '5 seconds'),
        ('b05c2964-c5a0-5bfd-a71f-af9da95be022'::uuid, 'seed-epsilon-003', 1438, 1176, 2614, now() - interval '38 minutes' + interval '5 seconds'),
        ('9cc59103-dfb0-5440-b191-6e216ca1798f'::uuid, 'seed-epsilon-004', 1569, 2614, 4183, now() - interval '37 minutes' + interval '5 seconds'),
        ('1acb9ea7-7529-529d-8ea2-4e129a8254a1'::uuid, 'seed-epsilon-005', 1700, 4183, 5883, now() - interval '36 minutes' + interval '5 seconds'),
        ('b01bfa3d-61a1-50bc-9e48-34e832103cf6'::uuid, 'seed-epsilon-006', -889, 5883, 4994, now() - interval '35 minutes' + interval '5 seconds'),
        ('add97ae9-6496-5a78-82b3-3ff21f816bdc'::uuid, 'seed-epsilon-008', 2093, 4994, 7087, now() - interval '33 minutes' + interval '5 seconds'),
        ('9bb89910-8ff1-5286-aea9-fe2370ad4b12'::uuid, 'seed-epsilon-009', -1156, 7087, 5931, now() - interval '32 minutes' + interval '5 seconds'),
        ('dd085716-3d7a-59db-92ea-fd60e909c997'::uuid, 'seed-epsilon-011', 2486, 5931, 8417, now() - interval '30 minutes' + interval '5 seconds'),
        ('851778bf-a855-5d9d-8a2b-87d68c5a04ef'::uuid, 'seed-epsilon-012', -1423, 8417, 6994, now() - interval '29 minutes' + interval '5 seconds'),
        ('0d3fd15f-1138-51ac-90d7-e90bd218f095'::uuid, 'seed-epsilon-013', 2748, 6994, 9742, now() - interval '28 minutes' + interval '5 seconds'),
        ('719c7703-3af7-5072-8fb6-604ec7866726'::uuid, 'seed-epsilon-014', 2879, 9742, 12621, now() - interval '27 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000105.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('83e277af-4799-596c-8a7e-9fa334757ddc'::uuid, 'seed-epsilon-010', 1470, 12621, 14091, now());

UPDATE tenant_00000000000000000000000000000105.balances SET balance = 14091, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000106.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('b9c77ef1-8004-5ff3-b49b-8a0850da45f6'::uuid, 'seed-zeta-001', 'credit', 1205, 'Seed transaction #1 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '54 minutes', now() - interval '54 minutes' + interval '2 seconds', now() - interval '54 minutes' + interval '5 seconds'),
        ('966eb3dc-c4f5-5e02-b96f-3ba580bbbba4'::uuid, 'seed-zeta-002', 'debit', 1739, 'Seed transaction #2 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":2,"scenario":"insufficient_balance_debit","available_before":1205}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1739 exceeds available balance of 1205', now() - interval '53 minutes', now() - interval '53 minutes' + interval '2 seconds', now() - interval '53 minutes' + interval '5 seconds'),
        ('6ffcb074-a19f-5c0c-b45e-bc5c5746615a'::uuid, 'seed-zeta-003', 'debit', 633, 'Seed transaction #3 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '52 minutes', now() - interval '52 minutes' + interval '2 seconds', now() - interval '52 minutes' + interval '5 seconds'),
        ('c0b3f7ee-a960-5735-b440-2efe14baa3a6'::uuid, 'seed-zeta-004', 'credit', 1598, 'Seed transaction #4 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '51 minutes', now() - interval '51 minutes' + interval '2 seconds', now() - interval '51 minutes' + interval '5 seconds'),
        ('7d2c1930-64f3-5a3f-836f-a1bfec1953c3'::uuid, 'seed-zeta-005', 'credit', 1729, 'Seed transaction #5 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '50 minutes', now() - interval '50 minutes' + interval '2 seconds', now() - interval '50 minutes' + interval '5 seconds'),
        ('fc27f16d-4288-5e3d-b444-7061d39b1a1f'::uuid, 'seed-zeta-006', 'debit', 900, 'Seed transaction #6 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '49 minutes', now() - interval '49 minutes' + interval '2 seconds', now() - interval '49 minutes' + interval '5 seconds'),
        ('c71267b8-80c5-51a9-8e02-78e988efc005'::uuid, 'seed-zeta-007', 'debit', 3618, 'Seed transaction #7 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":7,"scenario":"insufficient_balance_debit","available_before":2999}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 3618 exceeds available balance of 2999', now() - interval '48 minutes', now() - interval '48 minutes' + interval '2 seconds', now() - interval '48 minutes' + interval '5 seconds'),
        ('0cb1c43f-a27d-515c-913b-3db4fc562be9'::uuid, 'seed-zeta-008', 'credit', 2122, 'Seed transaction #8 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '47 minutes', now() - interval '47 minutes' + interval '2 seconds', now() - interval '47 minutes' + interval '5 seconds'),
        ('bf7c5be2-2b0e-5221-baba-70c8a5454395'::uuid, 'seed-zeta-009', 'debit', 1167, 'Seed transaction #9 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '46 minutes', now() - interval '46 minutes' + interval '2 seconds', now() - interval '46 minutes' + interval '5 seconds'),
        ('389d9f86-abe2-56f0-97ce-f6042e1438c0'::uuid, 'seed-zeta-010', 'credit', 1470, 'Seed transaction #10 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '45 minutes', now(), now()),
        ('cc252761-3f8b-50fa-b06d-f0558dbea540'::uuid, 'seed-zeta-011', 'credit', 2515, 'Seed transaction #11 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '44 minutes', now() - interval '44 minutes' + interval '2 seconds', now() - interval '44 minutes' + interval '5 seconds'),
        ('977a5d8d-1a1e-53a0-928a-909af83c3774'::uuid, 'seed-zeta-012', 'debit', 1434, 'Seed transaction #12 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '43 minutes', now() - interval '43 minutes' + interval '2 seconds', now() - interval '43 minutes' + interval '5 seconds'),
        ('6f654129-7a14-5b2d-8be8-3268fc446c15'::uuid, 'seed-zeta-013', 'credit', 2777, 'Seed transaction #13 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '42 minutes', now() - interval '42 minutes' + interval '2 seconds', now() - interval '42 minutes' + interval '5 seconds'),
        ('a1c787a8-5627-58f7-a91d-5320795aaf3e'::uuid, 'seed-zeta-014', 'credit', 2908, 'Seed transaction #14 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '41 minutes', now() - interval '41 minutes' + interval '2 seconds', now() - interval '41 minutes' + interval '5 seconds'),
        ('1819350e-8521-5399-9190-2ac2b642a677'::uuid, 'seed-zeta-015', 'debit', 11475, 'Seed transaction #15 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":15,"scenario":"insufficient_balance_debit","available_before":10720}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 11475 exceeds available balance of 10720', now() - interval '40 minutes', now() - interval '40 minutes' + interval '2 seconds', now() - interval '40 minutes' + interval '5 seconds'),
        ('59d54cb2-0a97-557e-9335-60db1ffda705'::uuid, 'seed-zeta-016', 'credit', 3170, 'Seed transaction #16 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '39 minutes', now() - interval '39 minutes' + interval '2 seconds', now() - interval '39 minutes' + interval '5 seconds'),
        ('1d0f5ba4-3cde-5c3c-a8ac-b0ddbd9047c1'::uuid, 'seed-zeta-017', 'credit', 3301, 'Seed transaction #17 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '38 minutes', now() - interval '38 minutes' + interval '2 seconds', now() - interval '38 minutes' + interval '5 seconds'),
        ('261728e0-66c8-5ca0-859f-370983ea35a1'::uuid, 'seed-zeta-018', 'debit', 468, 'Seed transaction #18 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '37 minutes', now() - interval '37 minutes' + interval '2 seconds', now() - interval '37 minutes' + interval '5 seconds'),
        ('a9edc2ce-4590-52c2-bddd-947111595327'::uuid, 'seed-zeta-019', 'credit', 3563, 'Seed transaction #19 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '36 minutes', now() - interval '36 minutes' + interval '2 seconds', now() - interval '36 minutes' + interval '5 seconds'),
        ('b6d1fcb2-d26c-502f-90fd-ddb963267f36'::uuid, 'seed-zeta-020', 'credit', 3694, 'Seed transaction #20 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '35 minutes', now() - interval '35 minutes' + interval '2 seconds', now() - interval '35 minutes' + interval '5 seconds'),
        ('94bcbe40-9db2-5855-b4bd-46201d5f5f75'::uuid, 'seed-zeta-021', 'debit', 735, 'Seed transaction #21 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":21,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '34 minutes', now() - interval '34 minutes' + interval '2 seconds', now() - interval '34 minutes' + interval '5 seconds'),
        ('ef9ce36b-156b-51a1-9643-ce75f31650ab'::uuid, 'seed-zeta-022', 'credit', 3956, 'Seed transaction #22 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":22,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '33 minutes', now() - interval '33 minutes' + interval '2 seconds', now() - interval '33 minutes' + interval '5 seconds'),
        ('ec686f1d-d5f6-57a6-9691-3c609d5ecdb0'::uuid, 'seed-zeta-023', 'credit', 4087, 'Seed transaction #23 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":23,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '32 minutes', now() - interval '32 minutes' + interval '2 seconds', now() - interval '32 minutes' + interval '5 seconds'),
        ('8415916d-6226-5734-9d2f-8e6394573ad7'::uuid, 'seed-zeta-024', 'debit', 1002, 'Seed transaction #24 for tenant zeta', '{"seed":true,"tenant_code":"zeta","sequence":24,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '31 minutes', now() - interval '31 minutes' + interval '2 seconds', now() - interval '31 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000106.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('b9c77ef1-8004-5ff3-b49b-8a0850da45f6'::uuid, 'seed-zeta-001', 1205, 0, 1205, now() - interval '54 minutes' + interval '5 seconds'),
        ('6ffcb074-a19f-5c0c-b45e-bc5c5746615a'::uuid, 'seed-zeta-003', -633, 1205, 572, now() - interval '52 minutes' + interval '5 seconds'),
        ('c0b3f7ee-a960-5735-b440-2efe14baa3a6'::uuid, 'seed-zeta-004', 1598, 572, 2170, now() - interval '51 minutes' + interval '5 seconds'),
        ('7d2c1930-64f3-5a3f-836f-a1bfec1953c3'::uuid, 'seed-zeta-005', 1729, 2170, 3899, now() - interval '50 minutes' + interval '5 seconds'),
        ('fc27f16d-4288-5e3d-b444-7061d39b1a1f'::uuid, 'seed-zeta-006', -900, 3899, 2999, now() - interval '49 minutes' + interval '5 seconds'),
        ('0cb1c43f-a27d-515c-913b-3db4fc562be9'::uuid, 'seed-zeta-008', 2122, 2999, 5121, now() - interval '47 minutes' + interval '5 seconds'),
        ('bf7c5be2-2b0e-5221-baba-70c8a5454395'::uuid, 'seed-zeta-009', -1167, 5121, 3954, now() - interval '46 minutes' + interval '5 seconds'),
        ('cc252761-3f8b-50fa-b06d-f0558dbea540'::uuid, 'seed-zeta-011', 2515, 3954, 6469, now() - interval '44 minutes' + interval '5 seconds'),
        ('977a5d8d-1a1e-53a0-928a-909af83c3774'::uuid, 'seed-zeta-012', -1434, 6469, 5035, now() - interval '43 minutes' + interval '5 seconds'),
        ('6f654129-7a14-5b2d-8be8-3268fc446c15'::uuid, 'seed-zeta-013', 2777, 5035, 7812, now() - interval '42 minutes' + interval '5 seconds'),
        ('a1c787a8-5627-58f7-a91d-5320795aaf3e'::uuid, 'seed-zeta-014', 2908, 7812, 10720, now() - interval '41 minutes' + interval '5 seconds'),
        ('59d54cb2-0a97-557e-9335-60db1ffda705'::uuid, 'seed-zeta-016', 3170, 10720, 13890, now() - interval '39 minutes' + interval '5 seconds'),
        ('1d0f5ba4-3cde-5c3c-a8ac-b0ddbd9047c1'::uuid, 'seed-zeta-017', 3301, 13890, 17191, now() - interval '38 minutes' + interval '5 seconds'),
        ('261728e0-66c8-5ca0-859f-370983ea35a1'::uuid, 'seed-zeta-018', -468, 17191, 16723, now() - interval '37 minutes' + interval '5 seconds'),
        ('a9edc2ce-4590-52c2-bddd-947111595327'::uuid, 'seed-zeta-019', 3563, 16723, 20286, now() - interval '36 minutes' + interval '5 seconds'),
        ('b6d1fcb2-d26c-502f-90fd-ddb963267f36'::uuid, 'seed-zeta-020', 3694, 20286, 23980, now() - interval '35 minutes' + interval '5 seconds'),
        ('94bcbe40-9db2-5855-b4bd-46201d5f5f75'::uuid, 'seed-zeta-021', -735, 23980, 23245, now() - interval '34 minutes' + interval '5 seconds'),
        ('ef9ce36b-156b-51a1-9643-ce75f31650ab'::uuid, 'seed-zeta-022', 3956, 23245, 27201, now() - interval '33 minutes' + interval '5 seconds'),
        ('ec686f1d-d5f6-57a6-9691-3c609d5ecdb0'::uuid, 'seed-zeta-023', 4087, 27201, 31288, now() - interval '32 minutes' + interval '5 seconds'),
        ('8415916d-6226-5734-9d2f-8e6394573ad7'::uuid, 'seed-zeta-024', -1002, 31288, 30286, now() - interval '31 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000106.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('389d9f86-abe2-56f0-97ce-f6042e1438c0'::uuid, 'seed-zeta-010', 1470, 30286, 31756, now());

UPDATE tenant_00000000000000000000000000000106.balances SET balance = 31756, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000107.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('cd8e7c67-dbb7-556f-955b-62057bd4b0fc'::uuid, 'seed-eta-001', 'credit', 1234, 'Seed transaction #1 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '75 minutes', now() - interval '75 minutes' + interval '2 seconds', now() - interval '75 minutes' + interval '5 seconds'),
        ('b5fddaa2-804b-5a6b-9972-47015365f9fe'::uuid, 'seed-eta-002', 'debit', 1768, 'Seed transaction #2 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":2,"scenario":"insufficient_balance_debit","available_before":1234}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1768 exceeds available balance of 1234', now() - interval '74 minutes', now() - interval '74 minutes' + interval '2 seconds', now() - interval '74 minutes' + interval '5 seconds'),
        ('094509de-127f-51e9-bbe5-3ff42a0e2c4c'::uuid, 'seed-eta-003', 'debit', 644, 'Seed transaction #3 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '73 minutes', now() - interval '73 minutes' + interval '2 seconds', now() - interval '73 minutes' + interval '5 seconds'),
        ('1a231f55-879c-56ce-98f0-029cec4c178b'::uuid, 'seed-eta-004', 'credit', 1627, 'Seed transaction #4 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '72 minutes', now() - interval '72 minutes' + interval '2 seconds', now() - interval '72 minutes' + interval '5 seconds'),
        ('bac4e2fc-2d05-5ff9-ad2f-49cabf6093fe'::uuid, 'seed-eta-005', 'credit', 1758, 'Seed transaction #5 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '71 minutes', now() - interval '71 minutes' + interval '2 seconds', now() - interval '71 minutes' + interval '5 seconds'),
        ('e10b8983-deef-51c2-ae01-e2c33b9cd4c0'::uuid, 'seed-eta-006', 'debit', 911, 'Seed transaction #6 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '70 minutes', now() - interval '70 minutes' + interval '2 seconds', now() - interval '70 minutes' + interval '5 seconds'),
        ('b2246f19-88d4-5128-bf49-6b57d7e2a3a0'::uuid, 'seed-eta-007', 'debit', 3683, 'Seed transaction #7 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":7,"scenario":"insufficient_balance_debit","available_before":3064}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 3683 exceeds available balance of 3064', now() - interval '69 minutes', now() - interval '69 minutes' + interval '2 seconds', now() - interval '69 minutes' + interval '5 seconds'),
        ('dccd454a-90dc-57fb-bdd3-411d71ae090f'::uuid, 'seed-eta-008', 'credit', 2151, 'Seed transaction #8 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '68 minutes', now() - interval '68 minutes' + interval '2 seconds', now() - interval '68 minutes' + interval '5 seconds'),
        ('a6543bff-e403-5421-a83d-2f14e2e296d3'::uuid, 'seed-eta-009', 'debit', 1178, 'Seed transaction #9 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '67 minutes', now() - interval '67 minutes' + interval '2 seconds', now() - interval '67 minutes' + interval '5 seconds'),
        ('b8ef5dd9-61c8-5373-a187-0109e5dc12cc'::uuid, 'seed-eta-010', 'credit', 1470, 'Seed transaction #10 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '66 minutes', now(), now()),
        ('f016e40c-2396-52bb-99b5-f8827349598e'::uuid, 'seed-eta-011', 'credit', 2544, 'Seed transaction #11 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '65 minutes', now() - interval '65 minutes' + interval '2 seconds', now() - interval '65 minutes' + interval '5 seconds'),
        ('35c432d5-6c6c-5888-8f39-6568750d8a78'::uuid, 'seed-eta-012', 'debit', 1445, 'Seed transaction #12 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '64 minutes', now() - interval '64 minutes' + interval '2 seconds', now() - interval '64 minutes' + interval '5 seconds'),
        ('72dbfae7-d613-551f-8169-b8a94c3db33b'::uuid, 'seed-eta-013', 'credit', 2806, 'Seed transaction #13 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '63 minutes', now() - interval '63 minutes' + interval '2 seconds', now() - interval '63 minutes' + interval '5 seconds'),
        ('adbcb17b-1a5a-5958-bf77-40023c5a58e3'::uuid, 'seed-eta-014', 'credit', 2937, 'Seed transaction #14 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '62 minutes', now() - interval '62 minutes' + interval '2 seconds', now() - interval '62 minutes' + interval '5 seconds'),
        ('061264e2-089f-55d5-8cbe-b5c5abd3b8c8'::uuid, 'seed-eta-015', 'debit', 11634, 'Seed transaction #15 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":15,"scenario":"insufficient_balance_debit","available_before":10879}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 11634 exceeds available balance of 10879', now() - interval '61 minutes', now() - interval '61 minutes' + interval '2 seconds', now() - interval '61 minutes' + interval '5 seconds'),
        ('6e943c64-aec9-5798-8a43-6a16f28565bc'::uuid, 'seed-eta-016', 'credit', 3199, 'Seed transaction #16 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '60 minutes', now() - interval '60 minutes' + interval '2 seconds', now() - interval '60 minutes' + interval '5 seconds'),
        ('0b401af1-41c0-5acc-9ea5-bc6004350125'::uuid, 'seed-eta-017', 'credit', 3330, 'Seed transaction #17 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '59 minutes', now() - interval '59 minutes' + interval '2 seconds', now() - interval '59 minutes' + interval '5 seconds'),
        ('4ea4c286-b275-593f-8686-e66c0fedf035'::uuid, 'seed-eta-018', 'debit', 479, 'Seed transaction #18 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '58 minutes', now() - interval '58 minutes' + interval '2 seconds', now() - interval '58 minutes' + interval '5 seconds'),
        ('f3f39aec-c603-59f1-9104-eb98c4ccb519'::uuid, 'seed-eta-019', 'credit', 3592, 'Seed transaction #19 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '57 minutes', now() - interval '57 minutes' + interval '2 seconds', now() - interval '57 minutes' + interval '5 seconds'),
        ('324b1551-16ff-573d-872b-486ad8ef1232'::uuid, 'seed-eta-020', 'credit', 3723, 'Seed transaction #20 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '56 minutes', now() - interval '56 minutes' + interval '2 seconds', now() - interval '56 minutes' + interval '5 seconds'),
        ('e873af10-4b90-532c-a596-caf234c07dbd'::uuid, 'seed-eta-021', 'debit', 746, 'Seed transaction #21 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":21,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '55 minutes', now() - interval '55 minutes' + interval '2 seconds', now() - interval '55 minutes' + interval '5 seconds'),
        ('460d58c4-f113-51ac-a0ae-d6da7050cbd4'::uuid, 'seed-eta-022', 'credit', 3985, 'Seed transaction #22 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":22,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '54 minutes', now() - interval '54 minutes' + interval '2 seconds', now() - interval '54 minutes' + interval '5 seconds'),
        ('0be71122-8a60-53f7-8a3f-c89e183b1888'::uuid, 'seed-eta-023', 'credit', 4116, 'Seed transaction #23 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":23,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '53 minutes', now() - interval '53 minutes' + interval '2 seconds', now() - interval '53 minutes' + interval '5 seconds'),
        ('2a6d4745-cc87-5405-924e-fc85023b97e8'::uuid, 'seed-eta-024', 'debit', 1013, 'Seed transaction #24 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":24,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '52 minutes', now() - interval '52 minutes' + interval '2 seconds', now() - interval '52 minutes' + interval '5 seconds'),
        ('7150d32c-e531-5fae-b0b1-91344ec60465'::uuid, 'seed-eta-025', 'debit', 525, 'Seed transaction #25 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":25,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '51 minutes', now(), now()),
        ('56016780-d363-5c00-84ac-c95360fe984d'::uuid, 'seed-eta-026', 'credit', 1009, 'Seed transaction #26 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":26,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '50 minutes', now() - interval '50 minutes' + interval '2 seconds', now() - interval '50 minutes' + interval '5 seconds'),
        ('49d7165b-16c3-5b7c-a6b1-362f91f620a0'::uuid, 'seed-eta-027', 'debit', 1280, 'Seed transaction #27 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":27,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '49 minutes', now() - interval '49 minutes' + interval '2 seconds', now() - interval '49 minutes' + interval '5 seconds'),
        ('874a0f26-9a62-5843-bf70-66a822d5eca5'::uuid, 'seed-eta-028', 'credit', 1271, 'Seed transaction #28 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":28,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '48 minutes', now() - interval '48 minutes' + interval '2 seconds', now() - interval '48 minutes' + interval '5 seconds'),
        ('a983034d-8b7d-52c1-a061-688b8f37741c'::uuid, 'seed-eta-029', 'credit', 1402, 'Seed transaction #29 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":29,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '47 minutes', now() - interval '47 minutes' + interval '2 seconds', now() - interval '47 minutes' + interval '5 seconds'),
        ('83761891-145a-588d-a6ad-8cac29a21ad4'::uuid, 'seed-eta-030', 'debit', 33998, 'Seed transaction #30 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":30,"scenario":"insufficient_balance_debit","available_before":32988}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 33998 exceeds available balance of 32988', now() - interval '46 minutes', now() - interval '46 minutes' + interval '2 seconds', now() - interval '46 minutes' + interval '5 seconds'),
        ('45f51ae8-8892-5c2b-9930-f602b4922c9f'::uuid, 'seed-eta-031', 'credit', 1664, 'Seed transaction #31 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":31,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '45 minutes', now() - interval '45 minutes' + interval '2 seconds', now() - interval '45 minutes' + interval '5 seconds'),
        ('74e3be39-c6eb-524a-be26-2e80a13857a3'::uuid, 'seed-eta-032', 'credit', 1795, 'Seed transaction #32 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":32,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '44 minutes', now() - interval '44 minutes' + interval '2 seconds', now() - interval '44 minutes' + interval '5 seconds'),
        ('208515fc-6888-5dd1-9da5-d62ff1d0a598'::uuid, 'seed-eta-033', 'debit', 314, 'Seed transaction #33 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":33,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '43 minutes', now() - interval '43 minutes' + interval '2 seconds', now() - interval '43 minutes' + interval '5 seconds'),
        ('82c150d1-0680-5ed5-8377-1dc396ae576c'::uuid, 'seed-eta-034', 'credit', 2057, 'Seed transaction #34 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":34,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '42 minutes', now() - interval '42 minutes' + interval '2 seconds', now() - interval '42 minutes' + interval '5 seconds'),
        ('e772aa3a-8032-5d38-b4bf-70653c0afc9d'::uuid, 'seed-eta-035', 'credit', 2188, 'Seed transaction #35 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":35,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '41 minutes', now() - interval '41 minutes' + interval '2 seconds', now() - interval '41 minutes' + interval '5 seconds'),
        ('cd9f4e4f-fcb4-5675-8592-f9670a035909'::uuid, 'seed-eta-036', 'debit', 581, 'Seed transaction #36 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":36,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '40 minutes', now() - interval '40 minutes' + interval '2 seconds', now() - interval '40 minutes' + interval '5 seconds'),
        ('c7d7e546-1f21-5a3d-99c0-e3ae08813b2e'::uuid, 'seed-eta-037', 'credit', 2450, 'Seed transaction #37 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":37,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '39 minutes', now() - interval '39 minutes' + interval '2 seconds', now() - interval '39 minutes' + interval '5 seconds'),
        ('6d1802a1-4954-5d9b-9ad5-c7c86856aac0'::uuid, 'seed-eta-038', 'credit', 2581, 'Seed transaction #38 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":38,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '38 minutes', now() - interval '38 minutes' + interval '2 seconds', now() - interval '38 minutes' + interval '5 seconds'),
        ('575dd293-41d9-53c4-a853-b96b43e72057'::uuid, 'seed-eta-039', 'debit', 848, 'Seed transaction #39 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":39,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '37 minutes', now() - interval '37 minutes' + interval '2 seconds', now() - interval '37 minutes' + interval '5 seconds'),
        ('22ce94bb-4148-5219-9b02-f497a045c95c'::uuid, 'seed-eta-040', 'credit', 2843, 'Seed transaction #40 for tenant eta', '{"seed":true,"tenant_code":"eta","sequence":40,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '36 minutes', now() - interval '36 minutes' + interval '2 seconds', now() - interval '36 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000107.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('cd8e7c67-dbb7-556f-955b-62057bd4b0fc'::uuid, 'seed-eta-001', 1234, 0, 1234, now() - interval '75 minutes' + interval '5 seconds'),
        ('094509de-127f-51e9-bbe5-3ff42a0e2c4c'::uuid, 'seed-eta-003', -644, 1234, 590, now() - interval '73 minutes' + interval '5 seconds'),
        ('1a231f55-879c-56ce-98f0-029cec4c178b'::uuid, 'seed-eta-004', 1627, 590, 2217, now() - interval '72 minutes' + interval '5 seconds'),
        ('bac4e2fc-2d05-5ff9-ad2f-49cabf6093fe'::uuid, 'seed-eta-005', 1758, 2217, 3975, now() - interval '71 minutes' + interval '5 seconds'),
        ('e10b8983-deef-51c2-ae01-e2c33b9cd4c0'::uuid, 'seed-eta-006', -911, 3975, 3064, now() - interval '70 minutes' + interval '5 seconds'),
        ('dccd454a-90dc-57fb-bdd3-411d71ae090f'::uuid, 'seed-eta-008', 2151, 3064, 5215, now() - interval '68 minutes' + interval '5 seconds'),
        ('a6543bff-e403-5421-a83d-2f14e2e296d3'::uuid, 'seed-eta-009', -1178, 5215, 4037, now() - interval '67 minutes' + interval '5 seconds'),
        ('f016e40c-2396-52bb-99b5-f8827349598e'::uuid, 'seed-eta-011', 2544, 4037, 6581, now() - interval '65 minutes' + interval '5 seconds'),
        ('35c432d5-6c6c-5888-8f39-6568750d8a78'::uuid, 'seed-eta-012', -1445, 6581, 5136, now() - interval '64 minutes' + interval '5 seconds'),
        ('72dbfae7-d613-551f-8169-b8a94c3db33b'::uuid, 'seed-eta-013', 2806, 5136, 7942, now() - interval '63 minutes' + interval '5 seconds'),
        ('adbcb17b-1a5a-5958-bf77-40023c5a58e3'::uuid, 'seed-eta-014', 2937, 7942, 10879, now() - interval '62 minutes' + interval '5 seconds'),
        ('6e943c64-aec9-5798-8a43-6a16f28565bc'::uuid, 'seed-eta-016', 3199, 10879, 14078, now() - interval '60 minutes' + interval '5 seconds'),
        ('0b401af1-41c0-5acc-9ea5-bc6004350125'::uuid, 'seed-eta-017', 3330, 14078, 17408, now() - interval '59 minutes' + interval '5 seconds'),
        ('4ea4c286-b275-593f-8686-e66c0fedf035'::uuid, 'seed-eta-018', -479, 17408, 16929, now() - interval '58 minutes' + interval '5 seconds'),
        ('f3f39aec-c603-59f1-9104-eb98c4ccb519'::uuid, 'seed-eta-019', 3592, 16929, 20521, now() - interval '57 minutes' + interval '5 seconds'),
        ('324b1551-16ff-573d-872b-486ad8ef1232'::uuid, 'seed-eta-020', 3723, 20521, 24244, now() - interval '56 minutes' + interval '5 seconds'),
        ('e873af10-4b90-532c-a596-caf234c07dbd'::uuid, 'seed-eta-021', -746, 24244, 23498, now() - interval '55 minutes' + interval '5 seconds'),
        ('460d58c4-f113-51ac-a0ae-d6da7050cbd4'::uuid, 'seed-eta-022', 3985, 23498, 27483, now() - interval '54 minutes' + interval '5 seconds'),
        ('0be71122-8a60-53f7-8a3f-c89e183b1888'::uuid, 'seed-eta-023', 4116, 27483, 31599, now() - interval '53 minutes' + interval '5 seconds'),
        ('2a6d4745-cc87-5405-924e-fc85023b97e8'::uuid, 'seed-eta-024', -1013, 31599, 30586, now() - interval '52 minutes' + interval '5 seconds'),
        ('56016780-d363-5c00-84ac-c95360fe984d'::uuid, 'seed-eta-026', 1009, 30586, 31595, now() - interval '50 minutes' + interval '5 seconds'),
        ('49d7165b-16c3-5b7c-a6b1-362f91f620a0'::uuid, 'seed-eta-027', -1280, 31595, 30315, now() - interval '49 minutes' + interval '5 seconds'),
        ('874a0f26-9a62-5843-bf70-66a822d5eca5'::uuid, 'seed-eta-028', 1271, 30315, 31586, now() - interval '48 minutes' + interval '5 seconds'),
        ('a983034d-8b7d-52c1-a061-688b8f37741c'::uuid, 'seed-eta-029', 1402, 31586, 32988, now() - interval '47 minutes' + interval '5 seconds'),
        ('45f51ae8-8892-5c2b-9930-f602b4922c9f'::uuid, 'seed-eta-031', 1664, 32988, 34652, now() - interval '45 minutes' + interval '5 seconds'),
        ('74e3be39-c6eb-524a-be26-2e80a13857a3'::uuid, 'seed-eta-032', 1795, 34652, 36447, now() - interval '44 minutes' + interval '5 seconds'),
        ('208515fc-6888-5dd1-9da5-d62ff1d0a598'::uuid, 'seed-eta-033', -314, 36447, 36133, now() - interval '43 minutes' + interval '5 seconds'),
        ('82c150d1-0680-5ed5-8377-1dc396ae576c'::uuid, 'seed-eta-034', 2057, 36133, 38190, now() - interval '42 minutes' + interval '5 seconds'),
        ('e772aa3a-8032-5d38-b4bf-70653c0afc9d'::uuid, 'seed-eta-035', 2188, 38190, 40378, now() - interval '41 minutes' + interval '5 seconds'),
        ('cd9f4e4f-fcb4-5675-8592-f9670a035909'::uuid, 'seed-eta-036', -581, 40378, 39797, now() - interval '40 minutes' + interval '5 seconds'),
        ('c7d7e546-1f21-5a3d-99c0-e3ae08813b2e'::uuid, 'seed-eta-037', 2450, 39797, 42247, now() - interval '39 minutes' + interval '5 seconds'),
        ('6d1802a1-4954-5d9b-9ad5-c7c86856aac0'::uuid, 'seed-eta-038', 2581, 42247, 44828, now() - interval '38 minutes' + interval '5 seconds'),
        ('575dd293-41d9-53c4-a853-b96b43e72057'::uuid, 'seed-eta-039', -848, 44828, 43980, now() - interval '37 minutes' + interval '5 seconds'),
        ('22ce94bb-4148-5219-9b02-f497a045c95c'::uuid, 'seed-eta-040', 2843, 43980, 46823, now() - interval '36 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000107.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('b8ef5dd9-61c8-5373-a187-0109e5dc12cc'::uuid, 'seed-eta-010', 1470, 46823, 48293, now()),
        ('7150d32c-e531-5fae-b0b1-91344ec60465'::uuid, 'seed-eta-025', -525, 48293, 47768, now() + interval '1 second');

UPDATE tenant_00000000000000000000000000000107.balances SET balance = 47768, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000108.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('e58cb257-caca-59d4-bfec-ec4ebc1acc84'::uuid, 'seed-theta-001', 'credit', 1263, 'Seed transaction #1 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '104 minutes', now() - interval '104 minutes' + interval '2 seconds', now() - interval '104 minutes' + interval '5 seconds'),
        ('088f1878-a170-5f86-96d2-1e3d651ae4dc'::uuid, 'seed-theta-002', 'debit', 1797, 'Seed transaction #2 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":2,"scenario":"insufficient_balance_debit","available_before":1263}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1797 exceeds available balance of 1263', now() - interval '103 minutes', now() - interval '103 minutes' + interval '2 seconds', now() - interval '103 minutes' + interval '5 seconds'),
        ('cb0cdf1d-ee75-5f2c-9cf4-337e73bb44f4'::uuid, 'seed-theta-003', 'debit', 655, 'Seed transaction #3 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '102 minutes', now() - interval '102 minutes' + interval '2 seconds', now() - interval '102 minutes' + interval '5 seconds'),
        ('63628475-663a-54c6-8358-84b2c74c8ecc'::uuid, 'seed-theta-004', 'credit', 1656, 'Seed transaction #4 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '101 minutes', now() - interval '101 minutes' + interval '2 seconds', now() - interval '101 minutes' + interval '5 seconds'),
        ('f023137a-19ac-5185-96c4-7a9a11802f17'::uuid, 'seed-theta-005', 'credit', 1787, 'Seed transaction #5 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '100 minutes', now() - interval '100 minutes' + interval '2 seconds', now() - interval '100 minutes' + interval '5 seconds'),
        ('bee6e7b9-8e70-5125-ba49-0736198a6979'::uuid, 'seed-theta-006', 'debit', 922, 'Seed transaction #6 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '99 minutes', now() - interval '99 minutes' + interval '2 seconds', now() - interval '99 minutes' + interval '5 seconds'),
        ('cf5976f4-c298-5198-8939-2c9b4c6738dc'::uuid, 'seed-theta-007', 'debit', 3748, 'Seed transaction #7 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":7,"scenario":"insufficient_balance_debit","available_before":3129}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 3748 exceeds available balance of 3129', now() - interval '98 minutes', now() - interval '98 minutes' + interval '2 seconds', now() - interval '98 minutes' + interval '5 seconds'),
        ('69c99eb2-af13-5f88-a248-d55aae0c218b'::uuid, 'seed-theta-008', 'credit', 2180, 'Seed transaction #8 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '97 minutes', now() - interval '97 minutes' + interval '2 seconds', now() - interval '97 minutes' + interval '5 seconds'),
        ('89e28e82-39e3-508a-aced-e9f6f8e9aaae'::uuid, 'seed-theta-009', 'debit', 1189, 'Seed transaction #9 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '96 minutes', now() - interval '96 minutes' + interval '2 seconds', now() - interval '96 minutes' + interval '5 seconds'),
        ('2de8e03f-d424-5ebf-b7e5-e0dfd713c709'::uuid, 'seed-theta-010', 'credit', 1470, 'Seed transaction #10 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '95 minutes', now(), now()),
        ('f42a1b7d-1bcb-507e-93b4-f76cab452609'::uuid, 'seed-theta-011', 'credit', 2573, 'Seed transaction #11 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '94 minutes', now() - interval '94 minutes' + interval '2 seconds', now() - interval '94 minutes' + interval '5 seconds'),
        ('6d12c0a3-f855-5b55-ac70-2e34c93e9d84'::uuid, 'seed-theta-012', 'debit', 1456, 'Seed transaction #12 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '93 minutes', now() - interval '93 minutes' + interval '2 seconds', now() - interval '93 minutes' + interval '5 seconds'),
        ('ebf136ea-dbc2-51b8-8beb-c05e3e5701c6'::uuid, 'seed-theta-013', 'credit', 2835, 'Seed transaction #13 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '92 minutes', now() - interval '92 minutes' + interval '2 seconds', now() - interval '92 minutes' + interval '5 seconds'),
        ('95398efa-450f-58f7-a401-28a087fea5ab'::uuid, 'seed-theta-014', 'credit', 2966, 'Seed transaction #14 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '91 minutes', now() - interval '91 minutes' + interval '2 seconds', now() - interval '91 minutes' + interval '5 seconds'),
        ('c72798ff-e0e8-5d03-9a83-c9e62c34c800'::uuid, 'seed-theta-015', 'debit', 11793, 'Seed transaction #15 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":15,"scenario":"insufficient_balance_debit","available_before":11038}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 11793 exceeds available balance of 11038', now() - interval '90 minutes', now() - interval '90 minutes' + interval '2 seconds', now() - interval '90 minutes' + interval '5 seconds'),
        ('37a026c8-5e26-5a01-994f-1231024d4436'::uuid, 'seed-theta-016', 'credit', 3228, 'Seed transaction #16 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '89 minutes', now() - interval '89 minutes' + interval '2 seconds', now() - interval '89 minutes' + interval '5 seconds'),
        ('235d1ccf-8bef-58ab-a3a4-44581d52ee59'::uuid, 'seed-theta-017', 'credit', 3359, 'Seed transaction #17 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '88 minutes', now() - interval '88 minutes' + interval '2 seconds', now() - interval '88 minutes' + interval '5 seconds'),
        ('fd31b06f-4722-5fdf-9aa9-ff4178830719'::uuid, 'seed-theta-018', 'debit', 490, 'Seed transaction #18 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '87 minutes', now() - interval '87 minutes' + interval '2 seconds', now() - interval '87 minutes' + interval '5 seconds'),
        ('69600f8b-644e-5b95-9dba-c50dd40ee943'::uuid, 'seed-theta-019', 'credit', 3621, 'Seed transaction #19 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '86 minutes', now() - interval '86 minutes' + interval '2 seconds', now() - interval '86 minutes' + interval '5 seconds'),
        ('38489111-3ed5-526b-ac6c-31fb14fa74e8'::uuid, 'seed-theta-020', 'credit', 3752, 'Seed transaction #20 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '85 minutes', now() - interval '85 minutes' + interval '2 seconds', now() - interval '85 minutes' + interval '5 seconds'),
        ('57405aa3-4929-57d2-9e3d-caf96bc03e8a'::uuid, 'seed-theta-021', 'debit', 757, 'Seed transaction #21 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":21,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '84 minutes', now() - interval '84 minutes' + interval '2 seconds', now() - interval '84 minutes' + interval '5 seconds'),
        ('f8d52adf-479f-5ce3-9322-dc7a021d4456'::uuid, 'seed-theta-022', 'credit', 4014, 'Seed transaction #22 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":22,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '83 minutes', now() - interval '83 minutes' + interval '2 seconds', now() - interval '83 minutes' + interval '5 seconds'),
        ('ac517aa1-33f1-50e9-983a-b78ed08d2837'::uuid, 'seed-theta-023', 'credit', 4145, 'Seed transaction #23 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":23,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '82 minutes', now() - interval '82 minutes' + interval '2 seconds', now() - interval '82 minutes' + interval '5 seconds'),
        ('96c5c528-eacc-5228-a8f2-51710049ccd1'::uuid, 'seed-theta-024', 'debit', 1024, 'Seed transaction #24 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":24,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '81 minutes', now() - interval '81 minutes' + interval '2 seconds', now() - interval '81 minutes' + interval '5 seconds'),
        ('e26cd3ef-3f49-586f-a0fb-2debac4b51e8'::uuid, 'seed-theta-025', 'debit', 525, 'Seed transaction #25 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":25,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '80 minutes', now(), now()),
        ('61445c5a-445d-5582-a9d4-4fc5a2d7aa29'::uuid, 'seed-theta-026', 'credit', 1038, 'Seed transaction #26 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":26,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '79 minutes', now() - interval '79 minutes' + interval '2 seconds', now() - interval '79 minutes' + interval '5 seconds'),
        ('f96d04a6-81d0-541c-9023-180aa56d2cc5'::uuid, 'seed-theta-027', 'debit', 1291, 'Seed transaction #27 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":27,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '78 minutes', now() - interval '78 minutes' + interval '2 seconds', now() - interval '78 minutes' + interval '5 seconds'),
        ('ad3fbda3-4530-5433-a94e-11e832ba6473'::uuid, 'seed-theta-028', 'credit', 1300, 'Seed transaction #28 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":28,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '77 minutes', now() - interval '77 minutes' + interval '2 seconds', now() - interval '77 minutes' + interval '5 seconds'),
        ('47f119a3-9152-56c9-a858-2acd4734c3f2'::uuid, 'seed-theta-029', 'credit', 1431, 'Seed transaction #29 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":29,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '76 minutes', now() - interval '76 minutes' + interval '2 seconds', now() - interval '76 minutes' + interval '5 seconds'),
        ('25677b9f-1706-54a6-b74d-9e36d18f9b14'::uuid, 'seed-theta-030', 'debit', 34374, 'Seed transaction #30 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":30,"scenario":"insufficient_balance_debit","available_before":33364}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 34374 exceeds available balance of 33364', now() - interval '75 minutes', now() - interval '75 minutes' + interval '2 seconds', now() - interval '75 minutes' + interval '5 seconds'),
        ('a4c50f47-c7a8-5c2f-b0f2-c9a8072b4c22'::uuid, 'seed-theta-031', 'credit', 1693, 'Seed transaction #31 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":31,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '74 minutes', now() - interval '74 minutes' + interval '2 seconds', now() - interval '74 minutes' + interval '5 seconds'),
        ('50b06003-a7de-5481-8953-f38a7de0b76b'::uuid, 'seed-theta-032', 'credit', 1824, 'Seed transaction #32 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":32,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '73 minutes', now() - interval '73 minutes' + interval '2 seconds', now() - interval '73 minutes' + interval '5 seconds'),
        ('f1ca4a9f-6ab5-5252-bb6a-832f9edaa956'::uuid, 'seed-theta-033', 'debit', 325, 'Seed transaction #33 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":33,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '72 minutes', now() - interval '72 minutes' + interval '2 seconds', now() - interval '72 minutes' + interval '5 seconds'),
        ('2a284637-7c14-5326-9478-d022ef27da0c'::uuid, 'seed-theta-034', 'credit', 2086, 'Seed transaction #34 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":34,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '71 minutes', now() - interval '71 minutes' + interval '2 seconds', now() - interval '71 minutes' + interval '5 seconds'),
        ('3ebf0c69-9aeb-5ae2-b80f-e5724a1b6fe6'::uuid, 'seed-theta-035', 'credit', 2217, 'Seed transaction #35 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":35,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '70 minutes', now() - interval '70 minutes' + interval '2 seconds', now() - interval '70 minutes' + interval '5 seconds'),
        ('9967b4f2-d586-5cc3-9768-8d1d9a806f69'::uuid, 'seed-theta-036', 'debit', 592, 'Seed transaction #36 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":36,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '69 minutes', now() - interval '69 minutes' + interval '2 seconds', now() - interval '69 minutes' + interval '5 seconds'),
        ('3c8b7810-e33e-5caf-971d-b9514e266784'::uuid, 'seed-theta-037', 'credit', 2479, 'Seed transaction #37 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":37,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '68 minutes', now() - interval '68 minutes' + interval '2 seconds', now() - interval '68 minutes' + interval '5 seconds'),
        ('5861bd38-2a64-53dc-89db-ca165b04cfb9'::uuid, 'seed-theta-038', 'credit', 2610, 'Seed transaction #38 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":38,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '67 minutes', now() - interval '67 minutes' + interval '2 seconds', now() - interval '67 minutes' + interval '5 seconds'),
        ('75d79d21-716d-5ae9-803d-775b0e87e6bb'::uuid, 'seed-theta-039', 'debit', 859, 'Seed transaction #39 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":39,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '66 minutes', now() - interval '66 minutes' + interval '2 seconds', now() - interval '66 minutes' + interval '5 seconds'),
        ('a96073f3-1c38-51cf-8bea-dda6aae34bde'::uuid, 'seed-theta-040', 'credit', 2872, 'Seed transaction #40 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":40,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '65 minutes', now() - interval '65 minutes' + interval '2 seconds', now() - interval '65 minutes' + interval '5 seconds'),
        ('087b21b4-c75f-5d05-9338-f3f2d3ceb820'::uuid, 'seed-theta-041', 'credit', 3003, 'Seed transaction #41 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":41,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '64 minutes', now() - interval '64 minutes' + interval '2 seconds', now() - interval '64 minutes' + interval '5 seconds'),
        ('fb253853-3edd-5acf-8240-664a63f21892'::uuid, 'seed-theta-042', 'debit', 1126, 'Seed transaction #42 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":42,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '63 minutes', now() - interval '63 minutes' + interval '2 seconds', now() - interval '63 minutes' + interval '5 seconds'),
        ('ac97ca97-0f98-5782-9e5a-6a98012d59a4'::uuid, 'seed-theta-043', 'credit', 3265, 'Seed transaction #43 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":43,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '62 minutes', now() - interval '62 minutes' + interval '2 seconds', now() - interval '62 minutes' + interval '5 seconds'),
        ('7fdc422f-8239-5a95-bcaa-2d94ba5f0e77'::uuid, 'seed-theta-044', 'credit', 3396, 'Seed transaction #44 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":44,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '61 minutes', now() - interval '61 minutes' + interval '2 seconds', now() - interval '61 minutes' + interval '5 seconds'),
        ('c5626072-97e5-516c-8da7-7723000310c0'::uuid, 'seed-theta-045', 'debit', 1393, 'Seed transaction #45 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":45,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '60 minutes', now() - interval '60 minutes' + interval '2 seconds', now() - interval '60 minutes' + interval '5 seconds'),
        ('c3851495-6d28-548e-8ef4-4089a428203b'::uuid, 'seed-theta-046', 'credit', 3658, 'Seed transaction #46 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":46,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '59 minutes', now() - interval '59 minutes' + interval '2 seconds', now() - interval '59 minutes' + interval '5 seconds'),
        ('1d836a6c-09db-5ac6-bcf2-3bcdea8aefb8'::uuid, 'seed-theta-047', 'credit', 3789, 'Seed transaction #47 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":47,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '58 minutes', now() - interval '58 minutes' + interval '2 seconds', now() - interval '58 minutes' + interval '5 seconds'),
        ('88021f62-ddb7-58ed-94e8-19877054287b'::uuid, 'seed-theta-048', 'debit', 1660, 'Seed transaction #48 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":48,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '57 minutes', now() - interval '57 minutes' + interval '2 seconds', now() - interval '57 minutes' + interval '5 seconds'),
        ('c806bd98-f770-5ed4-b994-89dfa4642e91'::uuid, 'seed-theta-049', 'credit', 4051, 'Seed transaction #49 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":49,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '56 minutes', now() - interval '56 minutes' + interval '2 seconds', now() - interval '56 minutes' + interval '5 seconds'),
        ('786d42c5-0d09-5c77-a714-33a89973c4bb'::uuid, 'seed-theta-050', 'credit', 550, 'Seed transaction #50 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":50,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '55 minutes', now(), now()),
        ('ae424b20-4440-51fa-892a-402b85bceb00'::uuid, 'seed-theta-051', 'debit', 427, 'Seed transaction #51 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":51,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '54 minutes', now() - interval '54 minutes' + interval '2 seconds', now() - interval '54 minutes' + interval '5 seconds'),
        ('0b1c7ac3-fa5b-5e2e-adab-5da32f5e27c2'::uuid, 'seed-theta-052', 'credit', 944, 'Seed transaction #52 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":52,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '53 minutes', now() - interval '53 minutes' + interval '2 seconds', now() - interval '53 minutes' + interval '5 seconds'),
        ('49057d79-bc59-50a9-8804-a3c9e8b9f790'::uuid, 'seed-theta-053', 'credit', 1075, 'Seed transaction #53 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":53,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '52 minutes', now() - interval '52 minutes' + interval '2 seconds', now() - interval '52 minutes' + interval '5 seconds'),
        ('dba28fad-0b9c-55e9-b43a-ca4ef974f559'::uuid, 'seed-theta-054', 'debit', 694, 'Seed transaction #54 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":54,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '51 minutes', now() - interval '51 minutes' + interval '2 seconds', now() - interval '51 minutes' + interval '5 seconds'),
        ('c3611825-dd22-558a-afc0-c6de1129033a'::uuid, 'seed-theta-055', 'credit', 1337, 'Seed transaction #55 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":55,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '50 minutes', now() - interval '50 minutes' + interval '2 seconds', now() - interval '50 minutes' + interval '5 seconds'),
        ('bfd02af0-a295-5529-8c1f-a33b935b01a4'::uuid, 'seed-theta-056', 'credit', 1468, 'Seed transaction #56 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":56,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '49 minutes', now() - interval '49 minutes' + interval '2 seconds', now() - interval '49 minutes' + interval '5 seconds'),
        ('177025c4-b2aa-57fc-9323-aa91f9fae8a4'::uuid, 'seed-theta-057', 'debit', 961, 'Seed transaction #57 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":57,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '48 minutes', now() - interval '48 minutes' + interval '2 seconds', now() - interval '48 minutes' + interval '5 seconds'),
        ('77877dbf-3a60-5fd9-b1c8-a0b2ef1105a5'::uuid, 'seed-theta-058', 'credit', 1730, 'Seed transaction #58 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":58,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '47 minutes', now() - interval '47 minutes' + interval '2 seconds', now() - interval '47 minutes' + interval '5 seconds'),
        ('1a5bac85-9854-5991-bc8d-a2238fb6f861'::uuid, 'seed-theta-059', 'credit', 1861, 'Seed transaction #59 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":59,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '46 minutes', now() - interval '46 minutes' + interval '2 seconds', now() - interval '46 minutes' + interval '5 seconds'),
        ('b7a1c7b9-29e3-5991-a7c0-93b272a3eed0'::uuid, 'seed-theta-060', 'debit', 72205, 'Seed transaction #60 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":60,"scenario":"insufficient_balance_debit","available_before":70685}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 72205 exceeds available balance of 70685', now() - interval '45 minutes', now() - interval '45 minutes' + interval '2 seconds', now() - interval '45 minutes' + interval '5 seconds'),
        ('98161aa2-f150-533c-bd89-c7efe3e331a9'::uuid, 'seed-theta-061', 'credit', 2123, 'Seed transaction #61 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":61,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '44 minutes', now() - interval '44 minutes' + interval '2 seconds', now() - interval '44 minutes' + interval '5 seconds'),
        ('ab775d3d-5a71-56ab-a652-94f0f0bd42e8'::uuid, 'seed-theta-062', 'credit', 2254, 'Seed transaction #62 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":62,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '43 minutes', now() - interval '43 minutes' + interval '2 seconds', now() - interval '43 minutes' + interval '5 seconds'),
        ('7dace4ee-330a-53e1-a64c-254508e396c1'::uuid, 'seed-theta-063', 'debit', 1495, 'Seed transaction #63 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":63,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '42 minutes', now() - interval '42 minutes' + interval '2 seconds', now() - interval '42 minutes' + interval '5 seconds'),
        ('c3cf6765-71da-583e-b6f2-24e0bd53e65b'::uuid, 'seed-theta-064', 'credit', 2516, 'Seed transaction #64 for tenant theta', '{"seed":true,"tenant_code":"theta","sequence":64,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '41 minutes', now() - interval '41 minutes' + interval '2 seconds', now() - interval '41 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000108.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('e58cb257-caca-59d4-bfec-ec4ebc1acc84'::uuid, 'seed-theta-001', 1263, 0, 1263, now() - interval '104 minutes' + interval '5 seconds'),
        ('cb0cdf1d-ee75-5f2c-9cf4-337e73bb44f4'::uuid, 'seed-theta-003', -655, 1263, 608, now() - interval '102 minutes' + interval '5 seconds'),
        ('63628475-663a-54c6-8358-84b2c74c8ecc'::uuid, 'seed-theta-004', 1656, 608, 2264, now() - interval '101 minutes' + interval '5 seconds'),
        ('f023137a-19ac-5185-96c4-7a9a11802f17'::uuid, 'seed-theta-005', 1787, 2264, 4051, now() - interval '100 minutes' + interval '5 seconds'),
        ('bee6e7b9-8e70-5125-ba49-0736198a6979'::uuid, 'seed-theta-006', -922, 4051, 3129, now() - interval '99 minutes' + interval '5 seconds'),
        ('69c99eb2-af13-5f88-a248-d55aae0c218b'::uuid, 'seed-theta-008', 2180, 3129, 5309, now() - interval '97 minutes' + interval '5 seconds'),
        ('89e28e82-39e3-508a-aced-e9f6f8e9aaae'::uuid, 'seed-theta-009', -1189, 5309, 4120, now() - interval '96 minutes' + interval '5 seconds'),
        ('f42a1b7d-1bcb-507e-93b4-f76cab452609'::uuid, 'seed-theta-011', 2573, 4120, 6693, now() - interval '94 minutes' + interval '5 seconds'),
        ('6d12c0a3-f855-5b55-ac70-2e34c93e9d84'::uuid, 'seed-theta-012', -1456, 6693, 5237, now() - interval '93 minutes' + interval '5 seconds'),
        ('ebf136ea-dbc2-51b8-8beb-c05e3e5701c6'::uuid, 'seed-theta-013', 2835, 5237, 8072, now() - interval '92 minutes' + interval '5 seconds'),
        ('95398efa-450f-58f7-a401-28a087fea5ab'::uuid, 'seed-theta-014', 2966, 8072, 11038, now() - interval '91 minutes' + interval '5 seconds'),
        ('37a026c8-5e26-5a01-994f-1231024d4436'::uuid, 'seed-theta-016', 3228, 11038, 14266, now() - interval '89 minutes' + interval '5 seconds'),
        ('235d1ccf-8bef-58ab-a3a4-44581d52ee59'::uuid, 'seed-theta-017', 3359, 14266, 17625, now() - interval '88 minutes' + interval '5 seconds'),
        ('fd31b06f-4722-5fdf-9aa9-ff4178830719'::uuid, 'seed-theta-018', -490, 17625, 17135, now() - interval '87 minutes' + interval '5 seconds'),
        ('69600f8b-644e-5b95-9dba-c50dd40ee943'::uuid, 'seed-theta-019', 3621, 17135, 20756, now() - interval '86 minutes' + interval '5 seconds'),
        ('38489111-3ed5-526b-ac6c-31fb14fa74e8'::uuid, 'seed-theta-020', 3752, 20756, 24508, now() - interval '85 minutes' + interval '5 seconds'),
        ('57405aa3-4929-57d2-9e3d-caf96bc03e8a'::uuid, 'seed-theta-021', -757, 24508, 23751, now() - interval '84 minutes' + interval '5 seconds'),
        ('f8d52adf-479f-5ce3-9322-dc7a021d4456'::uuid, 'seed-theta-022', 4014, 23751, 27765, now() - interval '83 minutes' + interval '5 seconds'),
        ('ac517aa1-33f1-50e9-983a-b78ed08d2837'::uuid, 'seed-theta-023', 4145, 27765, 31910, now() - interval '82 minutes' + interval '5 seconds'),
        ('96c5c528-eacc-5228-a8f2-51710049ccd1'::uuid, 'seed-theta-024', -1024, 31910, 30886, now() - interval '81 minutes' + interval '5 seconds'),
        ('61445c5a-445d-5582-a9d4-4fc5a2d7aa29'::uuid, 'seed-theta-026', 1038, 30886, 31924, now() - interval '79 minutes' + interval '5 seconds'),
        ('f96d04a6-81d0-541c-9023-180aa56d2cc5'::uuid, 'seed-theta-027', -1291, 31924, 30633, now() - interval '78 minutes' + interval '5 seconds'),
        ('ad3fbda3-4530-5433-a94e-11e832ba6473'::uuid, 'seed-theta-028', 1300, 30633, 31933, now() - interval '77 minutes' + interval '5 seconds'),
        ('47f119a3-9152-56c9-a858-2acd4734c3f2'::uuid, 'seed-theta-029', 1431, 31933, 33364, now() - interval '76 minutes' + interval '5 seconds'),
        ('a4c50f47-c7a8-5c2f-b0f2-c9a8072b4c22'::uuid, 'seed-theta-031', 1693, 33364, 35057, now() - interval '74 minutes' + interval '5 seconds'),
        ('50b06003-a7de-5481-8953-f38a7de0b76b'::uuid, 'seed-theta-032', 1824, 35057, 36881, now() - interval '73 minutes' + interval '5 seconds'),
        ('f1ca4a9f-6ab5-5252-bb6a-832f9edaa956'::uuid, 'seed-theta-033', -325, 36881, 36556, now() - interval '72 minutes' + interval '5 seconds'),
        ('2a284637-7c14-5326-9478-d022ef27da0c'::uuid, 'seed-theta-034', 2086, 36556, 38642, now() - interval '71 minutes' + interval '5 seconds'),
        ('3ebf0c69-9aeb-5ae2-b80f-e5724a1b6fe6'::uuid, 'seed-theta-035', 2217, 38642, 40859, now() - interval '70 minutes' + interval '5 seconds'),
        ('9967b4f2-d586-5cc3-9768-8d1d9a806f69'::uuid, 'seed-theta-036', -592, 40859, 40267, now() - interval '69 minutes' + interval '5 seconds'),
        ('3c8b7810-e33e-5caf-971d-b9514e266784'::uuid, 'seed-theta-037', 2479, 40267, 42746, now() - interval '68 minutes' + interval '5 seconds'),
        ('5861bd38-2a64-53dc-89db-ca165b04cfb9'::uuid, 'seed-theta-038', 2610, 42746, 45356, now() - interval '67 minutes' + interval '5 seconds'),
        ('75d79d21-716d-5ae9-803d-775b0e87e6bb'::uuid, 'seed-theta-039', -859, 45356, 44497, now() - interval '66 minutes' + interval '5 seconds'),
        ('a96073f3-1c38-51cf-8bea-dda6aae34bde'::uuid, 'seed-theta-040', 2872, 44497, 47369, now() - interval '65 minutes' + interval '5 seconds'),
        ('087b21b4-c75f-5d05-9338-f3f2d3ceb820'::uuid, 'seed-theta-041', 3003, 47369, 50372, now() - interval '64 minutes' + interval '5 seconds'),
        ('fb253853-3edd-5acf-8240-664a63f21892'::uuid, 'seed-theta-042', -1126, 50372, 49246, now() - interval '63 minutes' + interval '5 seconds'),
        ('ac97ca97-0f98-5782-9e5a-6a98012d59a4'::uuid, 'seed-theta-043', 3265, 49246, 52511, now() - interval '62 minutes' + interval '5 seconds'),
        ('7fdc422f-8239-5a95-bcaa-2d94ba5f0e77'::uuid, 'seed-theta-044', 3396, 52511, 55907, now() - interval '61 minutes' + interval '5 seconds'),
        ('c5626072-97e5-516c-8da7-7723000310c0'::uuid, 'seed-theta-045', -1393, 55907, 54514, now() - interval '60 minutes' + interval '5 seconds'),
        ('c3851495-6d28-548e-8ef4-4089a428203b'::uuid, 'seed-theta-046', 3658, 54514, 58172, now() - interval '59 minutes' + interval '5 seconds'),
        ('1d836a6c-09db-5ac6-bcf2-3bcdea8aefb8'::uuid, 'seed-theta-047', 3789, 58172, 61961, now() - interval '58 minutes' + interval '5 seconds'),
        ('88021f62-ddb7-58ed-94e8-19877054287b'::uuid, 'seed-theta-048', -1660, 61961, 60301, now() - interval '57 minutes' + interval '5 seconds'),
        ('c806bd98-f770-5ed4-b994-89dfa4642e91'::uuid, 'seed-theta-049', 4051, 60301, 64352, now() - interval '56 minutes' + interval '5 seconds'),
        ('ae424b20-4440-51fa-892a-402b85bceb00'::uuid, 'seed-theta-051', -427, 64352, 63925, now() - interval '54 minutes' + interval '5 seconds'),
        ('0b1c7ac3-fa5b-5e2e-adab-5da32f5e27c2'::uuid, 'seed-theta-052', 944, 63925, 64869, now() - interval '53 minutes' + interval '5 seconds'),
        ('49057d79-bc59-50a9-8804-a3c9e8b9f790'::uuid, 'seed-theta-053', 1075, 64869, 65944, now() - interval '52 minutes' + interval '5 seconds'),
        ('dba28fad-0b9c-55e9-b43a-ca4ef974f559'::uuid, 'seed-theta-054', -694, 65944, 65250, now() - interval '51 minutes' + interval '5 seconds'),
        ('c3611825-dd22-558a-afc0-c6de1129033a'::uuid, 'seed-theta-055', 1337, 65250, 66587, now() - interval '50 minutes' + interval '5 seconds'),
        ('bfd02af0-a295-5529-8c1f-a33b935b01a4'::uuid, 'seed-theta-056', 1468, 66587, 68055, now() - interval '49 minutes' + interval '5 seconds'),
        ('177025c4-b2aa-57fc-9323-aa91f9fae8a4'::uuid, 'seed-theta-057', -961, 68055, 67094, now() - interval '48 minutes' + interval '5 seconds'),
        ('77877dbf-3a60-5fd9-b1c8-a0b2ef1105a5'::uuid, 'seed-theta-058', 1730, 67094, 68824, now() - interval '47 minutes' + interval '5 seconds'),
        ('1a5bac85-9854-5991-bc8d-a2238fb6f861'::uuid, 'seed-theta-059', 1861, 68824, 70685, now() - interval '46 minutes' + interval '5 seconds'),
        ('98161aa2-f150-533c-bd89-c7efe3e331a9'::uuid, 'seed-theta-061', 2123, 70685, 72808, now() - interval '44 minutes' + interval '5 seconds'),
        ('ab775d3d-5a71-56ab-a652-94f0f0bd42e8'::uuid, 'seed-theta-062', 2254, 72808, 75062, now() - interval '43 minutes' + interval '5 seconds'),
        ('7dace4ee-330a-53e1-a64c-254508e396c1'::uuid, 'seed-theta-063', -1495, 75062, 73567, now() - interval '42 minutes' + interval '5 seconds'),
        ('c3cf6765-71da-583e-b6f2-24e0bd53e65b'::uuid, 'seed-theta-064', 2516, 73567, 76083, now() - interval '41 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000108.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('2de8e03f-d424-5ebf-b7e5-e0dfd713c709'::uuid, 'seed-theta-010', 1470, 76083, 77553, now()),
        ('e26cd3ef-3f49-586f-a0fb-2debac4b51e8'::uuid, 'seed-theta-025', -525, 77553, 77028, now() + interval '1 second'),
        ('786d42c5-0d09-5c77-a714-33a89973c4bb'::uuid, 'seed-theta-050', 550, 77028, 77578, now() + interval '2 seconds');

UPDATE tenant_00000000000000000000000000000108.balances SET balance = 77578, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000109.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('54930b3b-be12-57d0-b484-dcde6859a171'::uuid, 'seed-iota-001', 'credit', 1292, 'Seed transaction #1 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '117 minutes', now() - interval '117 minutes' + interval '2 seconds', now() - interval '117 minutes' + interval '5 seconds'),
        ('d25b1ce9-ced6-5071-82c5-ed9bd163d36b'::uuid, 'seed-iota-002', 'debit', 1826, 'Seed transaction #2 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":2,"scenario":"insufficient_balance_debit","available_before":1292}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1826 exceeds available balance of 1292', now() - interval '116 minutes', now() - interval '116 minutes' + interval '2 seconds', now() - interval '116 minutes' + interval '5 seconds'),
        ('3944fe5e-b78d-57e6-8431-377e02bde1aa'::uuid, 'seed-iota-003', 'debit', 666, 'Seed transaction #3 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '115 minutes', now() - interval '115 minutes' + interval '2 seconds', now() - interval '115 minutes' + interval '5 seconds'),
        ('b3507028-f641-5913-9c20-7e9036648523'::uuid, 'seed-iota-004', 'credit', 1685, 'Seed transaction #4 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '114 minutes', now() - interval '114 minutes' + interval '2 seconds', now() - interval '114 minutes' + interval '5 seconds'),
        ('d6d5f78d-29b7-55b4-8a6c-b4906561821d'::uuid, 'seed-iota-005', 'credit', 1816, 'Seed transaction #5 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '113 minutes', now() - interval '113 minutes' + interval '2 seconds', now() - interval '113 minutes' + interval '5 seconds'),
        ('97e5f907-af06-5e13-aaa9-9c5acce7ffaf'::uuid, 'seed-iota-006', 'debit', 933, 'Seed transaction #6 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '112 minutes', now() - interval '112 minutes' + interval '2 seconds', now() - interval '112 minutes' + interval '5 seconds'),
        ('41704917-2d10-5909-af88-2c942e28e7ed'::uuid, 'seed-iota-007', 'debit', 3813, 'Seed transaction #7 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":7,"scenario":"insufficient_balance_debit","available_before":3194}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 3813 exceeds available balance of 3194', now() - interval '111 minutes', now() - interval '111 minutes' + interval '2 seconds', now() - interval '111 minutes' + interval '5 seconds'),
        ('87f36e66-95e0-59e6-bdc8-49b272eadf8e'::uuid, 'seed-iota-008', 'credit', 2209, 'Seed transaction #8 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '110 minutes', now() - interval '110 minutes' + interval '2 seconds', now() - interval '110 minutes' + interval '5 seconds'),
        ('992dafd0-1957-5f6b-bb43-65008704c95d'::uuid, 'seed-iota-009', 'debit', 1200, 'Seed transaction #9 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '109 minutes', now() - interval '109 minutes' + interval '2 seconds', now() - interval '109 minutes' + interval '5 seconds'),
        ('e63681f1-884f-59a1-862d-c17d72f770f4'::uuid, 'seed-iota-010', 'credit', 1470, 'Seed transaction #10 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '108 minutes', now(), now()),
        ('272a878d-cc78-5eed-85f0-8c7663592bee'::uuid, 'seed-iota-011', 'credit', 2602, 'Seed transaction #11 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '107 minutes', now() - interval '107 minutes' + interval '2 seconds', now() - interval '107 minutes' + interval '5 seconds'),
        ('9cb00811-61f5-5302-bedf-7206ff0700d0'::uuid, 'seed-iota-012', 'debit', 1467, 'Seed transaction #12 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '106 minutes', now() - interval '106 minutes' + interval '2 seconds', now() - interval '106 minutes' + interval '5 seconds'),
        ('29c90533-adb0-5d46-8b77-f801417dd6c8'::uuid, 'seed-iota-013', 'credit', 2864, 'Seed transaction #13 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '105 minutes', now() - interval '105 minutes' + interval '2 seconds', now() - interval '105 minutes' + interval '5 seconds'),
        ('16c0cb86-0771-56fd-ae97-a4a68c8cb553'::uuid, 'seed-iota-014', 'credit', 2995, 'Seed transaction #14 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '104 minutes', now() - interval '104 minutes' + interval '2 seconds', now() - interval '104 minutes' + interval '5 seconds'),
        ('4f765b97-e480-5fe5-ae6b-6698d297373e'::uuid, 'seed-iota-015', 'debit', 11952, 'Seed transaction #15 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":15,"scenario":"insufficient_balance_debit","available_before":11197}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 11952 exceeds available balance of 11197', now() - interval '103 minutes', now() - interval '103 minutes' + interval '2 seconds', now() - interval '103 minutes' + interval '5 seconds'),
        ('e19d50ba-8f29-524c-b9db-e06177887597'::uuid, 'seed-iota-016', 'credit', 3257, 'Seed transaction #16 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '102 minutes', now() - interval '102 minutes' + interval '2 seconds', now() - interval '102 minutes' + interval '5 seconds'),
        ('1133ffc1-d7fd-5c02-8477-b910f176e5da'::uuid, 'seed-iota-017', 'credit', 3388, 'Seed transaction #17 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '101 minutes', now() - interval '101 minutes' + interval '2 seconds', now() - interval '101 minutes' + interval '5 seconds'),
        ('abf5af71-cdbd-52e2-acef-e2d4687f8810'::uuid, 'seed-iota-018', 'debit', 501, 'Seed transaction #18 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '100 minutes', now() - interval '100 minutes' + interval '2 seconds', now() - interval '100 minutes' + interval '5 seconds'),
        ('e989bbb8-62fd-501b-8c6d-18e3e15d6e25'::uuid, 'seed-iota-019', 'credit', 3650, 'Seed transaction #19 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '99 minutes', now() - interval '99 minutes' + interval '2 seconds', now() - interval '99 minutes' + interval '5 seconds'),
        ('e30074b8-e49b-5717-8155-b4bbd701e204'::uuid, 'seed-iota-020', 'credit', 3781, 'Seed transaction #20 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '98 minutes', now() - interval '98 minutes' + interval '2 seconds', now() - interval '98 minutes' + interval '5 seconds'),
        ('9a23e651-5bcb-53d3-8a8b-640eab01d4f8'::uuid, 'seed-iota-021', 'debit', 768, 'Seed transaction #21 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":21,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '97 minutes', now() - interval '97 minutes' + interval '2 seconds', now() - interval '97 minutes' + interval '5 seconds'),
        ('5bc1d578-846e-5415-8532-e9fee0b65926'::uuid, 'seed-iota-022', 'credit', 4043, 'Seed transaction #22 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":22,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '96 minutes', now() - interval '96 minutes' + interval '2 seconds', now() - interval '96 minutes' + interval '5 seconds'),
        ('76f214f6-ecd5-5fc5-acb3-2ceaa90609a0'::uuid, 'seed-iota-023', 'credit', 4174, 'Seed transaction #23 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":23,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '95 minutes', now() - interval '95 minutes' + interval '2 seconds', now() - interval '95 minutes' + interval '5 seconds'),
        ('db1c9a7c-db22-5bc8-9a26-7487c7d56642'::uuid, 'seed-iota-024', 'debit', 1035, 'Seed transaction #24 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":24,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '94 minutes', now() - interval '94 minutes' + interval '2 seconds', now() - interval '94 minutes' + interval '5 seconds'),
        ('ec881af1-b3d8-5a8d-9af0-a739382959b4'::uuid, 'seed-iota-025', 'debit', 525, 'Seed transaction #25 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":25,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '93 minutes', now(), now()),
        ('f2685db0-f41b-5517-a876-8280be7b9679'::uuid, 'seed-iota-026', 'credit', 1067, 'Seed transaction #26 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":26,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '92 minutes', now() - interval '92 minutes' + interval '2 seconds', now() - interval '92 minutes' + interval '5 seconds'),
        ('d044f918-b9ff-59b8-a373-a436c99df49e'::uuid, 'seed-iota-027', 'debit', 1302, 'Seed transaction #27 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":27,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '91 minutes', now() - interval '91 minutes' + interval '2 seconds', now() - interval '91 minutes' + interval '5 seconds'),
        ('c2cb673b-ff7c-5814-9622-1c2ad12be11e'::uuid, 'seed-iota-028', 'credit', 1329, 'Seed transaction #28 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":28,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '90 minutes', now() - interval '90 minutes' + interval '2 seconds', now() - interval '90 minutes' + interval '5 seconds'),
        ('c2810cea-a9ea-5701-b7b5-5e081d8bc4a8'::uuid, 'seed-iota-029', 'credit', 1460, 'Seed transaction #29 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":29,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '89 minutes', now() - interval '89 minutes' + interval '2 seconds', now() - interval '89 minutes' + interval '5 seconds'),
        ('c5e6d96c-b983-532a-9394-a6998e0d738c'::uuid, 'seed-iota-030', 'debit', 34750, 'Seed transaction #30 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":30,"scenario":"insufficient_balance_debit","available_before":33740}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 34750 exceeds available balance of 33740', now() - interval '88 minutes', now() - interval '88 minutes' + interval '2 seconds', now() - interval '88 minutes' + interval '5 seconds'),
        ('725a4f53-0f5b-54d2-864e-12bdb2dd6b81'::uuid, 'seed-iota-031', 'credit', 1722, 'Seed transaction #31 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":31,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '87 minutes', now() - interval '87 minutes' + interval '2 seconds', now() - interval '87 minutes' + interval '5 seconds'),
        ('10fa2717-50df-5d73-9235-78040fa22834'::uuid, 'seed-iota-032', 'credit', 1853, 'Seed transaction #32 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":32,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '86 minutes', now() - interval '86 minutes' + interval '2 seconds', now() - interval '86 minutes' + interval '5 seconds'),
        ('ecb449c9-ae8b-5cbd-aebf-b85c57dab19b'::uuid, 'seed-iota-033', 'debit', 336, 'Seed transaction #33 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":33,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '85 minutes', now() - interval '85 minutes' + interval '2 seconds', now() - interval '85 minutes' + interval '5 seconds'),
        ('aa62c3c2-0a31-5dbf-b9df-ecd5add319f5'::uuid, 'seed-iota-034', 'credit', 2115, 'Seed transaction #34 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":34,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '84 minutes', now() - interval '84 minutes' + interval '2 seconds', now() - interval '84 minutes' + interval '5 seconds'),
        ('10dcccbe-7237-568e-a94b-fb13ad4b609a'::uuid, 'seed-iota-035', 'credit', 2246, 'Seed transaction #35 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":35,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '83 minutes', now() - interval '83 minutes' + interval '2 seconds', now() - interval '83 minutes' + interval '5 seconds'),
        ('9f4cb095-84a8-58fa-a2bb-97beb9bbc6f7'::uuid, 'seed-iota-036', 'debit', 603, 'Seed transaction #36 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":36,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '82 minutes', now() - interval '82 minutes' + interval '2 seconds', now() - interval '82 minutes' + interval '5 seconds'),
        ('00ddbcea-182d-5484-8569-ddb7225a24b8'::uuid, 'seed-iota-037', 'credit', 2508, 'Seed transaction #37 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":37,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '81 minutes', now() - interval '81 minutes' + interval '2 seconds', now() - interval '81 minutes' + interval '5 seconds'),
        ('4203d28a-863d-5b78-8907-f3507cbf4865'::uuid, 'seed-iota-038', 'credit', 2639, 'Seed transaction #38 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":38,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '80 minutes', now() - interval '80 minutes' + interval '2 seconds', now() - interval '80 minutes' + interval '5 seconds'),
        ('090974e2-6ded-5c02-9146-799c951cc47d'::uuid, 'seed-iota-039', 'debit', 870, 'Seed transaction #39 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":39,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '79 minutes', now() - interval '79 minutes' + interval '2 seconds', now() - interval '79 minutes' + interval '5 seconds'),
        ('b7543aea-4f9e-5477-911b-a5bbf2a9b70e'::uuid, 'seed-iota-040', 'credit', 2901, 'Seed transaction #40 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":40,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '78 minutes', now() - interval '78 minutes' + interval '2 seconds', now() - interval '78 minutes' + interval '5 seconds'),
        ('2b3c1659-5182-5bcf-9b1f-bdd8b50005e6'::uuid, 'seed-iota-041', 'credit', 3032, 'Seed transaction #41 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":41,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '77 minutes', now() - interval '77 minutes' + interval '2 seconds', now() - interval '77 minutes' + interval '5 seconds'),
        ('27a524b3-8315-5674-8f06-d571cd5efa5f'::uuid, 'seed-iota-042', 'debit', 1137, 'Seed transaction #42 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":42,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '76 minutes', now() - interval '76 minutes' + interval '2 seconds', now() - interval '76 minutes' + interval '5 seconds'),
        ('7a9550cb-9785-5ae1-8a7a-fbde8fbd40d3'::uuid, 'seed-iota-043', 'credit', 3294, 'Seed transaction #43 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":43,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '75 minutes', now() - interval '75 minutes' + interval '2 seconds', now() - interval '75 minutes' + interval '5 seconds'),
        ('10cfd5d5-7423-5422-8fde-699cb4f2f814'::uuid, 'seed-iota-044', 'credit', 3425, 'Seed transaction #44 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":44,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '74 minutes', now() - interval '74 minutes' + interval '2 seconds', now() - interval '74 minutes' + interval '5 seconds'),
        ('870de717-cbfd-5487-9fe8-a65fd62a611c'::uuid, 'seed-iota-045', 'debit', 1404, 'Seed transaction #45 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":45,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '73 minutes', now() - interval '73 minutes' + interval '2 seconds', now() - interval '73 minutes' + interval '5 seconds'),
        ('5a3e7191-5fdf-5cdc-841c-db01c78c25b3'::uuid, 'seed-iota-046', 'credit', 3687, 'Seed transaction #46 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":46,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '72 minutes', now() - interval '72 minutes' + interval '2 seconds', now() - interval '72 minutes' + interval '5 seconds'),
        ('3e8db412-32c2-5bde-9a98-eb4e650b84bd'::uuid, 'seed-iota-047', 'credit', 3818, 'Seed transaction #47 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":47,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '71 minutes', now() - interval '71 minutes' + interval '2 seconds', now() - interval '71 minutes' + interval '5 seconds'),
        ('5e4737ac-6137-5ebb-981b-27d6ff40b3f5'::uuid, 'seed-iota-048', 'debit', 1671, 'Seed transaction #48 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":48,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '70 minutes', now() - interval '70 minutes' + interval '2 seconds', now() - interval '70 minutes' + interval '5 seconds'),
        ('54702d91-b6cb-5558-8dce-7296f22d434c'::uuid, 'seed-iota-049', 'credit', 4080, 'Seed transaction #49 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":49,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '69 minutes', now() - interval '69 minutes' + interval '2 seconds', now() - interval '69 minutes' + interval '5 seconds'),
        ('b71bb718-be48-5381-863d-5582906589ca'::uuid, 'seed-iota-050', 'credit', 550, 'Seed transaction #50 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":50,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '68 minutes', now(), now()),
        ('9562c064-1179-547e-9344-5df3b96730a0'::uuid, 'seed-iota-051', 'debit', 438, 'Seed transaction #51 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":51,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '67 minutes', now() - interval '67 minutes' + interval '2 seconds', now() - interval '67 minutes' + interval '5 seconds'),
        ('f737a1c0-bc6f-5877-a90d-ac594c42a5cb'::uuid, 'seed-iota-052', 'credit', 973, 'Seed transaction #52 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":52,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '66 minutes', now() - interval '66 minutes' + interval '2 seconds', now() - interval '66 minutes' + interval '5 seconds'),
        ('15e36716-6368-5a9b-9341-4fe5097da0b4'::uuid, 'seed-iota-053', 'credit', 1104, 'Seed transaction #53 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":53,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '65 minutes', now() - interval '65 minutes' + interval '2 seconds', now() - interval '65 minutes' + interval '5 seconds'),
        ('0c5a5d59-d378-55b2-be06-14bfaaefe61f'::uuid, 'seed-iota-054', 'debit', 705, 'Seed transaction #54 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":54,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '64 minutes', now() - interval '64 minutes' + interval '2 seconds', now() - interval '64 minutes' + interval '5 seconds'),
        ('afcc431e-6837-5e09-8247-0839b44e92dd'::uuid, 'seed-iota-055', 'credit', 1366, 'Seed transaction #55 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":55,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '63 minutes', now() - interval '63 minutes' + interval '2 seconds', now() - interval '63 minutes' + interval '5 seconds'),
        ('1e2d7f6d-0025-592f-b5ec-191df03b61b0'::uuid, 'seed-iota-056', 'credit', 1497, 'Seed transaction #56 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":56,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '62 minutes', now() - interval '62 minutes' + interval '2 seconds', now() - interval '62 minutes' + interval '5 seconds'),
        ('1dc26fe0-c911-5a7a-bcd7-4bf472db63d8'::uuid, 'seed-iota-057', 'debit', 972, 'Seed transaction #57 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":57,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '61 minutes', now() - interval '61 minutes' + interval '2 seconds', now() - interval '61 minutes' + interval '5 seconds'),
        ('8d10a55a-c637-5558-a500-7296f525f2f6'::uuid, 'seed-iota-058', 'credit', 1759, 'Seed transaction #58 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":58,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '60 minutes', now() - interval '60 minutes' + interval '2 seconds', now() - interval '60 minutes' + interval '5 seconds'),
        ('a99cd2f2-ec89-58be-96e8-b3bb2251891e'::uuid, 'seed-iota-059', 'credit', 1890, 'Seed transaction #59 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":59,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '59 minutes', now() - interval '59 minutes' + interval '2 seconds', now() - interval '59 minutes' + interval '5 seconds'),
        ('933c5933-ffba-5aea-a253-1a1d8089b7d1'::uuid, 'seed-iota-060', 'debit', 73033, 'Seed transaction #60 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":60,"scenario":"insufficient_balance_debit","available_before":71513}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 73033 exceeds available balance of 71513', now() - interval '58 minutes', now() - interval '58 minutes' + interval '2 seconds', now() - interval '58 minutes' + interval '5 seconds'),
        ('35490621-877f-5786-bb75-8c252c64a386'::uuid, 'seed-iota-061', 'credit', 2152, 'Seed transaction #61 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":61,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '57 minutes', now() - interval '57 minutes' + interval '2 seconds', now() - interval '57 minutes' + interval '5 seconds'),
        ('9f282e8f-eaf0-54ea-adb5-2c5f2945501a'::uuid, 'seed-iota-062', 'credit', 2283, 'Seed transaction #62 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":62,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '56 minutes', now() - interval '56 minutes' + interval '2 seconds', now() - interval '56 minutes' + interval '5 seconds'),
        ('8964f9da-d8f5-5fe7-98fe-b0cad814f905'::uuid, 'seed-iota-063', 'debit', 1506, 'Seed transaction #63 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":63,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '55 minutes', now() - interval '55 minutes' + interval '2 seconds', now() - interval '55 minutes' + interval '5 seconds'),
        ('f23bf7a9-c867-542a-888d-092c90904fd5'::uuid, 'seed-iota-064', 'credit', 2545, 'Seed transaction #64 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":64,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '54 minutes', now() - interval '54 minutes' + interval '2 seconds', now() - interval '54 minutes' + interval '5 seconds'),
        ('a65b1208-c553-5201-94a8-79cc819ecfa3'::uuid, 'seed-iota-065', 'credit', 2676, 'Seed transaction #65 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":65,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '53 minutes', now() - interval '53 minutes' + interval '2 seconds', now() - interval '53 minutes' + interval '5 seconds'),
        ('3989a08c-21af-55e8-b1d1-af773605ea96'::uuid, 'seed-iota-066', 'debit', 1773, 'Seed transaction #66 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":66,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '52 minutes', now() - interval '52 minutes' + interval '2 seconds', now() - interval '52 minutes' + interval '5 seconds'),
        ('6321c946-950e-5609-ae5a-6b4cc5ae577b'::uuid, 'seed-iota-067', 'credit', 2938, 'Seed transaction #67 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":67,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '51 minutes', now() - interval '51 minutes' + interval '2 seconds', now() - interval '51 minutes' + interval '5 seconds'),
        ('25583aaa-dc38-5e3d-b8aa-7149a6f55078'::uuid, 'seed-iota-068', 'credit', 3069, 'Seed transaction #68 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":68,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '50 minutes', now() - interval '50 minutes' + interval '2 seconds', now() - interval '50 minutes' + interval '5 seconds'),
        ('e6a1508c-9e95-583d-af8a-9c43e9401bcf'::uuid, 'seed-iota-069', 'debit', 540, 'Seed transaction #69 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":69,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '49 minutes', now() - interval '49 minutes' + interval '2 seconds', now() - interval '49 minutes' + interval '5 seconds'),
        ('b852981f-3c50-5f1c-86db-2c3059d9dee1'::uuid, 'seed-iota-070', 'credit', 3331, 'Seed transaction #70 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":70,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '48 minutes', now() - interval '48 minutes' + interval '2 seconds', now() - interval '48 minutes' + interval '5 seconds'),
        ('5aacbd2c-cbbe-5cfd-9a7b-40f702534871'::uuid, 'seed-iota-071', 'credit', 3462, 'Seed transaction #71 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":71,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '47 minutes', now() - interval '47 minutes' + interval '2 seconds', now() - interval '47 minutes' + interval '5 seconds'),
        ('1a1e29a2-2651-5cd4-9f6c-21cebf337a4c'::uuid, 'seed-iota-072', 'debit', 807, 'Seed transaction #72 for tenant iota', '{"seed":true,"tenant_code":"iota","sequence":72,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '46 minutes', now() - interval '46 minutes' + interval '2 seconds', now() - interval '46 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000109.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('54930b3b-be12-57d0-b484-dcde6859a171'::uuid, 'seed-iota-001', 1292, 0, 1292, now() - interval '117 minutes' + interval '5 seconds'),
        ('3944fe5e-b78d-57e6-8431-377e02bde1aa'::uuid, 'seed-iota-003', -666, 1292, 626, now() - interval '115 minutes' + interval '5 seconds'),
        ('b3507028-f641-5913-9c20-7e9036648523'::uuid, 'seed-iota-004', 1685, 626, 2311, now() - interval '114 minutes' + interval '5 seconds'),
        ('d6d5f78d-29b7-55b4-8a6c-b4906561821d'::uuid, 'seed-iota-005', 1816, 2311, 4127, now() - interval '113 minutes' + interval '5 seconds'),
        ('97e5f907-af06-5e13-aaa9-9c5acce7ffaf'::uuid, 'seed-iota-006', -933, 4127, 3194, now() - interval '112 minutes' + interval '5 seconds'),
        ('87f36e66-95e0-59e6-bdc8-49b272eadf8e'::uuid, 'seed-iota-008', 2209, 3194, 5403, now() - interval '110 minutes' + interval '5 seconds'),
        ('992dafd0-1957-5f6b-bb43-65008704c95d'::uuid, 'seed-iota-009', -1200, 5403, 4203, now() - interval '109 minutes' + interval '5 seconds'),
        ('272a878d-cc78-5eed-85f0-8c7663592bee'::uuid, 'seed-iota-011', 2602, 4203, 6805, now() - interval '107 minutes' + interval '5 seconds'),
        ('9cb00811-61f5-5302-bedf-7206ff0700d0'::uuid, 'seed-iota-012', -1467, 6805, 5338, now() - interval '106 minutes' + interval '5 seconds'),
        ('29c90533-adb0-5d46-8b77-f801417dd6c8'::uuid, 'seed-iota-013', 2864, 5338, 8202, now() - interval '105 minutes' + interval '5 seconds'),
        ('16c0cb86-0771-56fd-ae97-a4a68c8cb553'::uuid, 'seed-iota-014', 2995, 8202, 11197, now() - interval '104 minutes' + interval '5 seconds'),
        ('e19d50ba-8f29-524c-b9db-e06177887597'::uuid, 'seed-iota-016', 3257, 11197, 14454, now() - interval '102 minutes' + interval '5 seconds'),
        ('1133ffc1-d7fd-5c02-8477-b910f176e5da'::uuid, 'seed-iota-017', 3388, 14454, 17842, now() - interval '101 minutes' + interval '5 seconds'),
        ('abf5af71-cdbd-52e2-acef-e2d4687f8810'::uuid, 'seed-iota-018', -501, 17842, 17341, now() - interval '100 minutes' + interval '5 seconds'),
        ('e989bbb8-62fd-501b-8c6d-18e3e15d6e25'::uuid, 'seed-iota-019', 3650, 17341, 20991, now() - interval '99 minutes' + interval '5 seconds'),
        ('e30074b8-e49b-5717-8155-b4bbd701e204'::uuid, 'seed-iota-020', 3781, 20991, 24772, now() - interval '98 minutes' + interval '5 seconds'),
        ('9a23e651-5bcb-53d3-8a8b-640eab01d4f8'::uuid, 'seed-iota-021', -768, 24772, 24004, now() - interval '97 minutes' + interval '5 seconds'),
        ('5bc1d578-846e-5415-8532-e9fee0b65926'::uuid, 'seed-iota-022', 4043, 24004, 28047, now() - interval '96 minutes' + interval '5 seconds'),
        ('76f214f6-ecd5-5fc5-acb3-2ceaa90609a0'::uuid, 'seed-iota-023', 4174, 28047, 32221, now() - interval '95 minutes' + interval '5 seconds'),
        ('db1c9a7c-db22-5bc8-9a26-7487c7d56642'::uuid, 'seed-iota-024', -1035, 32221, 31186, now() - interval '94 minutes' + interval '5 seconds'),
        ('f2685db0-f41b-5517-a876-8280be7b9679'::uuid, 'seed-iota-026', 1067, 31186, 32253, now() - interval '92 minutes' + interval '5 seconds'),
        ('d044f918-b9ff-59b8-a373-a436c99df49e'::uuid, 'seed-iota-027', -1302, 32253, 30951, now() - interval '91 minutes' + interval '5 seconds'),
        ('c2cb673b-ff7c-5814-9622-1c2ad12be11e'::uuid, 'seed-iota-028', 1329, 30951, 32280, now() - interval '90 minutes' + interval '5 seconds'),
        ('c2810cea-a9ea-5701-b7b5-5e081d8bc4a8'::uuid, 'seed-iota-029', 1460, 32280, 33740, now() - interval '89 minutes' + interval '5 seconds'),
        ('725a4f53-0f5b-54d2-864e-12bdb2dd6b81'::uuid, 'seed-iota-031', 1722, 33740, 35462, now() - interval '87 minutes' + interval '5 seconds'),
        ('10fa2717-50df-5d73-9235-78040fa22834'::uuid, 'seed-iota-032', 1853, 35462, 37315, now() - interval '86 minutes' + interval '5 seconds'),
        ('ecb449c9-ae8b-5cbd-aebf-b85c57dab19b'::uuid, 'seed-iota-033', -336, 37315, 36979, now() - interval '85 minutes' + interval '5 seconds'),
        ('aa62c3c2-0a31-5dbf-b9df-ecd5add319f5'::uuid, 'seed-iota-034', 2115, 36979, 39094, now() - interval '84 minutes' + interval '5 seconds'),
        ('10dcccbe-7237-568e-a94b-fb13ad4b609a'::uuid, 'seed-iota-035', 2246, 39094, 41340, now() - interval '83 minutes' + interval '5 seconds'),
        ('9f4cb095-84a8-58fa-a2bb-97beb9bbc6f7'::uuid, 'seed-iota-036', -603, 41340, 40737, now() - interval '82 minutes' + interval '5 seconds'),
        ('00ddbcea-182d-5484-8569-ddb7225a24b8'::uuid, 'seed-iota-037', 2508, 40737, 43245, now() - interval '81 minutes' + interval '5 seconds'),
        ('4203d28a-863d-5b78-8907-f3507cbf4865'::uuid, 'seed-iota-038', 2639, 43245, 45884, now() - interval '80 minutes' + interval '5 seconds'),
        ('090974e2-6ded-5c02-9146-799c951cc47d'::uuid, 'seed-iota-039', -870, 45884, 45014, now() - interval '79 minutes' + interval '5 seconds'),
        ('b7543aea-4f9e-5477-911b-a5bbf2a9b70e'::uuid, 'seed-iota-040', 2901, 45014, 47915, now() - interval '78 minutes' + interval '5 seconds'),
        ('2b3c1659-5182-5bcf-9b1f-bdd8b50005e6'::uuid, 'seed-iota-041', 3032, 47915, 50947, now() - interval '77 minutes' + interval '5 seconds'),
        ('27a524b3-8315-5674-8f06-d571cd5efa5f'::uuid, 'seed-iota-042', -1137, 50947, 49810, now() - interval '76 minutes' + interval '5 seconds'),
        ('7a9550cb-9785-5ae1-8a7a-fbde8fbd40d3'::uuid, 'seed-iota-043', 3294, 49810, 53104, now() - interval '75 minutes' + interval '5 seconds'),
        ('10cfd5d5-7423-5422-8fde-699cb4f2f814'::uuid, 'seed-iota-044', 3425, 53104, 56529, now() - interval '74 minutes' + interval '5 seconds'),
        ('870de717-cbfd-5487-9fe8-a65fd62a611c'::uuid, 'seed-iota-045', -1404, 56529, 55125, now() - interval '73 minutes' + interval '5 seconds'),
        ('5a3e7191-5fdf-5cdc-841c-db01c78c25b3'::uuid, 'seed-iota-046', 3687, 55125, 58812, now() - interval '72 minutes' + interval '5 seconds'),
        ('3e8db412-32c2-5bde-9a98-eb4e650b84bd'::uuid, 'seed-iota-047', 3818, 58812, 62630, now() - interval '71 minutes' + interval '5 seconds'),
        ('5e4737ac-6137-5ebb-981b-27d6ff40b3f5'::uuid, 'seed-iota-048', -1671, 62630, 60959, now() - interval '70 minutes' + interval '5 seconds'),
        ('54702d91-b6cb-5558-8dce-7296f22d434c'::uuid, 'seed-iota-049', 4080, 60959, 65039, now() - interval '69 minutes' + interval '5 seconds'),
        ('9562c064-1179-547e-9344-5df3b96730a0'::uuid, 'seed-iota-051', -438, 65039, 64601, now() - interval '67 minutes' + interval '5 seconds'),
        ('f737a1c0-bc6f-5877-a90d-ac594c42a5cb'::uuid, 'seed-iota-052', 973, 64601, 65574, now() - interval '66 minutes' + interval '5 seconds'),
        ('15e36716-6368-5a9b-9341-4fe5097da0b4'::uuid, 'seed-iota-053', 1104, 65574, 66678, now() - interval '65 minutes' + interval '5 seconds'),
        ('0c5a5d59-d378-55b2-be06-14bfaaefe61f'::uuid, 'seed-iota-054', -705, 66678, 65973, now() - interval '64 minutes' + interval '5 seconds'),
        ('afcc431e-6837-5e09-8247-0839b44e92dd'::uuid, 'seed-iota-055', 1366, 65973, 67339, now() - interval '63 minutes' + interval '5 seconds'),
        ('1e2d7f6d-0025-592f-b5ec-191df03b61b0'::uuid, 'seed-iota-056', 1497, 67339, 68836, now() - interval '62 minutes' + interval '5 seconds'),
        ('1dc26fe0-c911-5a7a-bcd7-4bf472db63d8'::uuid, 'seed-iota-057', -972, 68836, 67864, now() - interval '61 minutes' + interval '5 seconds'),
        ('8d10a55a-c637-5558-a500-7296f525f2f6'::uuid, 'seed-iota-058', 1759, 67864, 69623, now() - interval '60 minutes' + interval '5 seconds'),
        ('a99cd2f2-ec89-58be-96e8-b3bb2251891e'::uuid, 'seed-iota-059', 1890, 69623, 71513, now() - interval '59 minutes' + interval '5 seconds'),
        ('35490621-877f-5786-bb75-8c252c64a386'::uuid, 'seed-iota-061', 2152, 71513, 73665, now() - interval '57 minutes' + interval '5 seconds'),
        ('9f282e8f-eaf0-54ea-adb5-2c5f2945501a'::uuid, 'seed-iota-062', 2283, 73665, 75948, now() - interval '56 minutes' + interval '5 seconds'),
        ('8964f9da-d8f5-5fe7-98fe-b0cad814f905'::uuid, 'seed-iota-063', -1506, 75948, 74442, now() - interval '55 minutes' + interval '5 seconds'),
        ('f23bf7a9-c867-542a-888d-092c90904fd5'::uuid, 'seed-iota-064', 2545, 74442, 76987, now() - interval '54 minutes' + interval '5 seconds'),
        ('a65b1208-c553-5201-94a8-79cc819ecfa3'::uuid, 'seed-iota-065', 2676, 76987, 79663, now() - interval '53 minutes' + interval '5 seconds'),
        ('3989a08c-21af-55e8-b1d1-af773605ea96'::uuid, 'seed-iota-066', -1773, 79663, 77890, now() - interval '52 minutes' + interval '5 seconds'),
        ('6321c946-950e-5609-ae5a-6b4cc5ae577b'::uuid, 'seed-iota-067', 2938, 77890, 80828, now() - interval '51 minutes' + interval '5 seconds'),
        ('25583aaa-dc38-5e3d-b8aa-7149a6f55078'::uuid, 'seed-iota-068', 3069, 80828, 83897, now() - interval '50 minutes' + interval '5 seconds'),
        ('e6a1508c-9e95-583d-af8a-9c43e9401bcf'::uuid, 'seed-iota-069', -540, 83897, 83357, now() - interval '49 minutes' + interval '5 seconds'),
        ('b852981f-3c50-5f1c-86db-2c3059d9dee1'::uuid, 'seed-iota-070', 3331, 83357, 86688, now() - interval '48 minutes' + interval '5 seconds'),
        ('5aacbd2c-cbbe-5cfd-9a7b-40f702534871'::uuid, 'seed-iota-071', 3462, 86688, 90150, now() - interval '47 minutes' + interval '5 seconds'),
        ('1a1e29a2-2651-5cd4-9f6c-21cebf337a4c'::uuid, 'seed-iota-072', -807, 90150, 89343, now() - interval '46 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000109.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('e63681f1-884f-59a1-862d-c17d72f770f4'::uuid, 'seed-iota-010', 1470, 89343, 90813, now()),
        ('ec881af1-b3d8-5a8d-9af0-a739382959b4'::uuid, 'seed-iota-025', -525, 90813, 90288, now() + interval '1 second'),
        ('b71bb718-be48-5381-863d-5582906589ca'::uuid, 'seed-iota-050', 550, 90288, 90838, now() + interval '2 seconds');

UPDATE tenant_00000000000000000000000000000109.balances SET balance = 90838, updated_at = now() WHERE id = 1;

INSERT INTO tenant_00000000000000000000000000000110.transactions (
    id, reference, type, amount, description, metadata, status, failure_code, failure_reason, created_at, updated_at, processed_at
)
VALUES
        ('f9407436-44e4-5cc8-a073-784b8101a515'::uuid, 'seed-kappa-001', 'credit', 1321, 'Seed transaction #1 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":1,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '150 minutes', now() - interval '150 minutes' + interval '2 seconds', now() - interval '150 minutes' + interval '5 seconds'),
        ('81ae7d5f-95b0-5fea-aeaa-c60f5b04bcf2'::uuid, 'seed-kappa-002', 'debit', 1855, 'Seed transaction #2 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":2,"scenario":"insufficient_balance_debit","available_before":1321}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 1855 exceeds available balance of 1321', now() - interval '149 minutes', now() - interval '149 minutes' + interval '2 seconds', now() - interval '149 minutes' + interval '5 seconds'),
        ('1383f3a5-7c6a-52f6-b92e-172e2c1ffa8f'::uuid, 'seed-kappa-003', 'debit', 677, 'Seed transaction #3 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":3,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '148 minutes', now() - interval '148 minutes' + interval '2 seconds', now() - interval '148 minutes' + interval '5 seconds'),
        ('8dcd4281-3d64-5b3a-a361-86dc190e3aef'::uuid, 'seed-kappa-004', 'credit', 1714, 'Seed transaction #4 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":4,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '147 minutes', now() - interval '147 minutes' + interval '2 seconds', now() - interval '147 minutes' + interval '5 seconds'),
        ('644b57fe-711b-55f0-a18f-048e8b441b62'::uuid, 'seed-kappa-005', 'credit', 1845, 'Seed transaction #5 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":5,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '146 minutes', now() - interval '146 minutes' + interval '2 seconds', now() - interval '146 minutes' + interval '5 seconds'),
        ('e4036f1c-3d10-521c-9475-c73a6c63c654'::uuid, 'seed-kappa-006', 'debit', 944, 'Seed transaction #6 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":6,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '145 minutes', now() - interval '145 minutes' + interval '2 seconds', now() - interval '145 minutes' + interval '5 seconds'),
        ('8301ca3a-b048-5992-88b4-9c71d885eccb'::uuid, 'seed-kappa-007', 'debit', 3878, 'Seed transaction #7 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":7,"scenario":"insufficient_balance_debit","available_before":3259}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 3878 exceeds available balance of 3259', now() - interval '144 minutes', now() - interval '144 minutes' + interval '2 seconds', now() - interval '144 minutes' + interval '5 seconds'),
        ('beca20b8-1bd2-5794-993a-bb2fd8c3af24'::uuid, 'seed-kappa-008', 'credit', 2238, 'Seed transaction #8 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":8,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '143 minutes', now() - interval '143 minutes' + interval '2 seconds', now() - interval '143 minutes' + interval '5 seconds'),
        ('767307d6-9536-5187-9890-fb69e95f85be'::uuid, 'seed-kappa-009', 'debit', 1211, 'Seed transaction #9 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":9,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '142 minutes', now() - interval '142 minutes' + interval '2 seconds', now() - interval '142 minutes' + interval '5 seconds'),
        ('5e84a30a-5ef8-53d1-a46f-2acfa5df3757'::uuid, 'seed-kappa-010', 'credit', 1470, 'Seed transaction #10 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":10,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '141 minutes', now(), now()),
        ('35baaded-dd1b-521d-828c-6d35231f076b'::uuid, 'seed-kappa-011', 'credit', 2631, 'Seed transaction #11 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":11,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '140 minutes', now() - interval '140 minutes' + interval '2 seconds', now() - interval '140 minutes' + interval '5 seconds'),
        ('2e2a3320-ee97-52f4-83d5-423d6a6102ee'::uuid, 'seed-kappa-012', 'debit', 1478, 'Seed transaction #12 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":12,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '139 minutes', now() - interval '139 minutes' + interval '2 seconds', now() - interval '139 minutes' + interval '5 seconds'),
        ('3adcf44e-50a5-52c7-bf58-7d6efc245071'::uuid, 'seed-kappa-013', 'credit', 2893, 'Seed transaction #13 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":13,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '138 minutes', now() - interval '138 minutes' + interval '2 seconds', now() - interval '138 minutes' + interval '5 seconds'),
        ('69061380-43e7-5006-b673-7e87cae5bdfd'::uuid, 'seed-kappa-014', 'credit', 3024, 'Seed transaction #14 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":14,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '137 minutes', now() - interval '137 minutes' + interval '2 seconds', now() - interval '137 minutes' + interval '5 seconds'),
        ('7d86577c-1a56-5caf-be47-eb464295e2c7'::uuid, 'seed-kappa-015', 'debit', 12111, 'Seed transaction #15 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":15,"scenario":"insufficient_balance_debit","available_before":11356}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 12111 exceeds available balance of 11356', now() - interval '136 minutes', now() - interval '136 minutes' + interval '2 seconds', now() - interval '136 minutes' + interval '5 seconds'),
        ('06127562-5960-599f-9b4f-df581af78be4'::uuid, 'seed-kappa-016', 'credit', 3286, 'Seed transaction #16 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":16,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '135 minutes', now() - interval '135 minutes' + interval '2 seconds', now() - interval '135 minutes' + interval '5 seconds'),
        ('74737492-8dcb-5fb3-968c-65359e3a26a0'::uuid, 'seed-kappa-017', 'credit', 3417, 'Seed transaction #17 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":17,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '134 minutes', now() - interval '134 minutes' + interval '2 seconds', now() - interval '134 minutes' + interval '5 seconds'),
        ('a626b941-da24-51bb-a808-8f048215d043'::uuid, 'seed-kappa-018', 'debit', 512, 'Seed transaction #18 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":18,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '133 minutes', now() - interval '133 minutes' + interval '2 seconds', now() - interval '133 minutes' + interval '5 seconds'),
        ('4073b540-1a5b-5b7e-8859-501037969bc2'::uuid, 'seed-kappa-019', 'credit', 3679, 'Seed transaction #19 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":19,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '132 minutes', now() - interval '132 minutes' + interval '2 seconds', now() - interval '132 minutes' + interval '5 seconds'),
        ('43364b99-ecdc-5586-a8bd-ed1a0b830503'::uuid, 'seed-kappa-020', 'credit', 3810, 'Seed transaction #20 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":20,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '131 minutes', now() - interval '131 minutes' + interval '2 seconds', now() - interval '131 minutes' + interval '5 seconds'),
        ('e192496b-4fac-5d87-ae6e-6b6e6d4fa05f'::uuid, 'seed-kappa-021', 'debit', 779, 'Seed transaction #21 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":21,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '130 minutes', now() - interval '130 minutes' + interval '2 seconds', now() - interval '130 minutes' + interval '5 seconds'),
        ('d36d5230-b68f-5663-8878-97e9f33eda04'::uuid, 'seed-kappa-022', 'credit', 4072, 'Seed transaction #22 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":22,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '129 minutes', now() - interval '129 minutes' + interval '2 seconds', now() - interval '129 minutes' + interval '5 seconds'),
        ('2f2d8b8b-2b02-52d7-a79e-2b3d5acb0e1c'::uuid, 'seed-kappa-023', 'credit', 4203, 'Seed transaction #23 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":23,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '128 minutes', now() - interval '128 minutes' + interval '2 seconds', now() - interval '128 minutes' + interval '5 seconds'),
        ('100f212e-1852-5cce-807a-ce4b51d93d99'::uuid, 'seed-kappa-024', 'debit', 1046, 'Seed transaction #24 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":24,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '127 minutes', now() - interval '127 minutes' + interval '2 seconds', now() - interval '127 minutes' + interval '5 seconds'),
        ('77befda6-0a4e-5834-b919-25a1fb2e69b8'::uuid, 'seed-kappa-025', 'debit', 525, 'Seed transaction #25 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":25,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '126 minutes', now(), now()),
        ('c86928be-918b-53a5-be14-10b0940829f9'::uuid, 'seed-kappa-026', 'credit', 1096, 'Seed transaction #26 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":26,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '125 minutes', now() - interval '125 minutes' + interval '2 seconds', now() - interval '125 minutes' + interval '5 seconds'),
        ('59872776-e12a-5bca-82e5-8feb3481c628'::uuid, 'seed-kappa-027', 'debit', 1313, 'Seed transaction #27 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":27,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '124 minutes', now() - interval '124 minutes' + interval '2 seconds', now() - interval '124 minutes' + interval '5 seconds'),
        ('efdcbdbf-81fa-5e77-b23d-efbf6fad64e6'::uuid, 'seed-kappa-028', 'credit', 1358, 'Seed transaction #28 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":28,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '123 minutes', now() - interval '123 minutes' + interval '2 seconds', now() - interval '123 minutes' + interval '5 seconds'),
        ('579e096f-dbf6-5703-a4bb-b62a095fbcf3'::uuid, 'seed-kappa-029', 'credit', 1489, 'Seed transaction #29 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":29,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '122 minutes', now() - interval '122 minutes' + interval '2 seconds', now() - interval '122 minutes' + interval '5 seconds'),
        ('d98850c8-7e19-585a-a2bd-f7c153b2b325'::uuid, 'seed-kappa-030', 'debit', 35126, 'Seed transaction #30 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":30,"scenario":"insufficient_balance_debit","available_before":34116}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 35126 exceeds available balance of 34116', now() - interval '121 minutes', now() - interval '121 minutes' + interval '2 seconds', now() - interval '121 minutes' + interval '5 seconds'),
        ('8a0af642-2c0d-5d82-83b8-f7dd2050c07d'::uuid, 'seed-kappa-031', 'credit', 1751, 'Seed transaction #31 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":31,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '120 minutes', now() - interval '120 minutes' + interval '2 seconds', now() - interval '120 minutes' + interval '5 seconds'),
        ('57161f7b-a380-5092-bc91-541a6dd9c60e'::uuid, 'seed-kappa-032', 'credit', 1882, 'Seed transaction #32 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":32,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '119 minutes', now() - interval '119 minutes' + interval '2 seconds', now() - interval '119 minutes' + interval '5 seconds'),
        ('706b2a9c-d00a-5aa0-9b28-a2a4caebe36d'::uuid, 'seed-kappa-033', 'debit', 347, 'Seed transaction #33 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":33,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '118 minutes', now() - interval '118 minutes' + interval '2 seconds', now() - interval '118 minutes' + interval '5 seconds'),
        ('3c009708-bea3-5bf8-99b1-663c3ac211f4'::uuid, 'seed-kappa-034', 'credit', 2144, 'Seed transaction #34 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":34,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '117 minutes', now() - interval '117 minutes' + interval '2 seconds', now() - interval '117 minutes' + interval '5 seconds'),
        ('778c29df-8827-52d8-a7bd-736da1897b83'::uuid, 'seed-kappa-035', 'credit', 2275, 'Seed transaction #35 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":35,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '116 minutes', now() - interval '116 minutes' + interval '2 seconds', now() - interval '116 minutes' + interval '5 seconds'),
        ('77446cef-11b8-5332-a674-97908afe8ea4'::uuid, 'seed-kappa-036', 'debit', 614, 'Seed transaction #36 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":36,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '115 minutes', now() - interval '115 minutes' + interval '2 seconds', now() - interval '115 minutes' + interval '5 seconds'),
        ('d5a96ecd-4148-55c6-baed-a93c83eb52d8'::uuid, 'seed-kappa-037', 'credit', 2537, 'Seed transaction #37 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":37,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '114 minutes', now() - interval '114 minutes' + interval '2 seconds', now() - interval '114 minutes' + interval '5 seconds'),
        ('50491a03-670e-5505-b265-ab326acd606e'::uuid, 'seed-kappa-038', 'credit', 2668, 'Seed transaction #38 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":38,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '113 minutes', now() - interval '113 minutes' + interval '2 seconds', now() - interval '113 minutes' + interval '5 seconds'),
        ('6c231a95-bc1b-5d7d-97c7-513c05a4a7cb'::uuid, 'seed-kappa-039', 'debit', 881, 'Seed transaction #39 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":39,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '112 minutes', now() - interval '112 minutes' + interval '2 seconds', now() - interval '112 minutes' + interval '5 seconds'),
        ('ca9b2e9b-93a4-583e-9a70-238aeed37668'::uuid, 'seed-kappa-040', 'credit', 2930, 'Seed transaction #40 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":40,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '111 minutes', now() - interval '111 minutes' + interval '2 seconds', now() - interval '111 minutes' + interval '5 seconds'),
        ('ce3451d0-017f-5e36-9bf1-66b70e288480'::uuid, 'seed-kappa-041', 'credit', 3061, 'Seed transaction #41 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":41,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '110 minutes', now() - interval '110 minutes' + interval '2 seconds', now() - interval '110 minutes' + interval '5 seconds'),
        ('f254f9c6-dacf-5ee4-b370-8111e7c1e03b'::uuid, 'seed-kappa-042', 'debit', 1148, 'Seed transaction #42 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":42,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '109 minutes', now() - interval '109 minutes' + interval '2 seconds', now() - interval '109 minutes' + interval '5 seconds'),
        ('6ff5116a-509a-53fa-9b31-340058099736'::uuid, 'seed-kappa-043', 'credit', 3323, 'Seed transaction #43 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":43,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '108 minutes', now() - interval '108 minutes' + interval '2 seconds', now() - interval '108 minutes' + interval '5 seconds'),
        ('2ed22a10-f86b-5d99-96b4-e3b73fb9d3d4'::uuid, 'seed-kappa-044', 'credit', 3454, 'Seed transaction #44 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":44,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '107 minutes', now() - interval '107 minutes' + interval '2 seconds', now() - interval '107 minutes' + interval '5 seconds'),
        ('049ee93a-ecf0-5650-9945-e5b27a3f6ba8'::uuid, 'seed-kappa-045', 'debit', 1415, 'Seed transaction #45 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":45,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '106 minutes', now() - interval '106 minutes' + interval '2 seconds', now() - interval '106 minutes' + interval '5 seconds'),
        ('c3c0ddab-320f-5409-bf51-f18129a55a6e'::uuid, 'seed-kappa-046', 'credit', 3716, 'Seed transaction #46 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":46,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '105 minutes', now() - interval '105 minutes' + interval '2 seconds', now() - interval '105 minutes' + interval '5 seconds'),
        ('ff54a391-52b0-59ca-84fe-6718d72bb8f8'::uuid, 'seed-kappa-047', 'credit', 3847, 'Seed transaction #47 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":47,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '104 minutes', now() - interval '104 minutes' + interval '2 seconds', now() - interval '104 minutes' + interval '5 seconds'),
        ('e872b4a1-1972-558e-8fe7-914513a18a92'::uuid, 'seed-kappa-048', 'debit', 1682, 'Seed transaction #48 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":48,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '103 minutes', now() - interval '103 minutes' + interval '2 seconds', now() - interval '103 minutes' + interval '5 seconds'),
        ('68515b3b-a47f-5adb-b5ad-9f4b6e068c66'::uuid, 'seed-kappa-049', 'credit', 4109, 'Seed transaction #49 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":49,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '102 minutes', now() - interval '102 minutes' + interval '2 seconds', now() - interval '102 minutes' + interval '5 seconds'),
        ('b4486763-9ff7-5e5c-b004-5941f6db089d'::uuid, 'seed-kappa-050', 'credit', 550, 'Seed transaction #50 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":50,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '101 minutes', now(), now()),
        ('e471cf78-231a-58ba-bad9-2b4638a85d7a'::uuid, 'seed-kappa-051', 'debit', 449, 'Seed transaction #51 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":51,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '100 minutes', now() - interval '100 minutes' + interval '2 seconds', now() - interval '100 minutes' + interval '5 seconds'),
        ('6f3561d1-b9c7-51cf-b685-e49783856755'::uuid, 'seed-kappa-052', 'credit', 1002, 'Seed transaction #52 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":52,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '99 minutes', now() - interval '99 minutes' + interval '2 seconds', now() - interval '99 minutes' + interval '5 seconds'),
        ('8007d40a-5f91-54ca-8a3c-3dd201c4c148'::uuid, 'seed-kappa-053', 'credit', 1133, 'Seed transaction #53 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":53,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '98 minutes', now() - interval '98 minutes' + interval '2 seconds', now() - interval '98 minutes' + interval '5 seconds'),
        ('b5b6378c-8a80-5657-a900-4478c6eeade2'::uuid, 'seed-kappa-054', 'debit', 716, 'Seed transaction #54 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":54,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '97 minutes', now() - interval '97 minutes' + interval '2 seconds', now() - interval '97 minutes' + interval '5 seconds'),
        ('ee98a093-fb6b-598f-ba22-f82b35adbb87'::uuid, 'seed-kappa-055', 'credit', 1395, 'Seed transaction #55 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":55,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '96 minutes', now() - interval '96 minutes' + interval '2 seconds', now() - interval '96 minutes' + interval '5 seconds'),
        ('6fd0b4fd-3494-5d8f-9eeb-107406e5c811'::uuid, 'seed-kappa-056', 'credit', 1526, 'Seed transaction #56 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":56,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '95 minutes', now() - interval '95 minutes' + interval '2 seconds', now() - interval '95 minutes' + interval '5 seconds'),
        ('7e0e3baa-dd7d-5a97-9d44-b52f042e33d5'::uuid, 'seed-kappa-057', 'debit', 983, 'Seed transaction #57 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":57,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '94 minutes', now() - interval '94 minutes' + interval '2 seconds', now() - interval '94 minutes' + interval '5 seconds'),
        ('55b84ed6-7b2b-5ebc-a7ea-a19ce1acc5f3'::uuid, 'seed-kappa-058', 'credit', 1788, 'Seed transaction #58 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":58,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '93 minutes', now() - interval '93 minutes' + interval '2 seconds', now() - interval '93 minutes' + interval '5 seconds'),
        ('bfe7db58-65ec-5a2e-9ca1-35b76d231485'::uuid, 'seed-kappa-059', 'credit', 1919, 'Seed transaction #59 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":59,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '92 minutes', now() - interval '92 minutes' + interval '2 seconds', now() - interval '92 minutes' + interval '5 seconds'),
        ('77b97d1f-06ee-5b0c-8586-62158334821d'::uuid, 'seed-kappa-060', 'debit', 73861, 'Seed transaction #60 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":60,"scenario":"insufficient_balance_debit","available_before":72341}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 73861 exceeds available balance of 72341', now() - interval '91 minutes', now() - interval '91 minutes' + interval '2 seconds', now() - interval '91 minutes' + interval '5 seconds'),
        ('b14d266a-5508-502f-9a00-5485548563a0'::uuid, 'seed-kappa-061', 'credit', 2181, 'Seed transaction #61 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":61,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '90 minutes', now() - interval '90 minutes' + interval '2 seconds', now() - interval '90 minutes' + interval '5 seconds'),
        ('b073f0c9-e580-5fd8-9e9d-cf6999a7d4c5'::uuid, 'seed-kappa-062', 'credit', 2312, 'Seed transaction #62 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":62,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '89 minutes', now() - interval '89 minutes' + interval '2 seconds', now() - interval '89 minutes' + interval '5 seconds'),
        ('987b8db0-6c42-595b-8f37-fe2bff8bd794'::uuid, 'seed-kappa-063', 'debit', 1517, 'Seed transaction #63 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":63,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '88 minutes', now() - interval '88 minutes' + interval '2 seconds', now() - interval '88 minutes' + interval '5 seconds'),
        ('569af025-26ff-5304-910e-049fda880826'::uuid, 'seed-kappa-064', 'credit', 2574, 'Seed transaction #64 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":64,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '87 minutes', now() - interval '87 minutes' + interval '2 seconds', now() - interval '87 minutes' + interval '5 seconds'),
        ('6767a873-0d33-5af0-92ad-b86196d5fd0b'::uuid, 'seed-kappa-065', 'credit', 2705, 'Seed transaction #65 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":65,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '86 minutes', now() - interval '86 minutes' + interval '2 seconds', now() - interval '86 minutes' + interval '5 seconds'),
        ('2508600a-11bd-5ece-8a15-d50af611c2e4'::uuid, 'seed-kappa-066', 'debit', 1784, 'Seed transaction #66 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":66,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '85 minutes', now() - interval '85 minutes' + interval '2 seconds', now() - interval '85 minutes' + interval '5 seconds'),
        ('8e3b9089-220c-5afd-bba3-fa3a31c8d19e'::uuid, 'seed-kappa-067', 'credit', 2967, 'Seed transaction #67 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":67,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '84 minutes', now() - interval '84 minutes' + interval '2 seconds', now() - interval '84 minutes' + interval '5 seconds'),
        ('39e86a51-f77b-5dfd-8913-012f435f3811'::uuid, 'seed-kappa-068', 'credit', 3098, 'Seed transaction #68 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":68,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '83 minutes', now() - interval '83 minutes' + interval '2 seconds', now() - interval '83 minutes' + interval '5 seconds'),
        ('b3f2bf7e-9268-5001-b1f4-ae841027819b'::uuid, 'seed-kappa-069', 'debit', 551, 'Seed transaction #69 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":69,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '82 minutes', now() - interval '82 minutes' + interval '2 seconds', now() - interval '82 minutes' + interval '5 seconds'),
        ('84373fd1-f2fe-5c51-8ed9-4ac8a01851e7'::uuid, 'seed-kappa-070', 'credit', 3360, 'Seed transaction #70 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":70,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '81 minutes', now() - interval '81 minutes' + interval '2 seconds', now() - interval '81 minutes' + interval '5 seconds'),
        ('e49ce7eb-a188-5395-a7d9-f848adb6ab38'::uuid, 'seed-kappa-071', 'credit', 3491, 'Seed transaction #71 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":71,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '80 minutes', now() - interval '80 minutes' + interval '2 seconds', now() - interval '80 minutes' + interval '5 seconds'),
        ('0c57e037-92b6-559e-af4d-ce879b561c24'::uuid, 'seed-kappa-072', 'debit', 818, 'Seed transaction #72 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":72,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '79 minutes', now() - interval '79 minutes' + interval '2 seconds', now() - interval '79 minutes' + interval '5 seconds'),
        ('c847d819-cfad-5e15-88dc-e14477a90752'::uuid, 'seed-kappa-073', 'credit', 3753, 'Seed transaction #73 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":73,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '78 minutes', now() - interval '78 minutes' + interval '2 seconds', now() - interval '78 minutes' + interval '5 seconds'),
        ('05cd07be-c459-58b7-b06b-908095e7a7ac'::uuid, 'seed-kappa-074', 'credit', 3884, 'Seed transaction #74 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":74,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '77 minutes', now() - interval '77 minutes' + interval '2 seconds', now() - interval '77 minutes' + interval '5 seconds'),
        ('4bbbeb63-13db-5b0a-8427-bba8301fc08f'::uuid, 'seed-kappa-075', 'debit', 575, 'Seed transaction #75 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":75,"scenario":"completed_after_review"}'::jsonb, 'completed', NULL, NULL, now() - interval '76 minutes', now(), now()),
        ('375e6ebb-6663-5ec1-b4ee-230326f0ae49'::uuid, 'seed-kappa-076', 'credit', 4146, 'Seed transaction #76 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":76,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '75 minutes', now() - interval '75 minutes' + interval '2 seconds', now() - interval '75 minutes' + interval '5 seconds'),
        ('8801b11c-7e5b-5b54-a8cf-5a659251754b'::uuid, 'seed-kappa-077', 'credit', 4277, 'Seed transaction #77 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":77,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '74 minutes', now() - interval '74 minutes' + interval '2 seconds', now() - interval '74 minutes' + interval '5 seconds'),
        ('f954fb81-a0ff-5191-9655-a5b491f4bbc4'::uuid, 'seed-kappa-078', 'debit', 1352, 'Seed transaction #78 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":78,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '73 minutes', now() - interval '73 minutes' + interval '2 seconds', now() - interval '73 minutes' + interval '5 seconds'),
        ('b490ab25-7f7c-5962-a728-a556d7150a7f'::uuid, 'seed-kappa-079', 'credit', 1039, 'Seed transaction #79 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":79,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '72 minutes', now() - interval '72 minutes' + interval '2 seconds', now() - interval '72 minutes' + interval '5 seconds'),
        ('58b6d334-efa2-50af-9576-2c3e87919568'::uuid, 'seed-kappa-080', 'credit', 1170, 'Seed transaction #80 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":80,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '71 minutes', now() - interval '71 minutes' + interval '2 seconds', now() - interval '71 minutes' + interval '5 seconds'),
        ('aefb7337-d886-543a-8f51-79856536483c'::uuid, 'seed-kappa-081', 'debit', 1619, 'Seed transaction #81 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":81,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '70 minutes', now() - interval '70 minutes' + interval '2 seconds', now() - interval '70 minutes' + interval '5 seconds'),
        ('8de4315c-0253-50fe-80cb-e56c1fc469c2'::uuid, 'seed-kappa-082', 'credit', 1432, 'Seed transaction #82 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":82,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '69 minutes', now() - interval '69 minutes' + interval '2 seconds', now() - interval '69 minutes' + interval '5 seconds'),
        ('dfb4a7d4-d335-5787-b3ea-03e84491aa14'::uuid, 'seed-kappa-083', 'credit', 1563, 'Seed transaction #83 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":83,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '68 minutes', now() - interval '68 minutes' + interval '2 seconds', now() - interval '68 minutes' + interval '5 seconds'),
        ('434d9248-c0c8-5ee7-8feb-34eb38edaed7'::uuid, 'seed-kappa-084', 'debit', 386, 'Seed transaction #84 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":84,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '67 minutes', now() - interval '67 minutes' + interval '2 seconds', now() - interval '67 minutes' + interval '5 seconds'),
        ('e855277e-f2ca-56d3-97ad-9f2d208b3fee'::uuid, 'seed-kappa-085', 'credit', 1825, 'Seed transaction #85 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":85,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '66 minutes', now() - interval '66 minutes' + interval '2 seconds', now() - interval '66 minutes' + interval '5 seconds'),
        ('792efdbb-6949-536a-a098-1fdf77307fa1'::uuid, 'seed-kappa-086', 'credit', 1956, 'Seed transaction #86 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":86,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '65 minutes', now() - interval '65 minutes' + interval '2 seconds', now() - interval '65 minutes' + interval '5 seconds'),
        ('3568ddce-ad20-5d8e-9a12-70c2512dea41'::uuid, 'seed-kappa-087', 'debit', 653, 'Seed transaction #87 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":87,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '64 minutes', now() - interval '64 minutes' + interval '2 seconds', now() - interval '64 minutes' + interval '5 seconds'),
        ('f4ec0a74-d325-54b2-ba08-26c8dab89009'::uuid, 'seed-kappa-088', 'credit', 2218, 'Seed transaction #88 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":88,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '63 minutes', now() - interval '63 minutes' + interval '2 seconds', now() - interval '63 minutes' + interval '5 seconds'),
        ('5b9568eb-3275-50c4-9c05-73cb8e2cf90f'::uuid, 'seed-kappa-089', 'credit', 2349, 'Seed transaction #89 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":89,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '62 minutes', now() - interval '62 minutes' + interval '2 seconds', now() - interval '62 minutes' + interval '5 seconds'),
        ('91f6e980-2305-5b92-98be-8ec31390153e'::uuid, 'seed-kappa-090', 'debit', 117991, 'Seed transaction #90 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":90,"scenario":"insufficient_balance_debit","available_before":115961}'::jsonb, 'failed', 'INSUFFICIENT_BALANCE', 'Debit of 117991 exceeds available balance of 115961', now() - interval '61 minutes', now() - interval '61 minutes' + interval '2 seconds', now() - interval '61 minutes' + interval '5 seconds'),
        ('8db2debe-919f-509e-b0ef-37be11705f53'::uuid, 'seed-kappa-091', 'credit', 2611, 'Seed transaction #91 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":91,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '60 minutes', now() - interval '60 minutes' + interval '2 seconds', now() - interval '60 minutes' + interval '5 seconds'),
        ('28d63de0-1ed8-5b7a-b504-65a8e8718772'::uuid, 'seed-kappa-092', 'credit', 2742, 'Seed transaction #92 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":92,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '59 minutes', now() - interval '59 minutes' + interval '2 seconds', now() - interval '59 minutes' + interval '5 seconds'),
        ('c7263e53-1b6d-54f9-9a3d-444c4bfc90ee'::uuid, 'seed-kappa-093', 'debit', 1187, 'Seed transaction #93 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":93,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '58 minutes', now() - interval '58 minutes' + interval '2 seconds', now() - interval '58 minutes' + interval '5 seconds'),
        ('a619d07b-6257-52d0-8c81-e6bca1686751'::uuid, 'seed-kappa-094', 'credit', 3004, 'Seed transaction #94 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":94,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '57 minutes', now() - interval '57 minutes' + interval '2 seconds', now() - interval '57 minutes' + interval '5 seconds'),
        ('ad6c7f61-a585-5dbe-8fbb-3a778b5d935b'::uuid, 'seed-kappa-095', 'credit', 3135, 'Seed transaction #95 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":95,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '56 minutes', now() - interval '56 minutes' + interval '2 seconds', now() - interval '56 minutes' + interval '5 seconds'),
        ('e97d270b-e019-5c1e-9178-460c8a668479'::uuid, 'seed-kappa-096', 'debit', 1454, 'Seed transaction #96 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":96,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '55 minutes', now() - interval '55 minutes' + interval '2 seconds', now() - interval '55 minutes' + interval '5 seconds'),
        ('85b38ef3-715b-57c2-be8b-e80ba5d33c77'::uuid, 'seed-kappa-097', 'credit', 3397, 'Seed transaction #97 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":97,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '54 minutes', now() - interval '54 minutes' + interval '2 seconds', now() - interval '54 minutes' + interval '5 seconds'),
        ('1d55d336-eed8-5ef9-8184-26aa563c666e'::uuid, 'seed-kappa-098', 'credit', 3528, 'Seed transaction #98 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":98,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '53 minutes', now() - interval '53 minutes' + interval '2 seconds', now() - interval '53 minutes' + interval '5 seconds'),
        ('93aa4bb5-c910-5e42-b9cd-fff595fbccb9'::uuid, 'seed-kappa-099', 'debit', 1721, 'Seed transaction #99 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":99,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '52 minutes', now() - interval '52 minutes' + interval '2 seconds', now() - interval '52 minutes' + interval '5 seconds'),
        ('c2e59101-0e33-5f41-aeb0-532bc7750f9b'::uuid, 'seed-kappa-100', 'credit', 3790, 'Seed transaction #100 for tenant kappa', '{"seed":true,"tenant_code":"kappa","sequence":100,"scenario":"completed"}'::jsonb, 'completed', NULL, NULL, now() - interval '51 minutes', now() - interval '51 minutes' + interval '2 seconds', now() - interval '51 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000110.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('f9407436-44e4-5cc8-a073-784b8101a515'::uuid, 'seed-kappa-001', 1321, 0, 1321, now() - interval '150 minutes' + interval '5 seconds'),
        ('1383f3a5-7c6a-52f6-b92e-172e2c1ffa8f'::uuid, 'seed-kappa-003', -677, 1321, 644, now() - interval '148 minutes' + interval '5 seconds'),
        ('8dcd4281-3d64-5b3a-a361-86dc190e3aef'::uuid, 'seed-kappa-004', 1714, 644, 2358, now() - interval '147 minutes' + interval '5 seconds'),
        ('644b57fe-711b-55f0-a18f-048e8b441b62'::uuid, 'seed-kappa-005', 1845, 2358, 4203, now() - interval '146 minutes' + interval '5 seconds'),
        ('e4036f1c-3d10-521c-9475-c73a6c63c654'::uuid, 'seed-kappa-006', -944, 4203, 3259, now() - interval '145 minutes' + interval '5 seconds'),
        ('beca20b8-1bd2-5794-993a-bb2fd8c3af24'::uuid, 'seed-kappa-008', 2238, 3259, 5497, now() - interval '143 minutes' + interval '5 seconds'),
        ('767307d6-9536-5187-9890-fb69e95f85be'::uuid, 'seed-kappa-009', -1211, 5497, 4286, now() - interval '142 minutes' + interval '5 seconds'),
        ('35baaded-dd1b-521d-828c-6d35231f076b'::uuid, 'seed-kappa-011', 2631, 4286, 6917, now() - interval '140 minutes' + interval '5 seconds'),
        ('2e2a3320-ee97-52f4-83d5-423d6a6102ee'::uuid, 'seed-kappa-012', -1478, 6917, 5439, now() - interval '139 minutes' + interval '5 seconds'),
        ('3adcf44e-50a5-52c7-bf58-7d6efc245071'::uuid, 'seed-kappa-013', 2893, 5439, 8332, now() - interval '138 minutes' + interval '5 seconds'),
        ('69061380-43e7-5006-b673-7e87cae5bdfd'::uuid, 'seed-kappa-014', 3024, 8332, 11356, now() - interval '137 minutes' + interval '5 seconds'),
        ('06127562-5960-599f-9b4f-df581af78be4'::uuid, 'seed-kappa-016', 3286, 11356, 14642, now() - interval '135 minutes' + interval '5 seconds'),
        ('74737492-8dcb-5fb3-968c-65359e3a26a0'::uuid, 'seed-kappa-017', 3417, 14642, 18059, now() - interval '134 minutes' + interval '5 seconds'),
        ('a626b941-da24-51bb-a808-8f048215d043'::uuid, 'seed-kappa-018', -512, 18059, 17547, now() - interval '133 minutes' + interval '5 seconds'),
        ('4073b540-1a5b-5b7e-8859-501037969bc2'::uuid, 'seed-kappa-019', 3679, 17547, 21226, now() - interval '132 minutes' + interval '5 seconds'),
        ('43364b99-ecdc-5586-a8bd-ed1a0b830503'::uuid, 'seed-kappa-020', 3810, 21226, 25036, now() - interval '131 minutes' + interval '5 seconds'),
        ('e192496b-4fac-5d87-ae6e-6b6e6d4fa05f'::uuid, 'seed-kappa-021', -779, 25036, 24257, now() - interval '130 minutes' + interval '5 seconds'),
        ('d36d5230-b68f-5663-8878-97e9f33eda04'::uuid, 'seed-kappa-022', 4072, 24257, 28329, now() - interval '129 minutes' + interval '5 seconds'),
        ('2f2d8b8b-2b02-52d7-a79e-2b3d5acb0e1c'::uuid, 'seed-kappa-023', 4203, 28329, 32532, now() - interval '128 minutes' + interval '5 seconds'),
        ('100f212e-1852-5cce-807a-ce4b51d93d99'::uuid, 'seed-kappa-024', -1046, 32532, 31486, now() - interval '127 minutes' + interval '5 seconds'),
        ('c86928be-918b-53a5-be14-10b0940829f9'::uuid, 'seed-kappa-026', 1096, 31486, 32582, now() - interval '125 minutes' + interval '5 seconds'),
        ('59872776-e12a-5bca-82e5-8feb3481c628'::uuid, 'seed-kappa-027', -1313, 32582, 31269, now() - interval '124 minutes' + interval '5 seconds'),
        ('efdcbdbf-81fa-5e77-b23d-efbf6fad64e6'::uuid, 'seed-kappa-028', 1358, 31269, 32627, now() - interval '123 minutes' + interval '5 seconds'),
        ('579e096f-dbf6-5703-a4bb-b62a095fbcf3'::uuid, 'seed-kappa-029', 1489, 32627, 34116, now() - interval '122 minutes' + interval '5 seconds'),
        ('8a0af642-2c0d-5d82-83b8-f7dd2050c07d'::uuid, 'seed-kappa-031', 1751, 34116, 35867, now() - interval '120 minutes' + interval '5 seconds'),
        ('57161f7b-a380-5092-bc91-541a6dd9c60e'::uuid, 'seed-kappa-032', 1882, 35867, 37749, now() - interval '119 minutes' + interval '5 seconds'),
        ('706b2a9c-d00a-5aa0-9b28-a2a4caebe36d'::uuid, 'seed-kappa-033', -347, 37749, 37402, now() - interval '118 minutes' + interval '5 seconds'),
        ('3c009708-bea3-5bf8-99b1-663c3ac211f4'::uuid, 'seed-kappa-034', 2144, 37402, 39546, now() - interval '117 minutes' + interval '5 seconds'),
        ('778c29df-8827-52d8-a7bd-736da1897b83'::uuid, 'seed-kappa-035', 2275, 39546, 41821, now() - interval '116 minutes' + interval '5 seconds'),
        ('77446cef-11b8-5332-a674-97908afe8ea4'::uuid, 'seed-kappa-036', -614, 41821, 41207, now() - interval '115 minutes' + interval '5 seconds'),
        ('d5a96ecd-4148-55c6-baed-a93c83eb52d8'::uuid, 'seed-kappa-037', 2537, 41207, 43744, now() - interval '114 minutes' + interval '5 seconds'),
        ('50491a03-670e-5505-b265-ab326acd606e'::uuid, 'seed-kappa-038', 2668, 43744, 46412, now() - interval '113 minutes' + interval '5 seconds'),
        ('6c231a95-bc1b-5d7d-97c7-513c05a4a7cb'::uuid, 'seed-kappa-039', -881, 46412, 45531, now() - interval '112 minutes' + interval '5 seconds'),
        ('ca9b2e9b-93a4-583e-9a70-238aeed37668'::uuid, 'seed-kappa-040', 2930, 45531, 48461, now() - interval '111 minutes' + interval '5 seconds'),
        ('ce3451d0-017f-5e36-9bf1-66b70e288480'::uuid, 'seed-kappa-041', 3061, 48461, 51522, now() - interval '110 minutes' + interval '5 seconds'),
        ('f254f9c6-dacf-5ee4-b370-8111e7c1e03b'::uuid, 'seed-kappa-042', -1148, 51522, 50374, now() - interval '109 minutes' + interval '5 seconds'),
        ('6ff5116a-509a-53fa-9b31-340058099736'::uuid, 'seed-kappa-043', 3323, 50374, 53697, now() - interval '108 minutes' + interval '5 seconds'),
        ('2ed22a10-f86b-5d99-96b4-e3b73fb9d3d4'::uuid, 'seed-kappa-044', 3454, 53697, 57151, now() - interval '107 minutes' + interval '5 seconds'),
        ('049ee93a-ecf0-5650-9945-e5b27a3f6ba8'::uuid, 'seed-kappa-045', -1415, 57151, 55736, now() - interval '106 minutes' + interval '5 seconds'),
        ('c3c0ddab-320f-5409-bf51-f18129a55a6e'::uuid, 'seed-kappa-046', 3716, 55736, 59452, now() - interval '105 minutes' + interval '5 seconds'),
        ('ff54a391-52b0-59ca-84fe-6718d72bb8f8'::uuid, 'seed-kappa-047', 3847, 59452, 63299, now() - interval '104 minutes' + interval '5 seconds'),
        ('e872b4a1-1972-558e-8fe7-914513a18a92'::uuid, 'seed-kappa-048', -1682, 63299, 61617, now() - interval '103 minutes' + interval '5 seconds'),
        ('68515b3b-a47f-5adb-b5ad-9f4b6e068c66'::uuid, 'seed-kappa-049', 4109, 61617, 65726, now() - interval '102 minutes' + interval '5 seconds'),
        ('e471cf78-231a-58ba-bad9-2b4638a85d7a'::uuid, 'seed-kappa-051', -449, 65726, 65277, now() - interval '100 minutes' + interval '5 seconds'),
        ('6f3561d1-b9c7-51cf-b685-e49783856755'::uuid, 'seed-kappa-052', 1002, 65277, 66279, now() - interval '99 minutes' + interval '5 seconds'),
        ('8007d40a-5f91-54ca-8a3c-3dd201c4c148'::uuid, 'seed-kappa-053', 1133, 66279, 67412, now() - interval '98 minutes' + interval '5 seconds'),
        ('b5b6378c-8a80-5657-a900-4478c6eeade2'::uuid, 'seed-kappa-054', -716, 67412, 66696, now() - interval '97 minutes' + interval '5 seconds'),
        ('ee98a093-fb6b-598f-ba22-f82b35adbb87'::uuid, 'seed-kappa-055', 1395, 66696, 68091, now() - interval '96 minutes' + interval '5 seconds'),
        ('6fd0b4fd-3494-5d8f-9eeb-107406e5c811'::uuid, 'seed-kappa-056', 1526, 68091, 69617, now() - interval '95 minutes' + interval '5 seconds'),
        ('7e0e3baa-dd7d-5a97-9d44-b52f042e33d5'::uuid, 'seed-kappa-057', -983, 69617, 68634, now() - interval '94 minutes' + interval '5 seconds'),
        ('55b84ed6-7b2b-5ebc-a7ea-a19ce1acc5f3'::uuid, 'seed-kappa-058', 1788, 68634, 70422, now() - interval '93 minutes' + interval '5 seconds'),
        ('bfe7db58-65ec-5a2e-9ca1-35b76d231485'::uuid, 'seed-kappa-059', 1919, 70422, 72341, now() - interval '92 minutes' + interval '5 seconds'),
        ('b14d266a-5508-502f-9a00-5485548563a0'::uuid, 'seed-kappa-061', 2181, 72341, 74522, now() - interval '90 minutes' + interval '5 seconds'),
        ('b073f0c9-e580-5fd8-9e9d-cf6999a7d4c5'::uuid, 'seed-kappa-062', 2312, 74522, 76834, now() - interval '89 minutes' + interval '5 seconds'),
        ('987b8db0-6c42-595b-8f37-fe2bff8bd794'::uuid, 'seed-kappa-063', -1517, 76834, 75317, now() - interval '88 minutes' + interval '5 seconds'),
        ('569af025-26ff-5304-910e-049fda880826'::uuid, 'seed-kappa-064', 2574, 75317, 77891, now() - interval '87 minutes' + interval '5 seconds'),
        ('6767a873-0d33-5af0-92ad-b86196d5fd0b'::uuid, 'seed-kappa-065', 2705, 77891, 80596, now() - interval '86 minutes' + interval '5 seconds'),
        ('2508600a-11bd-5ece-8a15-d50af611c2e4'::uuid, 'seed-kappa-066', -1784, 80596, 78812, now() - interval '85 minutes' + interval '5 seconds'),
        ('8e3b9089-220c-5afd-bba3-fa3a31c8d19e'::uuid, 'seed-kappa-067', 2967, 78812, 81779, now() - interval '84 minutes' + interval '5 seconds'),
        ('39e86a51-f77b-5dfd-8913-012f435f3811'::uuid, 'seed-kappa-068', 3098, 81779, 84877, now() - interval '83 minutes' + interval '5 seconds'),
        ('b3f2bf7e-9268-5001-b1f4-ae841027819b'::uuid, 'seed-kappa-069', -551, 84877, 84326, now() - interval '82 minutes' + interval '5 seconds'),
        ('84373fd1-f2fe-5c51-8ed9-4ac8a01851e7'::uuid, 'seed-kappa-070', 3360, 84326, 87686, now() - interval '81 minutes' + interval '5 seconds'),
        ('e49ce7eb-a188-5395-a7d9-f848adb6ab38'::uuid, 'seed-kappa-071', 3491, 87686, 91177, now() - interval '80 minutes' + interval '5 seconds'),
        ('0c57e037-92b6-559e-af4d-ce879b561c24'::uuid, 'seed-kappa-072', -818, 91177, 90359, now() - interval '79 minutes' + interval '5 seconds'),
        ('c847d819-cfad-5e15-88dc-e14477a90752'::uuid, 'seed-kappa-073', 3753, 90359, 94112, now() - interval '78 minutes' + interval '5 seconds'),
        ('05cd07be-c459-58b7-b06b-908095e7a7ac'::uuid, 'seed-kappa-074', 3884, 94112, 97996, now() - interval '77 minutes' + interval '5 seconds'),
        ('375e6ebb-6663-5ec1-b4ee-230326f0ae49'::uuid, 'seed-kappa-076', 4146, 97996, 102142, now() - interval '75 minutes' + interval '5 seconds'),
        ('8801b11c-7e5b-5b54-a8cf-5a659251754b'::uuid, 'seed-kappa-077', 4277, 102142, 106419, now() - interval '74 minutes' + interval '5 seconds'),
        ('f954fb81-a0ff-5191-9655-a5b491f4bbc4'::uuid, 'seed-kappa-078', -1352, 106419, 105067, now() - interval '73 minutes' + interval '5 seconds'),
        ('b490ab25-7f7c-5962-a728-a556d7150a7f'::uuid, 'seed-kappa-079', 1039, 105067, 106106, now() - interval '72 minutes' + interval '5 seconds'),
        ('58b6d334-efa2-50af-9576-2c3e87919568'::uuid, 'seed-kappa-080', 1170, 106106, 107276, now() - interval '71 minutes' + interval '5 seconds'),
        ('aefb7337-d886-543a-8f51-79856536483c'::uuid, 'seed-kappa-081', -1619, 107276, 105657, now() - interval '70 minutes' + interval '5 seconds'),
        ('8de4315c-0253-50fe-80cb-e56c1fc469c2'::uuid, 'seed-kappa-082', 1432, 105657, 107089, now() - interval '69 minutes' + interval '5 seconds'),
        ('dfb4a7d4-d335-5787-b3ea-03e84491aa14'::uuid, 'seed-kappa-083', 1563, 107089, 108652, now() - interval '68 minutes' + interval '5 seconds'),
        ('434d9248-c0c8-5ee7-8feb-34eb38edaed7'::uuid, 'seed-kappa-084', -386, 108652, 108266, now() - interval '67 minutes' + interval '5 seconds'),
        ('e855277e-f2ca-56d3-97ad-9f2d208b3fee'::uuid, 'seed-kappa-085', 1825, 108266, 110091, now() - interval '66 minutes' + interval '5 seconds'),
        ('792efdbb-6949-536a-a098-1fdf77307fa1'::uuid, 'seed-kappa-086', 1956, 110091, 112047, now() - interval '65 minutes' + interval '5 seconds'),
        ('3568ddce-ad20-5d8e-9a12-70c2512dea41'::uuid, 'seed-kappa-087', -653, 112047, 111394, now() - interval '64 minutes' + interval '5 seconds'),
        ('f4ec0a74-d325-54b2-ba08-26c8dab89009'::uuid, 'seed-kappa-088', 2218, 111394, 113612, now() - interval '63 minutes' + interval '5 seconds'),
        ('5b9568eb-3275-50c4-9c05-73cb8e2cf90f'::uuid, 'seed-kappa-089', 2349, 113612, 115961, now() - interval '62 minutes' + interval '5 seconds'),
        ('8db2debe-919f-509e-b0ef-37be11705f53'::uuid, 'seed-kappa-091', 2611, 115961, 118572, now() - interval '60 minutes' + interval '5 seconds'),
        ('28d63de0-1ed8-5b7a-b504-65a8e8718772'::uuid, 'seed-kappa-092', 2742, 118572, 121314, now() - interval '59 minutes' + interval '5 seconds'),
        ('c7263e53-1b6d-54f9-9a3d-444c4bfc90ee'::uuid, 'seed-kappa-093', -1187, 121314, 120127, now() - interval '58 minutes' + interval '5 seconds'),
        ('a619d07b-6257-52d0-8c81-e6bca1686751'::uuid, 'seed-kappa-094', 3004, 120127, 123131, now() - interval '57 minutes' + interval '5 seconds'),
        ('ad6c7f61-a585-5dbe-8fbb-3a778b5d935b'::uuid, 'seed-kappa-095', 3135, 123131, 126266, now() - interval '56 minutes' + interval '5 seconds'),
        ('e97d270b-e019-5c1e-9178-460c8a668479'::uuid, 'seed-kappa-096', -1454, 126266, 124812, now() - interval '55 minutes' + interval '5 seconds'),
        ('85b38ef3-715b-57c2-be8b-e80ba5d33c77'::uuid, 'seed-kappa-097', 3397, 124812, 128209, now() - interval '54 minutes' + interval '5 seconds'),
        ('1d55d336-eed8-5ef9-8184-26aa563c666e'::uuid, 'seed-kappa-098', 3528, 128209, 131737, now() - interval '53 minutes' + interval '5 seconds'),
        ('93aa4bb5-c910-5e42-b9cd-fff595fbccb9'::uuid, 'seed-kappa-099', -1721, 131737, 130016, now() - interval '52 minutes' + interval '5 seconds'),
        ('c2e59101-0e33-5f41-aeb0-532bc7750f9b'::uuid, 'seed-kappa-100', 3790, 130016, 133806, now() - interval '51 minutes' + interval '5 seconds');

INSERT INTO tenant_00000000000000000000000000000110.ledger_entries (
    transaction_id, reference, change_amount, previous_balance, new_balance, created_at
)
VALUES
        ('5e84a30a-5ef8-53d1-a46f-2acfa5df3757'::uuid, 'seed-kappa-010', 1470, 133806, 135276, now()),
        ('77befda6-0a4e-5834-b919-25a1fb2e69b8'::uuid, 'seed-kappa-025', -525, 135276, 134751, now() + interval '1 second'),
        ('b4486763-9ff7-5e5c-b004-5941f6db089d'::uuid, 'seed-kappa-050', 550, 134751, 135301, now() + interval '2 seconds'),
        ('4bbbeb63-13db-5b0a-8427-bba8301fc08f'::uuid, 'seed-kappa-075', -575, 135301, 134726, now() + interval '3 seconds');

UPDATE tenant_00000000000000000000000000000110.balances SET balance = 134726, updated_at = now() WHERE id = 1;

COMMIT;
