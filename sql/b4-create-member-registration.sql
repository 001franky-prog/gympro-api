\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

BEGIN;

-- Confirm prerequisites before making changes.
DO $$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Wrong database. Expected gympro_saas.';
    END IF;

    IF to_regclass('app.members') IS NULL THEN
        RAISE EXCEPTION 'Required table app.members is missing.';
    END IF;

    IF to_regclass('app.member_number_seq') IS NULL THEN
        RAISE EXCEPTION 'Member-number sequence is missing.';
    END IF;

    IF to_regprocedure(
        'security.verify_tenant_session(bytea)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Session-verification function is missing.';
    END IF;

    IF to_regprocedure(
        'security.has_tenant_permission(uuid,uuid,text,uuid)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Permission-verification function is missing.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'gympro_member_owner'
    ) THEN
        RAISE EXCEPTION
            'gympro_member_owner already exists. Inspect before rerunning.';
    END IF;

    IF to_regprocedure(
        'security.register_member(bytea,uuid,uuid,text,text,text)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION 'Registration function already exists.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM app.permissions
        WHERE permission_code = 'gym.members.create'
          AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Active gym.members.create permission is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'app.members'::regclass
          AND relrowsecurity
          AND relforcerowsecurity
    ) THEN
        RAISE EXCEPTION 'Members table requires enabled and forced RLS.';
    END IF;
END
$$;

-- Dedicated non-login owner for registration.
CREATE ROLE gympro_member_owner
    NOLOGIN
    NOINHERIT
    NOSUPERUSER
    NOBYPASSRLS
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

GRANT USAGE ON SCHEMA app, security
    TO gympro_member_owner;

GRANT SELECT, INSERT ON TABLE app.members
    TO gympro_member_owner;

GRANT USAGE ON SEQUENCE app.member_number_seq
    TO gympro_member_owner;

GRANT EXECUTE ON FUNCTION
    security.verify_tenant_session(bytea)
    TO gympro_member_owner;

GRANT EXECUTE ON FUNCTION
    security.has_tenant_permission(uuid, uuid, text, uuid)
    TO gympro_member_owner;

-- Complete the existing RBAC branch-read setup.
-- Its existing RLS policy restricts reads to active branches.
GRANT SELECT ON TABLE app.branches
    TO gympro_rbac_owner;

-- These policies apply only to the non-login function owner.
CREATE POLICY members_registration_owner_select
    ON app.members
    FOR SELECT
    TO gympro_member_owner
    USING (true);

CREATE POLICY members_registration_owner_insert
    ON app.members
    FOR INSERT
    TO gympro_member_owner
    WITH CHECK (true);

CREATE FUNCTION security.register_member(
    p_token_hash BYTEA,
    p_tenant_id UUID,
    p_branch_id UUID,
    p_full_name TEXT,
    p_phone TEXT,
    p_email TEXT
)
RETURNS SETOF app.members
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
AS $function$
DECLARE
    v_session RECORD;
    v_full_name TEXT;
    v_phone TEXT;
    v_email TEXT;
BEGIN
    -- Verify the token again at the database boundary.
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32 THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000',
            MESSAGE = 'Invalid or expired session';
    END IF;

    SELECT
        s.session_id,
        s.tenant_id,
        s.membership_id,
        s.user_id
    INTO v_session
    FROM security.verify_tenant_session(p_token_hash) AS s;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000',
            MESSAGE = 'Invalid or expired session';
    END IF;

    -- Requested tenant must match the verified session.
    IF p_tenant_id IS NULL
       OR p_tenant_id <> v_session.tenant_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Tenant access denied';
    END IF;

    -- Check member creation permission and branch applicability.
    IF security.has_tenant_permission(
        v_session.tenant_id,
        v_session.membership_id,
        'gym.members.create',
        p_branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member registration permission denied';
    END IF;

    -- Normalize member details.
    v_full_name := btrim(p_full_name);
    v_phone := nullif(btrim(p_phone), '');
    v_email := nullif(lower(btrim(p_email)), '');

    IF v_full_name IS NULL
       OR char_length(v_full_name) NOT BETWEEN 2 AND 150 THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member name must contain 2 to 150 characters';
    END IF;

    IF v_phone IS NULL AND v_email IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Phone number or email address is required';
    END IF;

    IF v_phone IS NOT NULL AND (
        char_length(v_phone) NOT BETWEEN 7 AND 20
        OR v_phone !~ '^\+?[0-9][0-9 ()-]*$'
        OR char_length(
            regexp_replace(v_phone, '[^0-9]', '', 'g')
        ) NOT BETWEEN 7 AND 15
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid phone number';
    END IF;

    IF v_email IS NOT NULL AND (
        char_length(v_email) > 254
        OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid email address';
    END IF;

    -- Ownership comes from the verified session.
    -- Member number and pending status use existing defaults.
    RETURN QUERY
    INSERT INTO app.members AS m (
        tenant_id,
        branch_id,
        full_name,
        phone,
        email
    )
    VALUES (
        v_session.tenant_id,
        p_branch_id,
        v_full_name,
        v_phone,
        v_email
    )
    RETURNING m.*;
END
$function$;

ALTER FUNCTION security.register_member(
    bytea, uuid, uuid, text, text, text
) OWNER TO gympro_member_owner;

REVOKE ALL ON FUNCTION security.register_member(
    bytea, uuid, uuid, text, text, text
) FROM PUBLIC, gympro_auth, gympro_session, gympro_introspect;

GRANT USAGE ON SCHEMA security TO gympro_app;

GRANT EXECUTE ON FUNCTION security.register_member(
    bytea, uuid, uuid, text, text, text
) TO gympro_app;

-- Verify installation before committing.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'gympro_member_owner'
          AND (rolcanlogin OR rolsuper OR rolbypassrls)
    ) THEN
        RAISE EXCEPTION 'Registration owner has unexpected privileges.';
    END IF;

    IF has_table_privilege('gympro_app', 'app.members', 'SELECT')
       OR has_table_privilege('gympro_app', 'app.members', 'INSERT')
       OR has_table_privilege('gympro_app', 'app.members', 'UPDATE')
       OR has_table_privilege('gympro_app', 'app.members', 'DELETE') THEN
        RAISE EXCEPTION 'Runtime role has unexpected direct member access.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_app',
        'security.register_member(bytea,uuid,uuid,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Registration EXECUTE privilege is missing.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.register_member(
            NULL::bytea,
            NULL::uuid,
            NULL::uuid,
            'B4 Invalid Token Test',
            '+959000000000',
            NULL::text
        );

        RAISE EXCEPTION 'Invalid token was not rejected.';
    EXCEPTION
        WHEN SQLSTATE '28000' THEN
            RAISE NOTICE 'PASS: Invalid token rejected.';
    END;

    RAISE NOTICE 'PASS: Owner role restrictions verified.';
    RAISE NOTICE 'PASS: Runtime function access verified.';
    RAISE NOTICE 'PASS: Direct member table access denied.';
END
$$;

COMMIT;

SELECT
    p.oid::regprocedure AS function_signature,
    pg_get_userbyid(p.proowner) AS function_owner,
    p.prosecdef AS security_definer,
    has_function_privilege(
        'gympro_app', p.oid, 'EXECUTE'
    ) AS runtime_can_execute,
    has_table_privilege(
        'gympro_app', 'app.members', 'SELECT'
    ) AS runtime_can_select_members,
    has_table_privilege(
        'gympro_app', 'app.members', 'INSERT'
    ) AS runtime_can_insert_members
FROM pg_proc AS p
WHERE p.oid = to_regprocedure(
    'security.register_member(bytea,uuid,uuid,text,text,text)'
);