\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Wrong database.';
    END IF;

    IF to_regclass('app.membership_plans') IS NULL
       OR to_regclass('app.branches') IS NULL
       OR to_regclass('app.permissions') IS NULL THEN
        RAISE EXCEPTION 'Required earlier tables are missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'gympro_app'
    ) THEN
        RAISE EXCEPTION 'Runtime role gympro_app is missing.';
    END IF;

    IF to_regclass('app.membership_promotions') IS NOT NULL THEN
        RAISE EXCEPTION
            'Promotion table already exists. Inspect before rerunning.';
    END IF;
END;
$$;

CREATE TABLE app.membership_promotions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    promotion_code varchar(32) NOT NULL,
    promotion_name varchar(150) NOT NULL,
    description text,

    -- NULL means applicable across the tenant's plans or branches.
    plan_id uuid,
    branch_id uuid,

    discount_kind varchar(20) NOT NULL,
    discount_value numeric(14,2) NOT NULL,
    currency_code varchar(3) NOT NULL DEFAULT 'MMK',

    -- starts_on is inclusive; ends_on is exclusive.
    starts_on date NOT NULL,
    ends_on date,
    status varchar(20) NOT NULL DEFAULT 'draft',

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_membership_promotions_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_membership_promotions_tenant_code
        UNIQUE (tenant_id, promotion_code),

    CONSTRAINT fk_membership_promotions_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants(id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_membership_promotions_plan
        FOREIGN KEY (tenant_id, plan_id)
        REFERENCES app.membership_plans(tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_membership_promotions_branch
        FOREIGN KEY (tenant_id, branch_id)
        REFERENCES app.branches(tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_membership_promotions_code
        CHECK (
            promotion_code = btrim(promotion_code)
            AND promotion_code ~ '^[A-Z][A-Z0-9_]*$'
        ),

    CONSTRAINT chk_membership_promotions_name
        CHECK (
            length(btrim(promotion_name)) BETWEEN 2 AND 150
        ),

    CONSTRAINT chk_membership_promotions_discount
        CHECK (
            (
                discount_kind = 'percentage'
                AND discount_value > 0
                AND discount_value <= 100
            )
            OR
            (
                discount_kind = 'fixed_amount'
                AND discount_value > 0
                AND discount_value < 1000000000000
            )
        ),

    CONSTRAINT chk_membership_promotions_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_membership_promotions_dates
        CHECK (
            isfinite(starts_on)
            AND (
                ends_on IS NULL
                OR (
                    isfinite(ends_on)
                    AND ends_on > starts_on
                )
            )
        ),

    CONSTRAINT chk_membership_promotions_status
        CHECK (status IN ('draft', 'active', 'inactive'))
);

CREATE INDEX idx_membership_promotions_tenant_status
    ON app.membership_promotions(tenant_id, status);

CREATE INDEX idx_membership_promotions_tenant_plan
    ON app.membership_promotions(tenant_id, plan_id);

CREATE INDEX idx_membership_promotions_tenant_branch
    ON app.membership_promotions(tenant_id, branch_id);

ALTER TABLE app.membership_promotions ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.membership_promotions FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE app.membership_promotions FROM PUBLIC;
REVOKE ALL ON TABLE app.membership_promotions FROM gympro_app;

-- Register permissions without assigning them to any role.
INSERT INTO app.permissions (
    module_code,
    resource_code,
    action_code,
    description
)
VALUES
    (
        'gym',
        'promotions',
        'manage',
        'Create and manage tenant membership promotions'
    ),
    (
        'gym',
        'memberships',
        'apply_discount',
        'Apply an eligible promotion to a membership purchase'
    )
ON CONFLICT (permission_code) DO NOTHING;

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
  AND c.relname = 'membership_promotions';

SELECT permission_code, is_active
FROM app.permissions
WHERE permission_code IN (
    'gym.promotions.manage',
    'gym.memberships.apply_discount'
)
ORDER BY permission_code;
