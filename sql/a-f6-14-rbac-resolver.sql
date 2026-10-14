
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.14
--
-- DATABASE-BACKED RBAC PERMISSION RESOLVER
--
-- Creates:
--   gympro_rbac_owner (NOLOGIN)
--   security.has_tenant_permission(
--       uuid, uuid, text, uuid
--   )
--
-- Does not:
--   - Enable session creation
--   - Modify RBAC assignments
--   - Modify tenant/user/branch records
--   - Grant direct RBAC table access to gympro_auth
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- -----------------------------------------------------
-- 1. Verify database
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
        WHERE rolname = 'gympro_auth'
          AND rolcanlogin = true
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'Required authentication role missing';
    END IF;
END
$gympro$;

-- -----------------------------------------------------
-- 2. Create an isolated function owner
-- -----------------------------------------------------

DO $gympro$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_rbac_owner'
    ) THEN
        EXECUTE
            'CREATE ROLE gympro_rbac_owner NOLOGIN NOINHERIT';
    END IF;
END
$gympro$;

-- Verify existing owner has not been widened.

DO $gympro$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_rbac_owner'
          AND rolcanlogin = false
          AND rolsuper = false
          AND rolcreaterole = false
          AND rolcreatedb = false
          AND rolbypassrls = false
    ) THEN
        RAISE EXCEPTION
            'RBAC owner role configuration is unsafe';
    END IF;
END
$gympro$;

-- -----------------------------------------------------
-- 3. Grant restricted lookup privileges
-- -----------------------------------------------------

GRANT USAGE ON SCHEMA app
TO gympro_rbac_owner;

GRANT USAGE ON SCHEMA platform
TO gympro_rbac_owner;

GRANT USAGE ON SCHEMA security
TO gympro_rbac_owner;

GRANT SELECT (id, status)
ON app.users
TO gympro_rbac_owner;

GRANT SELECT (id, status)
ON platform.tenants
TO gympro_rbac_owner;

GRANT SELECT (
    id,
    tenant_id,
    user_id,
    status
)
ON app.tenant_memberships
TO gympro_rbac_owner;

GRANT SELECT (
    id,
    tenant_id,
    status
)
ON app.roles
TO gympro_rbac_owner;

GRANT SELECT (
    tenant_id,
    membership_id,
    role_id,
    scope_type,
    branch_id
)
ON app.role_assignments
TO gympro_rbac_owner;

GRANT SELECT (
    tenant_id,
    role_id,
    permission_id
)
ON app.role_permissions
TO gympro_rbac_owner;

GRANT SELECT (
    id,
    permission_code,
    is_active
)
ON app.permissions
TO gympro_rbac_owner;

GRANT SELECT (
    id,
    tenant_id,
    status
)
ON app.branches
TO gympro_rbac_owner;

-- Existing forced RLS on app.branches remains
-- in effect for the restricted function owner.
-- Do not disable RLS to make branch checks pass.

-- -----------------------------------------------------
-- 4. Create the protected RBAC function
-- -----------------------------------------------------

CREATE OR REPLACE FUNCTION
security.has_tenant_permission(
    p_tenant_id uuid,
    p_membership_id uuid,
    p_permission_code text,
    p_branch_id uuid DEFAULT NULL
)
RETURNS boolean

LANGUAGE sql

SECURITY DEFINER

SET search_path = pg_catalog, pg_temp

STABLE

AS $function$

    SELECT
        CASE
            WHEN p_tenant_id IS NULL
              OR p_membership_id IS NULL
              OR p_permission_code IS NULL
              OR p_permission_code = ''
            THEN false

            ELSE EXISTS (
                SELECT 1

                FROM app.tenant_memberships AS m

                JOIN app.users AS u
                  ON u.id = m.user_id

                JOIN platform.tenants AS t
                  ON t.id = m.tenant_id

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

                WHERE m.id = p_membership_id
                  AND m.tenant_id = p_tenant_id

                  AND m.status = 'active'
                  AND u.status = 'active'
                  AND t.status = 'active'
                  AND r.status = 'active'

                  AND p.is_active = true
                  AND p.permission_code =
                      p_permission_code

                  AND (
                      -- Tenant-wide role applies to
                      -- the tenant and its branches.
                      (
                          ra.scope_type = 'tenant'
                          AND ra.branch_id IS NULL
                      )

                      OR

                      -- Branch assignment applies
                      -- only to the same branch.
                      (
                          ra.scope_type = 'branch'
                          AND p_branch_id IS NOT NULL
                          AND ra.branch_id = p_branch_id
                      )
                  )

                  -- If branch context is supplied,
                  -- the branch must exist and be active.
                  --
                  -- Forced RLS on app.branches may
                  -- additionally restrict visibility.
                  AND (
                      p_branch_id IS NULL

                      OR EXISTS (
                          SELECT 1
                          FROM app.branches AS b
                          WHERE b.id = p_branch_id
                            AND b.tenant_id = p_tenant_id
                            AND b.status = 'active'
                      )
                  )
            )
        END;

