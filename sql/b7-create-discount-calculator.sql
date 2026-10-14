\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

GRANT CREATE ON SCHEMA security TO gympro_promotion_owner;

CREATE FUNCTION security.calculate_membership_discount(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_plan_id uuid,
    p_branch_id uuid,
    p_listed_price numeric,
    p_promotion_id uuid
)
RETURNS TABLE (
    discount_amount numeric,
    agreed_price_amount numeric,
    promotion_snapshot jsonb,
    actor_snapshot jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
AS $$
DECLARE
    v_session record;
    v_promotion app.membership_promotions%ROWTYPE;
    v_today date;
    v_discount numeric;
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

    IF security.has_tenant_permission(
        p_tenant_id,
        v_session.membership_id,
        'gym.memberships.apply_discount',
        p_branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership discount permission denied';
    END IF;

    IF p_plan_id IS NULL
       OR p_promotion_id IS NULL
       OR p_listed_price IS NULL
       OR p_listed_price::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_listed_price < 0
       OR p_listed_price >= 1000000000000
       OR p_listed_price <> round(p_listed_price, 2) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid discount calculation input';
    END IF;

    -- Only the trusted purchase function supplies the listed price.
    -- Lock promotion status against concurrent deactivation.
    SELECT * INTO v_promotion
    FROM app.membership_promotions
    WHERE tenant_id = p_tenant_id
      AND id = p_promotion_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid membership promotion';
    END IF;

    v_today := (
        statement_timestamp() AT TIME ZONE 'Asia/Yangon'
    )::date;

    IF v_promotion.status <> 'active'
       OR v_promotion.starts_on > v_today
       OR (
           v_promotion.ends_on IS NOT NULL
           AND v_promotion.ends_on <= v_today
       )
       OR (
           v_promotion.plan_id IS NOT NULL
           AND v_promotion.plan_id IS DISTINCT FROM p_plan_id
       )
       OR (
           v_promotion.branch_id IS NOT NULL
           AND v_promotion.branch_id IS DISTINCT FROM p_branch_id
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Membership promotion is not applicable';
    END IF;

    v_discount := CASE v_promotion.discount_kind
        WHEN 'percentage' THEN
            round(
                p_listed_price * v_promotion.discount_value / 100,
                2
            )
        WHEN 'fixed_amount' THEN
            least(p_listed_price, v_promotion.discount_value)
    END;

    IF v_discount IS NULL
       OR v_discount < 0
       OR v_discount > p_listed_price THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid calculated membership discount';
    END IF;

    RETURN QUERY SELECT
        v_discount,
        p_listed_price - v_discount,
        to_jsonb(v_promotion),
        jsonb_build_object(
            'membership_id', v_session.membership_id,
            'user_id', v_session.user_id,
            'session_id', v_session.session_id,
            'processed_on', v_today
        );
END;
$$;

ALTER FUNCTION security.calculate_membership_discount(
    bytea,uuid,uuid,uuid,numeric,uuid
) OWNER TO gympro_promotion_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_promotion_owner;

REVOKE ALL ON FUNCTION security.calculate_membership_discount(
    bytea,uuid,uuid,uuid,numeric,uuid
) FROM PUBLIC;

REVOKE ALL ON FUNCTION security.calculate_membership_discount(
    bytea,uuid,uuid,uuid,numeric,uuid
) FROM gympro_app;

GRANT EXECUTE ON FUNCTION security.calculate_membership_discount(
    bytea,uuid,uuid,uuid,numeric,uuid
) TO gympro_membership_owner;

DO $$
BEGIN
    IF has_function_privilege(
        'gympro_app',
        'security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime must not call the internal calculator.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_membership_owner',
        'security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Purchase owner cannot call the calculator.';
    END IF;

    RAISE NOTICE 'PASS: Internal calculator restricted to the purchase owner.';
END;
$$;

COMMIT;

SELECT
    p.oid::regprocedure AS function_signature,
    r.rolname AS function_owner,
    p.prosecdef AS security_definer,
    has_function_privilege(
        'gympro_app', p.oid, 'EXECUTE'
    ) AS runtime_can_execute,
    has_function_privilege(
        'gympro_membership_owner', p.oid, 'EXECUTE'
    ) AS purchase_owner_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_roles r ON r.oid = p.proowner
WHERE n.nspname = 'security'
  AND p.proname = 'calculate_membership_discount';