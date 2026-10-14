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

    IF to_regclass('app.member_subscriptions') IS NULL
       OR to_regclass('app.plan_prices') IS NULL THEN
        RAISE EXCEPTION 'Required earlier tables are missing.';
    END IF;

    IF to_regclass('app.subscription_renewals') IS NOT NULL THEN
        RAISE EXCEPTION
            'subscription_renewals already exists. Inspect before retrying.';
    END IF;
END;
$$;

CREATE TABLE app.subscription_renewals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,

    -- Supplied once per renewal operation.
    request_id uuid NOT NULL,

    plan_id uuid NOT NULL,
    plan_price_id uuid NOT NULL,

    previous_ends_on date NOT NULL,

    -- Coverage purchased by this renewal.
    -- renewal_ends_on is exclusive.
    renewal_starts_on date NOT NULL,
    renewal_ends_on date NOT NULL,

    duration_value integer NOT NULL,
    duration_unit varchar(10) NOT NULL,

    agreed_price_amount numeric(14, 2) NOT NULL,
    currency_code varchar(3) NOT NULL DEFAULT 'MMK',

    -- Server-generated copy of the subscription before renewal.
    previous_subscription_snapshot jsonb NOT NULL,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_subscription_renewals_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_subscription_renewals_request
        UNIQUE (tenant_id, request_id),

    CONSTRAINT fk_subscription_renewals_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_renewals_subscription
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES app.member_subscriptions (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_renewals_plan
        FOREIGN KEY (tenant_id, plan_id)
        REFERENCES app.membership_plans (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_renewals_price
        FOREIGN KEY (tenant_id, plan_id, plan_price_id)
        REFERENCES app.plan_prices (tenant_id, plan_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_subscription_renewals_dates
        CHECK (
            isfinite(previous_ends_on)
            AND isfinite(renewal_starts_on)
            AND isfinite(renewal_ends_on)
            AND renewal_starts_on >= previous_ends_on
            AND renewal_ends_on > renewal_starts_on
        ),

    CONSTRAINT chk_subscription_renewals_duration_value
        CHECK (duration_value > 0),

    CONSTRAINT chk_subscription_renewals_duration_unit
        CHECK (
            duration_unit IN ('days', 'weeks', 'months', 'years')
        ),

    CONSTRAINT chk_subscription_renewals_price
        CHECK (
            agreed_price_amount >= 0
            AND agreed_price_amount < 1000000000000
        ),

    CONSTRAINT chk_subscription_renewals_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_subscription_renewals_snapshot
        CHECK (
            jsonb_typeof(previous_subscription_snapshot) = 'object'
            AND previous_subscription_snapshot <> '{}'::jsonb
        )
);

CREATE INDEX idx_subscription_renewals_subscription
    ON app.subscription_renewals (
        tenant_id,
        subscription_id,
        created_at DESC
    );

CREATE INDEX idx_subscription_renewals_price
    ON app.subscription_renewals (
        tenant_id,
        plan_id,
        plan_price_id
    );

ALTER TABLE app.subscription_renewals
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.subscription_renewals
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.subscription_renewals
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
  AND c.relname = 'subscription_renewals';

SELECT
    has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'DELETE'
    ) AS runtime_can_delete;