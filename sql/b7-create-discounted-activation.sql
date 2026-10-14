\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

GRANT SELECT, INSERT ON app.membership_discounts
    TO gympro_membership_owner;

CREATE POLICY discount_purchase_owner_read
    ON app.membership_discounts
    FOR SELECT TO gympro_membership_owner
    USING (true);

CREATE POLICY discount_purchase_owner_insert
    ON app.membership_discounts
    FOR INSERT TO gympro_membership_owner
    WITH CHECK (true);

GRANT CREATE ON SCHEMA security TO gympro_membership_owner;

CREATE FUNCTION security.activate_discounted_membership(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_member_id uuid,
    p_plan_id uuid,
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

    IF p_member_id IS NULL OR p_plan_id IS NULL
       OR p_plan_price_id IS NULL OR p_promotion_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Discounted activation identifiers are required';
    END IF;

    -- Shared request boundary for discounted purchase operations.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'gympro.discount:' || p_tenant_id::text
            || ':' || p_request_id::text,
            0
        )
    );

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

    IF security.has_tenant_permission(
        p_tenant_id, v_session.membership_id,
        'gym.memberships.manage', v_member.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership management permission denied';
    END IF;

    IF security.has_tenant_permission(
        p_tenant_id, v_session.membership_id,
        'gym.memberships.apply_discount', v_member.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership discount permission denied';
    END IF;

    SELECT * INTO v_history
    FROM app.membership_discounts
    WHERE tenant_id = p_tenant_id
      AND request_id = p_request_id;

    IF FOUND THEN
        IF v_history.purchase_kind <> 'activation'
           OR v_history.promotion_id IS DISTINCT FROM p_promotion_id
           OR v_history.actor_snapshot->>'purchase_member_id'
                IS DISTINCT FROM p_member_id::text
           OR v_history.actor_snapshot->>'purchase_plan_id'
                IS DISTINCT FROM p_plan_id::text
           OR v_history.actor_snapshot->>'purchase_plan_price_id'
                IS DISTINCT FROM p_plan_price_id::text THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Request ID belongs to another discounted purchase';
        END IF;

        -- Return the original receipt without reapplying the purchase.
        RETURN NEXT v_history;
        RETURN;
    END IF;

    -- Reuse existing eligibility, date calculation, and locking.
    SELECT * INTO STRICT v_subscription
    FROM security.activate_member_subscription(
        p_token_hash, p_tenant_id, p_member_id,
        p_plan_id, p_plan_price_id
    );

    IF v_subscription.membership_kind <> 'standard' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Discounts require a standard membership';
    END IF;

    SELECT * INTO STRICT v_calculation
    FROM security.calculate_membership_discount(
        p_token_hash,
        p_tenant_id,
        v_subscription.plan_id,
        v_subscription.branch_id,
        v_subscription.agreed_price_amount,
        p_promotion_id
    );

    INSERT INTO app.membership_discounts (
        tenant_id,
        subscription_id,
        promotion_id,
        request_id,
        purchase_kind,
        listed_price_amount,
        discount_amount,
        agreed_price_amount,
        currency_code,
        promotion_snapshot,
        actor_snapshot
    )
    VALUES (
        p_tenant_id,
        v_subscription.id,
        p_promotion_id,
        p_request_id,
        'activation',
        v_subscription.agreed_price_amount,
        v_calculation.discount_amount,
        v_calculation.agreed_price_amount,
        v_subscription.currency_code,
        v_calculation.promotion_snapshot,
        v_calculation.actor_snapshot || jsonb_build_object(
            'purchase_member_id', p_member_id,
            'purchase_plan_id', p_plan_id,
            'purchase_plan_price_id', p_plan_price_id
        )
    )
    RETURNING * INTO v_history;

    UPDATE app.member_subscriptions
    SET agreed_price_amount = v_calculation.agreed_price_amount,
        updated_at = statement_timestamp()
    WHERE tenant_id = p_tenant_id
      AND id = v_subscription.id;

    RETURN NEXT v_history;
END;
$$;

ALTER FUNCTION security.activate_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid,uuid
) OWNER TO gympro_membership_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;

REVOKE ALL ON FUNCTION security.activate_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid,uuid
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.activate_discounted_membership(
    bytea,uuid,uuid,uuid,uuid,uuid,uuid
) TO gympro_app;

DO $$
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.activate_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.membership_discounts',
        'SELECT,INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime function-only boundary failed.';
    END IF;

    IF NOT has_column_privilege(
        'gympro_membership_owner',
        'app.member_subscriptions',
        'agreed_price_amount',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION 'Purchase owner cannot store the agreed price.';
    END IF;

    RAISE NOTICE 'PASS: Discounted activation function-only access verified.';
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
  AND p.proname = 'activate_discounted_membership';