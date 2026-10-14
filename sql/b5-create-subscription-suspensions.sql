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

    IF to_regclass('app.subscription_suspensions') IS NOT NULL THEN
        RAISE EXCEPTION
            'subscription_suspensions already exists. Inspect before retrying.';
    END IF;
END;
$$;

CREATE TABLE app.subscription_suspensions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,

    reason varchar(500) NOT NULL,
    suspended_at timestamptz NOT NULL DEFAULT statement_timestamp(),

    previous_subscription_snapshot jsonb NOT NULL,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_subscription_suspensions_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_subscription_suspensions_request
        UNIQUE (tenant_id, request_id),

    CONSTRAINT fk_subscription_suspensions_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_suspensions_subscription
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES app.member_subscriptions (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_subscription_suspensions_reason
        CHECK (
            reason = btrim(reason)
            AND length(reason) BETWEEN 2 AND 500
            AND reason ~ '[^[:space:]]'
        ),

    CONSTRAINT chk_subscription_suspensions_timestamp
        CHECK (isfinite(suspended_at)),

    CONSTRAINT chk_subscription_suspensions_snapshot
        CHECK (
            jsonb_typeof(previous_subscription_snapshot) = 'object'
            AND previous_subscription_snapshot <> '{}'::jsonb
        )
);

CREATE INDEX idx_subscription_suspensions_subscription
    ON app.subscription_suspensions (
        tenant_id,
        subscription_id,
        suspended_at DESC
    );

ALTER TABLE app.subscription_suspensions
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.subscription_suspensions
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.subscription_suspensions
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
  AND c.relname = 'subscription_suspensions';

SELECT
    has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'DELETE'
    ) AS runtime_can_delete;