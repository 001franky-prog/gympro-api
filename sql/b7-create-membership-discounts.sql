\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF to_regclass('app.membership_promotions') IS NULL
       OR to_regclass('app.member_subscriptions') IS NULL
       OR to_regclass('app.subscription_renewals') IS NULL THEN
        RAISE EXCEPTION 'Required promotion or lifecycle tables are missing.';
    END IF;

    IF to_regclass('app.membership_discounts') IS NOT NULL THEN
        RAISE EXCEPTION
            'Discount history already exists. Inspect before rerunning.';
    END IF;
END;
$$;

ALTER TABLE app.subscription_renewals
    ADD CONSTRAINT uq_subscription_renewals_tenant_subscription_id
    UNIQUE (tenant_id, subscription_id, id);

CREATE TABLE app.membership_discounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    promotion_id uuid NOT NULL,
    request_id uuid NOT NULL,

    purchase_kind varchar(20) NOT NULL,
    renewal_id uuid,

    listed_price_amount numeric(14,2) NOT NULL,
    discount_amount numeric(14,2) NOT NULL,
    agreed_price_amount numeric(14,2) NOT NULL,
    currency_code varchar(3) NOT NULL DEFAULT 'MMK',

    promotion_snapshot jsonb NOT NULL,
    actor_snapshot jsonb NOT NULL,

    applied_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_membership_discounts_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_membership_discounts_tenant_request
        UNIQUE (tenant_id, request_id),

    CONSTRAINT fk_membership_discounts_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants(id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_membership_discounts_subscription
        FOREIGN KEY (tenant_id, subscription_id)
        REFERENCES app.member_subscriptions(tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_membership_discounts_promotion
        FOREIGN KEY (tenant_id, promotion_id)
        REFERENCES app.membership_promotions(tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_membership_discounts_renewal
        FOREIGN KEY (tenant_id, subscription_id, renewal_id)
        REFERENCES app.subscription_renewals(tenant_id, subscription_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_membership_discounts_purchase
        CHECK (
            (purchase_kind = 'activation' AND renewal_id IS NULL)
            OR
            (purchase_kind = 'renewal' AND renewal_id IS NOT NULL)
        ),

    CONSTRAINT chk_membership_discounts_amounts
        CHECK (
            listed_price_amount >= 0
            AND listed_price_amount < 1000000000000
            AND discount_amount >= 0
            AND discount_amount <= listed_price_amount
            AND agreed_price_amount >= 0
            AND agreed_price_amount < 1000000000000
            AND agreed_price_amount =
                listed_price_amount - discount_amount
        ),

    CONSTRAINT chk_membership_discounts_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_membership_discounts_promotion_snapshot
        CHECK (
            jsonb_typeof(promotion_snapshot) = 'object'
            AND promotion_snapshot <> '{}'::jsonb
        ),

    CONSTRAINT chk_membership_discounts_actor_snapshot
        CHECK (
            jsonb_typeof(actor_snapshot) = 'object'
            AND actor_snapshot <> '{}'::jsonb
        ),

    CONSTRAINT chk_membership_discounts_timestamps
        CHECK (
            isfinite(applied_at)
            AND isfinite(created_at)
        )
);

CREATE UNIQUE INDEX uq_membership_discounts_activation
    ON app.membership_discounts(tenant_id, subscription_id)
    WHERE purchase_kind = 'activation';

CREATE UNIQUE INDEX uq_membership_discounts_renewal
    ON app.membership_discounts(renewal_id)
    WHERE purchase_kind = 'renewal';

CREATE INDEX idx_membership_discounts_tenant_promotion
    ON app.membership_discounts(tenant_id, promotion_id);

CREATE INDEX idx_membership_discounts_tenant_subscription
    ON app.membership_discounts(tenant_id, subscription_id);

ALTER TABLE app.membership_discounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.membership_discounts FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE app.membership_discounts FROM PUBLIC;
REVOKE ALL ON TABLE app.membership_discounts FROM gympro_app;

COMMIT;

SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    has_table_privilege(
        'gympro_app', c.oid, 'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app', c.oid, 'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app', c.oid, 'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app', c.oid, 'DELETE'
    ) AS runtime_can_delete
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'membership_discounts';