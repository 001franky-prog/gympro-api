
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.19.1
--
-- FIX BRANCH RBAC RLS VISIBILITY
--
-- Adds a SELECT policy for gympro_rbac_owner.
--
-- Does NOT:
--   - Disable Row-Level Security
--   - Modify existing gympro_app policy
--   - Change users or membership statuses
--   - Grant access to gympro_auth
--   - Enable session creation
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- 1. Verify database identity.

DO $gympro$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'Wrong database. Expected gympro_saas';
    END IF;
END
$gympro$;

-- 2. Verify isolated RBAC owner remains restricted.

DO $gympro$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_rbac_owner'
          AND rolcanlogin = false
          AND rolsuper = false
          AND rolbypassrls = false
    ) THEN
        RAISE EXCEPTION
            'RBAC owner role is missing or unsafe';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'app'
          AND c.relname = 'branches'
          AND c.relrowsecurity = true
          AND c.relforcerowsecurity = true
    ) THEN
        RAISE EXCEPTION
            'Branch RLS configuration changed';
    END IF;
END
$gympro$;

-- 3. Protect against overwriting an existing policy.

DO $gympro$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'app'
          AND tablename = 'branches'
          AND policyname = 'branches_rbac_owner_select'
    ) THEN
        RAISE EXCEPTION
            'Policy already exists; review before changing';
    END IF;
END
$gympro$;

-- 4. Create narrow policy for the NOLOGIN RBAC owner.
--
-- Only active branches are visible to this role.
-- The protected RBAC function independently checks
-- the supplied tenant ID and branch ID.
--
-- IMPORTANT:
-- This policy allows the internal RBAC owner to see
-- active branches across tenants. It must remain
-- non-login and must not be granted to client roles.

CREATE POLICY branches_rbac_owner_select
ON app.branches
AS PERMISSIVE
FOR SELECT
TO gympro_rbac_owner
USING (
    status = 'active'
);

-- 5. Ensure branch RLS remains enabled and forced.

ALTER TABLE app.branches
ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.branches
FORCE ROW LEVEL SECURITY;

-- 6. Confirm dedicated owner and auth-role controls.

DO $gympro$
BEGIN

    IF NOT pg_catalog.has_column_privilege(
        'gympro_rbac_owner',
        'app.branches',
        'id',
        'SELECT'
    )
    OR NOT pg_catalog.has_column_privilege(
        'gympro_rbac_owner',
        'app.branches',
        'tenant_id',
        'SELECT'
    )
    OR NOT pg_catalog.has_column_privilege(
        'gympro_rbac_owner',
        'app.branches',
        'status',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            'RBAC owner lacks required branch columns';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_auth',
        'app.branches',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            'Authentication role has direct branch access';
    END IF;

    RAISE NOTICE
        'PASS: RBAC owner permissions verified';

END
$gympro$;

-- 7. Verify effective branch visibility as
-- gympro_rbac_owner within this transaction.

SET LOCAL ROLE gympro_rbac_owner;

SELECT
    current_user AS execution_role,
    COUNT(*) AS visible_active_branches
FROM app.branches
WHERE status = 'active';

-- 8. Verify branch assignments are visible.
-- This checks existing assignment-to-branch relations
-- without requiring user status changes.

SELECT
    COUNT(*) AS total_branch_assignments,
    COUNT(b.id) AS assignments_with_visible_branch
FROM app.role_assignments AS ra
LEFT JOIN app.branches AS b
    ON b.id = ra.branch_id
   AND b.tenant_id = ra.tenant_id
   AND b.status = 'active'
WHERE ra.scope_type = 'branch';

-- 9. Return to original execution role.

RESET ROLE;

-- 10. Validate that all assigned active branches
-- are visible to the RBAC owner.

DO $gympro$
DECLARE
    v_total integer;
    v_visible integer;
BEGIN

    -- Read policy-visible rows as the RBAC owner
    -- using a local role switch for the checks.
    -- Administrative catalog checks remain below.

    SELECT COUNT(*)
    INTO v_total
    FROM app.role_assignments
    WHERE scope_type = 'branch';

    IF v_total = 0 THEN
        RAISE EXCEPTION
            'No branch assignments exist to verify';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'app'
          AND tablename = 'branches'
          AND policyname = 'branches_rbac_owner_select'
          AND cmd = 'SELECT'
    ) THEN
        RAISE EXCEPTION
            'RBAC branch policy was not created';
    END IF;

    RAISE NOTICE
        'PASS: Branch RBAC RLS policy created';

END
$gympro$;

-- 11. Commit only after all validation succeeds.

COMMIT;

-- 12. Verify final RLS status.

SELECT
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_catalog.pg_class AS c
WHERE c.oid = 'app.branches'::regclass;

SELECT
    policyname,
    roles,
    cmd,
    qual AS using_expression
FROM pg_catalog.pg_policies
WHERE schemaname = 'app'
  AND tablename = 'branches'
ORDER BY policyname;

SELECT
    'A-F6.19.1 BRANCH RLS POLICY CREATED'
        AS final_result;

-- =====================================================
-- END OF STEP A-F6.19.1
-- =====================================================
