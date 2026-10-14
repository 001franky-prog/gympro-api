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

    IF to_regclass('app.subscription_foc_grants') IS NULL THEN
        RAISE EXCEPTION 'Required FOC history table is missing.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'gympro_foc_owner'
    ) THEN
        RAISE EXCEPTION 'FOC owner already exists. Inspect before retrying.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.memberships.grant_foc'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Active dedicated FOC permission is missing.';
    END IF;
END;
$$;

CREATE ROLE gympro_foc_owner
    NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS
    NOCREATEDB NOCREATEROLE NOREPLICATION;

GRANT USAGE ON SCHEMA app, security TO gympro_foc_owner;

GRANT SELECT ON
    app.members,
    app.membership_plans,
    app.plan_prices,
    app.member_subscriptions
TO gympro_foc_owner;

GRANT INSERT ON app.member_subscriptions TO gympro_foc_owner;
GRANT SELECT, INSERT ON app.subscription_foc_grants TO gympro_foc_owner;

GRANT UPDATE (status, updated_at) ON app.members TO gympro_foc_owner;

-- Required for locking the selected plan and price.
GRANT UPDATE (id) ON app.membership_plans, app.plan_prices
TO gympro_foc_owner;

GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea)
TO gympro_foc_owner;

GRANT EXECUTE ON FUNCTION
    security.has_tenant_permission(uuid, uuid, text, uuid)
TO gympro_foc_owner;

CREATE POLICY members_foc_owner_select
ON app.members FOR SELECT TO gympro_foc_owner USING (true);

CREATE POLICY members_foc_owner_update
ON app.members FOR UPDATE TO gympro_foc_owner
USING (true) WITH CHECK (true);

CREATE POLICY plans_foc_owner_select
ON app.membership_plans FOR SELECT TO gympro_foc_owner USING (true);

CREATE POLICY plans_foc_owner_lock
ON app.membership_plans FOR UPDATE TO gympro_foc_owner
USING (true) WITH CHECK (true);

CREATE POLICY prices_foc_owner_select
ON app.plan_prices FOR SELECT TO gympro_foc_owner USING (true);

CREATE POLICY prices_foc_owner_lock
ON app.plan_prices FOR UPDATE TO gympro_foc_owner
USING (true) WITH CHECK (true);

CREATE POLICY subscriptions_foc_owner_select
ON app.member_subscriptions FOR SELECT TO gympro_foc_owner USING (true);

CREATE POLICY subscriptions_foc_owner_insert
ON app.member_subscriptions FOR INSERT TO gympro_foc_owner
WITH CHECK (true);

CREATE POLICY foc_grants_owner_select
ON app.subscription_foc_grants FOR SELECT TO gympro_foc_owner USING (true);

CREATE POLICY foc_grants_owner_insert
ON app.subscription_foc_grants FOR INSERT TO gympro_foc_owner
WITH CHECK (true);

CREATE FUNCTION security.grant_foc_membership(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_member_id uuid,
    p_plan_id uuid,
    p_plan_price_id uuid,
    p_reason text,
    p_request_id uuid
)
RETURNS SETOF app.subscription_foc_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
AS $$
DECLARE
    v_session record;
    v_member app.members%ROWTYPE;
    v_plan app.membership_plans%ROWTYPE;
    v_price app.plan_prices%ROWTYPE;
    v_subscription app.member_subscriptions%ROWTYPE;
    v_grant app.subscription_foc_grants%ROWTYPE;
    v_reason text;
    v_today date;
    v_ends_on date;
