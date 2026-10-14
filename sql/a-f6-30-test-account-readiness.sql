
-- ========================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.30
--
-- ISOLATED DEVELOPMENT LOGIN ACCOUNT READINESS
--
-- READ ONLY
-- No INSERT, UPDATE, DELETE, GRANT or REVOKE.
-- No password hashes or personal records returned.
-- ========================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Confirm database.

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- 2. Inspect required user and membership fields.

SELECT
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE (
    table_schema = 'app'
    AND table_name IN (
        'users',
        'tenant_memberships',
        'role_assignments'
    )
)
OR (
    table_schema = 'platform'
    AND table_name = 'tenants'
)
ORDER BY
    table_schema,
    table_name,
    ordinal_position;

-- 3. Inspect primary, unique, foreign-key
--    and check constraints.

SELECT
    ns.nspname AS schema_name,
    tbl.relname AS table_name,
    con.conname AS constraint_name,
    pg_catalog.pg_get_constraintdef(
        con.oid
    ) AS definition
FROM pg_catalog.pg_constraint AS con
JOIN pg_catalog.pg_class AS tbl
    ON tbl.oid = con.conrelid
JOIN pg_catalog.pg_namespace AS ns
    ON ns.oid = tbl.relnamespace
WHERE (
    ns.nspname = 'app'
    AND tbl.relname IN (
        'users',
        'tenant_memberships',
        'role_assignments'
    )
)
OR (
    ns.nspname = 'platform'
    AND tbl.relname = 'tenants'
)
ORDER BY
    ns.nspname,
    tbl.relname,
    con.conname;

-- 4. Count active tenants without exposing
--    tenant identities or names.

SELECT
    status,
    COUNT(*) AS tenant_count
FROM platform.tenants
GROUP BY status
ORDER BY status;

-- 5. Count user and membership statuses.

SELECT
    status,
    COUNT(*) AS user_count
FROM app.users
GROUP BY status
ORDER BY status;

SELECT
    status,
    COUNT(*) AS membership_count
FROM app.tenant_memberships
GROUP BY status
ORDER BY status;

-- 6. Confirm development fixture constraints
--    will not require enabling session persistence.

SELECT
    pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS session_function_granted,

    pg_catalog.has_table_privilege(
        'gympro_session',
        'security.tenant_sessions',
        'INSERT'
    ) AS direct_session_insert_granted;

-- 7. Report completion.

SELECT
    'A-F6.30 TEST ACCOUNT READINESS INSPECTED'
        AS result;

-- ========================================================
-- END OF STEP A-F6.30
-- ========================================================
