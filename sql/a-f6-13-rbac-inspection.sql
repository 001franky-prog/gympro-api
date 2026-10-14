
-- ========================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.13
-- RBAC DATABASE STRUCTURE INSPECTION
--
-- READ ONLY
-- NO SCHEMA OR DATA MODIFICATIONS
-- ========================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Verify database connection

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- 2. Discover authorization-related tables

SELECT
    table_schema,
    table_name
FROM information_schema.tables
WHERE table_schema IN (
    'app',
    'platform',
    'security'
)
AND table_type = 'BASE TABLE'
AND (
    table_name ILIKE '%role%'
    OR table_name ILIKE '%permission%'
    OR table_name ILIKE '%membership%'
    OR table_name ILIKE '%branch%'
    OR table_name ILIKE '%staff%'
    OR table_name ILIKE '%access%'
)
ORDER BY
    table_schema,
    table_name;

-- 3. Inspect columns and data types

SELECT
    table_schema,
    table_name,
    ordinal_position,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema IN (
    'app',
    'platform',
    'security'
)
AND (
    table_name ILIKE '%role%'
    OR table_name ILIKE '%permission%'
    OR table_name ILIKE '%membership%'
    OR table_name ILIKE '%branch%'
    OR table_name ILIKE '%staff%'
    OR table_name ILIKE '%access%'
)
ORDER BY
    table_schema,
    table_name,
    ordinal_position;

-- 4. Inspect existing foreign-key relationships

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
WHERE con.contype = 'f'
  AND ns.nspname IN (
      'app',
      'platform',
      'security'
  )
  AND (
      tbl.relname ILIKE '%role%'
      OR tbl.relname ILIKE '%permission%'
      OR tbl.relname ILIKE '%membership%'
      OR tbl.relname ILIKE '%branch%'
      OR tbl.relname ILIKE '%staff%'
      OR tbl.relname ILIKE '%access%'
  )
ORDER BY
    ns.nspname,
    tbl.relname,
    con.conname;

-- 5. Discover authorization-related functions

SELECT
    ns.nspname AS schema_name,
    p.proname AS function_name,
    pg_catalog.pg_get_function_identity_arguments(
        p.oid
    ) AS arguments,
    pg_catalog.pg_get_userbyid(
        p.proowner
    ) AS owner_name,
    p.prosecdef AS security_definer
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS ns
    ON ns.oid = p.pronamespace
WHERE ns.nspname IN (
    'app',
    'platform',
    'security'
)
AND (
    p.proname ILIKE '%role%'
    OR p.proname ILIKE '%permission%'
    OR p.proname ILIKE '%access%'
    OR p.proname ILIKE '%authorize%'
    OR p.proname ILIKE '%branch%'
)
ORDER BY
    ns.nspname,
    p.proname;

-- 6. Inspect row-level security configuration

SELECT
    ns.nspname AS schema_name,
    tbl.relname AS table_name,
    tbl.relrowsecurity AS rls_enabled,
    tbl.relforcerowsecurity AS rls_forced
FROM pg_catalog.pg_class AS tbl
JOIN pg_catalog.pg_namespace AS ns
    ON ns.oid = tbl.relnamespace
WHERE ns.nspname IN (
    'app',
    'platform',
    'security'
)
AND tbl.relkind IN ('r', 'p')
AND (
    tbl.relname ILIKE '%role%'
    OR tbl.relname ILIKE '%permission%'
    OR tbl.relname ILIKE '%membership%'
    OR tbl.relname ILIKE '%branch%'
)
ORDER BY
    ns.nspname,
    tbl.relname;

-- ========================================================
-- END OF RBAC STRUCTURE INSPECTION
-- ========================================================
