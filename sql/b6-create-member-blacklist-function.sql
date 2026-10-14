\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run installation in gympro_saas as postgres.';
    END IF;

    IF to_regclass('app.member_blacklist_events') IS NULL
       OR to_regclass('app.member_subscriptions') IS NULL THEN
        RAISE EXCEPTION 'Required earlier tables are missing.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'gympro_blacklist_owner'
    ) THEN
        RAISE EXCEPTION 'Blacklist owner already exists. Inspect before retrying.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.members.update'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Active member update permission is missing.';
    END IF;
END;
$$;

CREATE ROLE gympro_blacklist_owner
    NOLOGIN
    NOINHERIT
    NOSUPERUSER
    NOBYPASSRLS
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

GRANT USAGE ON SCHEMA app, security TO gympro_blacklist_owner;

GRANT SELECT ON app.members, app.member_subscriptions
    TO gympro_blacklist_owner;

GRANT UPDATE (status, updated_at) ON app.members
    TO gympro_blacklist_owner;

GRANT SELECT, INSERT ON app.member_blacklist_events
    TO gympro_blacklist_owner;

GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea)
    TO gympro_blacklist_owner;

GRANT EXECUTE ON FUNCTION
    security.has_tenant_permission(uuid, uuid, text, uuid)
    TO gympro_blacklist_owner;

CREATE POLICY members_blacklist_owner_select
    ON app.members
    FOR SELECT TO gympro_blacklist_owner
    USING (true);

CREATE POLICY members_blacklist_owner_update
    ON app.members
    FOR UPDATE TO gympro_blacklist_owner
    USING (true)
    WITH CHECK (true);

CREATE POLICY subscriptions_blacklist_owner_select
    ON app.member_subscriptions
    FOR SELECT TO gympro_blacklist_owner
    USING (true);

CREATE POLICY blacklist_events_owner_select
    ON app.member_blacklist_events
    FOR SELECT TO gympro_blacklist_owner
    USING (true);

CREATE POLICY blacklist_events_owner_insert
    ON app.member_blacklist_events
    FOR INSERT TO gympro_blacklist_owner
    WITH CHECK (true);

CREATE FUNCTION security.change_member_blacklist(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_member_id uuid,
    p_action text,
    p_reason text,
    p_request_id uuid
)
RETURNS SETOF app.member_blacklist_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
AS $$
DECLARE
    v_session record;
    v_member app.members%ROWTYPE;
    v_event app.member_blacklist_events%ROWTYPE;
    v_previous_blacklist app.member_blacklist_events%ROWTYPE;
    v_reason text;
    v_resulting_status text;
    v_now timestamptz;
    v_today date;
