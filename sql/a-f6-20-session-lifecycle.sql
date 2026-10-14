
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.20
-- SESSION LIFECYCLE INTEGRATION TEST
--
-- DEVELOPMENT DATABASE ONLY
--
-- All modifications are made inside a transaction.
-- The transaction ends with ROLLBACK.
--
-- DO NOT COMMIT.
-- DO NOT GRANT DATABASE PERMISSIONS.
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- -----------------------------------------------------
-- 1. Verify test environment and permissions
-- -----------------------------------------------------

DO $gympro$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Wrong database';
    END IF;

    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Test requires the local postgres administrator';
    END IF;

    IF pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Session role is unexpectedly enabled';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.verify_tenant_session(bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Session verification permission missing';
    END IF;

    RAISE NOTICE
        'PASS: Database and session permissions verified';
END
$gympro$;

-- -----------------------------------------------------
-- 2. Find one isolated existing test candidate
-- -----------------------------------------------------

-- Select an account that is currently pending,
-- with an invited membership in an active tenant.

SELECT
    m.id AS test_membership,
    m.user_id AS test_user,
    m.tenant_id AS test_tenant

FROM app.tenant_memberships AS m

JOIN app.users AS u
    ON u.id = m.user_id

JOIN platform.tenants AS t
    ON t.id = m.tenant_id

WHERE u.status = 'pending'
  AND m.status = 'invited'
  AND t.status = 'active'

ORDER BY m.id
LIMIT 1
\gset

-- -----------------------------------------------------
-- 3. Verify original statuses
-- -----------------------------------------------------

SELECT
    'PRE01 Original user pending' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM app.users
            WHERE id = :'test_user'::uuid
              AND status = 'pending'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'PRE02 Original membership invited' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM app.tenant_memberships
            WHERE id = :'test_membership'::uuid
              AND status = 'invited'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- -----------------------------------------------------
-- 4. Temporarily activate selected records
-- -----------------------------------------------------

UPDATE app.users
SET status = 'active'
WHERE id = :'test_user'::uuid
  AND status = 'pending';

UPDATE app.tenant_memberships
SET status = 'active'
WHERE id = :'test_membership'::uuid
  AND status = 'invited';

-- -----------------------------------------------------
-- 5. Generate one 32-byte TEST-ONLY hash
-- -----------------------------------------------------

-- This value is ONLY for database integration tests.
-- Production tokens must continue to use Node.js
-- cryptographically secure random generation.

SELECT
    pg_catalog.decode(
        replace(
            pg_catalog.gen_random_uuid()::text,
            '-',
            ''
        ) ||
        replace(
            pg_catalog.gen_random_uuid()::text,
            '-',
            ''
        ),
        'hex'
    ) AS test_hash
\gset

-- -----------------------------------------------------
-- 6. Create a test session as administrator
-- -----------------------------------------------------

-- This does NOT grant session creation permission
-- to gympro_session or expose a public login.

SELECT
    security.create_tenant_session(
        :'test_membership'::uuid,
        :'test_hash'::bytea
    ) AS test_session
\gset

-- -----------------------------------------------------
-- 7. Verify persisted session properties
-- -----------------------------------------------------

SELECT
    'S01 Session created' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.tenant_sessions
            WHERE id = :'test_session'::uuid
              AND tenant_id = :'test_tenant'::uuid
              AND membership_id =
                  :'test_membership'::uuid
              AND octet_length(
                  session_token_hash
              ) = 32
              AND revoked_at IS NULL
              AND expires_at > CURRENT_TIMESTAMP
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- -----------------------------------------------------
-- 8. Verify through restricted authentication role
-- -----------------------------------------------------

SET LOCAL ROLE gympro_auth;

SELECT
    current_user AS verification_role;

SELECT
    'S02 Active session accepted' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                :'test_hash'::bytea
            ) AS s
            WHERE s.session_id =
                :'test_session'::uuid
              AND s.tenant_id =
                :'test_tenant'::uuid
              AND s.membership_id =
                :'test_membership'::uuid
              AND s.user_id =
                :'test_user'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- -----------------------------------------------------
-- 9. Return to administrator for test revocation
-- -----------------------------------------------------

RESET ROLE;

UPDATE security.tenant_sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE id = :'test_session'::uuid
  AND revoked_at IS NULL;

-- -----------------------------------------------------
-- 10. Verify revoked session is rejected
-- -----------------------------------------------------

SET LOCAL ROLE gympro_auth;

SELECT
    'S03 Revoked session rejected' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                :'test_hash'::bytea
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- -----------------------------------------------------
-- 11. Verify unrelated token is rejected
-- -----------------------------------------------------

SELECT
    'S04 Unknown token rejected' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                pg_catalog.decode(
                    repeat('00', 32),
                    'hex'
                )
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

RESET ROLE;

-- -----------------------------------------------------
-- 12. Discard all temporary modifications
-- -----------------------------------------------------

ROLLBACK;

-- -----------------------------------------------------
-- 13. Confirm original records are restored
-- -----------------------------------------------------

SELECT
    'RESTORE01 User remains pending' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM app.users
            WHERE id = :'test_user'::uuid
              AND status = 'pending'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'RESTORE02 Membership remains invited' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM app.tenant_memberships
            WHERE id = :'test_membership'::uuid
              AND status = 'invited'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'RESTORE03 Test session removed' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM security.tenant_sessions
            WHERE id = :'test_session'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT
    'A-F6.20 SESSION LIFECYCLE TEST COMPLETED'
        AS final_status;

-- =====================================================
-- END OF STEP A-F6.20
-- =====================================================