BEGIN
    IF p_token_hash IS NULL OR octet_length(p_token_hash) <> 32 THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000', MESSAGE = 'Invalid or expired session';
    END IF;

    SELECT * INTO v_session
    FROM security.verify_tenant_session(p_token_hash);

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '28000', MESSAGE = 'Invalid or expired session';
    END IF;

    IF p_tenant_id IS DISTINCT FROM v_session.tenant_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501', MESSAGE = 'Tenant access denied';
    END IF;

    IF p_member_id IS NULL OR p_plan_id IS NULL
       OR p_plan_price_id IS NULL OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member, plan, price, and request ID are required';
    END IF;

    v_reason := btrim(p_reason);

    IF v_reason IS NULL
       OR length(v_reason) NOT BETWEEN 2 AND 500
       OR v_reason !~ '[^[:space:]]' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'An FOC reason of 2 to 500 characters is required';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.foc:' || v_session.tenant_id::text
            || ':' || p_request_id::text,
            0
        )
    );

    SELECT * INTO v_member
    FROM app.members
    WHERE tenant_id = v_session.tenant_id AND id = p_member_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501', MESSAGE = 'Member access denied';
    END IF;

    IF NOT COALESCE(
        security.has_tenant_permission(
            v_session.tenant_id,
            v_session.membership_id,
            'gym.memberships.grant_foc',
            v_member.branch_id
        ),
        false
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Complimentary membership permission denied';
    END IF;

    SELECT * INTO v_grant
    FROM app.subscription_foc_grants
    WHERE tenant_id = v_session.tenant_id AND request_id = p_request_id;

    IF FOUND THEN
        SELECT * INTO v_subscription
        FROM app.member_subscriptions
        WHERE tenant_id = v_session.tenant_id
          AND id = v_grant.subscription_id;

        IF NOT FOUND
           OR v_subscription.member_id IS DISTINCT FROM p_member_id
           OR v_subscription.plan_id IS DISTINCT FROM p_plan_id
           OR v_subscription.plan_price_id IS DISTINCT FROM p_plan_price_id
           OR v_subscription.membership_kind <> 'foc'
           OR v_grant.reason IS DISTINCT FROM v_reason THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID already belongs to another FOC request';
        END IF;

        RETURN NEXT v_grant;
        RETURN;
    END IF;

    IF v_member.status NOT IN ('pending', 'active') THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member is not eligible for complimentary membership';
    END IF;

    IF EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE tenant_id = v_session.tenant_id
          AND member_id = v_member.id
          AND status IN ('active', 'suspended')
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member already has a current subscription';
    END IF;

    SELECT * INTO v_plan
    FROM app.membership_plans
    WHERE tenant_id = v_session.tenant_id AND id = p_plan_id
    FOR SHARE;

    IF NOT FOUND OR v_plan.status <> 'active' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023', MESSAGE = 'Active membership plan not found';
    END IF;

    SELECT * INTO v_price
    FROM app.plan_prices
    WHERE tenant_id = v_session.tenant_id
      AND plan_id = v_plan.id
      AND id = p_plan_price_id
    FOR SHARE;

    IF NOT FOUND OR v_price.status <> 'active' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023', MESSAGE = 'Active plan price not found';
    END IF;

    IF v_price.branch_id IS NOT NULL
       AND v_price.branch_id IS DISTINCT FROM v_member.branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Plan price does not apply to the member branch';
    END IF;

    v_today := (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date;

    BEGIN
        v_ends_on := CASE v_plan.duration_unit
            WHEN 'days' THEN v_today + v_plan.duration_value
            WHEN 'weeks' THEN v_today + (v_plan.duration_value * 7)
            WHEN 'months' THEN
                (v_today + make_interval(months => v_plan.duration_value))::date
            WHEN 'years' THEN
                (v_today + make_interval(years => v_plan.duration_value))::date
        END;
    EXCEPTION
        WHEN numeric_value_out_of_range OR datetime_field_overflow THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Plan duration is outside supported date limits';
    END;

    IF v_ends_on IS NULL OR NOT isfinite(v_ends_on)
       OR v_ends_on <= v_today THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023', MESSAGE = 'Invalid calculated membership dates';
    END IF;

    INSERT INTO app.member_subscriptions (
        tenant_id, member_id, branch_id, plan_id, plan_price_id,
        duration_value, duration_unit, agreed_price_amount,
        currency_code, membership_kind, status,
        starts_on, ends_on, activated_at
    )
    VALUES (
        v_session.tenant_id, v_member.id, v_member.branch_id,
        v_plan.id, v_price.id,
        v_plan.duration_value, v_plan.duration_unit, 0,
        v_price.currency_code, 'foc', 'active',
        v_today, v_ends_on, statement_timestamp()
    )
    RETURNING * INTO v_subscription;

    INSERT INTO app.subscription_foc_grants (
        tenant_id, subscription_id, request_id, reason,
        listed_price_amount, currency_code,
        previous_member_snapshot, granted_at
    )
    VALUES (
        v_session.tenant_id, v_subscription.id, p_request_id, v_reason,
        v_price.price_amount, v_price.currency_code,
        to_jsonb(v_member) || jsonb_build_object(
            'granted_by_membership_id', v_session.membership_id,
            'granted_by_user_id', v_session.user_id,
            'foc_session_id', v_session.session_id
        ),
        statement_timestamp()
    )
    RETURNING * INTO v_grant;

    UPDATE app.members
    SET status = 'active', updated_at = statement_timestamp()
    WHERE tenant_id = v_session.tenant_id AND id = v_member.id;

    RETURN NEXT v_grant;
END;
$$;

ALTER FUNCTION security.grant_foc_membership(
    bytea, uuid, uuid, uuid, uuid, text, uuid
)
OWNER TO gympro_foc_owner;

REVOKE ALL ON FUNCTION security.grant_foc_membership(
    bytea, uuid, uuid, uuid, uuid, text, uuid
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.grant_foc_membership(
    bytea, uuid, uuid, uuid, uuid, text, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_role record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO STRICT v_role
    FROM pg_roles WHERE rolname = 'gympro_foc_owner';

    IF v_role.rolcanlogin OR v_role.rolsuper OR v_role.rolbypassrls
       OR v_role.rolcreatedb OR v_role.rolcreaterole
       OR v_role.rolreplication OR v_role.rolinherit
       OR EXISTS (
           SELECT 1 FROM pg_auth_members
           WHERE roleid = v_role.oid OR member = v_role.oid
       ) THEN
        RAISE EXCEPTION 'Unsafe FOC owner configuration.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_app',
        'security.grant_foc_membership(bytea,uuid,uuid,uuid,uuid,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime FOC function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected direct runtime FOC history access.';
    END IF;

    BEGIN
        PERFORM * FROM security.grant_foc_membership(
            decode(repeat('00', 32), 'hex'),
            NULL::uuid, NULL::uuid, NULL::uuid, NULL::uuid,
            'Installation test', NULL::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Restricted FOC owner verified.';
    RAISE NOTICE 'PASS: Runtime function access verified.';
    RAISE NOTICE 'PASS: Direct FOC history access denied.';
    RAISE NOTICE 'PASS: Invalid session rejected.';
END;
$$;

COMMIT;

SELECT
    p.oid::regprocedure AS function_signature,
    pg_get_userbyid(p.proowner) AS function_owner,
    p.prosecdef AS security_definer,
    has_function_privilege('gympro_app', p.oid, 'EXECUTE')
        AS runtime_can_execute
FROM pg_proc AS p
WHERE p.oid = to_regprocedure(
    'security.grant_foc_membership(bytea,uuid,uuid,uuid,uuid,text,uuid)'
);