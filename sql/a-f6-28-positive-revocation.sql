
-- ==========================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.28
--
-- POSITIVE SESSION REVOCATION INTEGRATION TEST
--
-- DEVELOPMENT DATABASE ONLY
--
-- Creates a temporary session and verifies:
-- 1. Valid session lookup
-- 2. Protected revocation
-- 3. Revoked session rejection
-- 4. Repeated revocation rejection
-- 5. Wrong token hash rejection
-- 6. Complete transaction rollback
--
-- NEVER COMMIT THIS TEST.
-- ==========================================================

\set ON_ERROR_STOP on
\pset pager off

-- ----------------------------------------------------------
-- 1. Confirm environment before any changes.
-- ----------------------------------------------------------

DO $gympro$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Wrong database';
    END IF;

    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run as postgres administrator';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.revoke_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'gympro_auth cannot execute revocation function';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_auth',
        'security.tenant_sessions',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            'Unexpected direct UPDATE permission';
    END IF;
END
$gympro$;

-- Confirm a suitable development fixture exists.

DO $gympro$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.tenant_memberships AS m
        JOIN app.users AS u
          ON u.id = m.user_id
        JOIN platform.tenants AS t
          ON t.id = m.tenant_id
        WHERE m.status = 'invited'
          AND u.status = 'pending'
          AND t.status = 'active'
    ) THEN
        RAISE EXCEPTION
            'No isolated pending/invited fixture available';
    END IF;
END
$gympro$;

-- ----------------------------------------------------------
-- 2. Start transaction.
-- ----------------------------------------------------------

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ----------------------------------------------------------
-- 3. Select a pending user and invited membership.
-- ----------------------------------------------------------

SELECT
    m.id AS test_membership,
    m.user_id AS test_user,
    m.tenant_id AS test_tenant
FROM app.tenant_memberships AS m
JOIN app.users AS u
  ON u.id = m.user_id
JOIN platform.tenants AS t
  ON t.id = m.tenant_id
WHERE m.status = 'invited'
  AND u.status = 'pending'
  AND t.status = 'active'
ORDER BY m.id
LIMIT 1
\gset

-- ----------------------------------------------------------
-- 4. Temporarily activate test identity.
-- ----------------------------------------------------------

UPDATE app.users
SET status = 'active'
WHERE id = :'test_user'::uuid
  AND status = 'pending';

UPDATE app.tenant_memberships
SET status = 'active'
WHERE id = :'test_membership'::uuid
  AND status = 'invited';

-- ----------------------------------------------------------
-- 5. Generate a test-only 32-byte hash.
-- ----------------------------------------------------------

SELECT
    replace(
        pg_catalog.gen_random_uuid()::text,
        '-',
        ''
    ) ||
    replace(
        pg_catalog.gen_random_uuid()::text,
        '-',
        ''
    ) AS test_hash_hex
\gset

-- ----------------------------------------------------------
-- 6. Create a temporary session.
-- ----------------------------------------------------------

SELECT
    security.create_tenant_session(
        :'test_membership'::uuid,
        pg_catalog.decode(:'test_hash_hex', 'hex')
    ) AS test_session
\gset

-- ----------------------------------------------------------
-- 7. Validate session record.
-- ----------------------------------------------------------

SELECT
    'S01 Session created' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.tenant_sessions
            WHERE id = :'test_session'::uuid
              AND membership_id =
                  :'test_membership'::uuid
              AND tenant_id = :'test_tenant'::uuid
              AND revoked_at IS NULL
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 8. Switch to restricted auth role.
-- ----------------------------------------------------------

SET LOCAL ROLE gympro_auth;

SELECT
    current_user AS execution_role;

-- ----------------------------------------------------------
-- 9. Verify temporary session is active.
-- ----------------------------------------------------------

SELECT
    'S02 Active session accepted' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                pg_catalog.decode(
                    :'test_hash_hex',
                    'hex'
                )
            )
            WHERE session_id =
                :'test_session'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 10. Wrong token hash must NOT revoke the session.
-- ----------------------------------------------------------

SELECT
    'S03 Wrong hash rejected' AS test,
    CASE
        WHEN security.revoke_tenant_session(
            :'test_session'::uuid,
            pg_catalog.decode(
                repeat('ff', 32),
                'hex'
            )
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 11. Verify wrong hash did not revoke the session.
-- ----------------------------------------------------------

SELECT
    'S04 Session still active' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                pg_catalog.decode(
                    :'test_hash_hex',
                    'hex'
                )
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 12. Revoke matching session.
-- ----------------------------------------------------------

SELECT
    'S05 Valid revocation accepted' AS test,
    CASE
        WHEN security.revoke_tenant_session(
            :'test_session'::uuid,
            pg_catalog.decode(
                :'test_hash_hex',
                'hex'
            )
        ) IS TRUE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 13. Verify revoked token is rejected.
-- ----------------------------------------------------------

SELECT
    'S06 Revoked session rejected' AS test,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM security.verify_tenant_session(
                pg_catalog.decode(
                    :'test_hash_hex',
                    'hex'
                )
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 14. Repeating revocation must not reactivate it.
-- ----------------------------------------------------------

SELECT
    'S07 Repeat revocation rejected' AS test,
    CASE
        WHEN security.revoke_tenant_session(
            :'test_session'::uuid,
            pg_catalog.decode(
                :'test_hash_hex',
                'hex'
            )
        ) IS FALSE
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 15. Restore administrative role.
-- ----------------------------------------------------------

RESET ROLE;

-- ----------------------------------------------------------
-- 16. Inspect revoked_at within the transaction.
-- ----------------------------------------------------------

SELECT
    'S08 Revocation timestamp stored' AS test,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM security.tenant_sessions
            WHERE id = :'test_session'::uuid
              AND revoked_at IS NOT NULL
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- ----------------------------------------------------------
-- 17. Discard all temporary changes.
-- ----------------------------------------------------------

ROLLBACK;

-- ----------------------------------------------------------
-- 18. Verify original user and membership statuses.
-- ----------------------------------------------------------

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
    'A-F6.28 INTEGRATION TEST COMPLETED'
        AS final_status;

-- ==========================================================
-- END OF STEP A-F6.28
-- ==========================================================
