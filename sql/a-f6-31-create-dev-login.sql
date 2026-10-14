
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.31
--
-- CREATE ISOLATED DEVELOPMENT LOGIN FIXTURE
--
-- Creates:
-- 1. Development test tenant
-- 2. Development test user
-- 3. Active membership
-- 4. Tenant-scoped RBAC role
-- 5. gym.members.read permission assignment
--
-- DOES NOT:
-- - Modify existing users or memberships
-- - Create authentication sessions
-- - Change PostgreSQL privileges
-- - Enable session persistence
--
-- DEVELOPMENT DATABASE ONLY
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

-- Obtain the hash interactively.
-- Do not provide or store the plaintext password.

\prompt 'Paste the ARGON2ID HASH only: ' dev_hash

-- Verify password hash format before creating records.

SELECT
    1 / CASE
        WHEN :'dev_hash' LIKE '$argon2id$%'
        THEN 1
        ELSE 0
    END AS hash_format_check;

-- Verify correct database and administrator.

SELECT
    1 / CASE
        WHEN current_database() = 'gympro_saas'
         AND current_user = 'postgres'
        THEN 1
        ELSE 0
    END AS environment_check;

-- Confirm required permission exists and is active.

SELECT
    id AS test_permission_id
FROM app.permissions
WHERE permission_code = 'gym.members.read'
  AND is_active = true
\gset

-- Create test records atomically.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- Generate a unique fixture suffix.

SELECT
    substr(
        replace(gen_random_uuid()::text, '-', ''),
        1,
        12
    ) AS fixture_suffix
\gset

-- 1. Create isolated development gym.

INSERT INTO platform.tenants (
    tenant_code,
    tenant_name,
    tenant_type,
    status
)
VALUES (
    'DEV_E2E_' || :'fixture_suffix',
    'Gym Pro Development E2E Test Gym',
    'independent',
    'active'
)
RETURNING id AS test_tenant_id
\gset

-- 2. Create isolated login identity.

INSERT INTO app.users (
    email,
    password_hash,
    full_name,
    status,
    email_verified_at
)
VALUES (
    'gympro.dev.' || :'fixture_suffix' ||
        '@example.invalid',
    :'dev_hash',
    'Gym Pro E2E Test User',
    'active',
    CURRENT_TIMESTAMP
)
RETURNING
    id AS test_user_id,
    email AS test_email
\gset

-- 3. Create active tenant membership.

INSERT INTO app.tenant_memberships (
    tenant_id,
    user_id,
    status,
    joined_at
)
VALUES (
    :'test_tenant_id'::uuid,
    :'test_user_id'::uuid,
    'active',
    CURRENT_TIMESTAMP
)
RETURNING id AS test_membership_id
\gset

-- 4. Create a dedicated tenant-wide test role.

INSERT INTO app.roles (
    tenant_id,
    role_code,
    role_name,
    description,
    is_system_role,
    status
)
VALUES (
    :'test_tenant_id'::uuid,
    'DEV_E2E_READER',
    'Development E2E Reader',
    'Isolated authentication integration test role',
    false,
    'active'
)
RETURNING id AS test_role_id
\gset

-- 5. Assign the members.read permission.

INSERT INTO app.role_permissions (
    tenant_id,
    role_id,
    permission_id
)
VALUES (
    :'test_tenant_id'::uuid,
    :'test_role_id'::uuid,
    :'test_permission_id'::uuid
);

-- 6. Assign the role to the test membership.

INSERT INTO app.role_assignments (
    tenant_id,
    membership_id,
    role_id,
    scope_type,
    branch_id
)
VALUES (
    :'test_tenant_id'::uuid,
    :'test_membership_id'::uuid,
    :'test_role_id'::uuid,
    'tenant',
    NULL
);

-- 7. Verify all expected relationships.

DO $gympro$
DECLARE
    v_count integer;
BEGIN
    SELECT COUNT(*)
    INTO v_count
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
    WHERE t.tenant_code LIKE 'DEV_E2E_%'
      AND u.email LIKE 'gympro.dev.%@example.invalid'
      AND t.status = 'active'
      AND u.status = 'active'
      AND m.status = 'active'
      AND r.status = 'active'
      AND ra.scope_type = 'tenant'
      AND ra.branch_id IS NULL
      AND p.permission_code = 'gym.members.read'
      AND p.is_active = true;

    IF v_count < 1 THEN
        RAISE EXCEPTION
            'Development login fixture validation failed';
    END IF;

    RAISE NOTICE
        'PASS: Development login fixture relationships';
END
$gympro$;

-- Commit only after all insertions and checks succeed.

COMMIT;

-- Clear password hash from psql variable.
\unset dev_hash

-- Report only nonsecret fixture identifiers.

SELECT
    :'test_email' AS login_email,
    :'test_tenant_id' AS tenant_id,
    :'test_user_id' AS user_id,
    :'test_membership_id' AS membership_id,
    :'test_role_id' AS role_id;

-- Confirm real RBAC authorization as postgres.
-- The protected function has its own restricted owner.

SELECT
    CASE
        WHEN security.has_tenant_permission(
            :'test_tenant_id'::uuid,
            :'test_membership_id'::uuid,
            'gym.members.read',
            NULL
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS rbac_verification;

SELECT
    'A-F6.31 DEVELOPMENT LOGIN FIXTURE CREATED'
        AS final_result;

-- =====================================================
-- END OF STEP A-F6.31
-- =====================================================
