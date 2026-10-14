
-- ====================================================
-- GYM PRO SAAS
-- STEP A-F6.13.1
-- RBAC SCOPE AND PERMISSION RULE VERIFICATION
--
-- READ ONLY
-- No user credentials or personal data returned.
-- ====================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Verify database.

SELECT current_database() AS database_name;

-- 2. Existing role assignment scope values.

SELECT
    scope_type,
    COUNT(*) AS assignment_count,
    COUNT(*) FILTER (
        WHERE branch_id IS NULL
    ) AS without_branch,
    COUNT(*) FILTER (
        WHERE branch_id IS NOT NULL
    ) AS with_branch
FROM app.role_assignments
GROUP BY scope_type
ORDER BY scope_type;

-- 3. Role assignment constraints.

SELECT
    con.conname AS constraint_name,
    pg_catalog.pg_get_constraintdef(
        con.oid
    ) AS definition
FROM pg_catalog.pg_constraint AS con
WHERE con.conrelid =
    'app.role_assignments'::regclass
ORDER BY con.conname;

-- 4. Existing active permission definitions.

SELECT
    permission_code,
    module_code,
    resource_code,
    action_code
FROM app.permissions
WHERE is_active = true
ORDER BY
    module_code,
    resource_code,
    action_code
LIMIT 30;

-- 5. Role status values.

SELECT
    status,
    COUNT(*) AS role_count
FROM app.roles
GROUP BY status
ORDER BY status;

-- 6. Branch status values.

SELECT
    status,
    COUNT(*) AS branch_count
FROM app.branches
GROUP BY status
ORDER BY status;

-- 7. Counts of existing RBAC configuration.

SELECT
    (SELECT COUNT(*) FROM app.roles)
        AS roles,
    (SELECT COUNT(*) FROM app.permissions)
        AS permissions,
    (SELECT COUNT(*) FROM app.role_permissions)
        AS role_permissions,
    (SELECT COUNT(*) FROM app.role_assignments)
        AS role_assignments;

-- ====================================================
-- END OF STEP A-F6.13.1
-- ====================================================
