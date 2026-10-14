\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Run this migration in gympro_saas as postgres.';
    END IF;

    IF to_regclass('app.member_subscriptions') IS NULL THEN
        RAISE EXCEPTION 'Required subscription table is missing.';
    END IF;

    IF to_regclass('app.subscription_expirations') IS NOT NULL THEN
        RAISE EXCEPTION
            'subscription_expirations already exists. Inspect before retrying.';
    END IF;
END;
$$;

CREATE TABLE app.subscription_expirations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,

    -- Identifies the coverage period that expired.
    coverage_starts_on date NOT NULL,
    coverage_ends_on date NOT NULL,

    -- Server-calculated Myanmar date when expiry was processed.
    processed_on date NOT NULL,

    expired_at timestamptz NOT NULL DEFAULT statement_timestamp(),

    previous_subscription_snapshot jsonb NOT NULL,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_subscription_expirations_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_subscription_expirations_period
        UNIQUE (
            tenant_id,
            subscription_id,
            coverage_starts_on,
            coverage_ends_on
        ),

    CONSTRAINT fk_subscription_expirations_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_expirations_subscription
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES app.member_subscriptions (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_subscription_expirations_dates
        CHECK (
            isfinite(coverage_starts_on)
            AND isfinite(coverage_ends_on)
            AND isfinite(processed_on)
            AND coverage_ends_on > coverage_starts_on
            AND processed_on >= coverage_ends_on
        ),

    CONSTRAINT chk_subscription_expirations_timestamp
        CHECK (isfinite(expired_at)),

    CONSTRAINT chk_subscription_expirations_snapshot
        CHECK (
            jsonb_typeof(previous_subscription_snapshot) = 'object'
            AND previous_subscription_snapshot <> '{}'::jsonb
        )
);

CREATE INDEX idx_subscription_expirations_subscription
    ON app.subscription_expirations (
        tenant_id,
        subscription_id,
        expired_at DESC
    );

ALTER TABLE app.subscription_expirations
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.subscription_expirations
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.subscription_expirations
    FROM PUBLIC, gympro_app;

COMMIT;

SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'subscription_expirations';

SELECT
    has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'DELETE'
    ) AS runtime_can_delete;