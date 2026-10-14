
-- ====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.2
-- TRUSTED SESSION ACCESS BOUNDARY VERIFICATION
--
-- READ ONLY
-- NO GRANT / REVOKE / INSERT / UPDATE / DELETE
-- ====================================================

-- 1. Verify database identity.

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- 2. Display protected function information.

SELECT
    p.proname AS function_name,
    pg_get_userbyid(p.proowner) AS owner_name,
    p.prosecdef AS security_definer,
    p.proconfig AS function_settings
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = p.pronamespace
WHERE n.nspname = 'security'
  AND p.proname = 'create_tenant_session'
  AND pg_get_function_identity_arguments(p.oid)
      = 'p_membership_id uuid, p_token_hash bytea';

-- 3. Report role privileges.

SELECT
    r.rolname AS role_name,
    r.rolsuper AS is_superuser,
    r.rolcanlogin AS can_login,
    has_schema_privilege(
        r.rolname,
        'security',
        'USAGE'
    ) AS schema_usage,
    has_function_privilege(
        r.rolname,
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS function_execute,
    has_table_privilege(
        r.rolname,
        'security.tenant_sessions',
        'SELECT'
    ) AS can_select_sessions,
    has_table_privilege(
        r.rolname,
        'security.tenant_sessions',
        'INSERT'
    ) AS can_insert_sessions
FROM pg_catalog.pg_roles AS r
WHERE r.rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)
ORDER BY r.rolname;

-- 4. Enforce security expectations.
-- Report an error if any essential control fails.

DO $gympro$
DECLARE
    v_function_oid oid;
    v_function_owner text;
    v_security_definer boolean;
    v_search_path text[];
BEGIN

    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'FAIL: Connected to wrong database';
    END IF;

    -- Required roles must exist.
    IF (
        SELECT COUNT(*)
        FROM pg_catalog.pg_roles
        WHERE rolname IN (
            'gympro_app',
            'gympro_auth',
            'gympro_session',
            'gympro_session_owner'
        )
    ) <> 4 THEN
        RAISE EXCEPTION
            'FAIL: Required database role missing';
    END IF;

    -- Protected function must exist.
    SELECT
        p.oid,
        pg_get_userbyid(p.proowner),
        p.prosecdef,
        p.proconfig
    INTO
        v_function_oid,
        v_function_owner,
        v_security_definer,
        v_search_path
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid =
        to_regprocedure(
            'security.create_tenant_session(uuid,bytea)'
        );

    IF v_function_oid IS NULL THEN
        RAISE EXCEPTION
            'FAIL: Protected session function missing';
    END IF;

    IF v_function_owner <> 'gympro_session_owner'
       OR v_security_definer IS DISTINCT FROM TRUE
    THEN
        RAISE EXCEPTION
            'FAIL: Unexpected function owner or mode';
    END IF;

    IF NOT (
        'search_path=pg_catalog, pg_temp'
        = ANY(v_search_path)
    ) THEN
        RAISE EXCEPTION
            'FAIL: Protected function search path changed';
    END IF;

    -- General application role must be denied.
    IF has_schema_privilege(
        'gympro_app',
        'security',
        'USAGE'
    )
    OR has_function_privilege(
        'gympro_app',
        v_function_oid,
        'EXECUTE'
    )
    THEN
        RAISE EXCEPTION
            'FAIL: General application role has session access';
    END IF;

    -- Authentication role may use the security
    -- schema for its approved authentication
    -- functions, but must not create sessions.
    IF has_function_privilege(
        'gympro_auth',
        v_function_oid,
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Authentication role can create sessions';
    END IF;

    -- Session role must remain restricted
    -- until the trusted activation milestone.
    IF has_schema_privilege(
        'gympro_session',
        'security',
        'USAGE'
    )
    OR has_function_privilege(
        'gympro_session',
        v_function_oid,
        'EXECUTE'
    )
    THEN
        RAISE EXCEPTION
            'FAIL: Session role activated prematurely';
    END IF;

    -- None of the application login roles should
    -- directly access the protected session table.
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles AS r
        WHERE r.rolname IN (
            'gympro_app',
            'gympro_auth',
            'gympro_session'
        )
        AND (
            has_table_privilege(
                r.rolname,
                'security.tenant_sessions',
                'SELECT'
            )
            OR
            has_table_privilege(
                r.rolname,
                'security.tenant_sessions',
                'INSERT'
            )
        )
    ) THEN
        RAISE EXCEPTION
            'FAIL: Application role has direct session table access';
    END IF;

    -- Application roles should not be superusers.
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname IN (
            'gympro_app',
            'gympro_auth',
            'gympro_session',
            'gympro_session_owner'
        )
        AND rolsuper
    ) THEN
        RAISE EXCEPTION
            'FAIL: Protected role is a superuser';
    END IF;

    -- The function owner must not be a login role.
    IF (
        SELECT rolcanlogin
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session_owner'
    ) IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION
            'FAIL: Session function owner can log in';
    END IF;

    RAISE NOTICE
        'PASS: Gym Pro session database access boundary verified';

END
$gympro$;

-- ====================================================
-- END OF STEP A-F6.2
-- ====================================================
