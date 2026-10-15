\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

GRANT CREATE ON SCHEMA security TO gympro_membership_owner;

CREATE FUNCTION security.suspend_branch_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_branch_id uuid,
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
    v_subscription app.member_subscriptions%ROWTYPE;
    v_member app.members%ROWTYPE;
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

    IF p_tenant_id IS NULL
       OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Tenant access denied';
    END IF;

    IF p_branch_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Branch access denied';
    END IF;

    IF security.has_tenant_permission(
        p_tenant_id,
        v_session.membership_id,
        'gym.memberships.manage',
        p_branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership management permission denied';
    END IF;

    IF p_subscription_id IS NULL OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription and request ID are required';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.suspension:' || p_tenant_id::text
            || ':' || p_request_id::text,
            0
        )
    );

    SELECT * INTO v_subscription
    FROM app.member_subscriptions
    WHERE tenant_id = p_tenant_id
      AND id = p_subscription_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Subscription access denied';
    END IF;

    SELECT * INTO v_member
    FROM app.members
    WHERE tenant_id = p_tenant_id
      AND id = v_subscription.member_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member access denied';
    END IF;

    SELECT * INTO v_subscription
    FROM app.member_subscriptions
    WHERE tenant_id = p_tenant_id
      AND id = p_subscription_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_subscription.member_id IS DISTINCT FROM v_member.id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Subscription access denied';
    END IF;

    IF v_subscription.branch_id IS DISTINCT FROM p_branch_id
       OR v_member.branch_id IS DISTINCT FROM p_branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Branch access denied';
    END IF;

    RETURN QUERY
    SELECT *
    FROM security.suspend_member_subscription(
        p_token_hash,
        p_tenant_id,
        p_subscription_id,
        p_reason,
        p_request_id
    );
END;
$$;

ALTER FUNCTION security.suspend_branch_member_subscription(
    bytea,uuid,uuid,uuid,text,uuid
) OWNER TO gympro_membership_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;

REVOKE ALL ON FUNCTION security.suspend_branch_member_subscription(
    bytea,uuid,uuid,uuid,text,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.suspend_branch_member_subscription(
    bytea,uuid,uuid,uuid,text,uuid
) TO gympro_app;

DO $$
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.suspend_branch_member_subscription(bytea,uuid,uuid,uuid,text,uuid)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.subscription_suspensions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Branch suspension security boundary failed.';
    END IF;

    RAISE NOTICE 'PASS: Branch suspension function-only access verified.';
END;
$$;

COMMIT;

SELECT
    p.oid::regprocedure AS function_signature,
    r.rolname AS function_owner,
    p.prosecdef AS security_definer,
    has_function_privilege(
        'gympro_app', p.oid, 'EXECUTE'
    ) AS runtime_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_roles r ON r.oid = p.proowner
WHERE n.nspname = 'security'
  AND p.proname = 'suspend_branch_member_subscription';