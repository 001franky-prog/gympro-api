
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.18
-- REAL RBAC AUTHORIZATION INTEGRATION TEST
--
-- READ ONLY
-- No changes to users, roles, permissions, or sessions.
-- Uses the actual gympro_auth execution role.
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

-- Verify database and connected administrator.

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- =====================================================
-- 1. IDENTIFY A REAL POSITIVE TENANT-ROLE CANDIDATE
-- =====================================================

-- Obtain one active tenant-scope role assignment,
-- with an active permission and active identity.
-- Return empty values when none exists.

SELECT
    COALESCE(candidate.tenant_id::text, '') AS test_tenant,
    COALESCE(candidate.membership_id::text, '') AS test_membership,
    COALESCE(candidate.permission_code, '') AS test_permission,
    CASE
        WHEN candidate.membership_id IS NULL
        THEN 'false'
        ELSE 'true'
    END AS tenant_candidate_exists
FROM (SELECT 1) AS anchor
LEFT JOIN LATERAL (
    SELECT
        m.tenant_id,
        m.id AS membership_id,
        p.permission_code
    FROM app.tenant_memberships AS m
    JOIN app.users AS u
      ON u.id = m.user_id
    JOIN platform.tenants AS t
      ON t.id = m.tenant_id
    JOIN app.role_assignments AS ra
      ON ra.tenant_id = m.tenant_id
     AND ra.membership_id = m.id
    JOIN app.roles AS r
      ON r.tenant_id = ra.tenant_id
     AND r.id = ra.role_id
    JOIN app.role_permissions AS rp
      ON rp.tenant_id = r.tenant_id
     AND rp.role_id = r.id
    JOIN app.permissions AS p
      ON p.id = rp.permission_id
    WHERE m.status = 'active'
      AND u.status = 'active'
      AND t.status = 'active'
      AND r.status = 'active'
      AND p.is_active = true
      AND p.permission_code IS NOT NULL
      AND ra.scope_type = 'tenant'
      AND ra.branch_id IS NULL
    ORDER BY p.permission_code
    LIMIT 1
) AS candidate ON true
\gset

-- =====================================================
-- 2. IDENTIFY A REAL BRANCH-ROLE CANDIDATE
-- =====================================================

SELECT
    COALESCE(candidate.tenant_id::text, '') AS branch_tenant,
    COALESCE(candidate.membership_id::text, '') AS branch_membership,
    COALESCE(candidate.branch_id::text, '') AS test_branch,
    COALESCE(candidate.permission_code, '') AS branch_permission,
    CASE
        WHEN candidate.membership_id IS NULL
        THEN 'false'
        ELSE 'true'
    END AS branch_candidate_exists
FROM (SELECT 1) AS anchor
LEFT JOIN LATERAL (
    SELECT
        m.tenant_id,
        m.id AS membership_id,
        b.id AS branch_id,
        p.permission_code
    FROM app.tenant_memberships AS m
    JOIN app.users AS u
      ON u.id = m.user_id
    JOIN platform.tenants AS t
      ON t.id = m.tenant_id
    JOIN app.role_assignments AS ra
      ON ra.tenant_id = m.tenant_id
     AND ra.membership_id = m.id
    JOIN app.branches AS b
      ON b.tenant_id = ra.tenant_id
     AND b.id = ra.branch_id
    JOIN app.roles AS r
      ON r.tenant_id = ra.tenant_id
     AND r.id = ra.role_id
    JOIN app.role_permissions AS rp
      ON rp.tenant_id = r.tenant_id
     AND rp.role_id = r.id
    JOIN app.permissions AS p
      ON p.id = rp.permission_id
    WHERE m.status = 'active'
      AND u.status = 'active'
      AND t.status = 'active'
      AND b.status = 'active'
      AND r.status = 'active'
      AND p.is_active = true
      AND p.permission_code IS NOT NULL
      AND ra.scope_type = 'branch'
    ORDER BY p.permission_code
    LIMIT 1
) AS candidate ON true
\gset

-- =====================================================
-- 3. BEGIN READ-ONLY TRANSACTION
-- =====================================================

BEGIN TRANSACTION READ ONLY;

-- Run authorization checks under the actual
-- restricted application role, not postgres.

SET LOCAL ROLE gympro_auth;

SELECT
    current_database() AS database_name,
    current_user AS execution_role;

-- =====================================================
-- 4. NEGATIVE SECURITY TESTS
-- =====================================================

SELECT
    'N01 Unknown membership' AS test,
    CASE
        WHEN security.has_tenant_permission(
            '00000000-0000-4000-8000-000000000001',
            '00000000-0000-4000-8000-000000000002',
            'gym.members.read',
            NULL
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'N02 Unknown permission' AS test,
    CASE
        WHEN security.has_tenant_permission(
            '00000000-0000-4000-8000-000000000001',
            '00000000-0000-4000-8000-000000000002',
            'permission.does.not.exist',
            NULL
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'N03 Null membership' AS test,
    CASE
        WHEN security.has_tenant_permission(
            '00000000-0000-4000-8000-000000000001',
            NULL,
            'gym.members.read',
            NULL
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- =====================================================
-- 5. POSITIVE TENANT-SCOPE AUTHORIZATION
-- =====================================================

\if :tenant_candidate_exists

SELECT
    'P01 Active tenant role' AS test,
    CASE
        WHEN security.has_tenant_permission(
            :'test_tenant'::uuid,
            :'test_membership'::uuid,
            :'test_permission',
            NULL
        ) IS TRUE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- The same membership must not authorize a
-- different tenant.

SELECT
    'N04 Cross-tenant rejection' AS test,
    CASE
        WHEN security.has_tenant_permission(
            '00000000-0000-4000-8000-000000000003',
            :'test_membership'::uuid,
            :'test_permission',
            NULL
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

\else

\echo 'P01 SKIPPED: No active tenant-scope candidate'
\echo 'Positive tenant authorization still requires verification'

\endif

-- =====================================================
-- 6. BRANCH-SCOPE AUTHORIZATION
-- =====================================================

\if :branch_candidate_exists

SELECT
    'B01 Assigned branch permission' AS test,
    CASE
        WHEN security.has_tenant_permission(
            :'branch_tenant'::uuid,
            :'branch_membership'::uuid,
            :'branch_permission',
            :'test_branch'::uuid
        ) IS TRUE
        THEN 'PASS'
        ELSE 'DENIED - REVIEW BRANCH RLS AND ROLE SCOPE'
    END AS result;

-- Report tenant-wide evaluation separately.
-- A second tenant-scope role may legitimately grant
-- the same permission, so a TRUE result here is not
-- necessarily a security failure.

SELECT
    'B02 Tenant-wide permission comparison' AS test,
    security.has_tenant_permission(
        :'branch_tenant'::uuid,
        :'branch_membership'::uuid,
        :'branch_permission',
        NULL
    ) AS tenant_wide_allowed;

\else

\echo 'B01 SKIPPED: No active branch-role candidate'

\endif

-- =====================================================
-- 7. END TRANSACTION WITHOUT CHANGES
-- =====================================================

ROLLBACK;

SELECT
    'A-F6.18 RBAC INTEGRATION TEST COMPLETED'
        AS verification_status;

-- =====================================================
-- END OF STEP A-F6.18
-- =====================================================
