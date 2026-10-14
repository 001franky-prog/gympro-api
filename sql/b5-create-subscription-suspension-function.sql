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

    IF to_regclass('app.subscription_suspensions') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM pg_roles
           WHERE rolname = 'gympro_membership_owner'
             AND NOT rolcanlogin
             AND NOT rolsuper
             AND NOT rolbypassrls
             AND NOT rolcreatedb
             AND NOT rolcreaterole
             AND NOT rolreplication
             AND NOT rolinherit
       ) THEN
        RAISE EXCEPTION 'Required history table or restricted owner is missing.';
    END IF;

    IF to_regprocedure(
        'security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION 'Suspension function already exists. Inspect before retrying.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.memberships.manage'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Active membership management permission is missing.';
    END IF;
END;
$$;

GRANT SELECT, INSERT ON app.subscription_suspensions
    TO gympro_membership_owner;

GRANT UPDATE (status, suspended_at, updated_at)
    ON app.member_subscriptions
    TO gympro_membership_owner;

CREATE POLICY suspensions_membership_owner_select
    ON app.subscription_suspensions
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY suspensions_membership_owner_insert
    ON app.subscription_suspensions
    FOR INSERT
    TO gympro_membership_owner
    WITH CHECK (true);

CREATE FUNCTION security.suspend_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_subscription_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS SETOF app.subscription_suspensions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
AS $$
DECLARE
    v_session record;
    v_member app.members%ROWTYPE;
    v_subscription app.member_subscriptions%ROWTYPE;
    v_suspension app.subscription_suspensions%ROWTYPE;
    v_reason text;
    v_today date;
    v_suspended_at timestamptz;
BEGIN
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32 THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000',
            MESSAGE = 'Invalid or expired session';
    END IF;

    SELECT *
    INTO v_session
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

    IF p_subscription_id IS NULL OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription and request ID are required';
    END IF;

    v_reason := btrim(p_reason);

    IF v_reason IS NULL
       OR length(v_reason) NOT BETWEEN 2 AND 500
       OR v_reason !~ '[^[:space:]]' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'A suspension reason of 2 to 500 characters is required';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.suspension:'
            || v_session.tenant_id::text
            || ':'
            || p_request_id::text,
            0
        )
    );

    SELECT *
    INTO v_subscription
    FROM app.member_subscriptions
    WHERE tenant_id = v_session.tenant_id
      AND id = p_subscription_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Subscription access denied';
    END IF;

    -- Same member-first lock order as activation and renewal.
    SELECT *
    INTO v_member
    FROM app.members
    WHERE tenant_id = v_session.tenant_id
      AND id = v_subscription.member_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member access denied';
    END IF;

    SELECT *
    INTO v_subscription
    FROM app.member_subscriptions
    WHERE tenant_id = v_session.tenant_id
      AND id = p_subscription_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_subscription.member_id IS DISTINCT FROM v_member.id
       OR v_subscription.branch_id IS DISTINCT FROM v_member.branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Subscription access denied';
    END IF;

    IF NOT COALESCE(
        security.has_tenant_permission(
            v_session.tenant_id,
            v_session.membership_id,
            'gym.memberships.manage',
            v_subscription.branch_id
        ),
        false
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership management permission denied';
    END IF;

    -- Retry returns the original history record.
    SELECT *
    INTO v_suspension
    FROM app.subscription_suspensions
    WHERE tenant_id = v_session.tenant_id
      AND request_id = p_request_id;

    IF FOUND THEN
        IF v_suspension.subscription_id IS DISTINCT FROM p_subscription_id
           OR v_suspension.reason IS DISTINCT FROM v_reason THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID already belongs to another suspension request';
        END IF;

        RETURN NEXT v_suspension;
        RETURN;
    END IF;

    IF v_member.status <> 'active' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member is not eligible for suspension';
    END IF;

    v_suspended_at := statement_timestamp();

    v_today := (
        v_suspended_at AT TIME ZONE 'Asia/Yangon'
    )::date;

    IF v_subscription.status <> 'active'
       OR v_subscription.starts_on IS NULL
       OR v_subscription.ends_on IS NULL
       OR v_subscription.starts_on > v_today
       OR v_subscription.ends_on <= v_today
       OR v_subscription.activated_at IS NULL
       OR v_subscription.activated_at > v_suspended_at THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription is not eligible for suspension';
    END IF;

    INSERT INTO app.subscription_suspensions (
        tenant_id,
        subscription_id,
        request_id,
        reason,
        suspended_at,
        previous_subscription_snapshot
    )
    VALUES (
        v_session.tenant_id,
        v_subscription.id,
        p_request_id,
        v_reason,
        v_suspended_at,
        to_jsonb(v_subscription)
        || jsonb_build_object(
            'suspended_by_membership_id', v_session.membership_id,
            'suspended_by_user_id', v_session.user_id,
            'suspension_session_id', v_session.session_id
        )
    )
    RETURNING * INTO v_suspension;

    UPDATE app.member_subscriptions
    SET
        status = 'suspended',
        suspended_at = v_suspended_at,
        updated_at = v_suspended_at
    WHERE tenant_id = v_session.tenant_id
      AND id = v_subscription.id;

    RETURN NEXT v_suspension;
END;
$$;

ALTER FUNCTION security.suspend_member_subscription(
    bytea, uuid, uuid, text, uuid
)
OWNER TO gympro_membership_owner;

REVOKE ALL ON FUNCTION security.suspend_member_subscription(
    bytea, uuid, uuid, text, uuid
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.suspend_member_subscription(
    bytea, uuid, uuid, text, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime suspension function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime must not have direct suspension history access.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.suspend_member_subscription(
            decode(repeat('00', 32), 'hex'),
            NULL::uuid,
            NULL::uuid,
            'Installation test',
            NULL::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Runtime suspension function access verified.';
    RAISE NOTICE 'PASS: Direct suspension history access denied.';
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
    'security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)'
);