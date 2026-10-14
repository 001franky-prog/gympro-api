
-- ========================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.18.1
-- RBAC ASSIGNMENT ELIGIBILITY DIAGNOSTIC
--
-- READ ONLY
-- No updates, inserts, grants, or session creation.
-- ========================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Verify database.

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- 2. Count role assignments by scope.

SELECT
    scope_type,
    COUNT(*) AS assignment_count
FROM app.role_assignments
GROUP BY scope_type
ORDER BY scope_type;

-- 3. Examine eligibility of each assignment.
-- Identifiers and personal information are omitted.

WITH assignment_checks AS (
    SELECT
        ra.scope_type,

        m.status AS membership_status,
        u.status AS user_status,
        t.status AS tenant_status,
        r.status AS role_status,

        CASE
            WHEN ra.scope_type = 'tenant'
                 AND ra.branch_id IS NULL
            THEN true
            WHEN ra.scope_type = 'branch'
                 AND ra.branch_id IS NOT NULL
            THEN true
            ELSE false
        END AS scope_valid,

        CASE
            WHEN ra.scope_type = 'branch'
            THEN b.status = 'active'
            ELSE true
        END AS branch_eligible,

        EXISTS (
            SELECT 1
            FROM app.role_permissions AS rp
            JOIN app.permissions AS p
              ON p.id = rp.permission_id
            WHERE rp.tenant_id = ra.tenant_id
              AND rp.role_id = ra.role_id
              AND p.is_active = true
              AND p.permission_code IS NOT NULL
        ) AS has_active_permission

    FROM app.role_assignments AS ra

    LEFT JOIN app.tenant_memberships AS m
      ON m.id = ra.membership_id
     AND m.tenant_id = ra.tenant_id

    LEFT JOIN app.users AS u
      ON u.id = m.user_id

    LEFT JOIN platform.tenants AS t
      ON t.id = ra.tenant_id

    LEFT JOIN app.roles AS r
      ON r.id = ra.role_id
     AND r.tenant_id = ra.tenant_id

    LEFT JOIN app.branches AS b
      ON b.id = ra.branch_id
     AND b.tenant_id = ra.tenant_id
)

SELECT
    scope_type,
    membership_status,
    user_status,
    tenant_status,
    role_status,
    scope_valid,
    branch_eligible,
    has_active_permission,
    COUNT(*) AS assignment_count
FROM assignment_checks
GROUP BY
    scope_type,
    membership_status,
    user_status,
    tenant_status,
    role_status,
    scope_valid,
    branch_eligible,
    has_active_permission
ORDER BY
    scope_type,
    assignment_count DESC;

-- 4. Show overall eligibility counts.

WITH eligible_assignments AS (
    SELECT
        ra.id,
        ra.scope_type,

        (
            m.status = 'active'
            AND u.status = 'active'
            AND t.status = 'active'
            AND r.status = 'active'
            AND (
                ra.scope_type = 'tenant'
                OR (
                    ra.scope_type = 'branch'
                    AND b.status = 'active'
                )
            )
            AND EXISTS (
                SELECT 1
                FROM app.role_permissions AS rp
                JOIN app.permissions AS p
                  ON p.id = rp.permission_id
                WHERE rp.tenant_id = ra.tenant_id
                  AND rp.role_id = ra.role_id
                  AND p.is_active = true
                  AND p.permission_code IS NOT NULL
            )
        ) AS eligible

    FROM app.role_assignments AS ra
    JOIN app.tenant_memberships AS m
      ON m.id = ra.membership_id
     AND m.tenant_id = ra.tenant_id
    JOIN app.users AS u
      ON u.id = m.user_id
    JOIN platform.tenants AS t
      ON t.id = ra.tenant_id
    JOIN app.roles AS r
      ON r.id = ra.role_id
     AND r.tenant_id = ra.tenant_id
    LEFT JOIN app.branches AS b
      ON b.id = ra.branch_id
     AND b.tenant_id = ra.tenant_id
)

SELECT
    scope_type,
    COUNT(*) AS total_assignments,
    COUNT(*) FILTER (
        WHERE eligible IS TRUE
    ) AS eligible_assignments
FROM eligible_assignments
GROUP BY scope_type
ORDER BY scope_type;

-- ========================================================
-- END OF STEP A-F6.18.1
-- ========================================================
