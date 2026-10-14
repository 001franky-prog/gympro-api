\set ON_ERROR_STOP on
\connect gympro_saas postgres

BEGIN;

-- Check the database and required tables before making changes.
DO $$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'Wrong database. Expected gympro_saas, connected to %.',
            current_database();
    END IF;

    IF to_regclass('app.tenants') IS NULL THEN
        RAISE EXCEPTION
            'Required table app.tenants is missing. Stop and check the earlier database setup.';
    END IF;

    IF to_regclass('app.branches') IS NULL THEN
        RAISE EXCEPTION
            'Required table app.branches is missing. Stop and check the earlier database setup.';
    END IF;

    IF to_regclass('app.members') IS NOT NULL THEN
        RAISE EXCEPTION
            'app.members already exists. Stop and inspect it before continuing.';
    END IF;
END
$$;

CREATE SEQUENCE IF NOT EXISTS app.member_number_seq
    AS BIGINT
    START WITH 1
    INCREMENT BY 1;

CREATE TABLE app.members (
    id UUID NOT NULL DEFAULT gen_random_uuid(),

    tenant_id UUID NOT NULL,
    branch_id UUID,

    member_number TEXT NOT NULL DEFAULT (
        'GP-' ||
        LPAD(
            NEXTVAL('app.member_number_seq'::regclass)::TEXT,
            8,
            '0'
        )
    ),

    full_name TEXT NOT NULL,
    phone TEXT,
    email TEXT,

    status TEXT NOT NULL DEFAULT 'pending',

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT members_pk
        PRIMARY KEY (id),

    CONSTRAINT members_tenant_fk
        FOREIGN KEY (tenant_id)
        REFERENCES app.tenants (id),

    CONSTRAINT members_branch_tenant_fk
        FOREIGN KEY (tenant_id, branch_id)
        REFERENCES app.branches (tenant_id, id),

    CONSTRAINT members_tenant_member_number_uk
        UNIQUE (tenant_id, member_number),

    CONSTRAINT members_full_name_ck
        CHECK (BTRIM(full_name) <> ''),

    CONSTRAINT members_contact_required_ck
        CHECK (
            NULLIF(BTRIM(phone), '') IS NOT NULL
            OR NULLIF(BTRIM(email), '') IS NOT NULL
        ),

    CONSTRAINT members_status_ck
        CHECK (
            status IN (
                'pending',
                'active',
                'inactive',
                'blacklisted'
            )
        )
);

CREATE INDEX members_tenant_idx
    ON app.members (tenant_id);

CREATE INDEX members_branch_idx
    ON app.members (tenant_id, branch_id);

CREATE INDEX members_status_idx
    ON app.members (tenant_id, status);

ALTER TABLE app.members ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.members FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE app.members FROM PUBLIC;
REVOKE ALL ON SEQUENCE app.member_number_seq FROM PUBLIC;

COMMIT;

-- Confirm the database and RLS settings.
SELECT
    current_database() AS database_name,
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'members';

-- Confirm the columns.
SELECT
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'app'
  AND table_name = 'members'
ORDER BY ordinal_position;

-- Confirm the constraints.
SELECT
    conname AS constraint_name,
    pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'app.members'::regclass
ORDER BY conname;