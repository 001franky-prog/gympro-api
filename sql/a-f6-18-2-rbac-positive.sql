
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.18.2
-- TRANSACTIONAL POSITIVE RBAC INTEGRATION TEST
--
-- Temporarily activates ONE tenant-scope and
-- ONE branch-scope test assignment.
--
-- ALWAYS ROLLBACK.
-- DO NOT COMMIT.
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- 1. Confirm database.

SELECT current_database() AS database_name;

-- 2. Select one tenant-scope candidate.
-- Store IDs in psql variables without displaying
-- personal information.

SELECT
    m.tenant_id AS test_tenant,
    m.id AS test_membership,
    m.user_id AS test_user,
    p.permission_code AS test_permission
FROM app.tenant_memberships AS m
JOIN app.role_assignments AS ra
  ON ra.membership_id = m.id
 AND ra.tenant_id = m.tenant_id
JOIN app.roles AS r
  ON r.id = ra.role_id
 AND r.tenant_id = ra.tenant_id
JOIN app.role_permissions AS rp
  ON rp.role_id = r.id
 AND rp.tenant_id = r.tenant_id
JOIN app.permissions AS p
  ON p.id = rp.permission_id
WHERE ra.scope_type = 'tenant'
  AND ra.branch_id IS NULL
  AND r.status = 'active'
  AND p.is_active = true
  AND p.permission_code IS NOT NULL
ORDER BY m.id, p.permission_code
LIMIT 1
\gset

-- 3. Select one branch-scope candidate.

SELECT
    m.tenant_id AS branch_tenant,
    m.id AS branch_membership,
    m.user_id AS branch_user,
    ra.branch_id AS test_branch,
    p.permission_code AS branch_permission
FROM app.tenant_memberships AS m
JOIN app.role_assignments AS ra
  ON ra.membership_id = m.id
 AND ra.tenant_id = m.tenant_id
JOIN app.roles AS r
  ON r.id = ra.role_id
 AND r.tenant_id = ra.tenant_id
JOIN app.role_permissions AS rp
  ON rp.role_id = r.id
 AND rp.tenant_id = r.tenant_id
JOIN app.permissions AS p
  ON p.id = rp.permission_id
WHERE ra.scope_type = 'branch'
  AND ra.branch_id IS NOT NULL
  AND r.status = 'active'
  AND p.is_active = true
  AND p.permission_code IS NOT NULL
ORDER BY m.id, p.permission_code
LIMIT 1
\gset

-- 4. Confirm assignments are denied before activation.

SELECT
    'PRE01 Inactive tenant membership' AS test,
    security.has_tenant_permission(
        :'test_tenant'::uuid,
        :'test_membership'::uuid,
        :'test_permission',
        NULL
    ) AS allowed;

SELECT
    'PRE02 Inactive branch membership' AS test,
    security.has_tenant_permission(
        :'branch_tenant'::uuid,
        :'branch_membership'::uuid,
        :'branch_permission',
        :'test_branch'::uuid
    ) AS allowed;

-- 5. Temporarily activate ONLY selected accounts.
-- Changes are uncommitted.

UPDATE app.users
SET status = 'active'
WHERE id IN (
    :'test_user'::uuid,
    :'branch_user'::uuid
)
AND status = 'pending';

-- 6. Temporarily activate selected memberships.

UPDATE app.tenant_memberships
SET status = 'active'
WHERE id IN (
    :'test_membership'::uuid,
    :'branch_membership'::uuid
)
AND status = 'invited';

-- 7. Execute tests as the restricted auth role.

SET LOCAL ROLE gympro_auth;

SELECT current_user AS execution_role;

-- 8. Positive tenant-wide permission test.

SELECT
    'P01 Active tenant permission' AS test,
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

-- 9. Positive branch permission test.

SELECT
    'B01 Active assigned branch' AS test,
    CASE
        WHEN security.has_tenant_permission(
            :'branch_tenant'::uuid,
            :'branch_membership'::uuid,
            :'branch_permission',
            :'test_branch'::uuid
        ) IS TRUE
        THEN 'PASS'
        ELSE 'FAIL - REVIEW BRANCH RLS'
    END AS result;

-- 10. Negative cross-tenant test.

SELECT
    'N01 Cross-tenant denied' AS test,
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

-- 11. Negative nonexistent permission test.

SELECT
    'N02 Unknown permission denied' AS test,
    CASE
        WHEN security.has_tenant_permission(
            :'test_tenant'::uuid,
            :'test_membership'::uuid,
            'permission.does.not.exist',
            NULL
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- 12. Reject nonexistent branch scope.

SELECT
    'N03 Unknown branch denied' AS test,
    CASE
        WHEN security.has_tenant_permission(
            :'branch_tenant'::uuid,
            :'branch_membership'::uuid,
            :'branch_permission',
            '00000000-0000-4000-8000-000000000004'
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- 13. ALWAYS discard temporary changes.

ROLLBACK;

-- 14. Confirm original statuses were restored.

SELECT
    'RESTORE01 User statuses' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.users
            WHERE id IN (
                :'test_user'::uuid,
                :'branch_user'::uuid
            )
            AND status <> 'pending'
        )
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS result;

SELECT
    'RESTORE02 Membership statuses' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.tenant_memberships
            WHERE id IN (
                :'test_membership'::uuid,
                :'branch_membership'::uuid
            )
            AND status <> 'invited'
        )
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS result;

SELECT
    'A-F6.18.2 TEST FINISHED - CHANGES ROLLED BACK'
        AS final_status;

-- =====================================================
-- END OF STEP A-F6.18.2
-- =====================================================
