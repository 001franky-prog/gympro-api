
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.19
-- BRANCH RBAC AND ROW LEVEL SECURITY DIAGNOSTIC
--
-- READ ONLY
-- No INSERT, UPDATE, DELETE, GRANT or REVOKE.
-- No session activation.
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN TRANSACTION READ ONLY;

-- 1. Verify database.

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- 2. Inspect branch Row-Level Security policies.

SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual AS using_expression,
    with_check
FROM pg_catalog.pg_policies
WHERE schemaname = 'app'
  AND tablename = 'branches'
ORDER BY policyname;

-- 3. Inspect branch RLS flags and table owner.

SELECT
    c.relname AS table_name,
    pg_catalog.pg_get_userbyid(c.relowner)
        AS table_owner,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'branches';

-- 4. Check resolver-owner privileges.

SELECT
    r.rolname AS role_name,
    r.rolbypassrls AS bypasses_rls,

    pg_catalog.has_schema_privilege(
        r.oid,
        'app',
        'USAGE'
    ) AS app_schema_usage,

    pg_catalog.has_table_privilege(
        r.oid,
        'app.branches',
        'SELECT'
    ) AS branch_table_select,

    pg_catalog.has_column_privilege(
        r.oid,
        'app.branches',
        'status',
        'SELECT'
    ) AS branch_status_select

FROM pg_catalog.pg_roles AS r
WHERE r.rolname IN (
    'postgres',
    'gympro_auth',
    'gympro_rbac_owner'
)
ORDER BY r.rolname;

-- 5. Find branch assignments.
-- No personal information returned.

SELECT
    ra.scope_type,
    b.status AS branch_status,
    r.status AS role_status,
    COUNT(*) AS assignment_count
FROM app.role_assignments AS ra
JOIN app.branches AS b
    ON b.id = ra.branch_id
   AND b.tenant_id = ra.tenant_id
JOIN app.roles AS r
    ON r.id = ra.role_id
   AND r.tenant_id = ra.tenant_id
WHERE ra.scope_type = 'branch'
GROUP BY
    ra.scope_type,
    b.status,
    r.status
ORDER BY assignment_count DESC;

-- 6. Inspect the actual RLS visibility under
-- the function owner's database role.

SET LOCAL ROLE gympro_rbac_owner;

SELECT
    current_user AS execution_role,
    COUNT(*) AS visible_active_branches
FROM app.branches
WHERE status = 'active';

-- 7. Check if branch assignments reference
-- branches visible to gympro_rbac_owner.

SELECT
    COUNT(*) AS total_branch_assignments,

    COUNT(b.id) AS assignments_with_visible_branch,

    COUNT(*) - COUNT(b.id)
        AS assignments_without_visible_branch

FROM app.role_assignments AS ra

LEFT JOIN app.branches AS b
    ON b.id = ra.branch_id
   AND b.tenant_id = ra.tenant_id
   AND b.status = 'active'

WHERE ra.scope_type = 'branch';

-- 8. Report role after switching.

SELECT
    current_user AS final_execution_role;

-- 9. End the read-only transaction.

ROLLBACK;

SELECT
    'A-F6.19 DIAGNOSTIC COMPLETED'
        AS result;

-- =====================================================
-- END OF STEP A-F6.19
-- =====================================================
