\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

GRANT CREATE ON SCHEMA security TO gympro_membership_owner;

CREATE FUNCTION security.activate_branch_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_branch_id uuid,
    p_member_id uuid,
    p_plan_id uuid,
    p_plan_price_id uuid
)
RETURNS SETOF app.member_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
AS $$
DECLARE
    v_session record;
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

    -- Preserve the member-first lifecycle lock order.
    SELECT * INTO v_member
    FROM app.members
    WHERE tenant_id = p_tenant_id
      AND id = p_member_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Member access denied';
    END IF;

    -- Even a tenant administrator must use the member's actual branch.
    IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Branch access denied';
    END IF;

    RETURN QUERY
    SELECT *
    FROM security.activate_member_subscription(
        p_token_hash,
        p_tenant_id,
        p_member_id,
        p_plan_id,
        p_plan_price_id
    );
END;
$$;

ALTER FUNCTION security.activate_branch_member_subscription(
    bytea,uuid,uuid,uuid,uuid,uuid
) OWNER TO gympro_membership_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;

REVOKE ALL ON FUNCTION security.activate_branch_member_subscription(
    bytea,uuid,uuid,uuid,uuid,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.activate_branch_member_subscription(
    bytea,uuid,uuid,uuid,uuid,uuid
) TO gympro_app;

DO $$
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.activate_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.members',
        'SELECT,INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Branch activation security boundary failed.';
    END IF;

    RAISE NOTICE 'PASS: Branch activation function-only access verified.';
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
  AND p.proname = 'activate_branch_member_subscription';