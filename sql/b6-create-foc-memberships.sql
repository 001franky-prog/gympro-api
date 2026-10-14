\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run this migration in gympro_saas as postgres.';
    END IF;

    IF to_regclass('app.member_subscriptions') IS NULL THEN
        RAISE EXCEPTION 'Required subscription table is missing.';
    END IF;

    IF to_regclass('app.subscription_foc_grants') IS NOT NULL
       OR EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'app'
             AND table_name = 'member_subscriptions'
             AND column_name = 'membership_kind'
       ) THEN
        RAISE EXCEPTION 'FOC schema already exists. Inspect before retrying.';
    END IF;
END;
$$;

ALTER TABLE app.member_subscriptions
    ADD COLUMN membership_kind varchar(20)
    NOT NULL DEFAULT 'standard';

ALTER TABLE app.member_subscriptions
    ADD CONSTRAINT chk_member_subscriptions_kind
    CHECK (membership_kind IN ('standard', 'foc'));

ALTER TABLE app.member_subscriptions
    ADD CONSTRAINT chk_member_subscriptions_foc_price
    CHECK (
        membership_kind <> 'foc'
        OR agreed_price_amount = 0
    );

CREATE TABLE app.subscription_foc_grants (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,

    reason varchar(500) NOT NULL,

    -- Listed price when complimentary membership was granted.
    listed_price_amount numeric(14, 2) NOT NULL,
    currency_code varchar(3) NOT NULL DEFAULT 'MMK',

    previous_member_snapshot jsonb NOT NULL,

    granted_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_subscription_foc_grants_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_subscription_foc_grants_request
        UNIQUE (tenant_id, request_id),

    CONSTRAINT uq_subscription_foc_grants_subscription
        UNIQUE (tenant_id, subscription_id),

    CONSTRAINT fk_subscription_foc_grants_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_subscription_foc_grants_subscription
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES app.member_subscriptions (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_subscription_foc_grants_reason
        CHECK (
            reason = btrim(reason)
            AND length(reason) BETWEEN 2 AND 500
            AND reason ~ '[^[:space:]]'
        ),

    CONSTRAINT chk_subscription_foc_grants_listed_price
        CHECK (
            listed_price_amount >= 0
            AND listed_price_amount < 1000000000000
        ),

    CONSTRAINT chk_subscription_foc_grants_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_subscription_foc_grants_snapshot
        CHECK (
            jsonb_typeof(previous_member_snapshot) = 'object'
            AND previous_member_snapshot <> '{}'::jsonb
        ),

    CONSTRAINT chk_subscription_foc_grants_timestamp
        CHECK (isfinite(granted_at))
);

CREATE INDEX idx_subscription_foc_grants_created
    ON app.subscription_foc_grants (
        tenant_id,
        granted_at DESC
    );

ALTER TABLE app.subscription_foc_grants
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.subscription_foc_grants
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.subscription_foc_grants
    FROM PUBLIC, gympro_app;

INSERT INTO app.permissions (
    module_code,
    resource_code,
    action_code,
    description,
    is_active
)
VALUES (
    'gym',
    'memberships',
    'grant_foc',
    'Grant complimentary membership with a required reason and audit history.',
    true
)
ON CONFLICT (permission_code) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.memberships.grant_foc'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Dedicated FOC permission is not active.';
    END IF;
END;
$$;

COMMIT;

SELECT
    'foc_history_rls_enabled' AS check_name,
    c.relrowsecurity::text AS result
FROM pg_class AS c
WHERE c.oid = 'app.subscription_foc_grants'::regclass

UNION ALL

SELECT
    'foc_history_rls_forced',
    c.relforcerowsecurity::text
FROM pg_class AS c
WHERE c.oid = 'app.subscription_foc_grants'::regclass

UNION ALL

SELECT
    'runtime_has_direct_foc_history_access',
    (
        has_table_privilege(
            'gympro_app', 'app.subscription_foc_grants', 'SELECT'
        )
        OR has_table_privilege(
            'gympro_app', 'app.subscription_foc_grants', 'INSERT'
        )
        OR has_table_privilege(
            'gympro_app', 'app.subscription_foc_grants', 'UPDATE'
        )
        OR has_table_privilege(
            'gympro_app', 'app.subscription_foc_grants', 'DELETE'
        )
    )::text

UNION ALL

SELECT
    'active_foc_permission',
    is_active::text
FROM app.permissions
WHERE permission_code = 'gym.memberships.grant_foc'

UNION ALL

SELECT
    'existing_subscriptions_remain_standard',
    COALESCE(bool_and(membership_kind = 'standard'), true)::text
FROM app.member_subscriptions;