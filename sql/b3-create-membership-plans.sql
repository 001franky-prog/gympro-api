\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

BEGIN;

-- Check prerequisites before creating the tables.
DO $$
BEGIN
    IF to_regclass('platform.tenants') IS NULL THEN
        RAISE EXCEPTION 'Required table platform.tenants is missing.';
    END IF;

    IF to_regclass('app.branches') IS NULL THEN
        RAISE EXCEPTION 'Required table app.branches is missing.';
    END IF;

    IF to_regclass('app.membership_plans') IS NOT NULL
       OR to_regclass('app.plan_prices') IS NOT NULL THEN
        RAISE EXCEPTION
            'A B3 table already exists. Inspect the existing structure before continuing.';
    END IF;
END
$$;

-- Membership plan definitions.
CREATE TABLE app.membership_plans (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,

    plan_code VARCHAR(32) NOT NULL,
    plan_name VARCHAR(150) NOT NULL,
    description TEXT,
    terms_and_conditions TEXT,

    duration_value INTEGER NOT NULL,
    duration_unit VARCHAR(10) NOT NULL,

    status VARCHAR(20) NOT NULL DEFAULT 'draft',

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT membership_plans_pkey
        PRIMARY KEY (id),

    CONSTRAINT uq_membership_plans_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_membership_plans_tenant_code
        UNIQUE (tenant_id, plan_code),

    CONSTRAINT fk_membership_plans_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_membership_plans_code
        CHECK (
            plan_code = BTRIM(plan_code)
            AND LENGTH(plan_code) > 0
        ),

    CONSTRAINT chk_membership_plans_name
        CHECK (LENGTH(BTRIM(plan_name)) BETWEEN 2 AND 150),

    CONSTRAINT chk_membership_plans_duration_value
        CHECK (duration_value > 0),

    CONSTRAINT chk_membership_plans_duration_unit
        CHECK (
            duration_unit IN ('days', 'weeks', 'months', 'years')
        ),

    CONSTRAINT chk_membership_plans_status
        CHECK (status IN ('draft', 'active', 'inactive'))
);

CREATE INDEX idx_membership_plans_tenant_status
    ON app.membership_plans (tenant_id, status);

-- Prices are stored separately from plan definitions.
-- NULL branch_id means the price applies across the tenant.
-- A branch-specific price can override that general price.
CREATE TABLE app.plan_prices (
    id UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    plan_id UUID NOT NULL,
    branch_id UUID,

    price_amount NUMERIC(14, 2) NOT NULL,
    currency_code VARCHAR(3) NOT NULL DEFAULT 'MMK',

    status VARCHAR(20) NOT NULL DEFAULT 'inactive',

    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT plan_prices_pkey
        PRIMARY KEY (id),

    CONSTRAINT uq_plan_prices_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT fk_plan_prices_plan
        FOREIGN KEY (tenant_id, plan_id)
        REFERENCES app.membership_plans (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_plan_prices_branch
        FOREIGN KEY (tenant_id, branch_id)
        REFERENCES app.branches (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_plan_prices_amount
        CHECK (price_amount >= 0),

    CONSTRAINT chk_plan_prices_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_plan_prices_status
        CHECK (status IN ('active', 'inactive'))
);

-- Allow one active general price per plan.
CREATE UNIQUE INDEX uq_plan_prices_active_general
    ON app.plan_prices (tenant_id, plan_id)
    WHERE branch_id IS NULL
      AND status = 'active';

-- Allow one active price per plan for each branch.
CREATE UNIQUE INDEX uq_plan_prices_active_branch
    ON app.plan_prices (tenant_id, plan_id, branch_id)
    WHERE branch_id IS NOT NULL
      AND status = 'active';

CREATE INDEX idx_plan_prices_tenant_plan
    ON app.plan_prices (tenant_id, plan_id);

CREATE INDEX idx_plan_prices_tenant_branch
    ON app.plan_prices (tenant_id, branch_id);

-- Enable the same RLS foundation used by app.members.
ALTER TABLE app.membership_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.membership_plans FORCE ROW LEVEL SECURITY;

ALTER TABLE app.plan_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.plan_prices FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE app.membership_plans FROM PUBLIC;
REVOKE ALL ON TABLE app.plan_prices FROM PUBLIC;

COMMIT;

-- Confirm that both tables exist with forced RLS.
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname IN ('membership_plans', 'plan_prices')
ORDER BY c.relname;