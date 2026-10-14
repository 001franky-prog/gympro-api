\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

-- Allow the trusted purchase function to finalize only the agreed price.
GRANT UPDATE (agreed_price_amount)
    ON app.subscription_renewals
    TO gympro_membership_owner;

CREATE POLICY discount_purchase_owner_renewal_update
    ON app.subscription_renewals
    FOR UPDATE TO gympro_membership_owner
    USING (true)
    WITH CHECK (true);

GRANT CREATE ON SCHEMA security TO gympro_membership_owner;

CREATE FUNCTION security.renew_discounted_membership(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_subscription_id uuid,
    p_plan_price_id uuid,
    p_promotion_id uuid,
    p_request_id uuid
)
RETURNS SETOF app.membership_discounts
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
    v_renewal app.subscription_renewals%ROWTYPE;
    v_history app.membership_discounts%ROWTYPE;
    v_calculation record;
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

    IF p_subscription_id IS NULL OR p_plan_price_id IS NULL
       OR p_promotion_id IS NULL OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Discounted renewal identifiers are required';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.discount:' || p_tenant_id::text
            || ':' || p_request_id::text,
            0
        )
    );

    -- Acquire the ordinary renewal request lock before member locks.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.renewal:' || p_tenant_id::text
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
       OR v_subscription.member_id IS DISTINCT FROM v_member.id
       OR v_subscription.branch_id IS DISTINCT FROM v_member.branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Subscription access denied';
    END IF;

    IF security.has_tenant_permission(
        p_tenant_id, v_session.membership_id,
        'gym.memberships.manage', v_subscription.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership management permission denied';
    END IF;

    IF security.has_tenant_permission(
        p_tenant_id, v_session.membership_id,
        'gym.memberships.apply_discount', v_subscription.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership discount permission denied';
    END IF;

    IF v_subscription.membership_kind <> 'standard' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'FOC subscriptions require dedicated complimentary authorization';
    END IF;

    SELECT * INTO v_history
    FROM app.membership_discounts
    WHERE tenant_id = p_tenant_id
      AND request_id = p_request_id;

    IF FOUND THEN
        IF v_history.purchase_kind <> 'renewal'
           OR v_history.subscription_id IS DISTINCT FROM p_subscription_id
           OR v_history.promotion_id IS DISTINCT FROM p_promotion_id
           OR v_history.actor_snapshot->>'purchase_plan_price_id'
                IS DISTINCT FROM p_plan_price_id::text THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID belongs to another discounted purchase';
        END IF;

        RETURN NEXT v_history;
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM app.subscription_renewals
        WHERE tenant_id = p_tenant_id
          AND request_id = p_request_id
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Request ID already belongs to an ordinary renewal';
    END IF;

    SELECT * INTO STRICT v_renewal
    FROM security.renew_member_subscription(
        p_token_hash, p_tenant_id, p_subscription_id,
        p_plan_price_id, p_request_id
    );

    SELECT * INTO STRICT v_calculation
    FROM security.calculate_membership_discount(
        p_token_hash,
        p_tenant_id,
        v_renewal.plan_id,
        v_subscription.branch_id,
        v_renewal.agreed_price_amount,
        p_promotion_id
    );

    INSERT INTO app.membership_discounts (
        tenant_id, subscription_id, promotion_id, request_id,
        purchase_kind, renewal_id,
        listed_price_amount, discount_amount, agreed_price_amount,
        currency_code, promotion_snapshot, actor_snapshot
    )
    VALUES (
        p_tenant_id, p_subscription_id, p_promotion_id, p_request_id,
        'renewal', v_renewal.id,
        v_renewal.agreed_price_amount,
        v_calculation.discount_amount,
        v_calculation.agreed_price_amount,
        v_renewal.currency_code,
        v_calculation.promotion_snapshot,
        v_calculation.actor_snapshot || jsonb_build_object(
            'purchase_member_id', v_member.id,
            'purchase_plan_id', v_renewal.plan_id,
            'purchase_plan_price_id', p_plan_price_id
        )
    )
    RETURNING * INTO v_history;

    UPDATE app.subscription_renewals
    SET agreed_price_amount = v_calculation.agreed_price_amount
    WHERE tenant_id = p_tenant_id
      AND subscription_id = p_subscription_id
      AND id = v_renewal.id;

    UPDATE app.member_subscriptions
    SET agreed_price_amount = v_calculation.agreed_price_amount,
        updated_at = statement_timestamp()
    WHERE tenant_id = p_tenant_id
      AND id = p_subscription_id;

    RETURN NEXT v_history;
END;
$$;

ALTER FUNCTION security.renew_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid
) OWNER TO gympro_membership_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;

REVOKE ALL ON FUNCTION security.renew_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.renew_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid
) TO gympro_app;

DO $$
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.renew_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.subscription_renewals',
        'SELECT,INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.membership_discounts',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime function-only boundary failed.';
    END IF;

    RAISE NOTICE 'PASS: Discounted renewal function-only access verified.';
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
  AND p.proname = 'renew_discounted_membership';