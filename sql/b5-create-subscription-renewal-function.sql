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

    IF to_regclass('app.subscription_renewals') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM pg_roles
           WHERE rolname = 'gympro_membership_owner'
             AND NOT rolcanlogin
             AND NOT rolsuper
             AND NOT rolbypassrls
       ) THEN
        RAISE EXCEPTION 'Required renewal table or restricted owner is missing.';
    END IF;

    IF to_regprocedure(
        'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION 'Renewal function already exists. Inspect before retrying.';
    END IF;
END;
$$;

GRANT SELECT, INSERT ON app.subscription_renewals
    TO gympro_membership_owner;

GRANT UPDATE (
    starts_on,
    ends_on,
    plan_price_id,
    duration_value,
    duration_unit,
    agreed_price_amount,
    currency_code,
    status,
    activated_at,
    updated_at
) ON app.member_subscriptions
    TO gympro_membership_owner;

CREATE POLICY renewals_membership_owner_select
    ON app.subscription_renewals
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY renewals_membership_owner_insert
    ON app.subscription_renewals
    FOR INSERT
    TO gympro_membership_owner
    WITH CHECK (true);

CREATE POLICY subscriptions_membership_owner_update
    ON app.member_subscriptions
    FOR UPDATE
    TO gympro_membership_owner
    USING (true)
    WITH CHECK (true);

CREATE FUNCTION security.renew_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_subscription_id uuid,
    p_plan_price_id uuid,
    p_request_id uuid
)
RETURNS SETOF app.subscription_renewals
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
    v_plan app.membership_plans%ROWTYPE;
    v_price app.plan_prices%ROWTYPE;
    v_renewal app.subscription_renewals%ROWTYPE;
    v_today date;
    v_starts_on date;
    v_ends_on date;
    v_restart boolean;
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

    IF p_subscription_id IS NULL
       OR p_plan_price_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription, price, and request ID are required';
    END IF;

    -- Serializes retries of the same tenant/request pair,
    -- including attempts to reuse it for another subscription.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.renewal:'
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

    -- Same member-first lock order as activation.
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

    -- A retry returns the original purchase record.
    -- It never extends dates a second time.
    SELECT *
    INTO v_renewal
    FROM app.subscription_renewals
    WHERE tenant_id = v_session.tenant_id
      AND request_id = p_request_id;

    IF FOUND THEN
        IF v_renewal.subscription_id IS DISTINCT FROM p_subscription_id
           OR v_renewal.plan_price_id IS DISTINCT FROM p_plan_price_id THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID already belongs to another renewal request';
        END IF;

        RETURN NEXT v_renewal;
        RETURN;
    END IF;

    IF v_subscription.status NOT IN ('active', 'expired')
       OR v_subscription.ends_on IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription is not eligible for renewal';
    END IF;

    v_today := (
        statement_timestamp() AT TIME ZONE 'Asia/Yangon'
    )::date;

    IF v_member.status <> 'active'
       AND NOT (
           v_member.status = 'inactive'
           AND v_subscription.ends_on <= v_today
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member is not eligible for renewal';
    END IF;

    IF v_subscription.status = 'expired'
       AND v_subscription.ends_on > v_today THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription expiry dates are inconsistent';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM app.member_subscriptions
        WHERE tenant_id = v_session.tenant_id
          AND member_id = v_member.id
          AND id <> v_subscription.id
          AND status IN ('active', 'suspended')
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member has another current subscription';
    END IF;

    SELECT *
    INTO v_plan
    FROM app.membership_plans
    WHERE tenant_id = v_session.tenant_id
      AND id = v_subscription.plan_id
    FOR SHARE;

    IF NOT FOUND OR v_plan.status <> 'active' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Active membership plan not found';
    END IF;

    SELECT *
    INTO v_price
    FROM app.plan_prices
    WHERE tenant_id = v_session.tenant_id
      AND plan_id = v_plan.id
      AND id = p_plan_price_id
    FOR SHARE;

    IF NOT FOUND OR v_price.status <> 'active' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Active plan price not found';
    END IF;

    IF v_price.branch_id IS NOT NULL
       AND v_price.branch_id IS DISTINCT FROM v_subscription.branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Plan price does not apply to the member branch';
    END IF;

    v_starts_on := greatest(v_today, v_subscription.ends_on);
    v_restart := v_subscription.ends_on <= v_today;

    BEGIN
        v_ends_on := CASE v_plan.duration_unit
            WHEN 'days' THEN
                v_starts_on + v_plan.duration_value
            WHEN 'weeks' THEN
                v_starts_on + (v_plan.duration_value * 7)
            WHEN 'months' THEN
                (
                    v_starts_on
                    + make_interval(months => v_plan.duration_value)
                )::date
            WHEN 'years' THEN
                (
                    v_starts_on
                    + make_interval(years => v_plan.duration_value)
                )::date
        END;
    EXCEPTION
        WHEN numeric_value_out_of_range
          OR datetime_field_overflow THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Plan duration is outside supported date limits';
    END;

    IF v_ends_on IS NULL
       OR NOT isfinite(v_ends_on)
       OR v_ends_on <= v_starts_on THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid calculated membership dates';
    END IF;

    INSERT INTO app.subscription_renewals (
        tenant_id,
        subscription_id,
        request_id,
        plan_id,
        plan_price_id,
        previous_ends_on,
        renewal_starts_on,
        renewal_ends_on,
        duration_value,
        duration_unit,
        agreed_price_amount,
        currency_code,
        previous_subscription_snapshot
    )
    VALUES (
        v_session.tenant_id,
        v_subscription.id,
        p_request_id,
        v_plan.id,
        v_price.id,
        v_subscription.ends_on,
        v_starts_on,
        v_ends_on,
        v_plan.duration_value,
        v_plan.duration_unit,
        v_price.price_amount,
        v_price.currency_code,
        to_jsonb(v_subscription)
        || jsonb_build_object(
            'renewed_by_membership_id', v_session.membership_id,
            'renewed_by_user_id', v_session.user_id,
            'renewal_session_id', v_session.session_id
        )
    )
    RETURNING * INTO v_renewal;

    UPDATE app.member_subscriptions
    SET
        starts_on = CASE
            WHEN v_restart THEN v_starts_on
            ELSE starts_on
        END,
        ends_on = v_ends_on,
        plan_price_id = v_price.id,
        duration_value = v_plan.duration_value,
        duration_unit = v_plan.duration_unit,
        agreed_price_amount = v_price.price_amount,
        currency_code = v_price.currency_code,
        status = 'active',
        activated_at = CASE
            WHEN v_restart THEN statement_timestamp()
            ELSE activated_at
        END,
        updated_at = statement_timestamp()
    WHERE tenant_id = v_session.tenant_id
      AND id = v_subscription.id;

    UPDATE app.members
    SET
        status = 'active',
        updated_at = statement_timestamp()
    WHERE tenant_id = v_session.tenant_id
      AND id = v_member.id;

    RETURN NEXT v_renewal;
END;
$$;

ALTER FUNCTION security.renew_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
OWNER TO gympro_membership_owner;

REVOKE ALL ON FUNCTION security.renew_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.renew_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime renewal function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime must not have direct renewal history access.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.renew_member_subscription(
            decode(repeat('00', 32), 'hex'),
            NULL::uuid,
            NULL::uuid,
            NULL::uuid,
            NULL::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Runtime renewal function access verified.';
    RAISE NOTICE 'PASS: Direct renewal history access denied.';
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
    'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)'
);