$function$;

-- -----------------------------------------------------
-- 5. Set isolated function ownership
-- -----------------------------------------------------

ALTER FUNCTION
security.has_tenant_permission(
    uuid, uuid, text, uuid
)
OWNER TO gympro_rbac_owner;

-- -----------------------------------------------------
-- 6. Restrict execution permissions
-- -----------------------------------------------------

REVOKE ALL
ON FUNCTION security.has_tenant_permission(
    uuid, uuid, text, uuid
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION security.has_tenant_permission(
    uuid, uuid, text, uuid
)
FROM gympro_app, gympro_session;

GRANT EXECUTE
ON FUNCTION security.has_tenant_permission(
    uuid, uuid, text, uuid
)
TO gympro_auth;

-- -----------------------------------------------------
-- 7. Verify function ownership and access
-- -----------------------------------------------------

DO $gympro$
DECLARE
    v_owner text;
    v_definer boolean;
    v_settings text[];
BEGIN
    SELECT
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosecdef,
        p.proconfig
    INTO
        v_owner,
        v_definer,
        v_settings
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid =
        'security.has_tenant_permission(uuid,uuid,text,uuid)'
            ::pg_catalog.regprocedure;

    IF v_owner <> 'gympro_rbac_owner'
       OR v_definer IS DISTINCT FROM true
       OR NOT (
           'search_path=pg_catalog, pg_temp'
           = ANY(v_settings)
       )
    THEN
        RAISE EXCEPTION
            'RBAC function configuration invalid';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.has_tenant_permission(uuid,uuid,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Authentication role cannot execute RBAC resolver';
    END IF;

    IF pg_catalog.has_function_privilege(
        'gympro_app',
        'security.has_tenant_permission(uuid,uuid,text,uuid)',
        'EXECUTE'
    )
    OR pg_catalog.has_function_privilege(
        'gympro_session',
        'security.has_tenant_permission(uuid,uuid,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'Unexpected role can execute RBAC resolver';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_auth',
        'app.role_assignments',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'gympro_auth',
        'app.role_permissions',
        'SELECT'
    ) THEN
        RAISE EXCEPTION
            'Authentication role has direct RBAC table access';
    END IF;

    RAISE NOTICE
        'PASS: RBAC function ownership and permissions';
END
$gympro$;

-- -----------------------------------------------------
-- 8. Negative authorization tests
-- -----------------------------------------------------

DO $gympro$
DECLARE
    v_tenant_id uuid :=
        '00000000-0000-4000-8000-000000000001';

    v_membership_id uuid :=
        '00000000-0000-4000-8000-000000000002';

    v_result boolean;
BEGIN

    SELECT security.has_tenant_permission(
        v_tenant_id,
        v_membership_id,
        'gym.members.read',
        NULL
    )
    INTO v_result;

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'FAIL: Unknown membership authorized';
    END IF;

    SELECT security.has_tenant_permission(
        v_tenant_id,
        v_membership_id,
        'permission.does.not.exist',
        NULL
    )
    INTO v_result;

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'FAIL: Unknown permission authorized';
    END IF;

    RAISE NOTICE
        'PASS: Unknown identity and permission denied';

END
$gympro$;

-- -----------------------------------------------------
-- 9. Confirm session creation remains restricted
-- -----------------------------------------------------

DO $gympro$
BEGIN

    IF pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Session creation unexpectedly enabled';
    END IF;

    RAISE NOTICE
        'PASS: Session creation still disabled';

END
$gympro$;

-- -----------------------------------------------------
-- 10. Commit after successful validation
-- -----------------------------------------------------

COMMIT;

SELECT
    'A-F6.14 RBAC RESOLVER CREATED'
        AS result;

-- =====================================================
-- END OF STEP A-F6.14
-- =====================================================