BEGIN
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32 THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000',
            MESSAGE = 'Invalid or expired session';
    END IF;

    SELECT * INTO v_session
    FROM security.verify_tenant_session(p_token_hash);

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000',
            MESSAGE = 'Invalid or expired session';
    END IF;

    IF p_tenant_id IS DISTINCT FROM v_session.tenant_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Tenant access denied';
    END IF;

    IF p_member_id IS NULL OR p_request_id IS NULL
       OR p_action IS NULL
       OR p_action NOT IN ('blacklist', 'unblacklist') THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Valid member, action, and request ID are required';
    END IF;

    v_reason := btrim(p_reason);

    IF v_reason IS NULL
       OR length(v_reason) NOT BETWEEN 2 AND 500
       OR v_reason !~ '[^[:space:]]' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'A blacklist reason of 2 to 500 characters is required';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.blacklist:'
            || v_session.tenant_id::text
            || ':'
            || p_request_id::text,
            0
        )
    );

    SELECT * INTO v_member
    FROM app.members
    WHERE tenant_id = v_session.tenant_id
      AND id = p_member_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member access denied';
    END IF;

    IF NOT COALESCE(
        security.has_tenant_permission(
            v_session.tenant_id,
            v_session.membership_id,
            'gym.members.update',
            v_member.branch_id
        ),
        false
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member blacklist permission denied';
    END IF;

    SELECT * INTO v_event
    FROM app.member_blacklist_events
    WHERE tenant_id = v_session.tenant_id
      AND request_id = p_request_id;

    IF FOUND THEN
        IF v_event.member_id IS DISTINCT FROM p_member_id
           OR v_event.event_type IS DISTINCT FROM p_action
           OR v_event.reason IS DISTINCT FROM v_reason THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID already belongs to another blacklist request';
        END IF;

        RETURN NEXT v_event;
        RETURN;
    END IF;

    v_now := statement_timestamp();
    v_today := (v_now AT TIME ZONE 'Asia/Yangon')::date;

    IF p_action = 'blacklist' THEN
        IF v_member.status = 'blacklisted' THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Member is already blacklisted';
        END IF;

        v_resulting_status := 'blacklisted';
    ELSE
        IF v_member.status <> 'blacklisted' THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Member is not blacklisted';
        END IF;

        SELECT * INTO v_previous_blacklist
        FROM app.member_blacklist_events
        WHERE tenant_id = v_session.tenant_id
          AND member_id = v_member.id
          AND event_type = 'blacklist'
        ORDER BY recorded_at DESC, id DESC
        LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Previous blacklist history is missing';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM app.member_subscriptions
            WHERE tenant_id = v_session.tenant_id
              AND member_id = v_member.id
              AND status = 'active'
              AND starts_on <= v_today
              AND ends_on > v_today
        ) THEN
            v_resulting_status := 'active';
        ELSIF v_previous_blacklist.previous_status = 'pending'
              AND NOT EXISTS (
                  SELECT 1
                  FROM app.member_subscriptions
                  WHERE tenant_id = v_session.tenant_id
                    AND member_id = v_member.id
              ) THEN
            v_resulting_status := 'pending';
        ELSE
            v_resulting_status := 'inactive';
        END IF;
    END IF;

    INSERT INTO app.member_blacklist_events (
        tenant_id,
        member_id,
        request_id,
        event_type,
        reason,
        previous_status,
        resulting_status,
        previous_member_snapshot,
        recorded_at
    )
    VALUES (
        v_session.tenant_id,
        v_member.id,
        p_request_id,
        p_action,
        v_reason,
        v_member.status,
        v_resulting_status,
        to_jsonb(v_member)
        || jsonb_build_object(
            'changed_by_membership_id', v_session.membership_id,
            'changed_by_user_id', v_session.user_id,
            'blacklist_session_id', v_session.session_id
        ),
        v_now
    )
    RETURNING * INTO v_event;

    UPDATE app.members
    SET
        status = v_resulting_status,
        updated_at = v_now
    WHERE tenant_id = v_session.tenant_id
      AND id = v_member.id;

    RETURN NEXT v_event;
END;
$$;

ALTER FUNCTION security.change_member_blacklist(
    bytea, uuid, uuid, text, text, uuid
)
OWNER TO gympro_blacklist_owner;

REVOKE ALL ON FUNCTION security.change_member_blacklist(
    bytea, uuid, uuid, text, text, uuid
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.change_member_blacklist(
    bytea, uuid, uuid, text, text, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_role record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO STRICT v_role
    FROM pg_roles
    WHERE rolname = 'gympro_blacklist_owner';

    IF v_role.rolcanlogin
       OR v_role.rolsuper
       OR v_role.rolbypassrls
       OR v_role.rolcreatedb
       OR v_role.rolcreaterole
       OR v_role.rolreplication
       OR v_role.rolinherit
       OR EXISTS (
           SELECT 1 FROM pg_auth_members
           WHERE roleid = v_role.oid OR member = v_role.oid
       ) THEN
        RAISE EXCEPTION 'Unsafe blacklist owner configuration.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_app',
        'security.change_member_blacklist(bytea,uuid,uuid,text,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime blacklist function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected runtime blacklist history access.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.change_member_blacklist(
            decode(repeat('00', 32), 'hex'),
            NULL::uuid,
            NULL::uuid,
            'blacklist',
            'Installation test',
            NULL::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Restricted blacklist owner verified.';
    RAISE NOTICE 'PASS: Runtime function access verified.';
    RAISE NOTICE 'PASS: Direct blacklist history access denied.';
    RAISE NOTICE 'PASS: Invalid session rejected.';
END;
$$;

COMMIT;

SELECT
    p.oid::regprocedure AS function_signature,
    pg_get_userbyid(p.proowner) AS function_owner,
    p.prosecdef AS security_definer,
    has_function_privilege(
        'gympro_app', p.oid, 'EXECUTE'
    ) AS runtime_can_execute
FROM pg_proc AS p
WHERE p.oid = to_regprocedure(
    'security.change_member_blacklist(bytea,uuid,uuid,text,text,uuid)'
);