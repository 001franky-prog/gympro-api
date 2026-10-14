
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.6
--
-- SECURE DATABASE-BACKED SESSION VERIFICATION
--
-- Creates:
-- security.verify_tenant_session(bytea)
--
-- Security:
-- - Verifies token hash, expiration and revocation.
-- - Validates active user, membership and tenant.
-- - Exposes only session identity information.
-- - Does not expose the stored token hash.
-- - Does not create or revoke sessions.
-- - Does not enable session persistence.
--
-- Execute as postgres in database gympro_saas.
-- =====================================================

\set ON_ERROR_STOP on

BEGIN;

-- -----------------------------------------------------
-- 1. Verify target database and function owner
-- -----------------------------------------------------

DO $gympro$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'Wrong database. Expected gympro_saas.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session_owner'
          AND rolcanlogin = false
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'Session function owner is missing or unsafe';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_auth'
          AND rolcanlogin = true
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'Authentication role is missing or unsafe';
    END IF;
END
$gympro$;

-- -----------------------------------------------------
-- 2. Grant the function owner narrowly scoped
--    SELECT privileges required for verification.
--
-- The role already has separate privileges for
-- the existing session-creation function.
-- -----------------------------------------------------

GRANT SELECT (
    id,
    tenant_id,
    membership_id,
    session_token_hash,
    expires_at,
    revoked_at
)
ON security.tenant_sessions
TO gympro_session_owner;

-- -----------------------------------------------------
-- 3. Create the secure verification function
-- -----------------------------------------------------

CREATE OR REPLACE FUNCTION
security.verify_tenant_session(
    p_token_hash bytea
)
RETURNS TABLE (
    session_id uuid,
    tenant_id uuid,
    membership_id uuid,
    user_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN

    -- Reject malformed input.
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32
    THEN
        RETURN;
    END IF;

    -- Return identity only for a currently valid
    -- session with active account relationships.

    RETURN QUERY
    SELECT
        s.id,
        s.tenant_id,
        s.membership_id,
        m.user_id

    FROM security.tenant_sessions AS s

    INNER JOIN app.tenant_memberships AS m
        ON m.id = s.membership_id
       AND m.tenant_id = s.tenant_id

    INNER JOIN app.users AS u
        ON u.id = m.user_id

    INNER JOIN platform.tenants AS t
        ON t.id = s.tenant_id

    WHERE s.session_token_hash = p_token_hash

      AND s.expires_at > statement_timestamp()

      AND s.revoked_at IS NULL

      AND m.status = 'active'

      AND u.status = 'active'

      AND t.status = 'active'

    LIMIT 1;

END;
$function$;

-- -----------------------------------------------------
-- 4. Assign least-privilege function ownership
-- -----------------------------------------------------

ALTER FUNCTION
security.verify_tenant_session(bytea)
OWNER TO gympro_session_owner;

-- -----------------------------------------------------
-- 5. Restrict execution
-- -----------------------------------------------------

REVOKE ALL
ON FUNCTION security.verify_tenant_session(bytea)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION security.verify_tenant_session(bytea)
FROM gympro_app, gympro_session;

GRANT EXECUTE
ON FUNCTION security.verify_tenant_session(bytea)
TO gympro_auth;

-- -----------------------------------------------------
-- 6. Validate effective permissions
-- -----------------------------------------------------

DO $gympro$
BEGIN

    IF NOT pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.verify_tenant_session(bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Authentication role cannot verify sessions';
    END IF;

    IF pg_catalog.has_function_privilege(
        'gympro_app',
        'security.verify_tenant_session(bytea)',
        'EXECUTE'
    )
    OR pg_catalog.has_function_privilege(
        'gympro_session',
        'security.verify_tenant_session(bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Unauthorized application role can verify sessions';
    END IF;

    IF pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Authentication role unexpectedly has session creation access';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_auth',
        'security.tenant_sessions',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'gympro_auth',
        'security.tenant_sessions',
        'INSERT'
    ) THEN
        RAISE EXCEPTION
            'Authentication role has direct session table access';
    END IF;

    RAISE NOTICE
        'PASS: Session verification permissions checked';

END
$gympro$;

-- -----------------------------------------------------
-- 7. Negative test: nonexistent token
-- -----------------------------------------------------

DO $gympro$
DECLARE
    v_count integer;
BEGIN

    SELECT COUNT(*)
    INTO v_count
    FROM security.verify_tenant_session(
        decode(repeat('00', 32), 'hex')
    );

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'FAIL: Unrecognized token accepted';
    END IF;

    RAISE NOTICE
        'PASS: Unrecognized token rejected';

END
$gympro$;

-- -----------------------------------------------------
-- 8. Commit only after all verification passes
-- -----------------------------------------------------

COMMIT;

-- -----------------------------------------------------
-- 9. Final confirmation
-- -----------------------------------------------------

SELECT
    pg_catalog.pg_get_userbyid(p.proowner)
        AS function_owner,
    p.prosecdef AS security_definer,
    p.proconfig AS function_settings

FROM pg_catalog.pg_proc AS p

WHERE p.oid =
    'security.verify_tenant_session(bytea)'
        ::pg_catalog.regprocedure;

SELECT
    r.rolname AS role_name,

    pg_catalog.has_function_privilege(
        r.rolname,
        'security.verify_tenant_session(bytea)',
        'EXECUTE'
    ) AS can_verify_sessions,

    pg_catalog.has_function_privilege(
        r.rolname,
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS can_create_sessions

FROM pg_catalog.pg_roles AS r

WHERE r.rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)

ORDER BY r.rolname;

-- =====================================================
-- END OF STEP A-F6.6
-- =====================================================
