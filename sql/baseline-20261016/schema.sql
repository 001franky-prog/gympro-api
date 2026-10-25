--
-- PostgreSQL database dump
--

\restrict ppruGTshysybdfqqc6YPIKDcit8uMxxYddaIE1ma0gTUTmMywC7GfKGG05G9feH

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: app; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA app;


ALTER SCHEMA app OWNER TO postgres;

--
-- Name: platform; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA platform;


ALTER SCHEMA platform OWNER TO postgres;

--
-- Name: security; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA security;


ALTER SCHEMA security OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: membership_discounts; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.membership_discounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    promotion_id uuid NOT NULL,
    request_id uuid NOT NULL,
    purchase_kind character varying(20) NOT NULL,
    renewal_id uuid,
    listed_price_amount numeric(14,2) NOT NULL,
    discount_amount numeric(14,2) NOT NULL,
    agreed_price_amount numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    promotion_snapshot jsonb NOT NULL,
    actor_snapshot jsonb NOT NULL,
    applied_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_membership_discounts_actor_snapshot CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_membership_discounts_amounts CHECK (((listed_price_amount >= (0)::numeric) AND (listed_price_amount < ('1000000000000'::bigint)::numeric) AND (discount_amount >= (0)::numeric) AND (discount_amount <= listed_price_amount) AND (agreed_price_amount >= (0)::numeric) AND (agreed_price_amount < ('1000000000000'::bigint)::numeric) AND (agreed_price_amount = (listed_price_amount - discount_amount)))),
    CONSTRAINT chk_membership_discounts_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_membership_discounts_promotion_snapshot CHECK (((jsonb_typeof(promotion_snapshot) = 'object'::text) AND (promotion_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_membership_discounts_purchase CHECK (((((purchase_kind)::text = 'activation'::text) AND (renewal_id IS NULL)) OR (((purchase_kind)::text = 'renewal'::text) AND (renewal_id IS NOT NULL)))),
    CONSTRAINT chk_membership_discounts_timestamps CHECK ((isfinite(applied_at) AND isfinite(created_at)))
);

ALTER TABLE ONLY app.membership_discounts FORCE ROW LEVEL SECURITY;


ALTER TABLE app.membership_discounts OWNER TO postgres;

--
-- Name: activate_branch_discounted_membership(bytea, uuid, uuid, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) RETURNS SETOF app.membership_discounts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.apply_discount',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.discount:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.activate_discounted_membership(p_token_hash,p_tenant_id,p_member_id,p_plan_id,p_plan_price_id,p_promotion_id,p_request_id);
END;
$$;


ALTER FUNCTION security.activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: member_subscriptions; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.member_subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    member_id uuid NOT NULL,
    branch_id uuid,
    plan_id uuid NOT NULL,
    plan_price_id uuid NOT NULL,
    duration_value integer NOT NULL,
    duration_unit character varying(10) NOT NULL,
    agreed_price_amount numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    starts_on date,
    ends_on date,
    activated_at timestamp with time zone,
    suspended_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    membership_kind character varying(20) DEFAULT 'standard'::character varying NOT NULL,
    CONSTRAINT chk_member_subscriptions_activation CHECK (((((status)::text = 'pending'::text) AND (activated_at IS NULL)) OR (((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying, 'expired'::character varying])::text[])) AND (starts_on IS NOT NULL) AND (ends_on IS NOT NULL) AND (activated_at IS NOT NULL) AND isfinite(activated_at)))),
    CONSTRAINT chk_member_subscriptions_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_member_subscriptions_dates CHECK ((((starts_on IS NULL) AND (ends_on IS NULL)) OR ((starts_on IS NOT NULL) AND (ends_on IS NOT NULL) AND isfinite(starts_on) AND isfinite(ends_on) AND (ends_on > starts_on)))),
    CONSTRAINT chk_member_subscriptions_duration_unit CHECK (((duration_unit)::text = ANY ((ARRAY['days'::character varying, 'weeks'::character varying, 'months'::character varying, 'years'::character varying])::text[]))),
    CONSTRAINT chk_member_subscriptions_duration_value CHECK ((duration_value > 0)),
    CONSTRAINT chk_member_subscriptions_foc_price CHECK ((((membership_kind)::text <> 'foc'::text) OR (agreed_price_amount = (0)::numeric))),
    CONSTRAINT chk_member_subscriptions_kind CHECK (((membership_kind)::text = ANY ((ARRAY['standard'::character varying, 'foc'::character varying])::text[]))),
    CONSTRAINT chk_member_subscriptions_price CHECK (((agreed_price_amount >= (0)::numeric) AND (agreed_price_amount < ('1000000000000'::bigint)::numeric))),
    CONSTRAINT chk_member_subscriptions_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'suspended'::character varying, 'expired'::character varying])::text[]))),
    CONSTRAINT chk_member_subscriptions_suspension CHECK (((((status)::text = 'suspended'::text) AND (suspended_at IS NOT NULL) AND isfinite(suspended_at) AND (suspended_at >= activated_at)) OR (((status)::text <> 'suspended'::text) AND (suspended_at IS NULL))))
);

ALTER TABLE ONLY app.member_subscriptions FORCE ROW LEVEL SECURITY;


ALTER TABLE app.member_subscriptions OWNER TO postgres;

--
-- Name: activate_branch_member_subscription(bytea, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.activate_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) RETURNS SETOF app.member_subscriptions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.activate_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: activate_discounted_membership(bytea, uuid, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.activate_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) RETURNS SETOF app.membership_discounts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.activate_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: activate_member_subscription(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.activate_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) RETURNS SETOF app.member_subscriptions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE
    v_session record;
    v_member app.members%ROWTYPE;
    v_plan app.membership_plans%ROWTYPE;
    v_price app.plan_prices%ROWTYPE;
    v_subscription app.member_subscriptions%ROWTYPE;
    v_starts_on date;
    v_ends_on date;
    v_constraint text;
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

    IF p_member_id IS NULL
       OR p_plan_id IS NULL
       OR p_plan_price_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member, plan, and price are required';
    END IF;

    -- Serializes lifecycle operations for the same member.
    SELECT *
    INTO v_member
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
            'gym.memberships.manage',
            v_member.branch_id
        ),
        false
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Membership management permission denied';
    END IF;

    IF v_member.status NOT IN ('pending', 'active') THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member is not eligible for activation';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM app.member_subscriptions
        WHERE tenant_id = v_session.tenant_id
          AND member_id = v_member.id
          AND status IN ('active', 'suspended')
    ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Member already has a current subscription';
    END IF;

    SELECT *
    INTO v_plan
    FROM app.membership_plans
    WHERE tenant_id = v_session.tenant_id
      AND id = p_plan_id
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

    -- General prices apply to any branch. Branch prices
    -- apply only to a member registered at that branch.
    IF v_price.branch_id IS NOT NULL
       AND v_price.branch_id IS DISTINCT FROM v_member.branch_id THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Plan price does not apply to the member branch';
    END IF;

    v_starts_on := (
        statement_timestamp() AT TIME ZONE 'Asia/Yangon'
    )::date;

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

    BEGIN
        INSERT INTO app.member_subscriptions (
            tenant_id,
            member_id,
            branch_id,
            plan_id,
            plan_price_id,
            duration_value,
            duration_unit,
            agreed_price_amount,
            currency_code,
            status,
            starts_on,
            ends_on,
            activated_at
        )
        VALUES (
            v_session.tenant_id,
            v_member.id,
            v_member.branch_id,
            v_plan.id,
            v_price.id,
            v_plan.duration_value,
            v_plan.duration_unit,
            v_price.price_amount,
            v_price.currency_code,
            'active',
            v_starts_on,
            v_ends_on,
            statement_timestamp()
        )
        RETURNING * INTO v_subscription;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS
            v_constraint = CONSTRAINT_NAME;

        IF v_constraint =
            'uq_member_subscriptions_current_member' THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Member already has a current subscription';
        END IF;

        RAISE;
    END;

    UPDATE app.members
    SET
        status = 'active',
        updated_at = statement_timestamp()
    WHERE tenant_id = v_session.tenant_id
      AND id = v_member.id;

    RETURN NEXT v_subscription;
END;
$$;


ALTER FUNCTION security.activate_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: adjust_inventory_stock(bytea, uuid, uuid, uuid, integer, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_inventory_owner
--

CREATE FUNCTION security.adjust_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_delta integer, p_reason text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record; p app.inventory_products%ROWTYPE; m app.inventory_stock_movements%ROWTYPE; v_balance bigint; v_new numeric;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.stock.adjust',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Stock adjustment requires read committed isolation' USING ERRCODE='22023'; END IF;
 p_reason:=btrim(p_reason);
 IF p_product IS NULL OR p_request IS NULL OR p_delta IS NULL OR p_delta=0 OR p_reason IS NULL OR length(p_reason) NOT BETWEEN 2 AND 500 OR p_reason!~'[^[:space:]]' THEN RAISE EXCEPTION 'Invalid adjustment' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,202));
 SELECT * INTO m FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF m.movement_kind<>'adjustment' OR m.branch_id<>p_branch OR m.product_id<>p_product OR m.quantity_delta<>p_delta OR m.reason<>p_reason THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
 ELSE
  SELECT * INTO p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product FOR UPDATE;
  IF NOT FOUND OR p.status<>'active' THEN RAISE EXCEPTION 'Invalid active product' USING ERRCODE='22023'; END IF;
  SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p_product;
  v_new:=v_balance::numeric+p_delta::numeric;
  IF v_new<0 OR v_new>9223372036854775807::numeric THEN RAISE EXCEPTION 'Insufficient or excessive stock' USING ERRCODE='22023'; END IF;
  INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot)
  VALUES(p_tenant,p_branch,p_product,p_request,p_delta,p_reason,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_new::bigint,jsonb_build_object('sku',p.sku,'productName',p.product_name,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code)) RETURNING * INTO m;
 END IF;
 RETURN jsonb_build_object('id',m.id,'tenantId',m.tenant_id,'branchId',m.branch_id,'productId',m.product_id,'requestId',m.request_id,'quantityDelta',m.quantity_delta,'balanceAfter',m.balance_after::text,'reason',m.reason,'createdAt',m.created_at);
END $$;


ALTER FUNCTION security.adjust_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_delta integer, p_reason text, p_request uuid) OWNER TO gympro_inventory_owner;

--
-- Name: calculate_membership_discount(bytea, uuid, uuid, uuid, numeric, uuid); Type: FUNCTION; Schema: security; Owner: gympro_promotion_owner
--

CREATE FUNCTION security.calculate_membership_discount(p_token_hash bytea, p_tenant_id uuid, p_plan_id uuid, p_branch_id uuid, p_listed_price numeric, p_promotion_id uuid) RETURNS TABLE(discount_amount numeric, agreed_price_amount numeric, promotion_snapshot jsonb, actor_snapshot jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.calculate_membership_discount(p_token_hash bytea, p_tenant_id uuid, p_plan_id uuid, p_branch_id uuid, p_listed_price numeric, p_promotion_id uuid) OWNER TO gympro_promotion_owner;

--
-- Name: member_blacklist_events; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.member_blacklist_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    member_id uuid NOT NULL,
    request_id uuid NOT NULL,
    event_type character varying(20) NOT NULL,
    reason character varying(500) NOT NULL,
    previous_status character varying(20) NOT NULL,
    resulting_status character varying(20) NOT NULL,
    previous_member_snapshot jsonb NOT NULL,
    recorded_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_member_blacklist_events_previous_status CHECK (((previous_status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'inactive'::character varying, 'blacklisted'::character varying])::text[]))),
    CONSTRAINT chk_member_blacklist_events_reason CHECK ((((reason)::text = btrim((reason)::text)) AND ((length((reason)::text) >= 2) AND (length((reason)::text) <= 500)) AND ((reason)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT chk_member_blacklist_events_resulting_status CHECK (((resulting_status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'inactive'::character varying, 'blacklisted'::character varying])::text[]))),
    CONSTRAINT chk_member_blacklist_events_snapshot CHECK (((jsonb_typeof(previous_member_snapshot) = 'object'::text) AND (previous_member_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_member_blacklist_events_timestamp CHECK (isfinite(recorded_at)),
    CONSTRAINT chk_member_blacklist_events_transition CHECK (((((event_type)::text = 'blacklist'::text) AND ((previous_status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'inactive'::character varying])::text[])) AND ((resulting_status)::text = 'blacklisted'::text)) OR (((event_type)::text = 'unblacklist'::text) AND ((previous_status)::text = 'blacklisted'::text) AND ((resulting_status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'inactive'::character varying])::text[]))))),
    CONSTRAINT chk_member_blacklist_events_type CHECK (((event_type)::text = ANY ((ARRAY['blacklist'::character varying, 'unblacklist'::character varying])::text[])))
);

ALTER TABLE ONLY app.member_blacklist_events FORCE ROW LEVEL SECURITY;


ALTER TABLE app.member_blacklist_events OWNER TO postgres;

--
-- Name: change_branch_member_blacklist(bytea, uuid, uuid, uuid, text, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_blacklist_owner
--

CREATE FUNCTION security.change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) RETURNS SETOF app.member_blacklist_events
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.members.update',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.blacklist:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.change_member_blacklist(p_token_hash,p_tenant_id,p_member_id,p_action,p_reason,p_request_id);
END;
$$;


ALTER FUNCTION security.change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) OWNER TO gympro_blacklist_owner;

--
-- Name: change_member_blacklist(bytea, uuid, uuid, text, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_blacklist_owner
--

CREATE FUNCTION security.change_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) RETURNS SETOF app.member_blacklist_events
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.change_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) OWNER TO gympro_blacklist_owner;

--
-- Name: member_card_events; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.member_card_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    member_id uuid NOT NULL,
    card_id uuid NOT NULL,
    request_id uuid NOT NULL,
    event_type character varying(20) NOT NULL,
    reason text,
    event_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    CONSTRAINT member_card_events_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT member_card_events_check CHECK (((((event_type)::text = 'issued'::text) AND (reason IS NULL)) OR (((event_type)::text = 'revoked'::text) AND (reason IS NOT NULL) AND (reason = btrim(reason)) AND ((length(reason) >= 2) AND (length(reason) <= 500)) AND (reason ~ '[^[:space:]]'::text)))),
    CONSTRAINT member_card_events_event_at_check CHECK (isfinite(event_at)),
    CONSTRAINT member_card_events_event_type_check CHECK (((event_type)::text = ANY ((ARRAY['issued'::character varying, 'revoked'::character varying])::text[])))
);

ALTER TABLE ONLY app.member_card_events FORCE ROW LEVEL SECURITY;


ALTER TABLE app.member_card_events OWNER TO postgres;

--
-- Name: change_member_card(bytea, uuid, uuid, uuid, text, uuid, text); Type: FUNCTION; Schema: security; Owner: gympro_card_owner
--

CREATE FUNCTION security.change_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_subject uuid, p_action text, p_request uuid, p_reason text) RETURNS SETOF app.member_card_events
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record;v_member app.members%ROWTYPE;v_card app.member_cards%ROWTYPE;v_event app.member_card_events%ROWTYPE;v_member_id uuid;v_at timestamptz;v_reason text;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_branch IS NULL OR p_subject IS NULL OR p_request IS NULL OR p_action IS NULL OR p_action NOT IN('issue','revoke') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.cards.manage',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_action='issue' AND p_reason IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 IF p_action='revoke' THEN
  v_reason:=btrim(p_reason);
  IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 2 AND 500 OR v_reason !~ '[^[:space:]]' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.card:'||p_tenant::text||':'||p_request::text,0));
 IF p_action='issue' THEN v_member_id:=p_subject;
 ELSE SELECT c.member_id INTO v_member_id FROM app.member_cards c WHERE c.tenant_id=p_tenant AND c.id=p_subject AND c.branch_id=p_branch;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 END IF;
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant AND id=v_member_id FOR UPDATE;
 IF NOT FOUND OR (p_action='issue' AND v_member.branch_id IS NOT NULL AND v_member.branch_id<>p_branch) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 SELECT * INTO v_event FROM app.member_card_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_event.branch_id<>p_branch OR (p_action='issue' AND (v_event.event_type<>'issued' OR v_event.member_id<>p_subject)) OR
    (p_action='revoke' AND (v_event.event_type<>'revoked' OR v_event.card_id<>p_subject OR v_event.reason IS DISTINCT FROM v_reason)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  RETURN NEXT v_event;RETURN;
 END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_action='issue' THEN
  IF v_member.status<>'active' OR EXISTS(SELECT 1 FROM app.member_cards WHERE tenant_id=p_tenant AND member_id=v_member_id AND status='active') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  INSERT INTO app.member_cards(tenant_id,branch_id,member_id) VALUES(p_tenant,p_branch,v_member_id) RETURNING * INTO v_card;
  v_at:=v_card.issued_at;
 ELSE
  SELECT * INTO v_card FROM app.member_cards WHERE tenant_id=p_tenant AND id=p_subject AND branch_id=p_branch AND member_id=v_member_id FOR UPDATE;
  IF NOT FOUND OR v_card.status<>'active' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  v_at:=greatest(clock_timestamp(),v_card.issued_at);
  UPDATE app.member_cards SET status='revoked',revoked_at=v_at WHERE tenant_id=p_tenant AND id=p_subject;
 END IF;
 INSERT INTO app.member_card_events(tenant_id,branch_id,member_id,card_id,request_id,event_type,reason,event_at,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,v_member_id,v_card.id,p_request,CASE WHEN p_action='issue' THEN 'issued' ELSE 'revoked' END,v_reason,v_at,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id)) RETURNING * INTO v_event;
 RETURN NEXT v_event;
END $$;


ALTER FUNCTION security.change_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_subject uuid, p_action text, p_request uuid, p_reason text) OWNER TO gympro_card_owner;

--
-- Name: change_pos_sale(bytea, uuid, uuid, uuid, text, jsonb, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_pos_return_owner
--

CREATE FUNCTION security.change_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_action text, p_items jsonb, p_reason text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
DECLARE v_session record;v_sale app.pos_sales%ROWTYPE;v_existing app.pos_sale_returns%ROWTYPE;v_line app.pos_sale_items%ROWTYPE;v_item jsonb;v_cart jsonb;v_count integer;v_total numeric;v_returned bigint;v_balance bigint;v_new_balance numeric;v_return_id uuid;v_return_item_id uuid;v_quantity integer;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('refund','void') THEN RAISE EXCEPTION 'Invalid action' USING ERRCODE='22023'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,CASE p_action WHEN 'refund' THEN 'pos.sales.refund' ELSE 'pos.sales.void' END,p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Returns require read committed isolation' USING ERRCODE='22023'; END IF;
 p_reason:=btrim(p_reason);
 IF p_sale IS NULL OR p_request IS NULL OR p_reason IS NULL OR length(p_reason) NOT BETWEEN 2 AND 500 OR p_reason!~'[^[:space:]]' THEN RAISE EXCEPTION 'Invalid return request' USING ERRCODE='22023'; END IF;
 IF p_action='refund' THEN
  IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'Invalid return cart' USING ERRCODE='22023'; END IF;
  IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'Invalid return cart size' USING ERRCODE='22023'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
   IF jsonb_typeof(v_item)<>'object' THEN RAISE EXCEPTION 'Invalid return item' USING ERRCODE='22023'; END IF;
   IF (SELECT count(*) FROM jsonb_object_keys(v_item))<>2 OR NOT(v_item ? 'saleItemId' AND v_item ? 'quantity') OR jsonb_typeof(v_item->'saleItemId') IS DISTINCT FROM 'string' OR (v_item->>'saleItemId')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR jsonb_typeof(v_item->'quantity') IS DISTINCT FROM 'number' OR (v_item->>'quantity')!~'^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'Invalid return fields' USING ERRCODE='22023'; END IF;
   IF (v_item->>'quantity')::numeric>2147483647 THEN RAISE EXCEPTION 'Excess return quantity' USING ERRCODE='22023'; END IF;
  END LOOP;
  SELECT jsonb_agg(jsonb_build_object('saleItemId',(value->>'saleItemId')::uuid,'quantity',(value->>'quantity')::integer) ORDER BY (value->>'saleItemId')::uuid),count(DISTINCT (value->>'saleItemId')::uuid) INTO v_cart,v_count FROM jsonb_array_elements(p_items);
  IF v_count<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'Duplicate return items' USING ERRCODE='22023'; END IF;
 ELSE
  IF p_items IS NOT NULL THEN RAISE EXCEPTION 'Void does not accept items' USING ERRCODE='22023'; END IF;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,204));
 SELECT * INTO v_existing FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_existing.branch_id<>p_branch OR v_existing.sale_id<>p_sale OR v_existing.action_code<>p_action OR v_existing.reason<>p_reason OR (p_action='refund' AND v_existing.input_items<>v_cart) THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  v_return_id:=v_existing.id;
 ELSE
  SELECT * INTO v_sale FROM app.pos_sales WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_sale FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=p_sale AND (action_code='void' OR p_action='void')) THEN RAISE EXCEPTION 'Sale already reversed or refunded' USING ERRCODE='22023'; END IF;
  IF p_action='void' THEN SELECT jsonb_agg(jsonb_build_object('saleItemId',li.id,'quantity',li.quantity) ORDER BY li.id) INTO v_cart FROM app.pos_sale_items li WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale; END IF;
  IF v_cart IS NULL THEN RAISE EXCEPTION 'Invalid empty sale' USING ERRCODE='22023'; END IF;
  SELECT count(*),sum(li.unit_price*(ci.value->>'quantity')::integer) INTO v_count,v_total FROM jsonb_array_elements(v_cart) ci JOIN app.pos_sale_items li ON li.tenant_id=p_tenant AND li.sale_id=p_sale AND li.id=(ci.value->>'saleItemId')::uuid;
  IF v_count<>jsonb_array_length(v_cart) THEN RAISE EXCEPTION 'Unknown sale item' USING ERRCODE='22023'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT v_line FROM app.pos_sale_items WHERE tenant_id=p_tenant AND sale_id=p_sale AND id=(v_item->>'saleItemId')::uuid;
   SELECT coalesce(sum(quantity),0) INTO v_returned FROM app.pos_sale_return_items WHERE tenant_id=p_tenant AND sale_item_id=v_line.id;
   IF v_returned+(v_item->>'quantity')::bigint>v_line.quantity THEN RAISE EXCEPTION 'Return exceeds sold quantity' USING ERRCODE='22023'; END IF;
  END LOOP;
  PERFORM ip.id FROM app.inventory_products ip WHERE ip.tenant_id=p_tenant AND ip.id IN (SELECT li.product_id FROM app.pos_sale_items li JOIN jsonb_array_elements(v_cart) ci ON li.id=(ci.value->>'saleItemId')::uuid WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale) ORDER BY ip.id FOR UPDATE;
  INSERT INTO app.pos_sale_returns(tenant_id,branch_id,sale_id,request_id,action_code,reason,input_items,total_amount,actor_membership_id,actor_snapshot) VALUES(p_tenant,p_branch,p_sale,p_request,p_action,p_reason,v_cart,v_total,v_session.membership_id,jsonb_build_object('membershipId',v_session.membership_id,'userId',v_session.user_id,'sessionId',v_session.session_id)) RETURNING id INTO v_return_id;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT v_line FROM app.pos_sale_items WHERE tenant_id=p_tenant AND sale_id=p_sale AND id=(v_item->>'saleItemId')::uuid;
   v_quantity:=(v_item->>'quantity')::integer;
   SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=v_line.product_id;
   v_new_balance:=v_balance::numeric+v_quantity::numeric;
   IF v_new_balance<0 OR v_new_balance>9223372036854775807::numeric THEN RAISE EXCEPTION 'Invalid resulting stock' USING ERRCODE='22023'; END IF;
   INSERT INTO app.pos_sale_return_items(tenant_id,branch_id,sale_id,return_id,sale_item_id,product_id,sku,product_name,unit_code,quantity,unit_price,line_total) VALUES(p_tenant,p_branch,p_sale,v_return_id,v_line.id,v_line.product_id,v_line.sku,v_line.product_name,v_line.unit_code,v_quantity,v_line.unit_price,v_quantity::numeric*v_line.unit_price) RETURNING id INTO v_return_item_id;
   INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot,movement_kind,sale_id,sale_item_id,return_id,return_item_id) VALUES(p_tenant,p_branch,v_line.product_id,v_return_item_id,v_quantity,p_reason,v_session.membership_id,jsonb_build_object('membershipId',v_session.membership_id,'userId',v_session.user_id,'sessionId',v_session.session_id),v_new_balance::bigint,jsonb_build_object('sku',v_line.sku,'productName',v_line.product_name,'unitCode',v_line.unit_code,'salePrice',v_line.unit_price::text,'currencyCode','MMK'),p_action,p_sale,v_line.id,v_return_id,v_return_item_id);
  END LOOP;
 END IF;
 SELECT jsonb_build_object('id',sr.id,'tenantId',sr.tenant_id,'branchId',sr.branch_id,'saleId',sr.sale_id,'requestId',sr.request_id,'action',sr.action_code,'reason',sr.reason,'currencyCode',sr.currency_code,'totalAmount',sr.total_amount::text,'createdAt',sr.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',ri.id,'saleItemId',ri.sale_item_id,'productId',ri.product_id,'sku',ri.sku,'productName',ri.product_name,'unitCode',ri.unit_code,'quantity',ri.quantity,'unitPrice',ri.unit_price::text,'lineTotal',ri.line_total::text) ORDER BY ri.sale_item_id) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sr.tenant_id AND ri.return_id=sr.id)) INTO v_receipt FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.branch_id=p_branch AND sr.sale_id=p_sale AND sr.id=v_return_id;
 RETURN v_receipt;
END $_$;


ALTER FUNCTION security.change_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_action text, p_items jsonb, p_reason text, p_request uuid) OWNER TO gympro_pos_return_owner;

--
-- Name: attendance_visits; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.attendance_visits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    member_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,
    checked_in_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    business_date date NOT NULL,
    checked_out_at timestamp with time zone,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    CONSTRAINT attendance_visits_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT attendance_visits_business_date_check CHECK (isfinite(business_date)),
    CONSTRAINT attendance_visits_check CHECK ((business_date = ((checked_in_at AT TIME ZONE 'Asia/Yangon'::text))::date)),
    CONSTRAINT attendance_visits_check1 CHECK (((checked_out_at IS NULL) OR (isfinite(checked_out_at) AND (checked_out_at >= checked_in_at)))),
    CONSTRAINT attendance_visits_checked_in_at_check CHECK (isfinite(checked_in_at))
);

ALTER TABLE ONLY app.attendance_visits FORCE ROW LEVEL SECURITY;


ALTER TABLE app.attendance_visits OWNER TO postgres;

--
-- Name: TABLE attendance_visits; Type: COMMENT; Schema: app; Owner: postgres
--

COMMENT ON TABLE app.attendance_visits IS 'GymPro C1 attendance v1';


--
-- Name: check_in_member(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_attendance_owner
--

CREATE FUNCTION security.check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid) RETURNS SETOF app.attendance_visits
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE;
 v_visit app.attendance_visits%ROWTYPE; v_today date; v_at timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_member IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance:'||p_tenant::text||':'||p_request::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant AND id=p_member FOR UPDATE;
 IF NOT FOUND OR (v_member.branch_id IS NOT NULL AND v_member.branch_id<>p_branch) THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_visit FROM app.attendance_visits WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_visit.member_id<>p_member OR v_visit.branch_id<>p_branch THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
  RETURN NEXT v_visit; RETURN;
 END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 v_at:=clock_timestamp(); v_today:=(v_at AT TIME ZONE 'Asia/Yangon')::date;
 IF v_member.status<>'active' OR EXISTS(SELECT 1 FROM app.attendance_visits WHERE tenant_id=p_tenant AND member_id=p_member AND checked_out_at IS NULL) THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant AND member_id=p_member
 AND status='active' AND starts_on<=v_today AND ends_on>v_today
 AND (branch_id IS NULL OR branch_id=p_branch) ORDER BY id LIMIT 1 FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 v_at:=clock_timestamp(); v_today:=(v_at AT TIME ZONE 'Asia/Yangon')::date;
 IF v_sub.starts_on>v_today OR v_sub.ends_on<=v_today THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 INSERT INTO app.attendance_visits(tenant_id,branch_id,member_id,subscription_id,request_id,checked_in_at,business_date,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,p_member,v_sub.id,p_request,v_at,v_today,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id,'membership_kind',v_sub.membership_kind))
 RETURNING * INTO v_visit;
 RETURN NEXT v_visit;
END $$;


ALTER FUNCTION security.check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid) OWNER TO gympro_attendance_owner;

--
-- Name: attendance_checkouts; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.attendance_checkouts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    visit_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    member_id uuid NOT NULL,
    request_id uuid NOT NULL,
    checked_in_at timestamp with time zone NOT NULL,
    checked_out_at timestamp with time zone NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    CONSTRAINT attendance_checkouts_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT attendance_checkouts_check CHECK ((isfinite(checked_out_at) AND (checked_out_at >= checked_in_at))),
    CONSTRAINT attendance_checkouts_checked_in_at_check CHECK (isfinite(checked_in_at))
);

ALTER TABLE ONLY app.attendance_checkouts FORCE ROW LEVEL SECURITY;


ALTER TABLE app.attendance_checkouts OWNER TO postgres;

--
-- Name: check_out_member(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_attendance_owner
--

CREATE FUNCTION security.check_out_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_visit uuid, p_request uuid) RETURNS SETOF app.attendance_checkouts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_visit app.attendance_visits%ROWTYPE; v_member uuid;
 v_receipt app.attendance_checkouts%ROWTYPE; v_at timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_visit IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance.checkout:'||p_tenant::text||':'||p_request::text,0));
 SELECT member_id INTO v_member FROM app.attendance_visits WHERE tenant_id=p_tenant AND id=p_visit AND branch_id=p_branch;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 -- Same member-before-visit lock order as check-in and membership operations.
 PERFORM 1 FROM app.members WHERE tenant_id=p_tenant AND id=v_member FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_visit FROM app.attendance_visits WHERE tenant_id=p_tenant AND id=p_visit AND member_id=v_member AND branch_id=p_branch FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_receipt FROM app.attendance_checkouts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_receipt.visit_id<>p_visit OR v_receipt.branch_id<>p_branch THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
  RETURN NEXT v_receipt; RETURN;
 END IF;
 IF v_visit.checked_out_at IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 v_at:=greatest(clock_timestamp(),v_visit.checked_in_at);
 INSERT INTO app.attendance_checkouts(tenant_id,visit_id,branch_id,member_id,request_id,checked_in_at,checked_out_at,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_visit,p_branch,v_member,p_request,v_visit.checked_in_at,v_at,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id)) RETURNING * INTO v_receipt;
 UPDATE app.attendance_visits SET checked_out_at=v_at WHERE tenant_id=p_tenant AND id=p_visit;
 RETURN NEXT v_receipt;
END $$;


ALTER FUNCTION security.check_out_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_visit uuid, p_request uuid) OWNER TO gympro_attendance_owner;

--
-- Name: create_inventory_product(bytea, uuid, text, text, text, numeric, uuid); Type: FUNCTION; Schema: security; Owner: gympro_inventory_owner
--

CREATE FUNCTION security.create_inventory_product(p_hash bytea, p_tenant uuid, p_sku text, p_name text, p_description text, p_price numeric, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
DECLARE s record; p app.inventory_products%ROWTYPE; e app.inventory_product_events%ROWTYPE; v_input jsonb; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.create',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 p_sku:=upper(btrim(p_sku));p_name:=btrim(p_name);p_description:=nullif(btrim(p_description),'');
 IF p_request IS NULL OR p_sku IS NULL OR p_sku!~'^[A-Z0-9][A-Z0-9_-]{0,31}$' OR p_name IS NULL OR length(p_name) NOT BETWEEN 2 AND 150 OR p_name!~'[^[:space:]]' OR coalesce(length(p_description),0)>2000 OR p_price IS NULL OR p_price<0 OR p_price>999999999999.99 OR p_price='NaN'::numeric OR p_price<>round(p_price,2) THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 v_input:=jsonb_build_object('sku',p_sku,'name',p_name,'description',p_description,'price',p_price);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,201));
 SELECT * INTO e FROM app.inventory_product_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF e.action_code<>'create' OR e.input_snapshot<>v_input THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  RETURN e.receipt;
 END IF;
 INSERT INTO app.inventory_products(tenant_id,sku,product_name,description,sale_price) VALUES(p_tenant,p_sku,p_name,p_description,p_price) RETURNING * INTO p;
 v_receipt:=jsonb_build_object('id',p.id,'tenantId',p.tenant_id,'sku',p.sku,'productName',p.product_name,'description',p.description,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code,'status',p.status,'createdAt',p.created_at,'updatedAt',p.updated_at,'requestId',p_request);
 INSERT INTO app.inventory_product_events(tenant_id,product_id,request_id,action_code,input_snapshot,actor_membership_id,actor_snapshot,receipt) VALUES(p_tenant,p.id,p_request,'create',v_input,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_receipt);
 RETURN v_receipt;
END $_$;


ALTER FUNCTION security.create_inventory_product(p_hash bytea, p_tenant uuid, p_sku text, p_name text, p_description text, p_price numeric, p_request uuid) OWNER TO gympro_inventory_owner;

--
-- Name: membership_promotions; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.membership_promotions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    promotion_code character varying(32) NOT NULL,
    promotion_name character varying(150) NOT NULL,
    description text,
    plan_id uuid,
    branch_id uuid,
    discount_kind character varying(20) NOT NULL,
    discount_value numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    starts_on date NOT NULL,
    ends_on date,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_membership_promotions_code CHECK ((((promotion_code)::text = btrim((promotion_code)::text)) AND ((promotion_code)::text ~ '^[A-Z][A-Z0-9_]*$'::text))),
    CONSTRAINT chk_membership_promotions_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_membership_promotions_dates CHECK ((isfinite(starts_on) AND ((ends_on IS NULL) OR (isfinite(ends_on) AND (ends_on > starts_on))))),
    CONSTRAINT chk_membership_promotions_discount CHECK (((((discount_kind)::text = 'percentage'::text) AND (discount_value > (0)::numeric) AND (discount_value <= (100)::numeric)) OR (((discount_kind)::text = 'fixed_amount'::text) AND (discount_value > (0)::numeric) AND (discount_value < ('1000000000000'::bigint)::numeric)))),
    CONSTRAINT chk_membership_promotions_name CHECK (((length(btrim((promotion_name)::text)) >= 2) AND (length(btrim((promotion_name)::text)) <= 150))),
    CONSTRAINT chk_membership_promotions_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'inactive'::character varying])::text[])))
);

ALTER TABLE ONLY app.membership_promotions FORCE ROW LEVEL SECURITY;


ALTER TABLE app.membership_promotions OWNER TO postgres;

--
-- Name: create_membership_promotion(bytea, uuid, text, text, text, uuid, uuid, text, numeric, date, date); Type: FUNCTION; Schema: security; Owner: gympro_promotion_owner
--

CREATE FUNCTION security.create_membership_promotion(p_token_hash bytea, p_tenant_id uuid, p_promotion_code text, p_promotion_name text, p_description text, p_plan_id uuid, p_branch_id uuid, p_discount_kind text, p_discount_value numeric, p_starts_on date, p_ends_on date) RETURNS SETOF app.membership_promotions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $_$
DECLARE
    v_session record;
    v_code text;
    v_name text;
    v_description text;
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
        'gym.promotions.manage',
        p_branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Promotion management permission denied';
    END IF;

    v_code := btrim(p_promotion_code);
    v_name := btrim(p_promotion_name);
    v_description := NULLIF(btrim(p_description), '');

    IF v_code IS NULL
       OR length(v_code) NOT BETWEEN 1 AND 32
       OR v_code !~ '^[A-Z][A-Z0-9_]*$'
       OR v_name IS NULL
       OR length(v_name) NOT BETWEEN 2 AND 150 THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid promotion details';
    END IF;

    IF p_discount_kind IS NULL
       OR p_discount_kind NOT IN ('percentage', 'fixed_amount')
       OR p_discount_value IS NULL
       OR p_discount_value::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_discount_value <= 0
       OR p_discount_value >= 1000000000000
       OR p_discount_value <> round(p_discount_value, 2)
       OR (
           p_discount_kind = 'percentage'
           AND p_discount_value > 100
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid promotion discount';
    END IF;

    IF p_starts_on IS NULL
       OR NOT isfinite(p_starts_on)
       OR (
           p_ends_on IS NOT NULL
           AND (
               NOT isfinite(p_ends_on)
               OR p_ends_on <= p_starts_on
           )
       ) THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid promotion dates';
    END IF;

    IF p_plan_id IS NOT NULL THEN
        PERFORM 1
        FROM app.membership_plans
        WHERE tenant_id = p_tenant_id
          AND id = p_plan_id
        ;

        IF NOT FOUND THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Invalid promotion plan';
        END IF;
    END IF;

    IF p_branch_id IS NOT NULL THEN
        PERFORM 1
        FROM app.branches
        WHERE tenant_id = p_tenant_id
          AND id = p_branch_id
          AND status = 'active'
        ;

        IF NOT FOUND THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Invalid promotion branch';
        END IF;
    END IF;

    BEGIN
        RETURN QUERY
        INSERT INTO app.membership_promotions (
            tenant_id,
            promotion_code,
            promotion_name,
            description,
            plan_id,
            branch_id,
            discount_kind,
            discount_value,
            starts_on,
            ends_on,
            status
        )
        VALUES (
            p_tenant_id,
            v_code,
            v_name,
            v_description,
            p_plan_id,
            p_branch_id,
            p_discount_kind,
            p_discount_value,
            p_starts_on,
            p_ends_on,
            'draft'
        )
        RETURNING *;
    EXCEPTION
        WHEN unique_violation THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Promotion code already exists';
    END;
END;
$_$;


ALTER FUNCTION security.create_membership_promotion(p_token_hash bytea, p_tenant_id uuid, p_promotion_code text, p_promotion_name text, p_description text, p_plan_id uuid, p_branch_id uuid, p_discount_kind text, p_discount_value numeric, p_starts_on date, p_ends_on date) OWNER TO gympro_promotion_owner;

--
-- Name: create_pos_sale(bytea, uuid, uuid, jsonb, uuid); Type: FUNCTION; Schema: security; Owner: gympro_pos_owner
--

CREATE FUNCTION security.create_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_items jsonb, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
DECLARE s record; v_existing app.pos_sales%ROWTYPE; p app.inventory_products%ROWTYPE; item jsonb; v_cart jsonb; v_count integer; v_balance bigint; v_total numeric; v_sale_id uuid; v_item_id uuid; v_quantity integer; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'pos.sales.create',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Sales require read committed isolation' USING ERRCODE='22023'; END IF;
 IF p_request IS NULL OR p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'Invalid sale request' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'Invalid cart size' USING ERRCODE='22023'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF jsonb_typeof(item)<>'object' THEN RAISE EXCEPTION 'Invalid cart item' USING ERRCODE='22023'; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(item))<>2 OR NOT(item ? 'productId' AND item ? 'quantity') OR jsonb_typeof(item->'productId')<>'string' OR (item->>'productId')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR jsonb_typeof(item->'quantity')<>'number' OR (item->>'quantity')!~'^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'Invalid cart fields' USING ERRCODE='22023'; END IF;
  IF (item->>'quantity')::numeric>2147483647 THEN RAISE EXCEPTION 'Excess quantity' USING ERRCODE='22023'; END IF;
 END LOOP;
 SELECT jsonb_agg(jsonb_build_object('productId',(value->>'productId')::uuid,'quantity',(value->>'quantity')::integer) ORDER BY (value->>'productId')::uuid),count(DISTINCT (value->>'productId')::uuid) INTO v_cart,v_count FROM jsonb_array_elements(p_items);
 IF v_count<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'Duplicate products' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,203));
 SELECT * INTO v_existing FROM app.pos_sales WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_existing.branch_id<>p_branch OR v_existing.input_cart<>v_cart THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  v_sale_id:=v_existing.id;
 ELSE
  PERFORM q.id FROM app.inventory_products q WHERE q.tenant_id=p_tenant AND q.id IN (SELECT (value->>'productId')::uuid FROM jsonb_array_elements(v_cart)) ORDER BY q.id FOR UPDATE;
  SELECT count(*),sum(q.sale_price*(x.value->>'quantity')::integer) INTO v_count,v_total FROM jsonb_array_elements(v_cart) x JOIN app.inventory_products q ON q.tenant_id=p_tenant AND q.id=(x.value->>'productId')::uuid AND q.status='active';
  IF v_count<>jsonb_array_length(v_cart) THEN RAISE EXCEPTION 'Invalid active product' USING ERRCODE='22023'; END IF;
  INSERT INTO app.pos_sales(tenant_id,branch_id,request_id,input_cart,total_amount,actor_membership_id,actor_snapshot) VALUES(p_tenant,p_branch,p_request,v_cart,v_total,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id)) RETURNING id INTO v_sale_id;
  FOR item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=(item->>'productId')::uuid;
   v_quantity:=(item->>'quantity')::integer;
   SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p.id;
   IF v_balance<v_quantity THEN RAISE EXCEPTION 'Insufficient stock' USING ERRCODE='22023'; END IF;
   INSERT INTO app.pos_sale_items(tenant_id,branch_id,sale_id,product_id,sku,product_name,unit_code,quantity,unit_price,line_total) VALUES(p_tenant,p_branch,v_sale_id,p.id,p.sku,p.product_name,p.unit_code,v_quantity,p.sale_price,v_quantity::numeric*p.sale_price) RETURNING id INTO v_item_id;
   INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot,movement_kind,sale_id,sale_item_id) VALUES(p_tenant,p_branch,p.id,v_item_id,-v_quantity,'POS sale',s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_balance-v_quantity,jsonb_build_object('sku',p.sku,'productName',p.product_name,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code),'sale',v_sale_id,v_item_id);
  END LOOP;
 END IF;
 SELECT jsonb_build_object('id',h.id,'tenantId',h.tenant_id,'branchId',h.branch_id,'requestId',h.request_id,'status',h.status,'currencyCode',h.currency_code,'totalAmount',h.total_amount::text,'createdAt',h.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'productId',i.product_id,'sku',i.sku,'productName',i.product_name,'unitCode',i.unit_code,'quantity',i.quantity,'unitPrice',i.unit_price::text,'lineTotal',i.line_total::text) ORDER BY i.product_id) FROM app.pos_sale_items i WHERE i.tenant_id=h.tenant_id AND i.sale_id=h.id)) INTO v_receipt FROM app.pos_sales h WHERE h.tenant_id=p_tenant AND h.branch_id=p_branch AND h.id=v_sale_id;
 RETURN v_receipt;
END $_$;


ALTER FUNCTION security.create_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_items jsonb, p_request uuid) OWNER TO gympro_pos_owner;

--
-- Name: create_tenant_session(uuid, bytea); Type: FUNCTION; Schema: security; Owner: gympro_session_owner
--

CREATE FUNCTION security.create_tenant_session(p_membership_id uuid, p_token_hash bytea) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
    v_tenant_id UUID;
    v_session_id UUID;
BEGIN
    -- Validate token digest length.
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32
    THEN
        RAISE EXCEPTION 'Invalid session request';
    END IF;

    /*
     * Lock user, tenant and membership rows.
     *
     * FOR SHARE permits concurrent readers but
     * conflicts with updates that change row
     * status values.
     *
     * These locks remain held until transaction
     * completion.
     */
    SELECT tm.tenant_id
    INTO v_tenant_id
    FROM app.tenant_memberships AS tm

    JOIN app.users AS u
        ON u.id = tm.user_id

    JOIN platform.tenants AS t
        ON t.id = tm.tenant_id

    WHERE tm.id = p_membership_id
      AND tm.status = 'active'
      AND u.status = 'active'
      AND t.status = 'active'

    FOR SHARE OF tm, u, t;

    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Invalid session request';
    END IF;

    -- Persist only the token digest.
    INSERT INTO security.tenant_sessions (
        tenant_id,
        membership_id,
        session_token_hash,
        expires_at
    )
    VALUES (
        v_tenant_id,
        p_membership_id,
        p_token_hash,
        CURRENT_TIMESTAMP + INTERVAL '8 hours'
    )
    RETURNING id INTO v_session_id;

    RETURN v_session_id;
END;
$$;


ALTER FUNCTION security.create_tenant_session(p_membership_id uuid, p_token_hash bytea) OWNER TO gympro_session_owner;

--
-- Name: subscription_expirations; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.subscription_expirations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    coverage_starts_on date NOT NULL,
    coverage_ends_on date NOT NULL,
    processed_on date NOT NULL,
    expired_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    previous_subscription_snapshot jsonb CONSTRAINT subscription_expirations_previous_subscription_snapsho_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_subscription_expirations_dates CHECK ((isfinite(coverage_starts_on) AND isfinite(coverage_ends_on) AND isfinite(processed_on) AND (coverage_ends_on > coverage_starts_on) AND (processed_on >= coverage_ends_on))),
    CONSTRAINT chk_subscription_expirations_snapshot CHECK (((jsonb_typeof(previous_subscription_snapshot) = 'object'::text) AND (previous_subscription_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_subscription_expirations_timestamp CHECK (isfinite(expired_at))
);

ALTER TABLE ONLY app.subscription_expirations FORCE ROW LEVEL SECURITY;


ALTER TABLE app.subscription_expirations OWNER TO postgres;

--
-- Name: expire_branch_member_subscription(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.expire_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid) RETURNS SETOF app.subscription_expirations
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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

    IF p_subscription_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription ID is required';
    END IF;

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
    FROM security.expire_member_subscription(
        p_token_hash,
        p_tenant_id,
        p_subscription_id
    );
END;
$$;


ALTER FUNCTION security.expire_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: expire_member_subscription(bytea, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.expire_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid) RETURNS SETOF app.subscription_expirations
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE
    v_session record;
    v_member app.members%ROWTYPE;
    v_subscription app.member_subscriptions%ROWTYPE;
    v_expiration app.subscription_expirations%ROWTYPE;
    v_today date;
    v_expired_at timestamptz;
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

    IF p_subscription_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription ID is required';
    END IF;

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

    -- Consistent member-first lock order across lifecycle functions.
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

    v_expired_at := statement_timestamp();

    v_today := (
        v_expired_at AT TIME ZONE 'Asia/Yangon'
    )::date;

    IF v_subscription.starts_on IS NULL
       OR v_subscription.ends_on IS NULL
       OR v_subscription.ends_on > v_today THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription is not due for expiration';
    END IF;

    SELECT *
    INTO v_expiration
    FROM app.subscription_expirations
    WHERE tenant_id = v_session.tenant_id
      AND subscription_id = v_subscription.id
      AND coverage_starts_on = v_subscription.starts_on
      AND coverage_ends_on = v_subscription.ends_on;

    IF FOUND THEN
        IF v_subscription.status <> 'expired' THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Subscription expiration history is inconsistent';
        END IF;

        RETURN NEXT v_expiration;
        RETURN;
    END IF;

    IF v_subscription.status NOT IN ('active', 'suspended') THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription is not eligible for expiration';
    END IF;

    INSERT INTO app.subscription_expirations (
        tenant_id,
        subscription_id,
        coverage_starts_on,
        coverage_ends_on,
        processed_on,
        expired_at,
        previous_subscription_snapshot
    )
    VALUES (
        v_session.tenant_id,
        v_subscription.id,
        v_subscription.starts_on,
        v_subscription.ends_on,
        v_today,
        v_expired_at,
        to_jsonb(v_subscription)
        || jsonb_build_object(
            'expired_by_membership_id', v_session.membership_id,
            'expired_by_user_id', v_session.user_id,
            'expiration_session_id', v_session.session_id
        )
    )
    RETURNING * INTO v_expiration;

    UPDATE app.member_subscriptions
    SET
        status = 'expired',
        suspended_at = NULL,
        updated_at = v_expired_at
    WHERE tenant_id = v_session.tenant_id
      AND id = v_subscription.id;

    -- Preserve blacklisted and other non-active profile statuses.
    UPDATE app.members
    SET
        status = 'inactive',
        updated_at = v_expired_at
    WHERE tenant_id = v_session.tenant_id
      AND id = v_member.id
      AND status = 'active'
      AND NOT EXISTS (
          SELECT 1
          FROM app.member_subscriptions AS s
          WHERE s.tenant_id = v_session.tenant_id
            AND s.member_id = v_member.id
            AND s.status IN ('active', 'suspended')
            AND s.ends_on > v_today
      );

    RETURN NEXT v_expiration;
END;
$$;


ALTER FUNCTION security.expire_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: find_member_card(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_card_owner
--

CREATE FUNCTION security.find_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid) RETURNS TABLE(card_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR p_member IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.cards.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied';END IF;
 PERFORM 1 FROM app.members m WHERE m.tenant_id=p_tenant AND m.id=p_member AND (m.branch_id=p_branch OR m.branch_id IS NULL);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied';END IF;
 RETURN QUERY SELECT c.id FROM app.member_cards c
 WHERE c.tenant_id=p_tenant AND c.branch_id=p_branch AND c.member_id=p_member
 ORDER BY (c.status='active') DESC,c.issued_at DESC,c.id DESC LIMIT 1;
END $$;


ALTER FUNCTION security.find_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid) OWNER TO gympro_card_owner;

--
-- Name: get_active_tenant_membership(uuid, uuid); Type: FUNCTION; Schema: security; Owner: postgres
--

CREATE FUNCTION security.get_active_tenant_membership(p_user_id uuid, p_tenant_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
    SELECT tm.id
    FROM app.tenant_memberships AS tm

    JOIN app.users AS u
        ON u.id = tm.user_id

    JOIN platform.tenants AS t
        ON t.id = tm.tenant_id

    WHERE tm.user_id = p_user_id
      AND tm.tenant_id = p_tenant_id
      AND tm.status = 'active'
      AND u.status = 'active'
      AND t.status = 'active'

    LIMIT 1;
$$;


ALTER FUNCTION security.get_active_tenant_membership(p_user_id uuid, p_tenant_id uuid) OWNER TO postgres;

--
-- Name: get_user_credentials(text); Type: FUNCTION; Schema: security; Owner: postgres
--

CREATE FUNCTION security.get_user_credentials(p_email text) RETURNS TABLE(user_id uuid, account_status character varying, password_hash text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
    SELECT
        u.id,
        u.status,
        u.password_hash
    FROM app.users AS u
    WHERE lower(u.email) = lower(trim(p_email))
    LIMIT 1;
$$;


ALTER FUNCTION security.get_user_credentials(p_email text) OWNER TO postgres;

--
-- Name: subscription_foc_grants; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.subscription_foc_grants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,
    reason character varying(500) NOT NULL,
    listed_price_amount numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    previous_member_snapshot jsonb NOT NULL,
    granted_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_subscription_foc_grants_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_subscription_foc_grants_listed_price CHECK (((listed_price_amount >= (0)::numeric) AND (listed_price_amount < ('1000000000000'::bigint)::numeric))),
    CONSTRAINT chk_subscription_foc_grants_reason CHECK ((((reason)::text = btrim((reason)::text)) AND ((length((reason)::text) >= 2) AND (length((reason)::text) <= 500)) AND ((reason)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT chk_subscription_foc_grants_snapshot CHECK (((jsonb_typeof(previous_member_snapshot) = 'object'::text) AND (previous_member_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_subscription_foc_grants_timestamp CHECK (isfinite(granted_at))
);

ALTER TABLE ONLY app.subscription_foc_grants FORCE ROW LEVEL SECURITY;


ALTER TABLE app.subscription_foc_grants OWNER TO postgres;

--
-- Name: grant_branch_foc_membership(bytea, uuid, uuid, uuid, uuid, uuid, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_foc_owner
--

CREATE FUNCTION security.grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) RETURNS SETOF app.subscription_foc_grants
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.grant_foc',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.foc:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.grant_foc_membership(p_token_hash,p_tenant_id,p_member_id,p_plan_id,p_plan_price_id,p_reason,p_request_id);
END;
$$;


ALTER FUNCTION security.grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) OWNER TO gympro_foc_owner;

--
-- Name: grant_foc_membership(bytea, uuid, uuid, uuid, uuid, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_foc_owner
--

CREATE FUNCTION security.grant_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) RETURNS SETOF app.subscription_foc_grants
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.grant_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) OWNER TO gympro_foc_owner;

--
-- Name: has_tenant_permission(uuid, uuid, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_rbac_owner
--

CREATE FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid DEFAULT NULL::uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$

    SELECT
        CASE
            WHEN p_tenant_id IS NULL
              OR p_membership_id IS NULL
              OR p_permission_code IS NULL
              OR p_permission_code = ''
            THEN false

            ELSE EXISTS (
                SELECT 1

                FROM app.tenant_memberships AS m

                JOIN app.users AS u
                  ON u.id = m.user_id

                JOIN platform.tenants AS t
                  ON t.id = m.tenant_id

                JOIN app.role_assignments AS ra
                  ON ra.membership_id = m.id
                 AND ra.tenant_id = m.tenant_id

                JOIN app.roles AS r
                  ON r.id = ra.role_id
                 AND r.tenant_id = ra.tenant_id

                JOIN app.role_permissions AS rp
                  ON rp.role_id = r.id
                 AND rp.tenant_id = r.tenant_id

                JOIN app.permissions AS p
                  ON p.id = rp.permission_id

                WHERE m.id = p_membership_id
                  AND m.tenant_id = p_tenant_id

                  AND m.status = 'active'
                  AND u.status = 'active'
                  AND t.status = 'active'
                  AND r.status = 'active'

                  AND p.is_active = true
                  AND p.permission_code =
                      p_permission_code

                  AND (
                      -- Tenant-wide role applies to
                      -- the tenant and its branches.
                      (
                          ra.scope_type = 'tenant'
                          AND ra.branch_id IS NULL
                      )

                      OR

                      -- Branch assignment applies
                      -- only to the same branch.
                      (
                          ra.scope_type = 'branch'
                          AND p_branch_id IS NOT NULL
                          AND ra.branch_id = p_branch_id
                      )
                  )

                  -- If branch context is supplied,
                  -- the branch must exist and be active.
                  --
                  -- Forced RLS on app.branches may
                  -- additionally restrict visibility.
                  AND (
                      p_branch_id IS NULL

                      OR EXISTS (
                          SELECT 1
                          FROM app.branches AS b
                          WHERE b.id = p_branch_id
                            AND b.tenant_id = p_tenant_id
                            AND b.status = 'active'
                      )
                  )
            )
        END;

$$;


ALTER FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) OWNER TO gympro_rbac_owner;

--
-- Name: is_tenant_session_valid(uuid); Type: FUNCTION; Schema: security; Owner: postgres
--

CREATE FUNCTION security.is_tenant_session_valid(p_session_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM security.tenant_sessions s

        JOIN app.tenant_memberships tm
            ON tm.id = s.membership_id
           AND tm.tenant_id = s.tenant_id

        JOIN app.users u
            ON u.id = tm.user_id

        JOIN platform.tenants t
            ON t.id = s.tenant_id

        WHERE s.id = p_session_id
          AND s.expires_at > CURRENT_TIMESTAMP
          AND s.revoked_at IS NULL
          AND u.status = 'active'
          AND tm.status = 'active'
          AND t.status = 'active'
    );
$$;


ALTER FUNCTION security.is_tenant_session_valid(p_session_id uuid) OWNER TO postgres;

--
-- Name: open_payment_charge(bytea, uuid, uuid, text, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.open_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_kind text, p_source uuid, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE; sale app.pos_sales%ROWTYPE;sub app.member_subscriptions%ROWTYPE;ren app.subscription_renewals%ROWTYPE;
 amount numeric; snap jsonb; scope_branch uuid; sub_id uuid; ren_id uuid; sale_id uuid; old_snapshot jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.record');
 IF current_setting('transaction_isolation')<>'read committed' OR p_source IS NULL OR p_request IS NULL OR p_kind IS NULL OR p_kind NOT IN ('pos_sale','membership_activation','membership_renewal') THEN RAISE EXCEPTION 'Invalid charge request' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 IF p_kind='pos_sale' THEN
  SELECT * INTO sale FROM app.pos_sales WHERE tenant_id=p_tenant AND id=p_source FOR UPDATE;
  IF sale.id IS NULL THEN RAISE EXCEPTION 'Unknown sale' USING ERRCODE='22023'; END IF;
  amount:=sale.total_amount;snap:=jsonb_build_object('saleId',sale.id,'originalAmount',sale.total_amount::text,'currencyCode',sale.currency_code);scope_branch:=sale.branch_id;sale_id:=sale.id;
 ELSE
  IF p_kind='membership_renewal' THEN
   SELECT * INTO ren FROM app.subscription_renewals WHERE tenant_id=p_tenant AND id=p_source;
   IF ren.id IS NULL THEN RAISE EXCEPTION 'Unknown renewal' USING ERRCODE='22023'; END IF;
   sub_id:=ren.subscription_id;ren_id:=ren.id;
  ELSE sub_id:=p_source; END IF;
  SELECT * INTO sub FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=sub_id FOR UPDATE;
  IF sub.id IS NULL OR sub.activated_at IS NULL THEN RAISE EXCEPTION 'Unknown activated membership' USING ERRCODE='22023'; END IF;
  scope_branch:=sub.branch_id;
  IF p_kind='membership_renewal' THEN
   amount:=ren.agreed_price_amount;snap:=jsonb_build_object('renewalId',ren.id,'subscriptionId',sub.id,'originalAmount',amount::text,'startsOn',ren.renewal_starts_on,'endsOn',ren.renewal_ends_on);
  ELSE
   SELECT previous_subscription_snapshot INTO old_snapshot FROM app.subscription_renewals WHERE tenant_id=p_tenant AND subscription_id=sub.id ORDER BY renewal_starts_on,created_at,id LIMIT 1;
   IF old_snapshot IS NOT NULL THEN
    IF NOT(old_snapshot ? 'agreed_price_amount') OR jsonb_typeof(old_snapshot->'agreed_price_amount') NOT IN ('number','string') THEN RAISE EXCEPTION 'Original activation amount cannot be established' USING ERRCODE='22023'; END IF;
    amount:=(old_snapshot->>'agreed_price_amount')::numeric;
   ELSE amount:=sub.agreed_price_amount; END IF;
   snap:=jsonb_build_object('subscriptionId',sub.id,'originalAmount',amount::text,'membershipKind',sub.membership_kind);
  END IF;
 END IF;
 IF scope_branch IS NOT NULL AND scope_branch<>p_branch THEN RAISE EXCEPTION 'Purchase branch mismatch' USING ERRCODE='42501'; END IF;
 IF scope_branch IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.record',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant membership payment access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND request_id=p_request;
 IF c.id IS NOT NULL THEN
  IF c.source_kind<>p_kind OR c.sale_id IS DISTINCT FROM sale_id OR c.subscription_id IS DISTINCT FROM sub_id OR c.renewal_id IS DISTINCT FROM ren_id THEN RAISE EXCEPTION 'Charge request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_charge_json(p_tenant,c.id);
 END IF;
 IF EXISTS(SELECT FROM app.payment_charges x WHERE x.tenant_id=p_tenant AND ((p_kind='pos_sale' AND x.sale_id=p_source) OR(p_kind='membership_activation' AND x.source_kind=p_kind AND x.subscription_id=p_source) OR(p_kind='membership_renewal' AND x.renewal_id=p_source))) THEN RAISE EXCEPTION 'Purchase already has a charge' USING ERRCODE='22023'; END IF;
 IF amount IS NULL OR NOT(amount>=0 AND amount<1e24) OR amount<>round(amount,2) THEN RAISE EXCEPTION 'Invalid source amount' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_charges(tenant_id,request_id,source_kind,branch_id,sale_id,subscription_id,renewal_id,amount_due,source_snapshot,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_request,p_kind,scope_branch,sale_id,sub_id,ren_id,amount,snap,(actor->>'membershipId')::uuid,actor) RETURNING * INTO c;
 RETURN security.payment_charge_json(p_tenant,c.id);
END $$;


ALTER FUNCTION security.open_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_kind text, p_source uuid, p_request uuid) OWNER TO gympro_payment_owner;

--
-- Name: payment_charge_json(uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.payment_charge_json(p_tenant uuid, p_charge uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
 SELECT jsonb_build_object('id',c.id,'tenantId',c.tenant_id,'branchId',c.branch_id,'requestId',c.request_id,'sourceKind',c.source_kind,'saleId',c.sale_id,'subscriptionId',c.subscription_id,'renewalId',c.renewal_id,'amountDue',c.amount_due::text,'currencyCode',c.currency_code,'createdAt',c.created_at)
 FROM app.payment_charges c WHERE c.tenant_id=p_tenant AND c.id=p_charge;
$$;


ALTER FUNCTION security.payment_charge_json(p_tenant uuid, p_charge uuid) OWNER TO gympro_payment_owner;

--
-- Name: payment_receipt_json(uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.payment_receipt_json(p_tenant uuid, p_receipt uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
 SELECT jsonb_build_object('id',r.id,'tenantId',r.tenant_id,'chargeId',r.charge_id,'collectionBranchId',r.collection_branch_id,'requestId',r.request_id,'amount',r.amount::text,'currencyCode',r.currency_code,'methodCode',r.method_code,'externalReference',r.external_reference,'recordedAt',r.recorded_at)
 FROM app.payment_receipts r WHERE r.tenant_id=p_tenant AND r.id=p_receipt;
$$;


ALTER FUNCTION security.payment_receipt_json(p_tenant uuid, p_receipt uuid) OWNER TO gympro_payment_owner;

--
-- Name: payment_reconciliation_json(uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.payment_reconciliation_json(p_tenant uuid, p_id uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
 SELECT jsonb_build_object('id',x.id,'tenantId',x.tenant_id,'branchId',x.branch_id,'date',to_char(x.reconciliation_date,'YYYY-MM-DD'),'requestId',x.request_id,'declaredTotals',x.declared_totals,'expectedTotals',x.expected_totals,'differenceTotals',x.difference_totals,'declaredNetAmount',x.declared_net_amount::text,'expectedNetAmount',x.expected_net_amount::text,'differenceAmount',x.difference_amount::text,'currencyCode',x.currency_code,'status',x.status,'note',x.note,'collectionSnapshot',x.collection_snapshot,'reconciledAt',x.reconciled_at)
 FROM app.payment_reconciliations x WHERE x.tenant_id=p_tenant AND x.id=p_id;
$$;


ALTER FUNCTION security.payment_reconciliation_json(p_tenant uuid, p_id uuid) OWNER TO gympro_payment_owner;

--
-- Name: payment_reversal_json(uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.payment_reversal_json(p_tenant uuid, p_reversal uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
 SELECT jsonb_build_object('id',v.id,'tenantId',v.tenant_id,'receiptId',v.receipt_id,'chargeId',r.charge_id,'collectionBranchId',r.collection_branch_id,'requestId',v.request_id,'reversalKind',v.reversal_kind,'amount',v.amount::text,'currencyCode',v.currency_code,'reason',v.reason,'recordedAt',v.recorded_at)
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id WHERE v.tenant_id=p_tenant AND v.id=p_reversal;
$$;


ALTER FUNCTION security.payment_reversal_json(p_tenant uuid, p_reversal uuid) OWNER TO gympro_payment_owner;

--
-- Name: payment_session(bytea, uuid, uuid, text); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.payment_session(p_hash bytea, p_tenant uuid, p_branch uuid, p_permission text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record; BEGIN
 IF p_hash IS NULL OR octet_length(p_hash)<>32 THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF s.session_id IS NULL THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR p_tenant<>s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,p_permission,p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Payment access denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active') THEN RAISE EXCEPTION 'Inactive payment branch' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('sessionId',s.session_id,'membershipId',s.membership_id,'userId',s.user_id);
END $$;


ALTER FUNCTION security.payment_session(p_hash bytea, p_tenant uuid, p_branch uuid, p_permission text) OWNER TO gympro_payment_owner;

--
-- Name: read_branch_attendance(bytea, uuid, uuid, boolean, date, date, integer, timestamp with time zone, uuid); Type: FUNCTION; Schema: security; Owner: gympro_attendance_reader
--

CREATE FUNCTION security.read_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_current boolean, p_from date, p_to date, p_limit integer, p_before_at timestamp with time zone, p_before_id uuid) RETURNS TABLE(id uuid, tenant_id uuid, branch_id uuid, member_id uuid, member_number text, full_name text, subscription_id uuid, checked_in_at timestamp with time zone, checked_out_at timestamp with time zone, business_date text, cursor_at text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record;v_today date;v_from date;v_to date;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_current IS NULL OR p_limit IS NULL OR p_limit<1 OR p_limit>100
 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_current THEN
  IF p_from IS NOT NULL OR p_to IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 ELSE
  v_today:=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date;
  IF (p_from IS NULL)<>(p_to IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
  v_from:=coalesce(p_from,v_today-29);v_to:=coalesce(p_to,v_today+1);
  IF NOT isfinite(v_from) OR NOT isfinite(v_to) OR v_to<=v_from OR v_to-v_from>93 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 END IF;
 RETURN QUERY
 SELECT v.id,v.tenant_id,v.branch_id,v.member_id,m.member_number::text,m.full_name::text,v.subscription_id,v.checked_in_at,v.checked_out_at,v.business_date::text,
 to_char(v.checked_in_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
 FROM app.attendance_visits v JOIN app.members m ON m.tenant_id=v.tenant_id AND m.id=v.member_id
 WHERE v.tenant_id=p_tenant AND v.branch_id=p_branch
 AND ((p_current AND v.checked_out_at IS NULL) OR (NOT p_current AND v.business_date>=v_from AND v.business_date<v_to))
 AND (p_before_at IS NULL OR (v.checked_in_at,v.id)<(p_before_at,p_before_id))
 ORDER BY v.checked_in_at DESC,v.id DESC LIMIT p_limit+1;
END $$;


ALTER FUNCTION security.read_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_current boolean, p_from date, p_to date, p_limit integer, p_before_at timestamp with time zone, p_before_id uuid) OWNER TO gympro_attendance_reader;

--
-- Name: read_inventory_products(bytea, uuid, uuid, uuid, integer); Type: FUNCTION; Schema: security; Owner: gympro_inventory_owner
--

CREATE FUNCTION security.read_inventory_products(p_hash bytea, p_tenant uuid, p_branch uuid, p_after uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 25) RETURNS TABLE(id uuid, tenant_id uuid, sku text, product_name text, description text, unit_code text, sale_price text, currency_code text, status text, updated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid limit' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT p.id,p.tenant_id,p.sku::text,p.product_name::text,p.description,p.unit_code::text,p.sale_price::text,p.currency_code::text,p.status::text,p.updated_at FROM app.inventory_products p WHERE p.tenant_id=p_tenant AND (p_after IS NULL OR p.id>p_after) ORDER BY p.id LIMIT p_limit+1;
END $$;


ALTER FUNCTION security.read_inventory_products(p_hash bytea, p_tenant uuid, p_branch uuid, p_after uuid, p_limit integer) OWNER TO gympro_inventory_owner;

--
-- Name: read_inventory_stock(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_inventory_owner
--

CREATE FUNCTION security.read_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record; v_balance bigint;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product) THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p_product;
 RETURN jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'productId',p_product,'quantity',v_balance::text);
END $$;


ALTER FUNCTION security.read_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid) OWNER TO gympro_inventory_owner;

--
-- Name: read_inventory_stock_history(bytea, uuid, uuid, uuid, date, date, uuid, integer); Type: FUNCTION; Schema: security; Owner: gympro_inventory_read_owner
--

CREATE FUNCTION security.read_inventory_stock_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE v_session record;v_from date;v_through date;v_lower timestamptz;v_upper timestamptz;v_cursor_created timestamptz;v_result jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_product IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_from IS NULL)<>(p_through IS NULL)) THEN RAISE EXCEPTION 'Invalid stock history query' USING ERRCODE='22023'; END IF;
 PERFORM ip.id FROM app.inventory_products ip WHERE ip.tenant_id=p_tenant AND ip.id=p_product;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 v_through:=coalesce(p_through,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);v_from:=coalesce(p_from,v_through-29);
 IF NOT isfinite(v_from) OR NOT isfinite(v_through) THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 IF v_from<DATE '0001-01-01' OR v_through>DATE '9999-12-30' THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 IF v_through<v_from OR v_through-v_from>365 THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 v_lower:=v_from::timestamp AT TIME ZONE 'Asia/Yangon';v_upper:=(v_through+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 IF p_cursor IS NOT NULL THEN
  SELECT mv.created_at INTO v_cursor_created FROM app.inventory_stock_movements mv WHERE mv.tenant_id=p_tenant AND mv.branch_id=p_branch AND mv.product_id=p_product AND mv.id=p_cursor AND mv.created_at>=v_lower AND mv.created_at<v_upper;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid stock history cursor' USING ERRCODE='22023'; END IF;
 END IF;
 WITH candidates AS MATERIALIZED(
  SELECT mv.id,mv.tenant_id,mv.branch_id,mv.product_id,mv.quantity_delta,mv.reason,mv.actor_membership_id,mv.balance_after,mv.product_snapshot,mv.movement_kind,mv.sale_id,mv.return_id,mv.created_at FROM app.inventory_stock_movements mv
  WHERE mv.tenant_id=p_tenant AND mv.branch_id=p_branch AND mv.product_id=p_product AND mv.created_at>=v_lower AND mv.created_at<v_upper AND (p_cursor IS NULL OR (mv.created_at,mv.id)<(v_cursor_created,p_cursor)) ORDER BY mv.created_at DESC,mv.id DESC LIMIT p_limit+1
 ),page AS MATERIALIZED(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit),public_rows AS(
  SELECT mv.id,mv.created_at,jsonb_build_object('id',mv.id,'tenantId',mv.tenant_id,'branchId',mv.branch_id,'productId',mv.product_id,'createdAt',mv.created_at,'kind',mv.movement_kind,'quantityDelta',mv.quantity_delta,'balanceAfter',mv.balance_after::text,'reason',mv.reason,'actorMembershipId',mv.actor_membership_id,'actorName',coalesce(nullif(left(btrim(staff.full_name),150),''),'Staff'),'sku',mv.product_snapshot->>'sku','productName',mv.product_snapshot->>'productName','saleId',mv.sale_id,'returnId',mv.return_id) AS item
  FROM page mv LEFT JOIN app.tenant_memberships membership ON membership.tenant_id=mv.tenant_id AND membership.id=mv.actor_membership_id LEFT JOIN app.users staff ON staff.id=membership.user_id
 ) SELECT jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'productId',p_product,'from',v_from::text,'through',v_through::text,'items',coalesce((SELECT jsonb_agg(item ORDER BY created_at DESC,id DESC) FROM public_rows),'[]'::jsonb),'nextCursor',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT id FROM page ORDER BY created_at ASC,id ASC LIMIT 1) ELSE NULL END) INTO v_result;
 RETURN v_result;
END $$;


ALTER FUNCTION security.read_inventory_stock_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) OWNER TO gympro_inventory_read_owner;

--
-- Name: read_member_card(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_card_owner
--

CREATE FUNCTION security.read_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid) RETURNS TABLE(id uuid, tenant_id uuid, branch_id uuid, member_id uuid, member_number text, full_name text, status text, issued_at timestamp with time zone, revoked_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE v_session record;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.cards.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 RETURN QUERY SELECT c.id,c.tenant_id,c.branch_id,c.member_id,m.member_number::text,m.full_name::text,c.status::text,c.issued_at,c.revoked_at FROM app.member_cards c JOIN app.members m ON m.tenant_id=c.tenant_id AND m.id=c.member_id WHERE c.tenant_id=p_tenant AND c.branch_id=p_branch AND c.id=p_card;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
END $$;


ALTER FUNCTION security.read_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid) OWNER TO gympro_card_owner;

--
-- Name: read_payment_charge(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.read_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE;v jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Unknown charge' USING ERRCODE='22023'; END IF;
 IF c.branch_id IS NOT NULL AND c.branch_id<>p_branch THEN RAISE EXCEPTION 'Charge branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 SELECT security.payment_charge_json(p_tenant,c.id)||jsonb_build_object('creditedAmount',credits::text,'payableAmount',greatest(0,c.amount_due-credits)::text,'receivedAmount',paid::text,'reversedAmount',rev::text,'netReceivedAmount',(paid-rev)::text,'outstandingAmount',greatest(0,c.amount_due-credits-paid+rev)::text,'refundDueAmount',greatest(0,paid-rev-greatest(0,c.amount_due-credits))::text)
 INTO v FROM
 (SELECT coalesce(sum(total_amount),0) AS credits FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=c.sale_id) cr,
 (SELECT coalesce(sum(amount),0) AS paid FROM app.payment_receipts WHERE tenant_id=p_tenant AND charge_id=c.id) pa,
 (SELECT coalesce(sum(x.amount),0) AS rev FROM app.payment_reversals x JOIN app.payment_receipts r ON r.tenant_id=x.tenant_id AND r.id=x.receipt_id WHERE r.tenant_id=p_tenant AND r.charge_id=c.id) re;
 RETURN v;
END $$;


ALTER FUNCTION security.read_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid) OWNER TO gympro_payment_owner;

--
-- Name: read_payment_history(bytea, uuid, uuid, date, date, text, uuid, integer); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.read_payment_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_to date, p_cursor_kind text, p_cursor uuid, p_limit integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;from_day date;to_day date;include_general boolean;period_start timestamptz;period_end timestamptz;result jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 to_day:=coalesce(p_to,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);from_day:=coalesce(p_from,to_day-29);
 IF NOT isfinite(from_day) OR NOT isfinite(to_day) OR to_day<from_day OR to_day-from_day>365 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_cursor IS NULL)<>(p_cursor_kind IS NULL) OR(p_cursor_kind IS NOT NULL AND p_cursor_kind NOT IN ('receipt','refund','void')) THEN RAISE EXCEPTION 'Invalid payment history query' USING ERRCODE='22023'; END IF;
 include_general:=security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS TRUE;
 period_start:=from_day::timestamp AT TIME ZONE 'Asia/Yangon';period_end:=(to_day+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 WITH events AS (SELECT 'receipt'::text AS event_kind,r.id,r.tenant_id,r.charge_id,r.id AS receipt_id,r.collection_branch_id,r.request_id,r.amount,r.currency_code,r.method_code,r.external_reference,NULL::text AS reason,r.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END AS source_id
 FROM app.payment_receipts r JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE r.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND r.recorded_at>=period_start AND r.recorded_at<period_end
 UNION ALL
 SELECT v.reversal_kind::text,v.id,v.tenant_id,r.charge_id,r.id,r.collection_branch_id,v.request_id,v.amount,v.currency_code,r.method_code,r.external_reference,v.reason,v.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE v.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND v.recorded_at>=period_start AND v.recorded_at<period_end),
 cursor_event AS(SELECT * FROM events WHERE id=p_cursor AND event_kind=p_cursor_kind),
 selected AS(SELECT e.* FROM events e WHERE p_cursor IS NULL OR (e.recorded_at,e.id,e.event_kind COLLATE "C")<(SELECT x.recorded_at,x.id,x.event_kind COLLATE "C" FROM cursor_event x) ORDER BY e.recorded_at DESC,e.id DESC,e.event_kind COLLATE "C" DESC LIMIT p_limit+1),
 page AS(SELECT * FROM selected ORDER BY recorded_at DESC,id DESC,event_kind COLLATE "C" DESC LIMIT p_limit)
 SELECT jsonb_build_object('tenantId',p_tenant,'collectionBranchId',p_branch,'fromDate',to_char(from_day,'YYYY-MM-DD'),'toDate',to_char(to_day,'YYYY-MM-DD'),'includesTenantMemberships',include_general,'limit',p_limit,'cursorFound',p_cursor IS NULL OR EXISTS(SELECT FROM cursor_event),
 'items',coalesce((SELECT jsonb_agg(jsonb_build_object('eventKind',event_kind,'id',id,'tenantId',tenant_id,'collectionBranchId',collection_branch_id,'receiptId',receipt_id,'chargeId',charge_id,'requestId',request_id,'sourceKind',source_kind,'sourceId',source_id,'amount',amount::text,'signedAmount',(CASE WHEN event_kind='receipt' THEN amount ELSE -amount END)::text,'currencyCode',currency_code,'methodCode',method_code,'externalReference',external_reference,'reason',reason,'recordedAt',recorded_at) ORDER BY recorded_at DESC,id DESC,event_kind COLLATE "C" DESC) FROM page),'[]'::jsonb),
 'nextCursor',CASE WHEN(SELECT count(*) FROM selected)>p_limit THEN(SELECT event_kind||':'||id::text FROM page ORDER BY recorded_at,id,event_kind COLLATE "C" LIMIT 1) ELSE NULL END) INTO result;
 IF (result->>'cursorFound')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Invalid payment history cursor' USING ERRCODE='22023'; END IF;
 RETURN result-'cursorFound';
END $$;


ALTER FUNCTION security.read_payment_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_to date, p_cursor_kind text, p_cursor uuid, p_limit integer) OWNER TO gympro_payment_owner;

--
-- Name: read_payment_receipt(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.read_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Unknown receipt' USING ERRCODE='22023'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 RETURN security.payment_receipt_json(p_tenant,r.id);
END $$;


ALTER FUNCTION security.read_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid) OWNER TO gympro_payment_owner;

--
-- Name: read_payment_reconciliation(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.read_payment_reconciliation(p_hash bytea, p_tenant uuid, p_branch uuid, p_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;x app.payment_reconciliations%ROWTYPE;current_snapshot jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.reconciliation.manage');
 IF security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Complete collection read access required' USING ERRCODE='42501'; END IF;
 SELECT * INTO x FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_id;
 IF x.id IS NULL THEN RAISE EXCEPTION 'Unknown payment reconciliation' USING ERRCODE='22023'; END IF;
 current_snapshot:=security.summarize_payment_collection(p_hash,p_tenant,p_branch,x.reconciliation_date);
 RETURN security.payment_reconciliation_json(p_tenant,x.id)||jsonb_build_object('currentCollection',current_snapshot,'ledgerChanged',current_snapshot<>x.collection_snapshot);
END $$;


ALTER FUNCTION security.read_payment_reconciliation(p_hash bytea, p_tenant uuid, p_branch uuid, p_id uuid) OWNER TO gympro_payment_owner;

--
-- Name: read_payment_reversal(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.read_payment_reversal(p_hash bytea, p_tenant uuid, p_branch uuid, p_reversal uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;v app.payment_reversals%ROWTYPE;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO v FROM app.payment_reversals WHERE tenant_id=p_tenant AND id=p_reversal;
 IF v.id IS NULL THEN RAISE EXCEPTION 'Unknown payment reversal' USING ERRCODE='22023'; END IF;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=v.receipt_id;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 RETURN security.payment_reversal_json(p_tenant,v.id);
END $$;


ALTER FUNCTION security.read_payment_reversal(p_hash bytea, p_tenant uuid, p_branch uuid, p_reversal uuid) OWNER TO gympro_payment_owner;

--
-- Name: read_pos_sale(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_pos_owner
--

CREATE FUNCTION security.read_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record; v_sale_id uuid:=p_sale; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',h.id,'tenantId',h.tenant_id,'branchId',h.branch_id,'requestId',h.request_id,'status',h.status,'currencyCode',h.currency_code,'totalAmount',h.total_amount::text,'createdAt',h.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'productId',i.product_id,'sku',i.sku,'productName',i.product_name,'unitCode',i.unit_code,'quantity',i.quantity,'unitPrice',i.unit_price::text,'lineTotal',i.line_total::text) ORDER BY i.product_id) FROM app.pos_sale_items i WHERE i.tenant_id=h.tenant_id AND i.sale_id=h.id)) INTO v_receipt FROM app.pos_sales h WHERE h.tenant_id=p_tenant AND h.branch_id=p_branch AND h.id=v_sale_id;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;


ALTER FUNCTION security.read_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) OWNER TO gympro_pos_owner;

--
-- Name: read_pos_sale_history(bytea, uuid, uuid, date, date, uuid, integer); Type: FUNCTION; Schema: security; Owner: gympro_pos_return_owner
--

CREATE FUNCTION security.read_pos_sale_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE v_session record;v_cursor_created timestamptz;v_result jsonb;v_from date;v_through date;v_lower timestamptz;v_upper timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_from IS NULL)<>(p_through IS NULL)) THEN RAISE EXCEPTION 'Invalid history query' USING ERRCODE='22023'; END IF;
 v_from:=coalesce(p_from,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);v_through:=coalesce(p_through,v_from);
 IF NOT isfinite(v_from) OR NOT isfinite(v_through) THEN RAISE EXCEPTION 'Invalid history date range' USING ERRCODE='22023'; END IF;
 IF v_from<DATE '0001-01-01' OR v_through>DATE '9999-12-30' OR v_through<v_from OR v_through-v_from>365 THEN RAISE EXCEPTION 'Invalid history date range' USING ERRCODE='22023'; END IF;
 v_lower:=v_from::timestamp AT TIME ZONE 'Asia/Yangon';v_upper:=(v_through+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 IF p_cursor IS NOT NULL THEN
  SELECT sh.created_at INTO v_cursor_created FROM app.pos_sales sh WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.id=p_cursor AND sh.created_at>=v_lower AND sh.created_at<v_upper;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid history cursor' USING ERRCODE='22023'; END IF;
 END IF;
 WITH candidates AS MATERIALIZED(
  SELECT sh.* FROM app.pos_sales sh WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.created_at>=v_lower AND sh.created_at<v_upper AND (p_cursor IS NULL OR (sh.created_at,sh.id)<(v_cursor_created,p_cursor)) ORDER BY sh.created_at DESC,sh.id DESC LIMIT p_limit+1
 ),page AS MATERIALIZED(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit), public_rows AS(
  SELECT sh.id,sh.created_at,jsonb_build_object('id',sh.id,'tenantId',sh.tenant_id,'branchId',sh.branch_id,'requestId',sh.request_id,'createdAt',sh.created_at,'currencyCode',sh.currency_code,'totalAmount',sh.total_amount::text,
  'reversedAmount',rev.amount::text,'status',CASE WHEN rev.voided THEN 'voided' WHEN units.returned=units.sold THEN 'refunded' WHEN units.returned>0 THEN 'partially_refunded' ELSE 'completed' END,
  'quantitySold',units.sold::text,'quantityReturned',units.returned::text) AS item
  FROM page sh CROSS JOIN LATERAL(SELECT coalesce(sum(sr.total_amount),0)::numeric(26,2) AS amount,coalesce(bool_or(sr.action_code='void'),false) AS voided FROM app.pos_sale_returns sr WHERE sr.tenant_id=sh.tenant_id AND sr.sale_id=sh.id)rev
  CROSS JOIN LATERAL(SELECT (SELECT coalesce(sum(li.quantity),0) FROM app.pos_sale_items li WHERE li.tenant_id=sh.tenant_id AND li.sale_id=sh.id) AS sold,(SELECT coalesce(sum(ri.quantity),0) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sh.tenant_id AND ri.sale_id=sh.id) AS returned)units
 )
 SELECT jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'from',v_from::text,'through',v_through::text,'items',coalesce((SELECT jsonb_agg(item ORDER BY created_at DESC,id DESC) FROM public_rows),'[]'::jsonb),'nextCursor',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT id FROM page ORDER BY created_at ASC,id ASC LIMIT 1) ELSE NULL END) INTO v_result;
 RETURN v_result;
END $$;


ALTER FUNCTION security.read_pos_sale_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) OWNER TO gympro_pos_return_owner;

--
-- Name: read_pos_sale_return(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_pos_return_owner
--

CREATE FUNCTION security.read_pos_sale_return(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_return uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE v_session record;v_return_id uuid:=p_return;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',sr.id,'tenantId',sr.tenant_id,'branchId',sr.branch_id,'saleId',sr.sale_id,'requestId',sr.request_id,'action',sr.action_code,'reason',sr.reason,'currencyCode',sr.currency_code,'totalAmount',sr.total_amount::text,'createdAt',sr.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',ri.id,'saleItemId',ri.sale_item_id,'productId',ri.product_id,'sku',ri.sku,'productName',ri.product_name,'unitCode',ri.unit_code,'quantity',ri.quantity,'unitPrice',ri.unit_price::text,'lineTotal',ri.line_total::text) ORDER BY ri.sale_item_id) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sr.tenant_id AND ri.return_id=sr.id)) INTO v_receipt FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.branch_id=p_branch AND sr.sale_id=p_sale AND sr.id=v_return_id;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale return' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;


ALTER FUNCTION security.read_pos_sale_return(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_return uuid) OWNER TO gympro_pos_return_owner;

--
-- Name: read_pos_sale_return_status(bytea, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_pos_return_owner
--

CREATE FUNCTION security.read_pos_sale_return_status(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE v_session record;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 WITH original AS (SELECT li.id,li.product_id,li.quantity,coalesce((SELECT sum(ri.quantity) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=li.tenant_id AND ri.sale_item_id=li.id),0)::integer AS returned FROM app.pos_sale_items li WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale),
 totals AS (SELECT count(*)>0 AS any_return,coalesce(bool_or(sr.action_code='void'),false) AS voided,coalesce(sum(sr.total_amount),0)::numeric(26,2) AS amount FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.sale_id=p_sale)
 SELECT jsonb_build_object('tenantId',sh.tenant_id,'branchId',sh.branch_id,'saleId',sh.id,'status',CASE WHEN totals.voided THEN 'voided' WHEN NOT EXISTS(SELECT 1 FROM original WHERE returned<quantity) THEN 'refunded' WHEN totals.any_return THEN 'partially_refunded' ELSE 'completed' END,'voided',totals.voided,'currencyCode',sh.currency_code,'saleTotalAmount',sh.total_amount::text,'reversedAmount',totals.amount::text,'items',(SELECT jsonb_agg(jsonb_build_object('saleItemId',original.id,'productId',original.product_id,'quantitySold',original.quantity,'quantityReturned',original.returned,'quantityRemaining',original.quantity-original.returned) ORDER BY original.id) FROM original)) INTO v_receipt FROM app.pos_sales sh CROSS JOIN totals WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.id=p_sale;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;


ALTER FUNCTION security.read_pos_sale_return_status(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) OWNER TO gympro_pos_return_owner;

--
-- Name: reconcile_payment_collection(bytea, uuid, uuid, date, jsonb, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.reconcile_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date, p_declared jsonb, p_note text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
DECLARE actor jsonb;existing app.payment_reconciliations%ROWTYPE;snapshot jsonb;declared jsonb:='{}';expected jsonb:='{}';difference jsonb:='{}';m text;v numeric;exp numeric;declared_sum numeric:=0;expected_sum numeric:=0;matched boolean:=true;why text;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.reconciliation.manage');
 IF security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Complete collection read access required' USING ERRCODE='42501'; END IF;
 why:=regexp_replace(p_note,'^[[:space:]]+|[[:space:]]+$','','g');
 IF current_setting('transaction_isolation')<>'read committed' OR p_date IS NULL OR NOT isfinite(p_date) OR p_date>=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date OR p_request IS NULL OR why IS NULL OR length(why) NOT BETWEEN 2 AND 500 OR why !~ '[^[:space:]]' OR p_declared IS NULL OR jsonb_typeof(p_declared)<>'object' THEN RAISE EXCEPTION 'Invalid reconciliation request' USING ERRCODE='22023'; END IF;
 IF NOT(p_declared ?& ARRAY['cash','bank_transfer','mobile_wallet','card']) OR(p_declared-ARRAY['cash','bank_transfer','mobile_wallet','card'])<>'{}'::jsonb THEN RAISE EXCEPTION 'Four declared method totals required' USING ERRCODE='22023'; END IF;
 FOREACH m IN ARRAY ARRAY['cash','bank_transfer','mobile_wallet','card'] LOOP
  IF jsonb_typeof(p_declared->m)<>'string' OR(p_declared->>m)!~'^-?(0|[1-9][0-9]{0,42})([.][0-9]{1,2})?$' THEN RAISE EXCEPTION 'Invalid declared amount' USING ERRCODE='22023'; END IF;
  v:=(p_declared->>m)::numeric(45,2);declared:=declared||jsonb_build_object(m,v::text);declared_sum:=declared_sum+v;
 END LOOP;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,506));
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_branch::text||':'||to_char(p_date,'YYYY-MM-DD'),507));
 SELECT * INTO existing FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND request_id=p_request;
 IF existing.id IS NOT NULL THEN
  IF existing.branch_id<>p_branch OR existing.reconciliation_date<>p_date OR existing.declared_totals<>declared OR existing.note<>why THEN RAISE EXCEPTION 'Reconciliation request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_reconciliation_json(p_tenant,existing.id);
 END IF;
 IF EXISTS(SELECT FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND branch_id=p_branch AND reconciliation_date=p_date) THEN RAISE EXCEPTION 'Collection day already reconciled' USING ERRCODE='22023'; END IF;
 snapshot:=security.summarize_payment_collection(p_hash,p_tenant,p_branch,p_date);
 IF (snapshot->>'includesTenantMemberships')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Incomplete collection snapshot' USING ERRCODE='22023'; END IF;
 FOREACH m IN ARRAY ARRAY['cash','bank_transfer','mobile_wallet','card'] LOOP
  SELECT (x->>'netAmount')::numeric INTO exp FROM jsonb_array_elements(snapshot->'byMethod') x WHERE x->>'methodCode'=m;
  IF exp IS NULL THEN RAISE EXCEPTION 'Incomplete method snapshot' USING ERRCODE='22023'; END IF;
  v:=(declared->>m)::numeric;expected:=expected||jsonb_build_object(m,exp::numeric(45,2)::text);difference:=difference||jsonb_build_object(m,(v-exp)::numeric(46,2)::text);expected_sum:=expected_sum+exp;matched:=matched AND v=exp;
 END LOOP;
 INSERT INTO app.payment_reconciliations(tenant_id,branch_id,reconciliation_date,request_id,declared_totals,expected_totals,difference_totals,declared_net_amount,expected_net_amount,difference_amount,status,note,collection_snapshot,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,p_date,p_request,declared,expected,difference,declared_sum,expected_sum,declared_sum-expected_sum,CASE WHEN matched THEN 'matched' ELSE 'variance' END,why,snapshot,(actor->>'membershipId')::uuid,actor) RETURNING * INTO existing;
 RETURN security.payment_reconciliation_json(p_tenant,existing.id);
END $_$;


ALTER FUNCTION security.reconcile_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date, p_declared jsonb, p_note text, p_request uuid) OWNER TO gympro_payment_owner;

--
-- Name: record_payment_receipt(bytea, uuid, uuid, uuid, numeric, text, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.record_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid, p_amount numeric, p_method text, p_reference text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE;r app.payment_receipts%ROWTYPE; paid numeric;rev numeric;credits numeric;ref text;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.record');
 IF current_setting('transaction_isolation')<>'read committed' OR p_charge IS NULL OR p_request IS NULL OR p_amount IS NULL OR NOT(p_amount>0 AND p_amount<1e24) OR p_amount<>round(p_amount,2) OR p_method IS NULL OR p_method NOT IN ('cash','bank_transfer','mobile_wallet','card') THEN RAISE EXCEPTION 'Invalid payment request' USING ERRCODE='22023'; END IF;
 ref:=nullif(btrim(p_reference),'');
 IF (ref IS NOT NULL AND (length(ref)>150 OR ref !~ '[^[:space:]]')) OR (p_method<>'cash' AND ref IS NULL) THEN RAISE EXCEPTION 'Payment reference required' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Unknown charge' USING ERRCODE='22023'; END IF;
 IF c.branch_id IS NOT NULL AND c.branch_id<>p_branch THEN RAISE EXCEPTION 'Charge branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.record',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 -- Same purchase lock used by existing sales-return and membership functions.
 IF c.sale_id IS NOT NULL THEN PERFORM id FROM app.pos_sales WHERE tenant_id=p_tenant AND id=c.sale_id FOR UPDATE;
 ELSE PERFORM id FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=c.subscription_id FOR UPDATE; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge FOR UPDATE;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF r.id IS NOT NULL THEN
  IF r.charge_id<>p_charge OR r.collection_branch_id<>p_branch OR r.amount<>p_amount OR r.method_code<>p_method OR r.external_reference IS DISTINCT FROM ref THEN RAISE EXCEPTION 'Payment request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_receipt_json(p_tenant,r.id);
 END IF;
 SELECT coalesce(sum(amount),0) INTO paid FROM app.payment_receipts WHERE tenant_id=p_tenant AND charge_id=p_charge;
 SELECT coalesce(sum(v.amount),0) INTO rev FROM app.payment_reversals v JOIN app.payment_receipts x ON x.tenant_id=v.tenant_id AND x.id=v.receipt_id WHERE x.tenant_id=p_tenant AND x.charge_id=p_charge;
 SELECT coalesce(sum(total_amount),0) INTO credits FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=c.sale_id;
 IF p_amount>greatest(0,c.amount_due-credits)-(paid-rev) THEN RAISE EXCEPTION 'Payment exceeds outstanding balance' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_receipts(tenant_id,charge_id,collection_branch_id,request_id,amount,method_code,external_reference,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_charge,p_branch,p_request,p_amount,p_method,ref,(actor->>'membershipId')::uuid,actor) RETURNING * INTO r;
 RETURN security.payment_receipt_json(p_tenant,r.id);
END $$;


ALTER FUNCTION security.record_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid, p_amount numeric, p_method text, p_reference text, p_request uuid) OWNER TO gympro_payment_owner;

--
-- Name: members; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid,
    member_number character varying(32) NOT NULL,
    full_name character varying(150) NOT NULL,
    phone character varying(20),
    email character varying(254),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_members_contact CHECK (((NULLIF(btrim((phone)::text), ''::text) IS NOT NULL) OR (NULLIF(btrim((email)::text), ''::text) IS NOT NULL))),
    CONSTRAINT chk_members_email CHECK (((email IS NULL) OR ((length((email)::text) <= 254) AND ((email)::text ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'::text)))),
    CONSTRAINT chk_members_name CHECK (((length(btrim((full_name)::text)) >= 2) AND (length(btrim((full_name)::text)) <= 150))),
    CONSTRAINT chk_members_number_not_blank CHECK ((length(btrim((member_number)::text)) > 0)),
    CONSTRAINT chk_members_phone CHECK (((phone IS NULL) OR (((length((phone)::text) >= 7) AND (length((phone)::text) <= 20)) AND ((phone)::text ~ '^\+?[0-9][0-9 ()-]*$'::text)))),
    CONSTRAINT chk_members_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'inactive'::character varying, 'blacklisted'::character varying])::text[])))
);

ALTER TABLE ONLY app.members FORCE ROW LEVEL SECURITY;


ALTER TABLE app.members OWNER TO postgres;

--
-- Name: register_member(bytea, uuid, uuid, text, text, text); Type: FUNCTION; Schema: security; Owner: gympro_member_owner
--

CREATE FUNCTION security.register_member(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_full_name text, p_phone text, p_email text) RETURNS SETOF app.members
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
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
$_$;


ALTER FUNCTION security.register_member(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_full_name text, p_phone text, p_email text) OWNER TO gympro_member_owner;

--
-- Name: renew_branch_discounted_membership(bytea, uuid, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) RETURNS SETOF app.membership_discounts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.apply_discount',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.discount:'||p_tenant_id::text||':'||p_request_id::text,0));
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.renewal:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant_id AND id=p_subscription_id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Subscription access denied'; END IF;
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=v_sub.member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant_id AND id=p_subscription_id FOR UPDATE;
 IF NOT FOUND OR v_sub.member_id IS DISTINCT FROM v_member.id OR v_sub.branch_id IS DISTINCT FROM p_branch_id OR v_member.branch_id IS DISTINCT FROM p_branch_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.renew_discounted_membership(p_token_hash,p_tenant_id,p_subscription_id,p_plan_price_id,p_promotion_id,p_request_id);
END;
$$;


ALTER FUNCTION security.renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: subscription_renewals; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.subscription_renewals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    plan_price_id uuid NOT NULL,
    previous_ends_on date NOT NULL,
    renewal_starts_on date NOT NULL,
    renewal_ends_on date NOT NULL,
    duration_value integer NOT NULL,
    duration_unit character varying(10) NOT NULL,
    agreed_price_amount numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    previous_subscription_snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_subscription_renewals_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_subscription_renewals_dates CHECK ((isfinite(previous_ends_on) AND isfinite(renewal_starts_on) AND isfinite(renewal_ends_on) AND (renewal_starts_on >= previous_ends_on) AND (renewal_ends_on > renewal_starts_on))),
    CONSTRAINT chk_subscription_renewals_duration_unit CHECK (((duration_unit)::text = ANY ((ARRAY['days'::character varying, 'weeks'::character varying, 'months'::character varying, 'years'::character varying])::text[]))),
    CONSTRAINT chk_subscription_renewals_duration_value CHECK ((duration_value > 0)),
    CONSTRAINT chk_subscription_renewals_price CHECK (((agreed_price_amount >= (0)::numeric) AND (agreed_price_amount < ('1000000000000'::bigint)::numeric))),
    CONSTRAINT chk_subscription_renewals_snapshot CHECK (((jsonb_typeof(previous_subscription_snapshot) = 'object'::text) AND (previous_subscription_snapshot <> '{}'::jsonb)))
);

ALTER TABLE ONLY app.subscription_renewals FORCE ROW LEVEL SECURITY;


ALTER TABLE app.subscription_renewals OWNER TO postgres;

--
-- Name: renew_branch_member_subscription(bytea, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.renew_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) RETURNS SETOF app.subscription_renewals
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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

    IF p_subscription_id IS NULL
       OR p_plan_price_id IS NULL
       OR p_request_id IS NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Subscription, price, and request ID are required';
    END IF;

    -- Match the existing renewal lock order.
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
    FROM security.renew_member_subscription(
        p_token_hash,
        p_tenant_id,
        p_subscription_id,
        p_plan_price_id,
        p_request_id
    );
END;
$$;


ALTER FUNCTION security.renew_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: renew_discounted_membership(bytea, uuid, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.renew_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) RETURNS SETOF app.membership_discounts
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.renew_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: renew_member_subscription(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.renew_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) RETURNS SETOF app.subscription_renewals
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


    IF v_subscription.membership_kind <> 'standard' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'FOC subscriptions require dedicated complimentary authorization';
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


ALTER FUNCTION security.renew_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: reverse_payment_receipt(bytea, uuid, uuid, uuid, text, numeric, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.reverse_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid, p_kind text, p_amount numeric, p_reason text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $_$
DECLARE actor jsonb;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;v app.payment_reversals%ROWTYPE;why text;already numeric;amount numeric;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.reverse');
 why:=regexp_replace(p_reason,'^[[:space:]]+|[[:space:]]+$','','g');
 IF current_setting('transaction_isolation')<>'read committed' OR p_receipt IS NULL OR p_request IS NULL OR p_kind IS NULL OR p_kind NOT IN ('refund','void') OR why IS NULL OR length(why) NOT BETWEEN 2 AND 500 OR why !~ '[^[:space:]]' THEN RAISE EXCEPTION 'Invalid payment reversal request' USING ERRCODE='22023'; END IF;
 IF (p_kind='void' AND p_amount IS NOT NULL) OR (p_kind='refund' AND (p_amount IS NULL OR NOT(p_amount>0 AND p_amount<1e24) OR p_amount<>round(p_amount,2))) THEN RAISE EXCEPTION 'Invalid reversal amount' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Unknown payment receipt' USING ERRCODE='22023'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.reverse',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant reversal access denied' USING ERRCODE='42501'; END IF;
 -- Preserve the purchase -> charge -> receipt lock order used by payment recording.
 IF c.sale_id IS NOT NULL THEN PERFORM id FROM app.pos_sales WHERE tenant_id=p_tenant AND id=c.sale_id FOR UPDATE;
 ELSE PERFORM id FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=c.subscription_id FOR UPDATE; END IF;
 PERFORM id FROM app.payment_charges WHERE tenant_id=p_tenant AND id=c.id FOR UPDATE;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt FOR UPDATE;
 SELECT * INTO v FROM app.payment_reversals WHERE tenant_id=p_tenant AND request_id=p_request;
 IF v.id IS NOT NULL THEN
  IF v.receipt_id<>p_receipt OR v.reversal_kind<>p_kind OR v.reason<>why OR(p_kind='refund' AND v.amount<>p_amount) THEN RAISE EXCEPTION 'Reversal request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_reversal_json(p_tenant,v.id);
 END IF;
 SELECT coalesce(sum(x.amount),0) INTO already FROM app.payment_reversals x WHERE x.tenant_id=p_tenant AND x.receipt_id=p_receipt;
 IF p_kind='void' THEN
  IF EXISTS(SELECT FROM app.payment_reversals WHERE tenant_id=p_tenant AND receipt_id=p_receipt) THEN RAISE EXCEPTION 'A reversed receipt cannot be voided' USING ERRCODE='22023'; END IF;
  amount:=r.amount;
 ELSE amount:=p_amount; END IF;
 IF amount>r.amount-already THEN RAISE EXCEPTION 'Reversal exceeds remaining receipt amount' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_reversals(tenant_id,receipt_id,request_id,reversal_kind,amount,reason,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_receipt,p_request,p_kind,amount,why,(actor->>'membershipId')::uuid,actor) RETURNING * INTO v;
 RETURN security.payment_reversal_json(p_tenant,v.id);
END $_$;


ALTER FUNCTION security.reverse_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid, p_kind text, p_amount numeric, p_reason text, p_request uuid) OWNER TO gympro_payment_owner;

--
-- Name: revoke_tenant_session(uuid, bytea); Type: FUNCTION; Schema: security; Owner: gympro_session_owner
--

CREATE FUNCTION security.revoke_tenant_session(p_session_id uuid, p_token_hash bytea) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE
    v_revoked_id uuid;
BEGIN
    -- Invalid input must not revoke anything.

    IF p_session_id IS NULL
       OR p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32
    THEN
        RETURN false;
    END IF;

    -- Both session ID and token hash must match.
    -- An already-revoked session is not updated again.

    UPDATE security.tenant_sessions AS s
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE s.id = p_session_id
      AND s.session_token_hash = p_token_hash
      AND s.revoked_at IS NULL
    RETURNING s.id INTO v_revoked_id;

    RETURN v_revoked_id IS NOT NULL;
END;
$$;


ALTER FUNCTION security.revoke_tenant_session(p_session_id uuid, p_token_hash bytea) OWNER TO gympro_session_owner;

--
-- Name: scan_member_card(bytea, uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: security; Owner: gympro_card_owner
--

CREATE FUNCTION security.scan_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid, p_request uuid) RETURNS SETOF app.attendance_visits
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record;v_card app.member_cards%ROWTYPE;v_member uuid;v_receipt app.card_scan_receipts%ROWTYPE;v_visit app.attendance_visits%ROWTYPE;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 IF p_branch IS NULL OR p_card IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 -- Acquire the delegated check-in request lock BEFORE the member lock.
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance:'||p_tenant::text||':'||p_request::text,0));
 SELECT member_id INTO v_member FROM app.member_cards WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_card;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 PERFORM 1 FROM app.members WHERE tenant_id=p_tenant AND id=v_member FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 -- Card revocation also locks member first, then card: same ordering.
 SELECT * INTO v_card FROM app.member_cards WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_card AND member_id=v_member FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 IF v_card.status<>'active' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan'; END IF;
 SELECT * INTO v_receipt FROM app.card_scan_receipts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_receipt.card_id<>p_card OR v_receipt.branch_id<>p_branch OR v_receipt.member_id<>v_member THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan';END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM app.attendance_visits WHERE tenant_id=p_tenant AND request_id=p_request) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan';END IF;
 END IF;
 SELECT * INTO v_visit FROM security.check_in_member(p_hash,p_tenant,p_branch,v_member,p_request);
 IF v_receipt.id IS NULL THEN
  INSERT INTO app.card_scan_receipts(tenant_id,branch_id,member_id,card_id,visit_id,request_id,actor_membership_id,actor_snapshot)
  VALUES(p_tenant,p_branch,v_member,p_card,v_visit.id,p_request,v_session.membership_id,
   jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id));
 END IF;
 RETURN NEXT v_visit;
END $$;


ALTER FUNCTION security.scan_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid, p_request uuid) OWNER TO gympro_card_owner;

--
-- Name: search_branch_members(bytea, uuid, uuid, text, integer, uuid); Type: FUNCTION; Schema: security; Owner: gympro_member_reader
--

CREATE FUNCTION security.search_branch_members(p_hash bytea, p_tenant uuid, p_branch uuid, p_query text, p_limit integer, p_after uuid) RETURNS TABLE(id uuid, tenant_id uuid, branch_id uuid, member_number text, full_name text, status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record;q text;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.members.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Member lookup access denied';END IF;
 q:=btrim(p_query);
 IF q IS NULL OR length(q) NOT BETWEEN 2 AND 100 OR q !~ '[^[:space:]]' OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid member lookup';END IF;
 -- Branch-assigned members only. Unassigned tenant-wide members are not exposed on this branch route.
 RETURN QUERY SELECT m.id,m.tenant_id,m.branch_id,m.member_number::text,m.full_name::text,m.status::text
 FROM app.members m WHERE m.tenant_id=p_tenant AND m.branch_id=p_branch
 AND (p_after IS NULL OR m.id>p_after)
 AND (strpos(lower(m.full_name),lower(q))>0 OR strpos(lower(m.member_number),lower(q))>0)
 ORDER BY m.id LIMIT p_limit+1;
END $$;


ALTER FUNCTION security.search_branch_members(p_hash bytea, p_tenant uuid, p_branch uuid, p_query text, p_limit integer, p_after uuid) OWNER TO gympro_member_reader;

--
-- Name: set_branch_membership_promotion_status(bytea, uuid, uuid, uuid, text); Type: FUNCTION; Schema: security; Owner: gympro_promotion_owner
--

CREATE FUNCTION security.set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text) RETURNS SETOF app.membership_promotions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.promotions.manage',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 SELECT branch_id INTO v_branch FROM app.membership_promotions WHERE tenant_id=p_tenant_id AND id=p_promotion_id FOR UPDATE;
 IF NOT FOUND OR v_branch IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.set_membership_promotion_status(p_token_hash,p_tenant_id,p_promotion_id,p_status);
END;
$$;


ALTER FUNCTION security.set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text) OWNER TO gympro_promotion_owner;

--
-- Name: set_membership_promotion_status(bytea, uuid, uuid, text); Type: FUNCTION; Schema: security; Owner: gympro_promotion_owner
--

CREATE FUNCTION security.set_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_promotion_id uuid, p_status text) RETURNS SETOF app.membership_promotions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE
    v_session record;
    v_promotion app.membership_promotions%ROWTYPE;
    v_today date := CURRENT_DATE;
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

    SELECT * INTO v_promotion
    FROM app.membership_promotions
    WHERE tenant_id = p_tenant_id
      AND id = p_promotion_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid promotion';
    END IF;

    IF security.has_tenant_permission(
        p_tenant_id,
        v_session.membership_id,
        'gym.promotions.manage',
        v_promotion.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'Promotion management permission denied';
    END IF;

    IF p_status IS NULL
       OR p_status NOT IN ('active', 'inactive') THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'Invalid promotion status';
    END IF;

    IF p_status = 'active' THEN
        IF v_promotion.ends_on IS NOT NULL
           AND v_promotion.ends_on <= v_today THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'Promotion validity period has ended';
        END IF;

        IF v_promotion.plan_id IS NOT NULL THEN
            PERFORM 1 FROM app.membership_plans
            WHERE tenant_id = p_tenant_id
              AND id = v_promotion.plan_id
              AND status = 'active';

            IF NOT FOUND THEN
                RAISE EXCEPTION USING
                    ERRCODE = '22023',
                    MESSAGE = 'Promotion plan is not active';
            END IF;
        END IF;

        IF v_promotion.branch_id IS NOT NULL THEN
            PERFORM 1 FROM app.branches
            WHERE tenant_id = p_tenant_id
              AND id = v_promotion.branch_id
              AND status = 'active';

            IF NOT FOUND THEN
                RAISE EXCEPTION USING
                    ERRCODE = '22023',
                    MESSAGE = 'Promotion branch is not active';
            END IF;
        END IF;
    END IF;

    -- Repeating the same status preserves the existing timestamps.
    IF v_promotion.status = p_status THEN
        RETURN NEXT v_promotion;
        RETURN;
    END IF;

    RETURN QUERY
    UPDATE app.membership_promotions
    SET status = p_status,
        updated_at = statement_timestamp()
    WHERE tenant_id = p_tenant_id
      AND id = p_promotion_id
    RETURNING *;
END;
$$;


ALTER FUNCTION security.set_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_promotion_id uuid, p_status text) OWNER TO gympro_promotion_owner;

--
-- Name: summarize_branch_attendance(bytea, uuid, uuid, date); Type: FUNCTION; Schema: security; Owner: gympro_attendance_reader
--

CREATE FUNCTION security.summarize_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_day date) RETURNS TABLE(tenant_id uuid, branch_id uuid, summary_day text, check_ins integer, distinct_members integer, check_outs integer, current_occupancy integer, generated_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
    AS $$
DECLARE s record;d date;at_time timestamptz;from_time timestamptz;to_time timestamptz;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.attendance.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied';END IF;
 at_time:=clock_timestamp();d:=coalesce(p_day,(at_time AT TIME ZONE 'Asia/Yangon')::date);
 IF NOT isfinite(d) OR d<DATE '0001-01-01' OR d>DATE '9999-12-31' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance day';END IF;
 from_time:=d::timestamp AT TIME ZONE 'Asia/Yangon';to_time:=(d+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 -- One aggregate statement, one MVCC snapshot. Occupancy includes all open visits,
 -- even when the selected summary day is historical or the visit began yesterday.
 RETURN QUERY SELECT p_tenant,p_branch,d::text,
 (count(*) FILTER(WHERE v.checked_in_at>=from_time AND v.checked_in_at<to_time))::integer,
 (count(DISTINCT v.member_id) FILTER(WHERE v.checked_in_at>=from_time AND v.checked_in_at<to_time))::integer,
 (count(*) FILTER(WHERE v.checked_out_at>=from_time AND v.checked_out_at<to_time))::integer,
 (count(*) FILTER(WHERE v.checked_out_at IS NULL))::integer,at_time
 FROM app.attendance_visits v WHERE v.tenant_id=p_tenant AND v.branch_id=p_branch
 AND ((v.checked_in_at>=from_time AND v.checked_in_at<to_time) OR (v.checked_out_at>=from_time AND v.checked_out_at<to_time) OR v.checked_out_at IS NULL);
END $$;


ALTER FUNCTION security.summarize_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_day date) OWNER TO gympro_attendance_reader;

--
-- Name: summarize_payment_collection(bytea, uuid, uuid, date); Type: FUNCTION; Schema: security; Owner: gympro_payment_owner
--

CREATE FUNCTION security.summarize_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE actor jsonb;day date;include_general boolean;period_start timestamptz;period_end timestamptz;result jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 day:=coalesce(p_date,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);
 IF NOT isfinite(day) THEN RAISE EXCEPTION 'Invalid collection date' USING ERRCODE='22023'; END IF;
 include_general:=security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS TRUE;
 period_start:=day::timestamp AT TIME ZONE 'Asia/Yangon';period_end:=(day+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 WITH events AS (SELECT 'receipt'::text AS event_kind,r.id,r.tenant_id,r.charge_id,r.id AS receipt_id,r.collection_branch_id,r.request_id,r.amount,r.currency_code,r.method_code,r.external_reference,NULL::text AS reason,r.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END AS source_id
 FROM app.payment_receipts r JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE r.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND r.recorded_at>=period_start AND r.recorded_at<period_end
 UNION ALL
 SELECT v.reversal_kind::text,v.id,v.tenant_id,r.charge_id,r.id,r.collection_branch_id,v.request_id,v.amount,v.currency_code,r.method_code,r.external_reference,v.reason,v.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE v.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND v.recorded_at>=period_start AND v.recorded_at<period_end),
 methods(ord,code) AS(VALUES(1,'cash'),(2,'bank_transfer'),(3,'mobile_wallet'),(4,'card')),
 aggregates AS(SELECT m.ord,m.code,count(e.id) FILTER(WHERE e.event_kind='receipt') receipt_count,count(e.id) FILTER(WHERE e.event_kind='refund') refund_count,count(e.id) FILTER(WHERE e.event_kind='void') void_count,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='receipt'),0) received,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='refund'),0) refunded,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='void'),0) voided FROM methods m LEFT JOIN events e ON e.method_code=m.code GROUP BY m.ord,m.code)
 SELECT jsonb_build_object('tenantId',p_tenant,'collectionBranchId',p_branch,'date',to_char(day,'YYYY-MM-DD'),'timezone','Asia/Yangon','currencyCode','MMK','includesTenantMemberships',include_general,
 'receiptCount',(SELECT sum(receipt_count)::text FROM aggregates),'refundCount',(SELECT sum(refund_count)::text FROM aggregates),'voidCount',(SELECT sum(void_count)::text FROM aggregates),
 'receivedAmount',(SELECT sum(received)::text FROM aggregates),'refundedAmount',(SELECT sum(refunded)::text FROM aggregates),'voidedAmount',(SELECT sum(voided)::text FROM aggregates),'netAmount',(SELECT sum(received-refunded-voided)::text FROM aggregates),
 'byMethod',(SELECT jsonb_agg(jsonb_build_object('methodCode',code,'receiptCount',receipt_count::text,'refundCount',refund_count::text,'voidCount',void_count::text,'receivedAmount',received::text,'refundedAmount',refunded::text,'voidedAmount',voided::text,'netAmount',(received-refunded-voided)::text) ORDER BY ord) FROM aggregates)) INTO result;
 RETURN result;
END $$;


ALTER FUNCTION security.summarize_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date) OWNER TO gympro_payment_owner;

--
-- Name: subscription_suspensions; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.subscription_suspensions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    subscription_id uuid NOT NULL,
    request_id uuid NOT NULL,
    reason character varying(500) NOT NULL,
    suspended_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    previous_subscription_snapshot jsonb CONSTRAINT subscription_suspensions_previous_subscription_snapsho_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_subscription_suspensions_reason CHECK ((((reason)::text = btrim((reason)::text)) AND ((length((reason)::text) >= 2) AND (length((reason)::text) <= 500)) AND ((reason)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT chk_subscription_suspensions_snapshot CHECK (((jsonb_typeof(previous_subscription_snapshot) = 'object'::text) AND (previous_subscription_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_subscription_suspensions_timestamp CHECK (isfinite(suspended_at))
);

ALTER TABLE ONLY app.subscription_suspensions FORCE ROW LEVEL SECURITY;


ALTER TABLE app.subscription_suspensions OWNER TO postgres;

--
-- Name: suspend_branch_member_subscription(bytea, uuid, uuid, uuid, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.suspend_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) RETURNS SETOF app.subscription_suspensions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.suspend_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: suspend_member_subscription(bytea, uuid, uuid, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_membership_owner
--

CREATE FUNCTION security.suspend_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) RETURNS SETOF app.subscription_suspensions
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    SET "TimeZone" TO 'Asia/Yangon'
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


ALTER FUNCTION security.suspend_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) OWNER TO gympro_membership_owner;

--
-- Name: update_inventory_product(bytea, uuid, uuid, text, text, numeric, text, uuid); Type: FUNCTION; Schema: security; Owner: gympro_inventory_owner
--

CREATE FUNCTION security.update_inventory_product(p_hash bytea, p_tenant uuid, p_product uuid, p_name text, p_description text, p_price numeric, p_status text, p_request uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET row_security TO 'on'
    AS $$
DECLARE s record; p app.inventory_products%ROWTYPE; e app.inventory_product_events%ROWTYPE; v_input jsonb; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.update',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 p_name:=btrim(p_name);p_description:=nullif(btrim(p_description),'');
 IF p_request IS NULL OR p_product IS NULL OR p_name IS NULL OR length(p_name) NOT BETWEEN 2 AND 150 OR p_name!~'[^[:space:]]' OR coalesce(length(p_description),0)>2000 OR p_price IS NULL OR p_price<0 OR p_price>999999999999.99 OR p_price='NaN'::numeric OR p_price<>round(p_price,2) OR p_status IS NULL OR p_status NOT IN ('draft','active','inactive') THEN RAISE EXCEPTION 'Invalid product update' USING ERRCODE='22023'; END IF;
 v_input:=jsonb_build_object('productId',p_product,'name',p_name,'description',p_description,'price',p_price,'status',p_status);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,201));
 SELECT * INTO e FROM app.inventory_product_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF e.action_code<>'update' OR e.input_snapshot<>v_input THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  RETURN e.receipt;
 END IF;
 SELECT * INTO p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 UPDATE app.inventory_products SET product_name=p_name,description=p_description,sale_price=p_price,status=p_status,updated_at=greatest(clock_timestamp(),created_at) WHERE tenant_id=p_tenant AND id=p_product RETURNING * INTO p;
 v_receipt:=jsonb_build_object('id',p.id,'tenantId',p.tenant_id,'sku',p.sku,'productName',p.product_name,'description',p.description,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code,'status',p.status,'createdAt',p.created_at,'updatedAt',p.updated_at,'requestId',p_request);
 INSERT INTO app.inventory_product_events(tenant_id,product_id,request_id,action_code,input_snapshot,actor_membership_id,actor_snapshot,receipt) VALUES(p_tenant,p.id,p_request,'update',v_input,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_receipt);
 RETURN v_receipt;
END $$;


ALTER FUNCTION security.update_inventory_product(p_hash bytea, p_tenant uuid, p_product uuid, p_name text, p_description text, p_price numeric, p_status text, p_request uuid) OWNER TO gympro_inventory_owner;

--
-- Name: verify_tenant_session(bytea); Type: FUNCTION; Schema: security; Owner: gympro_session_owner
--

CREATE FUNCTION security.verify_tenant_session(p_token_hash bytea) RETURNS TABLE(session_id uuid, tenant_id uuid, membership_id uuid, user_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
BEGIN

    -- Reject malformed input.
    IF p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32
    THEN
        RETURN;
    END IF;

    -- Return identity only for a currently valid
    -- session with active account relationships.

    RETURN QUERY
    SELECT
        s.id,
        s.tenant_id,
        s.membership_id,
        m.user_id

    FROM security.tenant_sessions AS s

    INNER JOIN app.tenant_memberships AS m
        ON m.id = s.membership_id
       AND m.tenant_id = s.tenant_id

    INNER JOIN app.users AS u
        ON u.id = m.user_id

    INNER JOIN platform.tenants AS t
        ON t.id = s.tenant_id

    WHERE s.session_token_hash = p_token_hash

      AND s.expires_at > statement_timestamp()

      AND s.revoked_at IS NULL

      AND m.status = 'active'

      AND u.status = 'active'

      AND t.status = 'active'

    LIMIT 1;

END;
$$;


ALTER FUNCTION security.verify_tenant_session(p_token_hash bytea) OWNER TO gympro_session_owner;

--
-- Name: branches; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.branches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_code character varying(30) NOT NULL,
    branch_name character varying(200) NOT NULL,
    address text,
    phone character varying(30),
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT branches_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::text[]))),
    CONSTRAINT chk_branch_code_not_blank CHECK ((length(TRIM(BOTH FROM branch_code)) > 0)),
    CONSTRAINT chk_branch_name_not_blank CHECK ((length(TRIM(BOTH FROM branch_name)) > 0))
);

ALTER TABLE ONLY app.branches FORCE ROW LEVEL SECURITY;


ALTER TABLE app.branches OWNER TO postgres;

--
-- Name: card_scan_receipts; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.card_scan_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    member_id uuid NOT NULL,
    card_id uuid NOT NULL,
    visit_id uuid NOT NULL,
    request_id uuid NOT NULL,
    scanned_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    CONSTRAINT card_scan_receipts_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT card_scan_receipts_scanned_at_check CHECK (isfinite(scanned_at))
);

ALTER TABLE ONLY app.card_scan_receipts FORCE ROW LEVEL SECURITY;


ALTER TABLE app.card_scan_receipts OWNER TO postgres;

--
-- Name: inventory_product_events; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.inventory_product_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    product_id uuid NOT NULL,
    request_id uuid NOT NULL,
    action_code text NOT NULL,
    input_snapshot jsonb NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    receipt jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT inventory_product_events_action_code_check CHECK ((action_code = ANY (ARRAY['create'::text, 'update'::text]))),
    CONSTRAINT inventory_product_events_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT inventory_product_events_created_at_check CHECK (isfinite(created_at)),
    CONSTRAINT inventory_product_events_input_snapshot_check CHECK (((jsonb_typeof(input_snapshot) = 'object'::text) AND (input_snapshot <> '{}'::jsonb))),
    CONSTRAINT inventory_product_events_receipt_check CHECK (((jsonb_typeof(receipt) = 'object'::text) AND (receipt <> '{}'::jsonb)))
);

ALTER TABLE ONLY app.inventory_product_events FORCE ROW LEVEL SECURITY;


ALTER TABLE app.inventory_product_events OWNER TO postgres;

--
-- Name: inventory_products; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.inventory_products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    sku character varying(32) NOT NULL,
    product_name character varying(150) NOT NULL,
    description text,
    unit_code character varying(16) DEFAULT 'piece'::character varying NOT NULL,
    sale_price numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_inventory_product_name_nonblank CHECK (((product_name)::text ~ '[^[:space:]]'::text)),
    CONSTRAINT chk_inventory_products_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_inventory_products_name CHECK ((((product_name)::text = btrim((product_name)::text)) AND ((length((product_name)::text) >= 2) AND (length((product_name)::text) <= 150)))),
    CONSTRAINT chk_inventory_products_price CHECK (((sale_price >= (0)::numeric) AND (sale_price <> 'NaN'::numeric))),
    CONSTRAINT chk_inventory_products_sku CHECK (((sku)::text ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'::text)),
    CONSTRAINT chk_inventory_products_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'inactive'::character varying])::text[]))),
    CONSTRAINT chk_inventory_products_times CHECK ((isfinite(created_at) AND isfinite(updated_at) AND (updated_at >= created_at))),
    CONSTRAINT chk_inventory_products_unit CHECK (((unit_code)::text ~ '^[a-z][a-z0-9_]{0,15}$'::text))
);

ALTER TABLE ONLY app.inventory_products FORCE ROW LEVEL SECURITY;


ALTER TABLE app.inventory_products OWNER TO postgres;

--
-- Name: inventory_stock_movements; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.inventory_stock_movements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    product_id uuid NOT NULL,
    request_id uuid NOT NULL,
    quantity_delta integer NOT NULL,
    reason text NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    balance_after bigint NOT NULL,
    product_snapshot jsonb NOT NULL,
    movement_kind character varying(16) DEFAULT 'adjustment'::character varying NOT NULL,
    sale_id uuid,
    sale_item_id uuid,
    return_id uuid,
    return_item_id uuid,
    CONSTRAINT chk_inventory_movement_balance CHECK ((balance_after >= 0)),
    CONSTRAINT chk_inventory_movement_kind CHECK (((((movement_kind)::text = 'adjustment'::text) AND (sale_id IS NULL) AND (sale_item_id IS NULL) AND (return_id IS NULL) AND (return_item_id IS NULL)) OR (((movement_kind)::text = 'sale'::text) AND (sale_id IS NOT NULL) AND (sale_item_id IS NOT NULL) AND (quantity_delta < 0) AND (return_id IS NULL) AND (return_item_id IS NULL)) OR (((movement_kind)::text = ANY ((ARRAY['refund'::character varying, 'void'::character varying])::text[])) AND (sale_id IS NOT NULL) AND (sale_item_id IS NOT NULL) AND (quantity_delta > 0) AND (return_id IS NOT NULL) AND (return_item_id IS NOT NULL)))),
    CONSTRAINT chk_inventory_movement_product_snapshot CHECK (((jsonb_typeof(product_snapshot) = 'object'::text) AND (product_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_inventory_movement_quantity CHECK ((quantity_delta <> 0)),
    CONSTRAINT chk_inventory_movement_reason CHECK (((reason = btrim(reason)) AND ((length(reason) >= 2) AND (length(reason) <= 500)) AND (reason ~ '[^[:space:]]'::text))),
    CONSTRAINT chk_inventory_movement_snapshot CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT chk_inventory_movement_time CHECK (isfinite(created_at))
);

ALTER TABLE ONLY app.inventory_stock_movements FORCE ROW LEVEL SECURITY;


ALTER TABLE app.inventory_stock_movements OWNER TO postgres;

--
-- Name: member_cards; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.member_cards (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    member_id uuid NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    issued_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT member_cards_check CHECK (((((status)::text = 'active'::text) AND (revoked_at IS NULL)) OR (((status)::text = 'revoked'::text) AND (revoked_at IS NOT NULL) AND isfinite(revoked_at) AND (revoked_at >= issued_at)))),
    CONSTRAINT member_cards_issued_at_check CHECK (isfinite(issued_at)),
    CONSTRAINT member_cards_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'revoked'::character varying])::text[])))
);

ALTER TABLE ONLY app.member_cards FORCE ROW LEVEL SECURITY;


ALTER TABLE app.member_cards OWNER TO postgres;

--
-- Name: member_number_seq; Type: SEQUENCE; Schema: app; Owner: postgres
--

CREATE SEQUENCE app.member_number_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE app.member_number_seq OWNER TO postgres;

--
-- Name: member_number_seq; Type: SEQUENCE OWNED BY; Schema: app; Owner: postgres
--

ALTER SEQUENCE app.member_number_seq OWNED BY app.members.member_number;


--
-- Name: membership_plans; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.membership_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    plan_code character varying(32) NOT NULL,
    plan_name character varying(150) NOT NULL,
    description text,
    terms_and_conditions text,
    duration_value integer NOT NULL,
    duration_unit character varying(10) NOT NULL,
    status character varying(20) DEFAULT 'draft'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_membership_plans_code CHECK ((((plan_code)::text = btrim((plan_code)::text)) AND (length((plan_code)::text) > 0))),
    CONSTRAINT chk_membership_plans_duration_unit CHECK (((duration_unit)::text = ANY ((ARRAY['days'::character varying, 'weeks'::character varying, 'months'::character varying, 'years'::character varying])::text[]))),
    CONSTRAINT chk_membership_plans_duration_value CHECK ((duration_value > 0)),
    CONSTRAINT chk_membership_plans_name CHECK (((length(btrim((plan_name)::text)) >= 2) AND (length(btrim((plan_name)::text)) <= 150))),
    CONSTRAINT chk_membership_plans_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'active'::character varying, 'inactive'::character varying])::text[])))
);

ALTER TABLE ONLY app.membership_plans FORCE ROW LEVEL SECURITY;


ALTER TABLE app.membership_plans OWNER TO postgres;

--
-- Name: payment_charges; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.payment_charges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    request_id uuid NOT NULL,
    source_kind character varying(24) NOT NULL,
    branch_id uuid,
    sale_id uuid,
    subscription_id uuid,
    renewal_id uuid,
    amount_due numeric(26,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    source_snapshot jsonb NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT payment_charges_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT payment_charges_amount_due_check CHECK (((amount_due >= (0)::numeric) AND (amount_due < '1000000000000000000000000'::numeric))),
    CONSTRAINT payment_charges_check CHECK (((((source_kind)::text = 'pos_sale'::text) AND (sale_id IS NOT NULL) AND (branch_id IS NOT NULL) AND (subscription_id IS NULL) AND (renewal_id IS NULL)) OR (((source_kind)::text = 'membership_activation'::text) AND (sale_id IS NULL) AND (subscription_id IS NOT NULL) AND (renewal_id IS NULL)) OR (((source_kind)::text = 'membership_renewal'::text) AND (sale_id IS NULL) AND (subscription_id IS NOT NULL) AND (renewal_id IS NOT NULL)))),
    CONSTRAINT payment_charges_created_at_check CHECK (isfinite(created_at)),
    CONSTRAINT payment_charges_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT payment_charges_source_snapshot_check CHECK (((jsonb_typeof(source_snapshot) = 'object'::text) AND (source_snapshot <> '{}'::jsonb)))
);

ALTER TABLE ONLY app.payment_charges FORCE ROW LEVEL SECURITY;


ALTER TABLE app.payment_charges OWNER TO postgres;

--
-- Name: payment_receipts; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.payment_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    charge_id uuid NOT NULL,
    collection_branch_id uuid NOT NULL,
    request_id uuid NOT NULL,
    amount numeric(26,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    method_code character varying(24) NOT NULL,
    external_reference character varying(150),
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    recorded_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT payment_receipts_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT payment_receipts_amount_check CHECK (((amount > (0)::numeric) AND (amount < '1000000000000000000000000'::numeric))),
    CONSTRAINT payment_receipts_check CHECK ((((method_code)::text = 'cash'::text) OR (external_reference IS NOT NULL))),
    CONSTRAINT payment_receipts_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT payment_receipts_external_reference_check CHECK (((external_reference IS NULL) OR (((external_reference)::text = btrim((external_reference)::text)) AND (length((external_reference)::text) > 0) AND ((external_reference)::text ~ '[^[:space:]]'::text)))),
    CONSTRAINT payment_receipts_method_code_check CHECK (((method_code)::text = ANY ((ARRAY['cash'::character varying, 'bank_transfer'::character varying, 'mobile_wallet'::character varying, 'card'::character varying])::text[]))),
    CONSTRAINT payment_receipts_recorded_at_check CHECK (isfinite(recorded_at))
);

ALTER TABLE ONLY app.payment_receipts FORCE ROW LEVEL SECURITY;


ALTER TABLE app.payment_receipts OWNER TO postgres;

--
-- Name: payment_reconciliations; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.payment_reconciliations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    reconciliation_date date NOT NULL,
    request_id uuid NOT NULL,
    declared_totals jsonb NOT NULL,
    expected_totals jsonb NOT NULL,
    difference_totals jsonb NOT NULL,
    declared_net_amount numeric(47,2) NOT NULL,
    expected_net_amount numeric(47,2) NOT NULL,
    difference_amount numeric(48,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    status character varying(16) NOT NULL,
    note character varying(500) NOT NULL,
    collection_snapshot jsonb NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    reconciled_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT payment_reconciliations_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT payment_reconciliations_check CHECK (((jsonb_typeof(collection_snapshot) = 'object'::text) AND (collection_snapshot ?& ARRAY['tenantId'::text, 'collectionBranchId'::text, 'date'::text, 'netAmount'::text, 'includesTenantMemberships'::text, 'byMethod'::text]) AND ((collection_snapshot ->> 'tenantId'::text) IS NOT NULL) AND ((collection_snapshot ->> 'collectionBranchId'::text) IS NOT NULL) AND ((collection_snapshot ->> 'date'::text) IS NOT NULL) AND ((collection_snapshot ->> 'netAmount'::text) IS NOT NULL) AND ((collection_snapshot ->> 'includesTenantMemberships'::text) = 'true'::text) AND ((collection_snapshot ->> 'tenantId'::text) = (tenant_id)::text) AND ((collection_snapshot ->> 'collectionBranchId'::text) = (branch_id)::text) AND ((collection_snapshot ->> 'date'::text) = to_char((reconciliation_date)::timestamp with time zone, 'YYYY-MM-DD'::text)) AND (jsonb_typeof((collection_snapshot -> 'byMethod'::text)) = 'array'::text) AND (jsonb_array_length((collection_snapshot -> 'byMethod'::text)) = 4))),
    CONSTRAINT payment_reconciliations_check1 CHECK ((reconciliation_date < ((reconciled_at AT TIME ZONE 'Asia/Yangon'::text))::date)),
    CONSTRAINT payment_reconciliations_check2 CHECK (((declared_net_amount = (((((declared_totals ->> 'cash'::text))::numeric + ((declared_totals ->> 'bank_transfer'::text))::numeric) + ((declared_totals ->> 'mobile_wallet'::text))::numeric) + ((declared_totals ->> 'card'::text))::numeric)) AND (expected_net_amount = (((((expected_totals ->> 'cash'::text))::numeric + ((expected_totals ->> 'bank_transfer'::text))::numeric) + ((expected_totals ->> 'mobile_wallet'::text))::numeric) + ((expected_totals ->> 'card'::text))::numeric)) AND (difference_amount = (declared_net_amount - expected_net_amount)) AND (expected_net_amount = ((collection_snapshot ->> 'netAmount'::text))::numeric))),
    CONSTRAINT payment_reconciliations_check3 CHECK (((((difference_totals ->> 'cash'::text))::numeric = (((declared_totals ->> 'cash'::text))::numeric - ((expected_totals ->> 'cash'::text))::numeric)) AND (((difference_totals ->> 'bank_transfer'::text))::numeric = (((declared_totals ->> 'bank_transfer'::text))::numeric - ((expected_totals ->> 'bank_transfer'::text))::numeric)) AND (((difference_totals ->> 'mobile_wallet'::text))::numeric = (((declared_totals ->> 'mobile_wallet'::text))::numeric - ((expected_totals ->> 'mobile_wallet'::text))::numeric)) AND (((difference_totals ->> 'card'::text))::numeric = (((declared_totals ->> 'card'::text))::numeric - ((expected_totals ->> 'card'::text))::numeric)))),
    CONSTRAINT payment_reconciliations_check4 CHECK ((((status)::text = 'matched'::text) = ((((difference_totals ->> 'cash'::text))::numeric = (0)::numeric) AND (((difference_totals ->> 'bank_transfer'::text))::numeric = (0)::numeric) AND (((difference_totals ->> 'mobile_wallet'::text))::numeric = (0)::numeric) AND (((difference_totals ->> 'card'::text))::numeric = (0)::numeric)))),
    CONSTRAINT payment_reconciliations_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT payment_reconciliations_declared_totals_check CHECK (((jsonb_typeof(declared_totals) = 'object'::text) AND (declared_totals ?& ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) AND ((declared_totals - ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) = '{}'::jsonb) AND (jsonb_typeof((declared_totals -> 'cash'::text)) = 'string'::text) AND ((declared_totals ->> 'cash'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((declared_totals -> 'bank_transfer'::text)) = 'string'::text) AND ((declared_totals ->> 'bank_transfer'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((declared_totals -> 'mobile_wallet'::text)) = 'string'::text) AND ((declared_totals ->> 'mobile_wallet'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((declared_totals -> 'card'::text)) = 'string'::text) AND ((declared_totals ->> 'card'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text))),
    CONSTRAINT payment_reconciliations_difference_totals_check CHECK (((jsonb_typeof(difference_totals) = 'object'::text) AND (difference_totals ?& ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) AND ((difference_totals - ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) = '{}'::jsonb) AND (jsonb_typeof((difference_totals -> 'cash'::text)) = 'string'::text) AND ((difference_totals ->> 'cash'::text) ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$'::text) AND (jsonb_typeof((difference_totals -> 'bank_transfer'::text)) = 'string'::text) AND ((difference_totals ->> 'bank_transfer'::text) ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$'::text) AND (jsonb_typeof((difference_totals -> 'mobile_wallet'::text)) = 'string'::text) AND ((difference_totals ->> 'mobile_wallet'::text) ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$'::text) AND (jsonb_typeof((difference_totals -> 'card'::text)) = 'string'::text) AND ((difference_totals ->> 'card'::text) ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$'::text))),
    CONSTRAINT payment_reconciliations_expected_totals_check CHECK (((jsonb_typeof(expected_totals) = 'object'::text) AND (expected_totals ?& ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) AND ((expected_totals - ARRAY['cash'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'card'::text]) = '{}'::jsonb) AND (jsonb_typeof((expected_totals -> 'cash'::text)) = 'string'::text) AND ((expected_totals ->> 'cash'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((expected_totals -> 'bank_transfer'::text)) = 'string'::text) AND ((expected_totals ->> 'bank_transfer'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((expected_totals -> 'mobile_wallet'::text)) = 'string'::text) AND ((expected_totals ->> 'mobile_wallet'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text) AND (jsonb_typeof((expected_totals -> 'card'::text)) = 'string'::text) AND ((expected_totals ->> 'card'::text) ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'::text))),
    CONSTRAINT payment_reconciliations_note_check CHECK ((((note)::text = btrim((note)::text)) AND ((length((note)::text) >= 2) AND (length((note)::text) <= 500)) AND ((note)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT payment_reconciliations_reconciled_at_check CHECK (isfinite(reconciled_at)),
    CONSTRAINT payment_reconciliations_reconciliation_date_check CHECK (isfinite(reconciliation_date)),
    CONSTRAINT payment_reconciliations_status_check CHECK (((status)::text = ANY ((ARRAY['matched'::character varying, 'variance'::character varying])::text[])))
);

ALTER TABLE ONLY app.payment_reconciliations FORCE ROW LEVEL SECURITY;


ALTER TABLE app.payment_reconciliations OWNER TO postgres;

--
-- Name: payment_reversals; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.payment_reversals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    receipt_id uuid NOT NULL,
    request_id uuid NOT NULL,
    reversal_kind character varying(16) NOT NULL,
    amount numeric(26,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    reason character varying(500) NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    recorded_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT payment_reversals_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT payment_reversals_amount_check CHECK (((amount > (0)::numeric) AND (amount < '1000000000000000000000000'::numeric))),
    CONSTRAINT payment_reversals_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT payment_reversals_reason_check CHECK ((((reason)::text = btrim((reason)::text)) AND ((length((reason)::text) >= 2) AND (length((reason)::text) <= 500)) AND ((reason)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT payment_reversals_recorded_at_check CHECK (isfinite(recorded_at)),
    CONSTRAINT payment_reversals_reversal_kind_check CHECK (((reversal_kind)::text = ANY ((ARRAY['refund'::character varying, 'void'::character varying])::text[])))
);

ALTER TABLE ONLY app.payment_reversals FORCE ROW LEVEL SECURITY;


ALTER TABLE app.payment_reversals OWNER TO postgres;

--
-- Name: permissions; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    permission_code character varying(150) GENERATED ALWAYS AS ((((((module_code)::text || '.'::text) || (resource_code)::text) || '.'::text) || (action_code)::text)) STORED,
    module_code character varying(50) NOT NULL,
    resource_code character varying(50) NOT NULL,
    action_code character varying(50) NOT NULL,
    description text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_permissions_action CHECK (((action_code)::text ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT chk_permissions_module CHECK (((module_code)::text ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT chk_permissions_resource CHECK (((resource_code)::text ~ '^[a-z][a-z0-9_]*$'::text))
);


ALTER TABLE app.permissions OWNER TO postgres;

--
-- Name: plan_prices; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.plan_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    branch_id uuid,
    price_amount numeric(14,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    status character varying(20) DEFAULT 'inactive'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_plan_prices_amount CHECK ((price_amount >= (0)::numeric)),
    CONSTRAINT chk_plan_prices_currency CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT chk_plan_prices_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::text[])))
);

ALTER TABLE ONLY app.plan_prices FORCE ROW LEVEL SECURITY;


ALTER TABLE app.plan_prices OWNER TO postgres;

--
-- Name: pos_sale_items; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.pos_sale_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    product_id uuid NOT NULL,
    sku character varying(32) NOT NULL,
    product_name character varying(150) NOT NULL,
    unit_code character varying(16) NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    line_total numeric(24,2) NOT NULL,
    CONSTRAINT pos_sale_items_check CHECK (((line_total = ((quantity)::numeric * unit_price)) AND (line_total <> 'NaN'::numeric))),
    CONSTRAINT pos_sale_items_product_name_check CHECK ((((product_name)::text = btrim((product_name)::text)) AND ((length((product_name)::text) >= 2) AND (length((product_name)::text) <= 150)) AND ((product_name)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT pos_sale_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT pos_sale_items_sku_check CHECK (((sku)::text ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'::text)),
    CONSTRAINT pos_sale_items_unit_price_check CHECK (((unit_price >= (0)::numeric) AND (unit_price <> 'NaN'::numeric)))
);

ALTER TABLE ONLY app.pos_sale_items FORCE ROW LEVEL SECURITY;


ALTER TABLE app.pos_sale_items OWNER TO postgres;

--
-- Name: pos_sale_return_items; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.pos_sale_return_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    return_id uuid NOT NULL,
    sale_item_id uuid NOT NULL,
    product_id uuid NOT NULL,
    sku character varying(32) NOT NULL,
    product_name character varying(150) NOT NULL,
    unit_code character varying(16) NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(14,2) NOT NULL,
    line_total numeric(24,2) NOT NULL,
    CONSTRAINT pos_sale_return_items_check CHECK (((line_total = ((quantity)::numeric * unit_price)) AND (line_total <> 'NaN'::numeric))),
    CONSTRAINT pos_sale_return_items_product_name_check CHECK ((((product_name)::text = btrim((product_name)::text)) AND ((length((product_name)::text) >= 2) AND (length((product_name)::text) <= 150)) AND ((product_name)::text ~ '[^[:space:]]'::text))),
    CONSTRAINT pos_sale_return_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT pos_sale_return_items_sku_check CHECK (((sku)::text ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'::text)),
    CONSTRAINT pos_sale_return_items_unit_price_check CHECK (((unit_price >= (0)::numeric) AND (unit_price <> 'NaN'::numeric)))
);

ALTER TABLE ONLY app.pos_sale_return_items FORCE ROW LEVEL SECURITY;


ALTER TABLE app.pos_sale_return_items OWNER TO postgres;

--
-- Name: pos_sale_returns; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.pos_sale_returns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    sale_id uuid NOT NULL,
    request_id uuid NOT NULL,
    action_code character varying(10) NOT NULL,
    reason text NOT NULL,
    input_items jsonb NOT NULL,
    total_amount numeric(26,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT pos_sale_returns_action_code_check CHECK (((action_code)::text = ANY ((ARRAY['refund'::character varying, 'void'::character varying])::text[]))),
    CONSTRAINT pos_sale_returns_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT pos_sale_returns_created_at_check CHECK (isfinite(created_at)),
    CONSTRAINT pos_sale_returns_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT pos_sale_returns_input_items_check CHECK (((jsonb_typeof(input_items) = 'array'::text) AND ((jsonb_array_length(input_items) >= 1) AND (jsonb_array_length(input_items) <= 50)))),
    CONSTRAINT pos_sale_returns_reason_check CHECK (((reason = btrim(reason)) AND ((length(reason) >= 2) AND (length(reason) <= 500)) AND (reason ~ '[^[:space:]]'::text))),
    CONSTRAINT pos_sale_returns_total_amount_check CHECK (((total_amount >= (0)::numeric) AND (total_amount <> 'NaN'::numeric)))
);

ALTER TABLE ONLY app.pos_sale_returns FORCE ROW LEVEL SECURITY;


ALTER TABLE app.pos_sale_returns OWNER TO postgres;

--
-- Name: pos_sales; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.pos_sales (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    branch_id uuid NOT NULL,
    request_id uuid NOT NULL,
    input_cart jsonb NOT NULL,
    status character varying(20) DEFAULT 'completed'::character varying NOT NULL,
    total_amount numeric(26,2) NOT NULL,
    currency_code character varying(3) DEFAULT 'MMK'::character varying NOT NULL,
    actor_membership_id uuid NOT NULL,
    actor_snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT pos_sales_actor_snapshot_check CHECK (((jsonb_typeof(actor_snapshot) = 'object'::text) AND (actor_snapshot <> '{}'::jsonb))),
    CONSTRAINT pos_sales_created_at_check CHECK (isfinite(created_at)),
    CONSTRAINT pos_sales_currency_code_check CHECK (((currency_code)::text = 'MMK'::text)),
    CONSTRAINT pos_sales_input_cart_check CHECK (((jsonb_typeof(input_cart) = 'array'::text) AND ((jsonb_array_length(input_cart) >= 1) AND (jsonb_array_length(input_cart) <= 50)))),
    CONSTRAINT pos_sales_status_check CHECK (((status)::text = 'completed'::text)),
    CONSTRAINT pos_sales_total_amount_check CHECK (((total_amount >= (0)::numeric) AND (total_amount <> 'NaN'::numeric)))
);

ALTER TABLE ONLY app.pos_sales FORCE ROW LEVEL SECURITY;


ALTER TABLE app.pos_sales OWNER TO postgres;

--
-- Name: role_assignments; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.role_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    role_id uuid NOT NULL,
    scope_type character varying(20) NOT NULL,
    branch_id uuid,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_assignment_scope CHECK (((((scope_type)::text = 'tenant'::text) AND (branch_id IS NULL)) OR (((scope_type)::text = 'branch'::text) AND (branch_id IS NOT NULL))))
);


ALTER TABLE app.role_assignments OWNER TO postgres;

--
-- Name: role_permissions; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.role_permissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE app.role_permissions OWNER TO postgres;

--
-- Name: roles; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    role_code character varying(50) NOT NULL,
    role_name character varying(100) NOT NULL,
    description text,
    is_system_role boolean DEFAULT false NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_role_code_format CHECK (((role_code)::text ~ '^[A-Z][A-Z0-9_]*$'::text)),
    CONSTRAINT chk_role_code_not_blank CHECK ((length(TRIM(BOTH FROM role_code)) > 0)),
    CONSTRAINT chk_role_name_not_blank CHECK ((length(TRIM(BOTH FROM role_name)) > 0)),
    CONSTRAINT roles_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::text[])))
);


ALTER TABLE app.roles OWNER TO postgres;

--
-- Name: tenant_memberships; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.tenant_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status character varying(20) DEFAULT 'invited'::character varying NOT NULL,
    joined_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT tenant_memberships_status_check CHECK (((status)::text = ANY ((ARRAY['invited'::character varying, 'active'::character varying, 'suspended'::character varying, 'revoked'::character varying])::text[])))
);


ALTER TABLE app.tenant_memberships OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: app; Owner: postgres
--

CREATE TABLE app.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(255) NOT NULL,
    password_hash text,
    full_name character varying(200) NOT NULL,
    phone character varying(30),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    email_verified_at timestamp with time zone,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_user_email_format CHECK ((((email)::text ~~ '%_@_%._%'::text) AND ((email)::text !~~ '% %'::text))),
    CONSTRAINT chk_user_email_not_blank CHECK ((length(TRIM(BOTH FROM email)) > 0)),
    CONSTRAINT chk_user_full_name_not_blank CHECK ((length(TRIM(BOTH FROM full_name)) > 0)),
    CONSTRAINT users_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'suspended'::character varying, 'disabled'::character varying])::text[])))
);


ALTER TABLE app.users OWNER TO postgres;

--
-- Name: tenants; Type: TABLE; Schema: platform; Owner: postgres
--

CREATE TABLE platform.tenants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_code character varying(30) NOT NULL,
    tenant_name character varying(200) NOT NULL,
    tenant_type character varying(20) DEFAULT 'independent'::character varying NOT NULL,
    contact_email character varying(255),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT tenant_code_not_blank CHECK ((length(TRIM(BOTH FROM tenant_code)) > 0)),
    CONSTRAINT tenant_name_not_blank CHECK ((length(TRIM(BOTH FROM tenant_name)) > 0)),
    CONSTRAINT tenants_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'suspended'::character varying, 'terminated'::character varying])::text[]))),
    CONSTRAINT tenants_tenant_type_check CHECK (((tenant_type)::text = ANY ((ARRAY['independent'::character varying, 'multi_branch'::character varying])::text[])))
);


ALTER TABLE platform.tenants OWNER TO postgres;

--
-- Name: tenant_sessions; Type: TABLE; Schema: security; Owner: postgres
--

CREATE TABLE security.tenant_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    membership_id uuid NOT NULL,
    session_token_hash bytea NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT chk_session_expiry CHECK ((expires_at > created_at)),
    CONSTRAINT chk_session_token_hash CHECK ((octet_length(session_token_hash) = 32))
);


ALTER TABLE security.tenant_sessions OWNER TO postgres;

--
-- Name: members member_number; Type: DEFAULT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members ALTER COLUMN member_number SET DEFAULT ('GP-'::text || lpad((nextval('app.member_number_seq'::regclass))::text, 10, '0'::text));


--
-- Name: attendance_checkouts attendance_checkouts_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_pkey PRIMARY KEY (id);


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_visit_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_visit_id_key UNIQUE (tenant_id, visit_id);


--
-- Name: attendance_visits attendance_visits_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_pkey PRIMARY KEY (id);


--
-- Name: attendance_visits attendance_visits_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: attendance_visits attendance_visits_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: card_scan_receipts card_scan_receipts_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_pkey PRIMARY KEY (id);


--
-- Name: card_scan_receipts card_scan_receipts_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: card_scan_receipts card_scan_receipts_tenant_id_visit_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_tenant_id_visit_id_key UNIQUE (tenant_id, visit_id);


--
-- Name: inventory_product_events inventory_product_events_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_product_events
    ADD CONSTRAINT inventory_product_events_pkey PRIMARY KEY (id);


--
-- Name: inventory_product_events inventory_product_events_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_product_events
    ADD CONSTRAINT inventory_product_events_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: inventory_products inventory_products_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_products
    ADD CONSTRAINT inventory_products_pkey PRIMARY KEY (id);


--
-- Name: inventory_stock_movements inventory_stock_movements_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT inventory_stock_movements_pkey PRIMARY KEY (id);


--
-- Name: member_blacklist_events member_blacklist_events_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_blacklist_events
    ADD CONSTRAINT member_blacklist_events_pkey PRIMARY KEY (id);


--
-- Name: member_card_events member_card_events_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_pkey PRIMARY KEY (id);


--
-- Name: member_card_events member_card_events_tenant_id_card_id_event_type_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_tenant_id_card_id_event_type_key UNIQUE (tenant_id, card_id, event_type);


--
-- Name: member_card_events member_card_events_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: member_card_events member_card_events_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: member_cards member_cards_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_pkey PRIMARY KEY (id);


--
-- Name: member_cards member_cards_tenant_id_branch_id_member_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_tenant_id_branch_id_member_id_id_key UNIQUE (tenant_id, branch_id, member_id, id);


--
-- Name: member_cards member_cards_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: member_subscriptions member_subscriptions_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT member_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: members members_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members
    ADD CONSTRAINT members_pkey PRIMARY KEY (id);


--
-- Name: membership_discounts membership_discounts_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT membership_discounts_pkey PRIMARY KEY (id);


--
-- Name: membership_plans membership_plans_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_plans
    ADD CONSTRAINT membership_plans_pkey PRIMARY KEY (id);


--
-- Name: membership_promotions membership_promotions_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT membership_promotions_pkey PRIMARY KEY (id);


--
-- Name: payment_charges payment_charges_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_pkey PRIMARY KEY (id);


--
-- Name: payment_charges payment_charges_tenant_id_id_currency_code_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_id_currency_code_key UNIQUE (tenant_id, id, currency_code);


--
-- Name: payment_charges payment_charges_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: payment_charges payment_charges_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: payment_receipts payment_receipts_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_pkey PRIMARY KEY (id);


--
-- Name: payment_receipts payment_receipts_tenant_id_id_currency_code_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_id_currency_code_key UNIQUE (tenant_id, id, currency_code);


--
-- Name: payment_receipts payment_receipts_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: payment_receipts payment_receipts_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: payment_reconciliations payment_reconciliations_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_pkey PRIMARY KEY (id);


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_branch_id_reconciliation__key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_branch_id_reconciliation__key UNIQUE (tenant_id, branch_id, reconciliation_date);


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: payment_reversals payment_reversals_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reversals
    ADD CONSTRAINT payment_reversals_pkey PRIMARY KEY (id);


--
-- Name: payment_reversals payment_reversals_tenant_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reversals
    ADD CONSTRAINT payment_reversals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: payment_reversals payment_reversals_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reversals
    ADD CONSTRAINT payment_reversals_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: plan_prices plan_prices_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.plan_prices
    ADD CONSTRAINT plan_prices_pkey PRIMARY KEY (id);


--
-- Name: pos_sale_items pos_sale_items_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_items
    ADD CONSTRAINT pos_sale_items_pkey PRIMARY KEY (id);


--
-- Name: pos_sale_items pos_sale_items_tenant_id_branch_id_sale_id_id_product_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_items
    ADD CONSTRAINT pos_sale_items_tenant_id_branch_id_sale_id_id_product_id_key UNIQUE (tenant_id, branch_id, sale_id, id, product_id);


--
-- Name: pos_sale_items pos_sale_items_tenant_id_sale_id_product_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_items
    ADD CONSTRAINT pos_sale_items_tenant_id_sale_id_product_id_key UNIQUE (tenant_id, sale_id, product_id);


--
-- Name: pos_sale_return_items pos_sale_return_items_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_return_items
    ADD CONSTRAINT pos_sale_return_items_pkey PRIMARY KEY (id);


--
-- Name: pos_sale_return_items pos_sale_return_items_tenant_id_branch_id_sale_id_return_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_return_items
    ADD CONSTRAINT pos_sale_return_items_tenant_id_branch_id_sale_id_return_id_key UNIQUE (tenant_id, branch_id, sale_id, return_id, id, sale_item_id, product_id);


--
-- Name: pos_sale_return_items pos_sale_return_items_tenant_id_return_id_sale_item_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_return_items
    ADD CONSTRAINT pos_sale_return_items_tenant_id_return_id_sale_item_id_key UNIQUE (tenant_id, return_id, sale_item_id);


--
-- Name: pos_sale_returns pos_sale_returns_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_returns
    ADD CONSTRAINT pos_sale_returns_pkey PRIMARY KEY (id);


--
-- Name: pos_sale_returns pos_sale_returns_tenant_id_branch_id_sale_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_returns
    ADD CONSTRAINT pos_sale_returns_tenant_id_branch_id_sale_id_id_key UNIQUE (tenant_id, branch_id, sale_id, id);


--
-- Name: pos_sale_returns pos_sale_returns_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_returns
    ADD CONSTRAINT pos_sale_returns_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: pos_sales pos_sales_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_pkey PRIMARY KEY (id);


--
-- Name: pos_sales pos_sales_tenant_id_branch_id_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_tenant_id_branch_id_id_key UNIQUE (tenant_id, branch_id, id);


--
-- Name: pos_sales pos_sales_tenant_id_request_id_key; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_tenant_id_request_id_key UNIQUE (tenant_id, request_id);


--
-- Name: role_assignments role_assignments_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_assignments
    ADD CONSTRAINT role_assignments_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: subscription_expirations subscription_expirations_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_expirations
    ADD CONSTRAINT subscription_expirations_pkey PRIMARY KEY (id);


--
-- Name: subscription_foc_grants subscription_foc_grants_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT subscription_foc_grants_pkey PRIMARY KEY (id);


--
-- Name: subscription_renewals subscription_renewals_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT subscription_renewals_pkey PRIMARY KEY (id);


--
-- Name: subscription_suspensions subscription_suspensions_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_suspensions
    ADD CONSTRAINT subscription_suspensions_pkey PRIMARY KEY (id);


--
-- Name: tenant_memberships tenant_memberships_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.tenant_memberships
    ADD CONSTRAINT tenant_memberships_pkey PRIMARY KEY (id);


--
-- Name: branches uq_branches_tenant_code; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.branches
    ADD CONSTRAINT uq_branches_tenant_code UNIQUE (tenant_id, branch_code);


--
-- Name: branches uq_branches_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.branches
    ADD CONSTRAINT uq_branches_tenant_id UNIQUE (tenant_id, id);


--
-- Name: inventory_products uq_inventory_products_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_products
    ADD CONSTRAINT uq_inventory_products_tenant_id UNIQUE (tenant_id, id);


--
-- Name: inventory_products uq_inventory_products_tenant_sku; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_products
    ADD CONSTRAINT uq_inventory_products_tenant_sku UNIQUE (tenant_id, sku);


--
-- Name: inventory_stock_movements uq_inventory_stock_movements_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT uq_inventory_stock_movements_request UNIQUE (tenant_id, request_id);


--
-- Name: inventory_stock_movements uq_inventory_stock_movements_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT uq_inventory_stock_movements_tenant_id UNIQUE (tenant_id, id);


--
-- Name: member_blacklist_events uq_member_blacklist_events_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_blacklist_events
    ADD CONSTRAINT uq_member_blacklist_events_request UNIQUE (tenant_id, request_id);


--
-- Name: member_blacklist_events uq_member_blacklist_events_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_blacklist_events
    ADD CONSTRAINT uq_member_blacklist_events_tenant_id UNIQUE (tenant_id, id);


--
-- Name: member_subscriptions uq_member_subscriptions_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT uq_member_subscriptions_tenant_id UNIQUE (tenant_id, id);


--
-- Name: members uq_members_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members
    ADD CONSTRAINT uq_members_tenant_id UNIQUE (tenant_id, id);


--
-- Name: members uq_members_tenant_number; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members
    ADD CONSTRAINT uq_members_tenant_number UNIQUE (tenant_id, member_number);


--
-- Name: membership_discounts uq_membership_discounts_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT uq_membership_discounts_tenant_id UNIQUE (tenant_id, id);


--
-- Name: membership_discounts uq_membership_discounts_tenant_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT uq_membership_discounts_tenant_request UNIQUE (tenant_id, request_id);


--
-- Name: membership_plans uq_membership_plans_tenant_code; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_plans
    ADD CONSTRAINT uq_membership_plans_tenant_code UNIQUE (tenant_id, plan_code);


--
-- Name: membership_plans uq_membership_plans_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_plans
    ADD CONSTRAINT uq_membership_plans_tenant_id UNIQUE (tenant_id, id);


--
-- Name: membership_promotions uq_membership_promotions_tenant_code; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT uq_membership_promotions_tenant_code UNIQUE (tenant_id, promotion_code);


--
-- Name: membership_promotions uq_membership_promotions_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT uq_membership_promotions_tenant_id UNIQUE (tenant_id, id);


--
-- Name: tenant_memberships uq_membership_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.tenant_memberships
    ADD CONSTRAINT uq_membership_tenant_id UNIQUE (tenant_id, id);


--
-- Name: tenant_memberships uq_membership_tenant_user; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.tenant_memberships
    ADD CONSTRAINT uq_membership_tenant_user UNIQUE (tenant_id, user_id);


--
-- Name: permissions uq_permissions_code; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.permissions
    ADD CONSTRAINT uq_permissions_code UNIQUE (permission_code);


--
-- Name: plan_prices uq_plan_prices_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.plan_prices
    ADD CONSTRAINT uq_plan_prices_tenant_id UNIQUE (tenant_id, id);


--
-- Name: plan_prices uq_plan_prices_tenant_plan_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.plan_prices
    ADD CONSTRAINT uq_plan_prices_tenant_plan_id UNIQUE (tenant_id, plan_id, id);


--
-- Name: role_assignments uq_role_assignment; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_assignments
    ADD CONSTRAINT uq_role_assignment UNIQUE NULLS NOT DISTINCT (tenant_id, membership_id, role_id, scope_type, branch_id);


--
-- Name: role_permissions uq_role_permissions_assignment; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_permissions
    ADD CONSTRAINT uq_role_permissions_assignment UNIQUE (tenant_id, role_id, permission_id);


--
-- Name: roles uq_roles_tenant_code; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.roles
    ADD CONSTRAINT uq_roles_tenant_code UNIQUE (tenant_id, role_code);


--
-- Name: roles uq_roles_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.roles
    ADD CONSTRAINT uq_roles_tenant_id UNIQUE (tenant_id, id);


--
-- Name: subscription_expirations uq_subscription_expirations_period; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_expirations
    ADD CONSTRAINT uq_subscription_expirations_period UNIQUE (tenant_id, subscription_id, coverage_starts_on, coverage_ends_on);


--
-- Name: subscription_expirations uq_subscription_expirations_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_expirations
    ADD CONSTRAINT uq_subscription_expirations_tenant_id UNIQUE (tenant_id, id);


--
-- Name: subscription_foc_grants uq_subscription_foc_grants_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT uq_subscription_foc_grants_request UNIQUE (tenant_id, request_id);


--
-- Name: subscription_foc_grants uq_subscription_foc_grants_subscription; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT uq_subscription_foc_grants_subscription UNIQUE (tenant_id, subscription_id);


--
-- Name: subscription_foc_grants uq_subscription_foc_grants_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT uq_subscription_foc_grants_tenant_id UNIQUE (tenant_id, id);


--
-- Name: subscription_renewals uq_subscription_renewals_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT uq_subscription_renewals_request UNIQUE (tenant_id, request_id);


--
-- Name: subscription_renewals uq_subscription_renewals_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT uq_subscription_renewals_tenant_id UNIQUE (tenant_id, id);


--
-- Name: subscription_renewals uq_subscription_renewals_tenant_subscription_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT uq_subscription_renewals_tenant_subscription_id UNIQUE (tenant_id, subscription_id, id);


--
-- Name: subscription_suspensions uq_subscription_suspensions_request; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_suspensions
    ADD CONSTRAINT uq_subscription_suspensions_request UNIQUE (tenant_id, request_id);


--
-- Name: subscription_suspensions uq_subscription_suspensions_tenant_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_suspensions
    ADD CONSTRAINT uq_subscription_suspensions_tenant_id UNIQUE (tenant_id, id);


--
-- Name: member_subscriptions uq_subscriptions_tenant_member_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT uq_subscriptions_tenant_member_id UNIQUE (tenant_id, member_id, id);


--
-- Name: attendance_visits uq_visits_tenant_branch_member_id; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT uq_visits_tenant_branch_member_id UNIQUE (tenant_id, branch_id, member_id, id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: platform; Owner: postgres
--

ALTER TABLE ONLY platform.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_tenant_code_key; Type: CONSTRAINT; Schema: platform; Owner: postgres
--

ALTER TABLE ONLY platform.tenants
    ADD CONSTRAINT tenants_tenant_code_key UNIQUE (tenant_code);


--
-- Name: tenant_sessions tenant_sessions_pkey; Type: CONSTRAINT; Schema: security; Owner: postgres
--

ALTER TABLE ONLY security.tenant_sessions
    ADD CONSTRAINT tenant_sessions_pkey PRIMARY KEY (id);


--
-- Name: tenant_sessions tenant_sessions_session_token_hash_key; Type: CONSTRAINT; Schema: security; Owner: postgres
--

ALTER TABLE ONLY security.tenant_sessions
    ADD CONSTRAINT tenant_sessions_session_token_hash_key UNIQUE (session_token_hash);


--
-- Name: idx_assignments_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_assignments_branch ON app.role_assignments USING btree (tenant_id, branch_id) WHERE (branch_id IS NOT NULL);


--
-- Name: idx_assignments_membership; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_assignments_membership ON app.role_assignments USING btree (tenant_id, membership_id);


--
-- Name: idx_assignments_role; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_assignments_role ON app.role_assignments USING btree (tenant_id, role_id);


--
-- Name: idx_attendance_branch_date; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_attendance_branch_date ON app.attendance_visits USING btree (tenant_id, branch_id, business_date DESC);


--
-- Name: idx_attendance_branch_history_page; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_attendance_branch_history_page ON app.attendance_visits USING btree (tenant_id, branch_id, checked_in_at DESC, id DESC);


--
-- Name: idx_attendance_branch_open_page; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_attendance_branch_open_page ON app.attendance_visits USING btree (tenant_id, branch_id, checked_in_at DESC, id DESC) WHERE (checked_out_at IS NULL);


--
-- Name: idx_attendance_checkouts_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_attendance_checkouts_branch ON app.attendance_checkouts USING btree (tenant_id, branch_id, checked_out_at DESC);


--
-- Name: idx_branches_tenant_id; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_branches_tenant_id ON app.branches USING btree (tenant_id);


--
-- Name: idx_e5_payment_reversal_time; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_e5_payment_reversal_time ON app.payment_reversals USING btree (tenant_id, recorded_at, id);


--
-- Name: idx_inventory_movements_product_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_inventory_movements_product_branch ON app.inventory_stock_movements USING btree (tenant_id, branch_id, product_id, created_at, id);


--
-- Name: idx_inventory_product_events_product; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_inventory_product_events_product ON app.inventory_product_events USING btree (tenant_id, product_id, created_at, id);


--
-- Name: idx_inventory_products_tenant_status; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_inventory_products_tenant_status ON app.inventory_products USING btree (tenant_id, status, id);


--
-- Name: idx_member_blacklist_events_member; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_blacklist_events_member ON app.member_blacklist_events USING btree (tenant_id, member_id, recorded_at DESC);


--
-- Name: idx_member_card_events_card; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_card_events_card ON app.member_card_events USING btree (tenant_id, card_id, event_at);


--
-- Name: idx_member_cards_branch_member; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_cards_branch_member ON app.member_cards USING btree (tenant_id, branch_id, member_id);


--
-- Name: idx_member_subscriptions_expiry; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_subscriptions_expiry ON app.member_subscriptions USING btree (tenant_id, ends_on) WHERE ((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying])::text[]));


--
-- Name: idx_member_subscriptions_tenant_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_subscriptions_tenant_branch ON app.member_subscriptions USING btree (tenant_id, branch_id);


--
-- Name: idx_member_subscriptions_tenant_member; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_subscriptions_tenant_member ON app.member_subscriptions USING btree (tenant_id, member_id);


--
-- Name: idx_member_subscriptions_tenant_plan; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_subscriptions_tenant_plan ON app.member_subscriptions USING btree (tenant_id, plan_id);


--
-- Name: idx_member_subscriptions_tenant_price; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_member_subscriptions_tenant_price ON app.member_subscriptions USING btree (tenant_id, plan_id, plan_price_id);


--
-- Name: idx_members_tenant_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_members_tenant_branch ON app.members USING btree (tenant_id, branch_id);


--
-- Name: idx_members_tenant_created; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_members_tenant_created ON app.members USING btree (tenant_id, created_at DESC);


--
-- Name: idx_members_tenant_name; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_members_tenant_name ON app.members USING btree (tenant_id, full_name);


--
-- Name: idx_members_tenant_status; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_members_tenant_status ON app.members USING btree (tenant_id, status);


--
-- Name: idx_membership_discounts_tenant_promotion; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_discounts_tenant_promotion ON app.membership_discounts USING btree (tenant_id, promotion_id);


--
-- Name: idx_membership_discounts_tenant_subscription; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_discounts_tenant_subscription ON app.membership_discounts USING btree (tenant_id, subscription_id);


--
-- Name: idx_membership_plans_tenant_status; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_plans_tenant_status ON app.membership_plans USING btree (tenant_id, status);


--
-- Name: idx_membership_promotions_tenant_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_promotions_tenant_branch ON app.membership_promotions USING btree (tenant_id, branch_id);


--
-- Name: idx_membership_promotions_tenant_plan; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_promotions_tenant_plan ON app.membership_promotions USING btree (tenant_id, plan_id);


--
-- Name: idx_membership_promotions_tenant_status; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_membership_promotions_tenant_status ON app.membership_promotions USING btree (tenant_id, status);


--
-- Name: idx_memberships_user_id; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_memberships_user_id ON app.tenant_memberships USING btree (user_id);


--
-- Name: idx_payment_charge_branch_time; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_payment_charge_branch_time ON app.payment_charges USING btree (tenant_id, branch_id, created_at, id);


--
-- Name: idx_payment_receipt_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_payment_receipt_branch ON app.payment_receipts USING btree (tenant_id, collection_branch_id, recorded_at, id);


--
-- Name: idx_payment_receipt_charge; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_payment_receipt_charge ON app.payment_receipts USING btree (tenant_id, charge_id, recorded_at, id);


--
-- Name: idx_payment_reconciliations_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_payment_reconciliations_branch ON app.payment_reconciliations USING btree (tenant_id, branch_id, reconciliation_date, id);


--
-- Name: idx_payment_reversal_receipt; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_payment_reversal_receipt ON app.payment_reversals USING btree (tenant_id, receipt_id, recorded_at, id);


--
-- Name: idx_plan_prices_tenant_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_plan_prices_tenant_branch ON app.plan_prices USING btree (tenant_id, branch_id);


--
-- Name: idx_plan_prices_tenant_plan; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_plan_prices_tenant_plan ON app.plan_prices USING btree (tenant_id, plan_id);


--
-- Name: idx_pos_return_items_original; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_pos_return_items_original ON app.pos_sale_return_items USING btree (tenant_id, sale_id, sale_item_id);


--
-- Name: idx_pos_sale_returns_sale; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_pos_sale_returns_sale ON app.pos_sale_returns USING btree (tenant_id, sale_id, created_at, id);


--
-- Name: idx_pos_sales_branch_time; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_pos_sales_branch_time ON app.pos_sales USING btree (tenant_id, branch_id, created_at, id);


--
-- Name: idx_role_permissions_permission_id; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_role_permissions_permission_id ON app.role_permissions USING btree (permission_id);


--
-- Name: idx_roles_tenant_id; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_roles_tenant_id ON app.roles USING btree (tenant_id);


--
-- Name: idx_subscription_expirations_subscription; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_subscription_expirations_subscription ON app.subscription_expirations USING btree (tenant_id, subscription_id, expired_at DESC);


--
-- Name: idx_subscription_foc_grants_created; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_subscription_foc_grants_created ON app.subscription_foc_grants USING btree (tenant_id, granted_at DESC);


--
-- Name: idx_subscription_renewals_price; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_subscription_renewals_price ON app.subscription_renewals USING btree (tenant_id, plan_id, plan_price_id);


--
-- Name: idx_subscription_renewals_subscription; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_subscription_renewals_subscription ON app.subscription_renewals USING btree (tenant_id, subscription_id, created_at DESC);


--
-- Name: idx_subscription_suspensions_subscription; Type: INDEX; Schema: app; Owner: postgres
--

CREATE INDEX idx_subscription_suspensions_subscription ON app.subscription_suspensions USING btree (tenant_id, subscription_id, suspended_at DESC);


--
-- Name: uq_attendance_open_member; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_attendance_open_member ON app.attendance_visits USING btree (tenant_id, member_id) WHERE (checked_out_at IS NULL);


--
-- Name: uq_inventory_movement_return_item; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_inventory_movement_return_item ON app.inventory_stock_movements USING btree (tenant_id, return_item_id) WHERE (return_item_id IS NOT NULL);


--
-- Name: uq_inventory_movement_sale_item; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_inventory_movement_sale_item ON app.inventory_stock_movements USING btree (tenant_id, sale_item_id) WHERE ((movement_kind)::text = 'sale'::text);


--
-- Name: uq_member_cards_active; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_member_cards_active ON app.member_cards USING btree (tenant_id, member_id) WHERE ((status)::text = 'active'::text);


--
-- Name: uq_member_subscriptions_current_member; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_member_subscriptions_current_member ON app.member_subscriptions USING btree (tenant_id, member_id) WHERE ((status)::text = ANY ((ARRAY['active'::character varying, 'suspended'::character varying])::text[]));


--
-- Name: uq_membership_discounts_activation; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_membership_discounts_activation ON app.membership_discounts USING btree (tenant_id, subscription_id) WHERE ((purchase_kind)::text = 'activation'::text);


--
-- Name: uq_membership_discounts_renewal; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_membership_discounts_renewal ON app.membership_discounts USING btree (renewal_id) WHERE ((purchase_kind)::text = 'renewal'::text);


--
-- Name: uq_payment_charge_activation; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_payment_charge_activation ON app.payment_charges USING btree (tenant_id, subscription_id) WHERE ((source_kind)::text = 'membership_activation'::text);


--
-- Name: uq_payment_charge_renewal; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_payment_charge_renewal ON app.payment_charges USING btree (tenant_id, renewal_id) WHERE ((source_kind)::text = 'membership_renewal'::text);


--
-- Name: uq_payment_charge_sale; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_payment_charge_sale ON app.payment_charges USING btree (tenant_id, sale_id) WHERE ((source_kind)::text = 'pos_sale'::text);


--
-- Name: uq_plan_prices_active_branch; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_plan_prices_active_branch ON app.plan_prices USING btree (tenant_id, plan_id, branch_id) WHERE ((branch_id IS NOT NULL) AND ((status)::text = 'active'::text));


--
-- Name: uq_plan_prices_active_general; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_plan_prices_active_general ON app.plan_prices USING btree (tenant_id, plan_id) WHERE ((branch_id IS NULL) AND ((status)::text = 'active'::text));


--
-- Name: uq_pos_sale_single_void; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_pos_sale_single_void ON app.pos_sale_returns USING btree (tenant_id, sale_id) WHERE ((action_code)::text = 'void'::text);


--
-- Name: uq_users_email_lower; Type: INDEX; Schema: app; Owner: postgres
--

CREATE UNIQUE INDEX uq_users_email_lower ON app.users USING btree (lower((email)::text));


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_branch_id_member_id_visit_i_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_branch_id_member_id_visit_i_fkey FOREIGN KEY (tenant_id, branch_id, member_id, visit_id) REFERENCES app.attendance_visits(tenant_id, branch_id, member_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_checkouts attendance_checkouts_tenant_id_member_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_checkouts
    ADD CONSTRAINT attendance_checkouts_tenant_id_member_id_fkey FOREIGN KEY (tenant_id, member_id) REFERENCES app.members(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_visits attendance_visits_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_visits attendance_visits_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_visits attendance_visits_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: attendance_visits attendance_visits_tenant_id_member_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_member_id_fkey FOREIGN KEY (tenant_id, member_id) REFERENCES app.members(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_visits attendance_visits_tenant_id_member_id_subscription_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.attendance_visits
    ADD CONSTRAINT attendance_visits_tenant_id_member_id_subscription_id_fkey FOREIGN KEY (tenant_id, member_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, member_id, id) ON DELETE RESTRICT;


--
-- Name: card_scan_receipts card_scan_receipts_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: card_scan_receipts card_scan_receipts_tenant_id_branch_id_member_id_card_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_tenant_id_branch_id_member_id_card_id_fkey FOREIGN KEY (tenant_id, branch_id, member_id, card_id) REFERENCES app.member_cards(tenant_id, branch_id, member_id, id) ON DELETE RESTRICT;


--
-- Name: card_scan_receipts card_scan_receipts_tenant_id_branch_id_member_id_visit_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.card_scan_receipts
    ADD CONSTRAINT card_scan_receipts_tenant_id_branch_id_member_id_visit_id_fkey FOREIGN KEY (tenant_id, branch_id, member_id, visit_id) REFERENCES app.attendance_visits(tenant_id, branch_id, member_id, id) ON DELETE RESTRICT;


--
-- Name: role_assignments fk_assignment_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_assignments
    ADD CONSTRAINT fk_assignment_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: role_assignments fk_assignment_membership; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_assignments
    ADD CONSTRAINT fk_assignment_membership FOREIGN KEY (tenant_id, membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE CASCADE;


--
-- Name: role_assignments fk_assignment_role; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_assignments
    ADD CONSTRAINT fk_assignment_role FOREIGN KEY (tenant_id, role_id) REFERENCES app.roles(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: branches fk_branches_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.branches
    ADD CONSTRAINT fk_branches_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements fk_inventory_movement_actor; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT fk_inventory_movement_actor FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements fk_inventory_movement_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT fk_inventory_movement_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements fk_inventory_movement_product; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT fk_inventory_movement_product FOREIGN KEY (tenant_id, product_id) REFERENCES app.inventory_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements fk_inventory_movement_return_item; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT fk_inventory_movement_return_item FOREIGN KEY (tenant_id, branch_id, sale_id, return_id, return_item_id, sale_item_id, product_id) REFERENCES app.pos_sale_return_items(tenant_id, branch_id, sale_id, return_id, id, sale_item_id, product_id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements fk_inventory_movement_sale_item; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT fk_inventory_movement_sale_item FOREIGN KEY (tenant_id, branch_id, sale_id, sale_item_id, product_id) REFERENCES app.pos_sale_items(tenant_id, branch_id, sale_id, id, product_id) ON DELETE RESTRICT;


--
-- Name: member_blacklist_events fk_member_blacklist_events_member; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_blacklist_events
    ADD CONSTRAINT fk_member_blacklist_events_member FOREIGN KEY (tenant_id, member_id) REFERENCES app.members(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_blacklist_events fk_member_blacklist_events_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_blacklist_events
    ADD CONSTRAINT fk_member_blacklist_events_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: member_subscriptions fk_member_subscriptions_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT fk_member_subscriptions_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_subscriptions fk_member_subscriptions_member; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT fk_member_subscriptions_member FOREIGN KEY (tenant_id, member_id) REFERENCES app.members(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_subscriptions fk_member_subscriptions_plan; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT fk_member_subscriptions_plan FOREIGN KEY (tenant_id, plan_id) REFERENCES app.membership_plans(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_subscriptions fk_member_subscriptions_price; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT fk_member_subscriptions_price FOREIGN KEY (tenant_id, plan_id, plan_price_id) REFERENCES app.plan_prices(tenant_id, plan_id, id) ON DELETE RESTRICT;


--
-- Name: member_subscriptions fk_member_subscriptions_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_subscriptions
    ADD CONSTRAINT fk_member_subscriptions_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: members fk_members_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members
    ADD CONSTRAINT fk_members_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: members fk_members_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.members
    ADD CONSTRAINT fk_members_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: membership_discounts fk_membership_discounts_promotion; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT fk_membership_discounts_promotion FOREIGN KEY (tenant_id, promotion_id) REFERENCES app.membership_promotions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: membership_discounts fk_membership_discounts_renewal; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT fk_membership_discounts_renewal FOREIGN KEY (tenant_id, subscription_id, renewal_id) REFERENCES app.subscription_renewals(tenant_id, subscription_id, id) ON DELETE RESTRICT;


--
-- Name: membership_discounts fk_membership_discounts_subscription; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT fk_membership_discounts_subscription FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: membership_discounts fk_membership_discounts_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_discounts
    ADD CONSTRAINT fk_membership_discounts_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: membership_plans fk_membership_plans_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_plans
    ADD CONSTRAINT fk_membership_plans_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: membership_promotions fk_membership_promotions_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT fk_membership_promotions_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: membership_promotions fk_membership_promotions_plan; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT fk_membership_promotions_plan FOREIGN KEY (tenant_id, plan_id) REFERENCES app.membership_plans(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: membership_promotions fk_membership_promotions_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.membership_promotions
    ADD CONSTRAINT fk_membership_promotions_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: tenant_memberships fk_membership_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.tenant_memberships
    ADD CONSTRAINT fk_membership_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: tenant_memberships fk_membership_user; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.tenant_memberships
    ADD CONSTRAINT fk_membership_user FOREIGN KEY (user_id) REFERENCES app.users(id) ON DELETE RESTRICT;


--
-- Name: plan_prices fk_plan_prices_branch; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.plan_prices
    ADD CONSTRAINT fk_plan_prices_branch FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: plan_prices fk_plan_prices_plan; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.plan_prices
    ADD CONSTRAINT fk_plan_prices_plan FOREIGN KEY (tenant_id, plan_id) REFERENCES app.membership_plans(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: role_permissions fk_role_permissions_permission; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_permissions
    ADD CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES app.permissions(id) ON DELETE RESTRICT;


--
-- Name: role_permissions fk_role_permissions_role; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.role_permissions
    ADD CONSTRAINT fk_role_permissions_role FOREIGN KEY (tenant_id, role_id) REFERENCES app.roles(tenant_id, id) ON DELETE CASCADE;


--
-- Name: roles fk_roles_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.roles
    ADD CONSTRAINT fk_roles_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: subscription_expirations fk_subscription_expirations_subscription; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_expirations
    ADD CONSTRAINT fk_subscription_expirations_subscription FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_expirations fk_subscription_expirations_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_expirations
    ADD CONSTRAINT fk_subscription_expirations_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: subscription_foc_grants fk_subscription_foc_grants_subscription; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT fk_subscription_foc_grants_subscription FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_foc_grants fk_subscription_foc_grants_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_foc_grants
    ADD CONSTRAINT fk_subscription_foc_grants_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: subscription_renewals fk_subscription_renewals_plan; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT fk_subscription_renewals_plan FOREIGN KEY (tenant_id, plan_id) REFERENCES app.membership_plans(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_renewals fk_subscription_renewals_price; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT fk_subscription_renewals_price FOREIGN KEY (tenant_id, plan_id, plan_price_id) REFERENCES app.plan_prices(tenant_id, plan_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_renewals fk_subscription_renewals_subscription; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT fk_subscription_renewals_subscription FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_renewals fk_subscription_renewals_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_renewals
    ADD CONSTRAINT fk_subscription_renewals_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: subscription_suspensions fk_subscription_suspensions_subscription; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_suspensions
    ADD CONSTRAINT fk_subscription_suspensions_subscription FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: subscription_suspensions fk_subscription_suspensions_tenant; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.subscription_suspensions
    ADD CONSTRAINT fk_subscription_suspensions_tenant FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: inventory_product_events inventory_product_events_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_product_events
    ADD CONSTRAINT inventory_product_events_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: inventory_product_events inventory_product_events_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_product_events
    ADD CONSTRAINT inventory_product_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: inventory_product_events inventory_product_events_tenant_id_product_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_product_events
    ADD CONSTRAINT inventory_product_events_tenant_id_product_id_fkey FOREIGN KEY (tenant_id, product_id) REFERENCES app.inventory_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: inventory_products inventory_products_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_products
    ADD CONSTRAINT inventory_products_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: inventory_stock_movements inventory_stock_movements_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.inventory_stock_movements
    ADD CONSTRAINT inventory_stock_movements_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: member_card_events member_card_events_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_card_events member_card_events_tenant_id_branch_id_member_id_card_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_card_events
    ADD CONSTRAINT member_card_events_tenant_id_branch_id_member_id_card_id_fkey FOREIGN KEY (tenant_id, branch_id, member_id, card_id) REFERENCES app.member_cards(tenant_id, branch_id, member_id, id) ON DELETE RESTRICT;


--
-- Name: member_cards member_cards_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: member_cards member_cards_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: member_cards member_cards_tenant_id_member_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.member_cards
    ADD CONSTRAINT member_cards_tenant_id_member_id_fkey FOREIGN KEY (tenant_id, member_id) REFERENCES app.members(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_branch_id_sale_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_branch_id_sale_id_fkey FOREIGN KEY (tenant_id, branch_id, sale_id) REFERENCES app.pos_sales(tenant_id, branch_id, id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_subscription_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_subscription_id_fkey FOREIGN KEY (tenant_id, subscription_id) REFERENCES app.member_subscriptions(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_charges payment_charges_tenant_id_subscription_id_renewal_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_charges
    ADD CONSTRAINT payment_charges_tenant_id_subscription_id_renewal_id_fkey FOREIGN KEY (tenant_id, subscription_id, renewal_id) REFERENCES app.subscription_renewals(tenant_id, subscription_id, id) ON DELETE RESTRICT;


--
-- Name: payment_receipts payment_receipts_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_receipts payment_receipts_tenant_id_charge_id_currency_code_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_charge_id_currency_code_fkey FOREIGN KEY (tenant_id, charge_id, currency_code) REFERENCES app.payment_charges(tenant_id, id, currency_code) ON DELETE RESTRICT;


--
-- Name: payment_receipts payment_receipts_tenant_id_collection_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_receipts
    ADD CONSTRAINT payment_receipts_tenant_id_collection_branch_id_fkey FOREIGN KEY (tenant_id, collection_branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_reconciliations payment_reconciliations_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reconciliations
    ADD CONSTRAINT payment_reconciliations_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: payment_reversals payment_reversals_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reversals
    ADD CONSTRAINT payment_reversals_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: payment_reversals payment_reversals_tenant_id_receipt_id_currency_code_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.payment_reversals
    ADD CONSTRAINT payment_reversals_tenant_id_receipt_id_currency_code_fkey FOREIGN KEY (tenant_id, receipt_id, currency_code) REFERENCES app.payment_receipts(tenant_id, id, currency_code) ON DELETE RESTRICT;


--
-- Name: pos_sale_items pos_sale_items_tenant_id_branch_id_sale_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_items
    ADD CONSTRAINT pos_sale_items_tenant_id_branch_id_sale_id_fkey FOREIGN KEY (tenant_id, branch_id, sale_id) REFERENCES app.pos_sales(tenant_id, branch_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sale_items pos_sale_items_tenant_id_product_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_items
    ADD CONSTRAINT pos_sale_items_tenant_id_product_id_fkey FOREIGN KEY (tenant_id, product_id) REFERENCES app.inventory_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sale_return_items pos_sale_return_items_tenant_id_branch_id_sale_id_return_i_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_return_items
    ADD CONSTRAINT pos_sale_return_items_tenant_id_branch_id_sale_id_return_i_fkey FOREIGN KEY (tenant_id, branch_id, sale_id, return_id) REFERENCES app.pos_sale_returns(tenant_id, branch_id, sale_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sale_return_items pos_sale_return_items_tenant_id_branch_id_sale_id_sale_ite_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_return_items
    ADD CONSTRAINT pos_sale_return_items_tenant_id_branch_id_sale_id_sale_ite_fkey FOREIGN KEY (tenant_id, branch_id, sale_id, sale_item_id, product_id) REFERENCES app.pos_sale_items(tenant_id, branch_id, sale_id, id, product_id) ON DELETE RESTRICT;


--
-- Name: pos_sale_returns pos_sale_returns_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_returns
    ADD CONSTRAINT pos_sale_returns_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sale_returns pos_sale_returns_tenant_id_branch_id_sale_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sale_returns
    ADD CONSTRAINT pos_sale_returns_tenant_id_branch_id_sale_id_fkey FOREIGN KEY (tenant_id, branch_id, sale_id) REFERENCES app.pos_sales(tenant_id, branch_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sales pos_sales_tenant_id_actor_membership_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_tenant_id_actor_membership_id_fkey FOREIGN KEY (tenant_id, actor_membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sales pos_sales_tenant_id_branch_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_tenant_id_branch_id_fkey FOREIGN KEY (tenant_id, branch_id) REFERENCES app.branches(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: pos_sales pos_sales_tenant_id_fkey; Type: FK CONSTRAINT; Schema: app; Owner: postgres
--

ALTER TABLE ONLY app.pos_sales
    ADD CONSTRAINT pos_sales_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES platform.tenants(id) ON DELETE RESTRICT;


--
-- Name: tenant_sessions fk_session_membership; Type: FK CONSTRAINT; Schema: security; Owner: postgres
--

ALTER TABLE ONLY security.tenant_sessions
    ADD CONSTRAINT fk_session_membership FOREIGN KEY (tenant_id, membership_id) REFERENCES app.tenant_memberships(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: attendance_checkouts; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.attendance_checkouts ENABLE ROW LEVEL SECURITY;

--
-- Name: attendance_visits; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.attendance_visits ENABLE ROW LEVEL SECURITY;

--
-- Name: member_blacklist_events blacklist_events_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY blacklist_events_owner_insert ON app.member_blacklist_events FOR INSERT TO gympro_blacklist_owner WITH CHECK (true);


--
-- Name: member_blacklist_events blacklist_events_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY blacklist_events_owner_select ON app.member_blacklist_events FOR SELECT TO gympro_blacklist_owner USING (true);


--
-- Name: branches; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.branches ENABLE ROW LEVEL SECURITY;

--
-- Name: branches branches_rbac_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY branches_rbac_owner_select ON app.branches FOR SELECT TO gympro_rbac_owner USING (((status)::text = 'active'::text));


--
-- Name: branches branches_tenant_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY branches_tenant_select ON app.branches FOR SELECT TO gympro_app USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: branches c1_branches_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_branches_lock ON app.branches FOR UPDATE TO gympro_attendance_owner USING (true) WITH CHECK (true);


--
-- Name: branches c1_branches_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_branches_select ON app.branches FOR SELECT TO gympro_attendance_owner USING (true);


--
-- Name: members c1_members_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_members_lock ON app.members FOR UPDATE TO gympro_attendance_owner USING (true) WITH CHECK (true);


--
-- Name: members c1_members_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_members_select ON app.members FOR SELECT TO gympro_attendance_owner USING (true);


--
-- Name: member_subscriptions c1_subscriptions_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_subscriptions_lock ON app.member_subscriptions FOR UPDATE TO gympro_attendance_owner USING (true) WITH CHECK (true);


--
-- Name: member_subscriptions c1_subscriptions_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_subscriptions_select ON app.member_subscriptions FOR SELECT TO gympro_attendance_owner USING (true);


--
-- Name: attendance_visits c1_visits_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_visits_insert ON app.attendance_visits FOR INSERT TO gympro_attendance_owner WITH CHECK (true);


--
-- Name: attendance_visits c1_visits_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c1_visits_select ON app.attendance_visits FOR SELECT TO gympro_attendance_owner USING (true);


--
-- Name: attendance_checkouts c2_checkouts_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c2_checkouts_insert ON app.attendance_checkouts FOR INSERT TO gympro_attendance_owner WITH CHECK (true);


--
-- Name: attendance_checkouts c2_checkouts_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c2_checkouts_select ON app.attendance_checkouts FOR SELECT TO gympro_attendance_owner USING (true);


--
-- Name: attendance_visits c2_visits_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c2_visits_update ON app.attendance_visits FOR UPDATE TO gympro_attendance_owner USING (true) WITH CHECK (true);


--
-- Name: members c3_members_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c3_members_read ON app.members FOR SELECT TO gympro_attendance_reader USING (true);


--
-- Name: attendance_visits c3_visits_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c3_visits_read ON app.attendance_visits FOR SELECT TO gympro_attendance_reader USING (true);


--
-- Name: branches c4_branches_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_branches_lock ON app.branches FOR UPDATE TO gympro_card_owner USING (true) WITH CHECK (true);


--
-- Name: branches c4_branches_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_branches_select ON app.branches FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: member_cards c4_cards_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_cards_insert ON app.member_cards FOR INSERT TO gympro_card_owner WITH CHECK (true);


--
-- Name: member_cards c4_cards_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_cards_select ON app.member_cards FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: member_cards c4_cards_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_cards_update ON app.member_cards FOR UPDATE TO gympro_card_owner USING (true) WITH CHECK (true);


--
-- Name: member_card_events c4_events_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_events_insert ON app.member_card_events FOR INSERT TO gympro_card_owner WITH CHECK (true);


--
-- Name: member_card_events c4_events_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_events_select ON app.member_card_events FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: members c4_members_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_members_lock ON app.members FOR UPDATE TO gympro_card_owner USING (true) WITH CHECK (true);


--
-- Name: members c4_members_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c4_members_select ON app.members FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: card_scan_receipts c5_scans_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c5_scans_insert ON app.card_scan_receipts FOR INSERT TO gympro_card_owner WITH CHECK (true);


--
-- Name: card_scan_receipts c5_scans_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c5_scans_select ON app.card_scan_receipts FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: attendance_visits c5_visits_request_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c5_visits_request_read ON app.attendance_visits FOR SELECT TO gympro_card_owner USING (true);


--
-- Name: members c7_members_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY c7_members_read ON app.members FOR SELECT TO gympro_member_reader USING (true);


--
-- Name: card_scan_receipts; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.card_scan_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_discounts discount_purchase_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY discount_purchase_owner_insert ON app.membership_discounts FOR INSERT TO gympro_membership_owner WITH CHECK (true);


--
-- Name: membership_discounts discount_purchase_owner_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY discount_purchase_owner_read ON app.membership_discounts FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: subscription_renewals discount_purchase_owner_renewal_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY discount_purchase_owner_renewal_update ON app.subscription_renewals FOR UPDATE TO gympro_membership_owner USING (true) WITH CHECK (true);


--
-- Name: payment_charges e2_payment_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_insert ON app.payment_charges FOR INSERT TO gympro_payment_owner WITH CHECK (true);


--
-- Name: payment_receipts e2_payment_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_insert ON app.payment_receipts FOR INSERT TO gympro_payment_owner WITH CHECK (true);


--
-- Name: member_subscriptions e2_payment_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_lock ON app.member_subscriptions FOR UPDATE TO gympro_payment_owner USING (true) WITH CHECK (true);


--
-- Name: payment_charges e2_payment_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_lock ON app.payment_charges FOR UPDATE TO gympro_payment_owner USING (true) WITH CHECK (true);


--
-- Name: pos_sales e2_payment_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_lock ON app.pos_sales FOR UPDATE TO gympro_payment_owner USING (true) WITH CHECK (true);


--
-- Name: branches e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.branches FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: member_subscriptions e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.member_subscriptions FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: payment_charges e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.payment_charges FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: payment_receipts e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.payment_receipts FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: payment_reversals e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.payment_reversals FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: pos_sale_returns e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.pos_sale_returns FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: pos_sales e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.pos_sales FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: subscription_renewals e2_payment_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e2_payment_select ON app.subscription_renewals FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: payment_receipts e4_payment_receipt_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e4_payment_receipt_lock ON app.payment_receipts FOR UPDATE TO gympro_payment_owner USING (true) WITH CHECK (true);


--
-- Name: payment_reversals e4_payment_reversal_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e4_payment_reversal_insert ON app.payment_reversals FOR INSERT TO gympro_payment_owner WITH CHECK (true);


--
-- Name: payment_reconciliations e6_reconciliation_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e6_reconciliation_insert ON app.payment_reconciliations FOR INSERT TO gympro_payment_owner WITH CHECK (true);


--
-- Name: payment_reconciliations e6_reconciliation_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY e6_reconciliation_select ON app.payment_reconciliations FOR SELECT TO gympro_payment_owner USING (true);


--
-- Name: subscription_expirations expirations_membership_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY expirations_membership_owner_insert ON app.subscription_expirations FOR INSERT TO gympro_membership_owner WITH CHECK (true);


--
-- Name: subscription_expirations expirations_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY expirations_membership_owner_select ON app.subscription_expirations FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: subscription_foc_grants foc_grants_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY foc_grants_owner_insert ON app.subscription_foc_grants FOR INSERT TO gympro_foc_owner WITH CHECK (true);


--
-- Name: subscription_foc_grants foc_grants_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY foc_grants_owner_select ON app.subscription_foc_grants FOR SELECT TO gympro_foc_owner USING (true);


--
-- Name: inventory_product_events inventory_events_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_events_owner_insert ON app.inventory_product_events FOR INSERT TO gympro_inventory_owner WITH CHECK (true);


--
-- Name: inventory_product_events inventory_events_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_events_owner_select ON app.inventory_product_events FOR SELECT TO gympro_inventory_owner USING (true);


--
-- Name: tenant_memberships inventory_history_memberships_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_history_memberships_read ON app.tenant_memberships FOR SELECT TO gympro_inventory_read_owner USING (true);


--
-- Name: inventory_stock_movements inventory_history_movements_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_history_movements_read ON app.inventory_stock_movements FOR SELECT TO gympro_inventory_read_owner USING (true);


--
-- Name: inventory_products inventory_history_products_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_history_products_read ON app.inventory_products FOR SELECT TO gympro_inventory_read_owner USING (true);


--
-- Name: users inventory_history_staff_names_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_history_staff_names_read ON app.users FOR SELECT TO gympro_inventory_read_owner USING (true);


--
-- Name: inventory_stock_movements inventory_movements_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_movements_owner_insert ON app.inventory_stock_movements FOR INSERT TO gympro_inventory_owner WITH CHECK (true);


--
-- Name: inventory_stock_movements inventory_movements_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_movements_owner_select ON app.inventory_stock_movements FOR SELECT TO gympro_inventory_owner USING (true);


--
-- Name: inventory_product_events; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.inventory_product_events ENABLE ROW LEVEL SECURITY;

--
-- Name: inventory_products; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.inventory_products ENABLE ROW LEVEL SECURITY;

--
-- Name: inventory_products inventory_products_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_products_owner_insert ON app.inventory_products FOR INSERT TO gympro_inventory_owner WITH CHECK (true);


--
-- Name: inventory_products inventory_products_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_products_owner_select ON app.inventory_products FOR SELECT TO gympro_inventory_owner USING (true);


--
-- Name: inventory_products inventory_products_owner_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY inventory_products_owner_update ON app.inventory_products FOR UPDATE TO gympro_inventory_owner USING (true) WITH CHECK (true);


--
-- Name: inventory_stock_movements; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.inventory_stock_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: member_blacklist_events; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.member_blacklist_events ENABLE ROW LEVEL SECURITY;

--
-- Name: member_card_events; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.member_card_events ENABLE ROW LEVEL SECURITY;

--
-- Name: member_cards; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.member_cards ENABLE ROW LEVEL SECURITY;

--
-- Name: member_subscriptions; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.member_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: members; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.members ENABLE ROW LEVEL SECURITY;

--
-- Name: members members_blacklist_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_blacklist_owner_select ON app.members FOR SELECT TO gympro_blacklist_owner USING (true);


--
-- Name: members members_blacklist_owner_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_blacklist_owner_update ON app.members FOR UPDATE TO gympro_blacklist_owner USING (true) WITH CHECK (true);


--
-- Name: members members_foc_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_foc_owner_select ON app.members FOR SELECT TO gympro_foc_owner USING (true);


--
-- Name: members members_foc_owner_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_foc_owner_update ON app.members FOR UPDATE TO gympro_foc_owner USING (true) WITH CHECK (true);


--
-- Name: members members_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_membership_owner_select ON app.members FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: members members_membership_owner_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_membership_owner_update ON app.members FOR UPDATE TO gympro_membership_owner USING (true) WITH CHECK (true);


--
-- Name: members members_registration_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_registration_owner_insert ON app.members FOR INSERT TO gympro_member_owner WITH CHECK (true);


--
-- Name: members members_registration_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY members_registration_owner_select ON app.members FOR SELECT TO gympro_member_owner USING (true);


--
-- Name: membership_discounts; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.membership_discounts ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_plans; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.membership_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_promotions; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.membership_promotions ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_charges; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.payment_charges ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_receipts; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.payment_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_reconciliations; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.payment_reconciliations ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_reversals; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.payment_reversals ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_prices; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.plan_prices ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_plans plans_foc_owner_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY plans_foc_owner_lock ON app.membership_plans FOR UPDATE TO gympro_foc_owner USING (true) WITH CHECK (true);


--
-- Name: membership_plans plans_foc_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY plans_foc_owner_select ON app.membership_plans FOR SELECT TO gympro_foc_owner USING (true);


--
-- Name: membership_plans plans_membership_owner_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY plans_membership_owner_lock ON app.membership_plans FOR UPDATE TO gympro_membership_owner USING (true) WITH CHECK (true);


--
-- Name: membership_plans plans_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY plans_membership_owner_select ON app.membership_plans FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: pos_sale_items pos_items_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_items_insert ON app.pos_sale_items FOR INSERT TO gympro_pos_owner WITH CHECK (true);


--
-- Name: pos_sale_items pos_items_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_items_select ON app.pos_sale_items FOR SELECT TO gympro_pos_owner USING (true);


--
-- Name: inventory_stock_movements pos_movements_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_movements_insert ON app.inventory_stock_movements FOR INSERT TO gympro_pos_owner WITH CHECK (true);


--
-- Name: inventory_stock_movements pos_movements_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_movements_select ON app.inventory_stock_movements FOR SELECT TO gympro_pos_owner USING (true);


--
-- Name: inventory_products pos_products_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_products_lock ON app.inventory_products FOR UPDATE TO gympro_pos_owner USING (true) WITH CHECK (true);


--
-- Name: inventory_products pos_products_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_products_select ON app.inventory_products FOR SELECT TO gympro_pos_owner USING (true);


--
-- Name: pos_sale_returns pos_return_history_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_history_insert ON app.pos_sale_returns FOR INSERT TO gympro_pos_return_owner WITH CHECK (true);


--
-- Name: pos_sale_returns pos_return_history_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_history_read ON app.pos_sale_returns FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: pos_sale_return_items pos_return_items_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_items_insert ON app.pos_sale_return_items FOR INSERT TO gympro_pos_return_owner WITH CHECK (true);


--
-- Name: pos_sale_return_items pos_return_items_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_items_read ON app.pos_sale_return_items FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: inventory_stock_movements pos_return_movements_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_movements_insert ON app.inventory_stock_movements FOR INSERT TO gympro_pos_return_owner WITH CHECK (true);


--
-- Name: inventory_stock_movements pos_return_movements_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_movements_read ON app.inventory_stock_movements FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: inventory_products pos_return_products_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_products_lock ON app.inventory_products FOR UPDATE TO gympro_pos_return_owner USING (true) WITH CHECK (true);


--
-- Name: inventory_products pos_return_products_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_products_read ON app.inventory_products FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: pos_sale_items pos_return_sale_items_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_sale_items_read ON app.pos_sale_items FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: pos_sales pos_return_sales_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_sales_lock ON app.pos_sales FOR UPDATE TO gympro_pos_return_owner USING (true) WITH CHECK (true);


--
-- Name: pos_sales pos_return_sales_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_return_sales_read ON app.pos_sales FOR SELECT TO gympro_pos_return_owner USING (true);


--
-- Name: pos_sale_items; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.pos_sale_items ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_sale_return_items; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.pos_sale_return_items ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_sale_returns; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.pos_sale_returns ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_sales; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.pos_sales ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_sales pos_sales_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_sales_insert ON app.pos_sales FOR INSERT TO gympro_pos_owner WITH CHECK (true);


--
-- Name: pos_sales pos_sales_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY pos_sales_select ON app.pos_sales FOR SELECT TO gympro_pos_owner USING (true);


--
-- Name: plan_prices prices_foc_owner_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY prices_foc_owner_lock ON app.plan_prices FOR UPDATE TO gympro_foc_owner USING (true) WITH CHECK (true);


--
-- Name: plan_prices prices_foc_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY prices_foc_owner_select ON app.plan_prices FOR SELECT TO gympro_foc_owner USING (true);


--
-- Name: plan_prices prices_membership_owner_lock; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY prices_membership_owner_lock ON app.plan_prices FOR UPDATE TO gympro_membership_owner USING (true) WITH CHECK (true);


--
-- Name: plan_prices prices_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY prices_membership_owner_select ON app.plan_prices FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: branches promotion_owner_branch_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY promotion_owner_branch_read ON app.branches FOR SELECT TO gympro_promotion_owner USING (true);


--
-- Name: membership_promotions promotion_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY promotion_owner_insert ON app.membership_promotions FOR INSERT TO gympro_promotion_owner WITH CHECK (true);


--
-- Name: membership_plans promotion_owner_plan_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY promotion_owner_plan_read ON app.membership_plans FOR SELECT TO gympro_promotion_owner USING (true);


--
-- Name: membership_promotions promotion_owner_read; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY promotion_owner_read ON app.membership_promotions FOR SELECT TO gympro_promotion_owner USING (true);


--
-- Name: membership_promotions promotion_owner_status_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY promotion_owner_status_update ON app.membership_promotions FOR UPDATE TO gympro_promotion_owner USING (true) WITH CHECK (true);


--
-- Name: subscription_renewals renewals_membership_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY renewals_membership_owner_insert ON app.subscription_renewals FOR INSERT TO gympro_membership_owner WITH CHECK (true);


--
-- Name: subscription_renewals renewals_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY renewals_membership_owner_select ON app.subscription_renewals FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: subscription_expirations; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.subscription_expirations ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_foc_grants; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.subscription_foc_grants ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_renewals; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.subscription_renewals ENABLE ROW LEVEL SECURITY;

--
-- Name: subscription_suspensions; Type: ROW SECURITY; Schema: app; Owner: postgres
--

ALTER TABLE app.subscription_suspensions ENABLE ROW LEVEL SECURITY;

--
-- Name: member_subscriptions subscriptions_blacklist_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_blacklist_owner_select ON app.member_subscriptions FOR SELECT TO gympro_blacklist_owner USING (true);


--
-- Name: member_subscriptions subscriptions_foc_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_foc_owner_insert ON app.member_subscriptions FOR INSERT TO gympro_foc_owner WITH CHECK (true);


--
-- Name: member_subscriptions subscriptions_foc_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_foc_owner_select ON app.member_subscriptions FOR SELECT TO gympro_foc_owner USING (true);


--
-- Name: member_subscriptions subscriptions_membership_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_membership_owner_insert ON app.member_subscriptions FOR INSERT TO gympro_membership_owner WITH CHECK (true);


--
-- Name: member_subscriptions subscriptions_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_membership_owner_select ON app.member_subscriptions FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: member_subscriptions subscriptions_membership_owner_update; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY subscriptions_membership_owner_update ON app.member_subscriptions FOR UPDATE TO gympro_membership_owner USING (true) WITH CHECK (true);


--
-- Name: subscription_suspensions suspensions_membership_owner_insert; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY suspensions_membership_owner_insert ON app.subscription_suspensions FOR INSERT TO gympro_membership_owner WITH CHECK (true);


--
-- Name: subscription_suspensions suspensions_membership_owner_select; Type: POLICY; Schema: app; Owner: postgres
--

CREATE POLICY suspensions_membership_owner_select ON app.subscription_suspensions FOR SELECT TO gympro_membership_owner USING (true);


--
-- Name: SCHEMA app; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA app TO gympro_app;
GRANT USAGE ON SCHEMA app TO gympro_introspect;
GRANT USAGE ON SCHEMA app TO gympro_session_owner;
GRANT USAGE ON SCHEMA app TO gympro_rbac_owner;
GRANT USAGE ON SCHEMA app TO gympro_member_owner;
GRANT USAGE ON SCHEMA app TO gympro_membership_owner;
GRANT USAGE ON SCHEMA app TO gympro_blacklist_owner;
GRANT USAGE ON SCHEMA app TO gympro_foc_owner;
GRANT USAGE ON SCHEMA app TO gympro_promotion_owner;
GRANT USAGE ON SCHEMA app TO gympro_attendance_owner;
GRANT USAGE ON SCHEMA app TO gympro_attendance_reader;
GRANT USAGE ON SCHEMA app TO gympro_card_owner;
GRANT USAGE ON SCHEMA app TO gympro_member_reader;
GRANT USAGE ON SCHEMA app TO gympro_inventory_owner;
GRANT USAGE ON SCHEMA app TO gympro_pos_owner;
GRANT USAGE ON SCHEMA app TO gympro_pos_return_owner;
GRANT USAGE ON SCHEMA app TO gympro_inventory_read_owner;
GRANT USAGE ON SCHEMA app TO gympro_payment_owner;


--
-- Name: SCHEMA platform; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA platform TO gympro_app;
GRANT USAGE ON SCHEMA platform TO gympro_introspect;
GRANT USAGE ON SCHEMA platform TO gympro_session_owner;
GRANT USAGE ON SCHEMA platform TO gympro_rbac_owner;


--
-- Name: SCHEMA security; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA security TO gympro_auth;
GRANT USAGE ON SCHEMA security TO gympro_session_owner;
GRANT USAGE ON SCHEMA security TO gympro_rbac_owner;
GRANT USAGE ON SCHEMA security TO gympro_session;
GRANT USAGE ON SCHEMA security TO gympro_member_owner;
GRANT USAGE ON SCHEMA security TO gympro_app;
GRANT USAGE ON SCHEMA security TO gympro_membership_owner;
GRANT USAGE ON SCHEMA security TO gympro_blacklist_owner;
GRANT USAGE ON SCHEMA security TO gympro_foc_owner;
GRANT USAGE ON SCHEMA security TO gympro_promotion_owner;
GRANT USAGE ON SCHEMA security TO gympro_attendance_owner;
GRANT USAGE ON SCHEMA security TO gympro_attendance_reader;
GRANT USAGE ON SCHEMA security TO gympro_card_owner;
GRANT USAGE ON SCHEMA security TO gympro_member_reader;
GRANT USAGE ON SCHEMA security TO gympro_inventory_owner;
GRANT USAGE ON SCHEMA security TO gympro_pos_owner;
GRANT USAGE ON SCHEMA security TO gympro_pos_return_owner;
GRANT USAGE ON SCHEMA security TO gympro_inventory_read_owner;
GRANT USAGE ON SCHEMA security TO gympro_payment_owner;


--
-- Name: TABLE membership_discounts; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.membership_discounts TO gympro_membership_owner;


--
-- Name: FUNCTION activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: TABLE member_subscriptions; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.member_subscriptions TO gympro_membership_owner;
GRANT SELECT ON TABLE app.member_subscriptions TO gympro_blacklist_owner;
GRANT SELECT,INSERT ON TABLE app.member_subscriptions TO gympro_foc_owner;
GRANT SELECT ON TABLE app.member_subscriptions TO gympro_attendance_owner;
GRANT SELECT ON TABLE app.member_subscriptions TO gympro_payment_owner;


--
-- Name: COLUMN member_subscriptions.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.member_subscriptions TO gympro_attendance_owner;
GRANT UPDATE(id) ON TABLE app.member_subscriptions TO gympro_payment_owner;


--
-- Name: COLUMN member_subscriptions.plan_price_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(plan_price_id) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.duration_value; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(duration_value) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.duration_unit; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(duration_unit) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.agreed_price_amount; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(agreed_price_amount) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.currency_code; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(currency_code) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(status) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.starts_on; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(starts_on) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.ends_on; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(ends_on) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.activated_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(activated_at) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.suspended_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(suspended_at) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: COLUMN member_subscriptions.updated_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE app.member_subscriptions TO gympro_membership_owner;


--
-- Name: FUNCTION activate_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.activate_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.activate_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) TO gympro_app;


--
-- Name: FUNCTION activate_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.activate_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.activate_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION activate_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.activate_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.activate_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid) TO gympro_app;


--
-- Name: FUNCTION adjust_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_delta integer, p_reason text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_inventory_owner
--

REVOKE ALL ON FUNCTION security.adjust_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_delta integer, p_reason text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.adjust_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_delta integer, p_reason text, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION calculate_membership_discount(p_token_hash bytea, p_tenant_id uuid, p_plan_id uuid, p_branch_id uuid, p_listed_price numeric, p_promotion_id uuid); Type: ACL; Schema: security; Owner: gympro_promotion_owner
--

REVOKE ALL ON FUNCTION security.calculate_membership_discount(p_token_hash bytea, p_tenant_id uuid, p_plan_id uuid, p_branch_id uuid, p_listed_price numeric, p_promotion_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.calculate_membership_discount(p_token_hash bytea, p_tenant_id uuid, p_plan_id uuid, p_branch_id uuid, p_listed_price numeric, p_promotion_id uuid) TO gympro_membership_owner;


--
-- Name: TABLE member_blacklist_events; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.member_blacklist_events TO gympro_blacklist_owner;


--
-- Name: FUNCTION change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_blacklist_owner
--

REVOKE ALL ON FUNCTION security.change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION change_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_blacklist_owner
--

REVOKE ALL ON FUNCTION security.change_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.change_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: TABLE member_card_events; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.member_card_events TO gympro_card_owner;


--
-- Name: FUNCTION change_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_subject uuid, p_action text, p_request uuid, p_reason text); Type: ACL; Schema: security; Owner: gympro_card_owner
--

REVOKE ALL ON FUNCTION security.change_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_subject uuid, p_action text, p_request uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION security.change_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_subject uuid, p_action text, p_request uuid, p_reason text) TO gympro_app;


--
-- Name: FUNCTION change_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_action text, p_items jsonb, p_reason text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_pos_return_owner
--

REVOKE ALL ON FUNCTION security.change_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_action text, p_items jsonb, p_reason text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.change_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_action text, p_items jsonb, p_reason text, p_request uuid) TO gympro_app;


--
-- Name: TABLE attendance_visits; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.attendance_visits TO gympro_attendance_owner;
GRANT SELECT ON TABLE app.attendance_visits TO gympro_attendance_reader;


--
-- Name: COLUMN attendance_visits.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.attendance_visits TO gympro_card_owner;


--
-- Name: COLUMN attendance_visits.request_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(request_id) ON TABLE app.attendance_visits TO gympro_card_owner;


--
-- Name: COLUMN attendance_visits.checked_out_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(checked_out_at) ON TABLE app.attendance_visits TO gympro_attendance_owner;


--
-- Name: FUNCTION check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid); Type: ACL; Schema: security; Owner: gympro_attendance_owner
--

REVOKE ALL ON FUNCTION security.check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid) TO gympro_app;
GRANT ALL ON FUNCTION security.check_in_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid, p_request uuid) TO gympro_card_owner;


--
-- Name: TABLE attendance_checkouts; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.attendance_checkouts TO gympro_attendance_owner;


--
-- Name: FUNCTION check_out_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_visit uuid, p_request uuid); Type: ACL; Schema: security; Owner: gympro_attendance_owner
--

REVOKE ALL ON FUNCTION security.check_out_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_visit uuid, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.check_out_member(p_hash bytea, p_tenant uuid, p_branch uuid, p_visit uuid, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION create_inventory_product(p_hash bytea, p_tenant uuid, p_sku text, p_name text, p_description text, p_price numeric, p_request uuid); Type: ACL; Schema: security; Owner: gympro_inventory_owner
--

REVOKE ALL ON FUNCTION security.create_inventory_product(p_hash bytea, p_tenant uuid, p_sku text, p_name text, p_description text, p_price numeric, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.create_inventory_product(p_hash bytea, p_tenant uuid, p_sku text, p_name text, p_description text, p_price numeric, p_request uuid) TO gympro_app;


--
-- Name: TABLE membership_promotions; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.membership_promotions TO gympro_promotion_owner;


--
-- Name: COLUMN membership_promotions.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(status) ON TABLE app.membership_promotions TO gympro_promotion_owner;


--
-- Name: COLUMN membership_promotions.updated_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE app.membership_promotions TO gympro_promotion_owner;


--
-- Name: FUNCTION create_membership_promotion(p_token_hash bytea, p_tenant_id uuid, p_promotion_code text, p_promotion_name text, p_description text, p_plan_id uuid, p_branch_id uuid, p_discount_kind text, p_discount_value numeric, p_starts_on date, p_ends_on date); Type: ACL; Schema: security; Owner: gympro_promotion_owner
--

REVOKE ALL ON FUNCTION security.create_membership_promotion(p_token_hash bytea, p_tenant_id uuid, p_promotion_code text, p_promotion_name text, p_description text, p_plan_id uuid, p_branch_id uuid, p_discount_kind text, p_discount_value numeric, p_starts_on date, p_ends_on date) FROM PUBLIC;
GRANT ALL ON FUNCTION security.create_membership_promotion(p_token_hash bytea, p_tenant_id uuid, p_promotion_code text, p_promotion_name text, p_description text, p_plan_id uuid, p_branch_id uuid, p_discount_kind text, p_discount_value numeric, p_starts_on date, p_ends_on date) TO gympro_app;


--
-- Name: FUNCTION create_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_items jsonb, p_request uuid); Type: ACL; Schema: security; Owner: gympro_pos_owner
--

REVOKE ALL ON FUNCTION security.create_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_items jsonb, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.create_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_items jsonb, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION create_tenant_session(p_membership_id uuid, p_token_hash bytea); Type: ACL; Schema: security; Owner: gympro_session_owner
--

REVOKE ALL ON FUNCTION security.create_tenant_session(p_membership_id uuid, p_token_hash bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION security.create_tenant_session(p_membership_id uuid, p_token_hash bytea) TO gympro_session;


--
-- Name: TABLE subscription_expirations; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.subscription_expirations TO gympro_membership_owner;


--
-- Name: FUNCTION expire_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.expire_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.expire_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid) TO gympro_app;


--
-- Name: FUNCTION expire_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.expire_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.expire_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid) TO gympro_app;


--
-- Name: FUNCTION find_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid); Type: ACL; Schema: security; Owner: gympro_card_owner
--

REVOKE ALL ON FUNCTION security.find_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.find_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_member uuid) TO gympro_app;


--
-- Name: FUNCTION get_active_tenant_membership(p_user_id uuid, p_tenant_id uuid); Type: ACL; Schema: security; Owner: postgres
--

REVOKE ALL ON FUNCTION security.get_active_tenant_membership(p_user_id uuid, p_tenant_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.get_active_tenant_membership(p_user_id uuid, p_tenant_id uuid) TO gympro_auth;


--
-- Name: FUNCTION get_user_credentials(p_email text); Type: ACL; Schema: security; Owner: postgres
--

REVOKE ALL ON FUNCTION security.get_user_credentials(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION security.get_user_credentials(p_email text) TO gympro_auth;


--
-- Name: TABLE subscription_foc_grants; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.subscription_foc_grants TO gympro_foc_owner;


--
-- Name: FUNCTION grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_foc_owner
--

REVOKE ALL ON FUNCTION security.grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION grant_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_foc_owner
--

REVOKE ALL ON FUNCTION security.grant_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.grant_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid); Type: ACL; Schema: security; Owner: gympro_rbac_owner
--

REVOKE ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_auth;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_member_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_membership_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_blacklist_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_foc_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_promotion_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_attendance_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_attendance_reader;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_card_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_member_reader;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_inventory_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_pos_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_pos_return_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_inventory_read_owner;
GRANT ALL ON FUNCTION security.has_tenant_permission(p_tenant_id uuid, p_membership_id uuid, p_permission_code text, p_branch_id uuid) TO gympro_payment_owner;


--
-- Name: FUNCTION is_tenant_session_valid(p_session_id uuid); Type: ACL; Schema: security; Owner: postgres
--

REVOKE ALL ON FUNCTION security.is_tenant_session_valid(p_session_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION open_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_kind text, p_source uuid, p_request uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.open_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_kind text, p_source uuid, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.open_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_kind text, p_source uuid, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION payment_charge_json(p_tenant uuid, p_charge uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.payment_charge_json(p_tenant uuid, p_charge uuid) FROM PUBLIC;


--
-- Name: FUNCTION payment_receipt_json(p_tenant uuid, p_receipt uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.payment_receipt_json(p_tenant uuid, p_receipt uuid) FROM PUBLIC;


--
-- Name: FUNCTION payment_reconciliation_json(p_tenant uuid, p_id uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.payment_reconciliation_json(p_tenant uuid, p_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION payment_reversal_json(p_tenant uuid, p_reversal uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.payment_reversal_json(p_tenant uuid, p_reversal uuid) FROM PUBLIC;


--
-- Name: FUNCTION payment_session(p_hash bytea, p_tenant uuid, p_branch uuid, p_permission text); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.payment_session(p_hash bytea, p_tenant uuid, p_branch uuid, p_permission text) FROM PUBLIC;


--
-- Name: FUNCTION read_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_current boolean, p_from date, p_to date, p_limit integer, p_before_at timestamp with time zone, p_before_id uuid); Type: ACL; Schema: security; Owner: gympro_attendance_reader
--

REVOKE ALL ON FUNCTION security.read_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_current boolean, p_from date, p_to date, p_limit integer, p_before_at timestamp with time zone, p_before_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_current boolean, p_from date, p_to date, p_limit integer, p_before_at timestamp with time zone, p_before_id uuid) TO gympro_app;


--
-- Name: FUNCTION read_inventory_products(p_hash bytea, p_tenant uuid, p_branch uuid, p_after uuid, p_limit integer); Type: ACL; Schema: security; Owner: gympro_inventory_owner
--

REVOKE ALL ON FUNCTION security.read_inventory_products(p_hash bytea, p_tenant uuid, p_branch uuid, p_after uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_inventory_products(p_hash bytea, p_tenant uuid, p_branch uuid, p_after uuid, p_limit integer) TO gympro_app;


--
-- Name: FUNCTION read_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid); Type: ACL; Schema: security; Owner: gympro_inventory_owner
--

REVOKE ALL ON FUNCTION security.read_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_inventory_stock(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid) TO gympro_app;


--
-- Name: FUNCTION read_inventory_stock_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_from date, p_through date, p_cursor uuid, p_limit integer); Type: ACL; Schema: security; Owner: gympro_inventory_read_owner
--

REVOKE ALL ON FUNCTION security.read_inventory_stock_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_inventory_stock_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_product uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) TO gympro_app;


--
-- Name: FUNCTION read_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid); Type: ACL; Schema: security; Owner: gympro_card_owner
--

REVOKE ALL ON FUNCTION security.read_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid) TO gympro_app;


--
-- Name: FUNCTION read_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.read_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_payment_charge(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid) TO gympro_app;


--
-- Name: FUNCTION read_payment_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_to date, p_cursor_kind text, p_cursor uuid, p_limit integer); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.read_payment_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_to date, p_cursor_kind text, p_cursor uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_payment_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_to date, p_cursor_kind text, p_cursor uuid, p_limit integer) TO gympro_app;


--
-- Name: FUNCTION read_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.read_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid) TO gympro_app;


--
-- Name: FUNCTION read_payment_reconciliation(p_hash bytea, p_tenant uuid, p_branch uuid, p_id uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.read_payment_reconciliation(p_hash bytea, p_tenant uuid, p_branch uuid, p_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_payment_reconciliation(p_hash bytea, p_tenant uuid, p_branch uuid, p_id uuid) TO gympro_app;


--
-- Name: FUNCTION read_payment_reversal(p_hash bytea, p_tenant uuid, p_branch uuid, p_reversal uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.read_payment_reversal(p_hash bytea, p_tenant uuid, p_branch uuid, p_reversal uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_payment_reversal(p_hash bytea, p_tenant uuid, p_branch uuid, p_reversal uuid) TO gympro_app;


--
-- Name: FUNCTION read_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid); Type: ACL; Schema: security; Owner: gympro_pos_owner
--

REVOKE ALL ON FUNCTION security.read_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_pos_sale(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) TO gympro_app;


--
-- Name: FUNCTION read_pos_sale_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_through date, p_cursor uuid, p_limit integer); Type: ACL; Schema: security; Owner: gympro_pos_return_owner
--

REVOKE ALL ON FUNCTION security.read_pos_sale_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_pos_sale_history(p_hash bytea, p_tenant uuid, p_branch uuid, p_from date, p_through date, p_cursor uuid, p_limit integer) TO gympro_app;


--
-- Name: FUNCTION read_pos_sale_return(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_return uuid); Type: ACL; Schema: security; Owner: gympro_pos_return_owner
--

REVOKE ALL ON FUNCTION security.read_pos_sale_return(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_return uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_pos_sale_return(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid, p_return uuid) TO gympro_app;


--
-- Name: FUNCTION read_pos_sale_return_status(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid); Type: ACL; Schema: security; Owner: gympro_pos_return_owner
--

REVOKE ALL ON FUNCTION security.read_pos_sale_return_status(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.read_pos_sale_return_status(p_hash bytea, p_tenant uuid, p_branch uuid, p_sale uuid) TO gympro_app;


--
-- Name: FUNCTION reconcile_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date, p_declared jsonb, p_note text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.reconcile_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date, p_declared jsonb, p_note text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.reconcile_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date, p_declared jsonb, p_note text, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION record_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid, p_amount numeric, p_method text, p_reference text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.record_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid, p_amount numeric, p_method text, p_reference text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.record_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_charge uuid, p_amount numeric, p_method text, p_reference text, p_request uuid) TO gympro_app;


--
-- Name: TABLE members; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.members TO gympro_member_owner;
GRANT SELECT ON TABLE app.members TO gympro_membership_owner;
GRANT SELECT ON TABLE app.members TO gympro_blacklist_owner;
GRANT SELECT ON TABLE app.members TO gympro_foc_owner;
GRANT SELECT ON TABLE app.members TO gympro_attendance_owner;
GRANT SELECT ON TABLE app.members TO gympro_attendance_reader;
GRANT SELECT ON TABLE app.members TO gympro_card_owner;
GRANT SELECT ON TABLE app.members TO gympro_member_reader;


--
-- Name: COLUMN members.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.members TO gympro_attendance_owner;
GRANT UPDATE(id) ON TABLE app.members TO gympro_card_owner;


--
-- Name: COLUMN members.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(status) ON TABLE app.members TO gympro_membership_owner;
GRANT UPDATE(status) ON TABLE app.members TO gympro_blacklist_owner;
GRANT UPDATE(status) ON TABLE app.members TO gympro_foc_owner;


--
-- Name: COLUMN members.updated_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE app.members TO gympro_membership_owner;
GRANT UPDATE(updated_at) ON TABLE app.members TO gympro_blacklist_owner;
GRANT UPDATE(updated_at) ON TABLE app.members TO gympro_foc_owner;


--
-- Name: FUNCTION register_member(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_full_name text, p_phone text, p_email text); Type: ACL; Schema: security; Owner: gympro_member_owner
--

REVOKE ALL ON FUNCTION security.register_member(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_full_name text, p_phone text, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION security.register_member(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_full_name text, p_phone text, p_email text) TO gympro_app;


--
-- Name: FUNCTION renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: TABLE subscription_renewals; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.subscription_renewals TO gympro_membership_owner;
GRANT SELECT ON TABLE app.subscription_renewals TO gympro_payment_owner;


--
-- Name: COLUMN subscription_renewals.agreed_price_amount; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(agreed_price_amount) ON TABLE app.subscription_renewals TO gympro_membership_owner;


--
-- Name: FUNCTION renew_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.renew_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.renew_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION renew_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.renew_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.renew_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION renew_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.renew_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.renew_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION reverse_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid, p_kind text, p_amount numeric, p_reason text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.reverse_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid, p_kind text, p_amount numeric, p_reason text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.reverse_payment_receipt(p_hash bytea, p_tenant uuid, p_branch uuid, p_receipt uuid, p_kind text, p_amount numeric, p_reason text, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION revoke_tenant_session(p_session_id uuid, p_token_hash bytea); Type: ACL; Schema: security; Owner: gympro_session_owner
--

REVOKE ALL ON FUNCTION security.revoke_tenant_session(p_session_id uuid, p_token_hash bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION security.revoke_tenant_session(p_session_id uuid, p_token_hash bytea) TO gympro_auth;


--
-- Name: FUNCTION scan_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid, p_request uuid); Type: ACL; Schema: security; Owner: gympro_card_owner
--

REVOKE ALL ON FUNCTION security.scan_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.scan_member_card(p_hash bytea, p_tenant uuid, p_branch uuid, p_card uuid, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION search_branch_members(p_hash bytea, p_tenant uuid, p_branch uuid, p_query text, p_limit integer, p_after uuid); Type: ACL; Schema: security; Owner: gympro_member_reader
--

REVOKE ALL ON FUNCTION security.search_branch_members(p_hash bytea, p_tenant uuid, p_branch uuid, p_query text, p_limit integer, p_after uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.search_branch_members(p_hash bytea, p_tenant uuid, p_branch uuid, p_query text, p_limit integer, p_after uuid) TO gympro_app;


--
-- Name: FUNCTION set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text); Type: ACL; Schema: security; Owner: gympro_promotion_owner
--

REVOKE ALL ON FUNCTION security.set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION security.set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text) TO gympro_app;


--
-- Name: FUNCTION set_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_promotion_id uuid, p_status text); Type: ACL; Schema: security; Owner: gympro_promotion_owner
--

REVOKE ALL ON FUNCTION security.set_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_promotion_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION security.set_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_promotion_id uuid, p_status text) TO gympro_app;


--
-- Name: FUNCTION summarize_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_day date); Type: ACL; Schema: security; Owner: gympro_attendance_reader
--

REVOKE ALL ON FUNCTION security.summarize_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_day date) FROM PUBLIC;
GRANT ALL ON FUNCTION security.summarize_branch_attendance(p_hash bytea, p_tenant uuid, p_branch uuid, p_day date) TO gympro_app;


--
-- Name: FUNCTION summarize_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date); Type: ACL; Schema: security; Owner: gympro_payment_owner
--

REVOKE ALL ON FUNCTION security.summarize_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date) FROM PUBLIC;
GRANT ALL ON FUNCTION security.summarize_payment_collection(p_hash bytea, p_tenant uuid, p_branch uuid, p_date date) TO gympro_app;


--
-- Name: TABLE subscription_suspensions; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.subscription_suspensions TO gympro_membership_owner;


--
-- Name: FUNCTION suspend_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.suspend_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.suspend_branch_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION suspend_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid); Type: ACL; Schema: security; Owner: gympro_membership_owner
--

REVOKE ALL ON FUNCTION security.suspend_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.suspend_member_subscription(p_token_hash bytea, p_tenant_id uuid, p_subscription_id uuid, p_reason text, p_request_id uuid) TO gympro_app;


--
-- Name: FUNCTION update_inventory_product(p_hash bytea, p_tenant uuid, p_product uuid, p_name text, p_description text, p_price numeric, p_status text, p_request uuid); Type: ACL; Schema: security; Owner: gympro_inventory_owner
--

REVOKE ALL ON FUNCTION security.update_inventory_product(p_hash bytea, p_tenant uuid, p_product uuid, p_name text, p_description text, p_price numeric, p_status text, p_request uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION security.update_inventory_product(p_hash bytea, p_tenant uuid, p_product uuid, p_name text, p_description text, p_price numeric, p_status text, p_request uuid) TO gympro_app;


--
-- Name: FUNCTION verify_tenant_session(p_token_hash bytea); Type: ACL; Schema: security; Owner: gympro_session_owner
--

REVOKE ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) FROM PUBLIC;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_auth;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_member_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_membership_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_blacklist_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_foc_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_promotion_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_attendance_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_attendance_reader;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_card_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_member_reader;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_inventory_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_pos_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_pos_return_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_inventory_read_owner;
GRANT ALL ON FUNCTION security.verify_tenant_session(p_token_hash bytea) TO gympro_payment_owner;


--
-- Name: TABLE branches; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.branches TO gympro_app;
GRANT SELECT ON TABLE app.branches TO gympro_introspect;
GRANT SELECT ON TABLE app.branches TO gympro_rbac_owner;
GRANT SELECT ON TABLE app.branches TO gympro_promotion_owner;
GRANT SELECT ON TABLE app.branches TO gympro_attendance_owner;
GRANT SELECT ON TABLE app.branches TO gympro_card_owner;
GRANT SELECT ON TABLE app.branches TO gympro_payment_owner;


--
-- Name: COLUMN branches.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id) ON TABLE app.branches TO gympro_rbac_owner;
GRANT UPDATE(id) ON TABLE app.branches TO gympro_attendance_owner;
GRANT UPDATE(id) ON TABLE app.branches TO gympro_card_owner;


--
-- Name: COLUMN branches.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.branches TO gympro_rbac_owner;


--
-- Name: COLUMN branches.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(status) ON TABLE app.branches TO gympro_rbac_owner;


--
-- Name: TABLE card_scan_receipts; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.card_scan_receipts TO gympro_card_owner;


--
-- Name: TABLE inventory_product_events; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.inventory_product_events TO gympro_inventory_owner;


--
-- Name: TABLE inventory_products; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.inventory_products TO gympro_inventory_owner;
GRANT SELECT ON TABLE app.inventory_products TO gympro_pos_owner;
GRANT SELECT ON TABLE app.inventory_products TO gympro_pos_return_owner;


--
-- Name: COLUMN inventory_products.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.inventory_products TO gympro_inventory_owner;
GRANT UPDATE(id) ON TABLE app.inventory_products TO gympro_pos_owner;
GRANT UPDATE(id) ON TABLE app.inventory_products TO gympro_pos_return_owner;
GRANT SELECT(id) ON TABLE app.inventory_products TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_products.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.inventory_products TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_products.product_name; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(product_name) ON TABLE app.inventory_products TO gympro_inventory_owner;


--
-- Name: COLUMN inventory_products.description; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(description) ON TABLE app.inventory_products TO gympro_inventory_owner;


--
-- Name: COLUMN inventory_products.sale_price; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(sale_price) ON TABLE app.inventory_products TO gympro_inventory_owner;


--
-- Name: COLUMN inventory_products.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(status) ON TABLE app.inventory_products TO gympro_inventory_owner;


--
-- Name: COLUMN inventory_products.updated_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(updated_at) ON TABLE app.inventory_products TO gympro_inventory_owner;


--
-- Name: TABLE inventory_stock_movements; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.inventory_stock_movements TO gympro_inventory_owner;
GRANT SELECT,INSERT ON TABLE app.inventory_stock_movements TO gympro_pos_owner;
GRANT SELECT,INSERT ON TABLE app.inventory_stock_movements TO gympro_pos_return_owner;


--
-- Name: COLUMN inventory_stock_movements.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.branch_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(branch_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.product_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(product_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.quantity_delta; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(quantity_delta) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.reason; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(reason) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.actor_membership_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(actor_membership_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.created_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(created_at) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.balance_after; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(balance_after) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.product_snapshot; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(product_snapshot) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.movement_kind; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(movement_kind) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.sale_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(sale_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: COLUMN inventory_stock_movements.return_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(return_id) ON TABLE app.inventory_stock_movements TO gympro_inventory_read_owner;


--
-- Name: TABLE member_cards; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.member_cards TO gympro_card_owner;


--
-- Name: COLUMN member_cards.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(status) ON TABLE app.member_cards TO gympro_card_owner;


--
-- Name: COLUMN member_cards.revoked_at; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(revoked_at) ON TABLE app.member_cards TO gympro_card_owner;


--
-- Name: SEQUENCE member_number_seq; Type: ACL; Schema: app; Owner: postgres
--

GRANT USAGE ON SEQUENCE app.member_number_seq TO gympro_member_owner;


--
-- Name: TABLE membership_plans; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.membership_plans TO gympro_membership_owner;
GRANT SELECT ON TABLE app.membership_plans TO gympro_foc_owner;
GRANT SELECT ON TABLE app.membership_plans TO gympro_promotion_owner;


--
-- Name: COLUMN membership_plans.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.membership_plans TO gympro_membership_owner;
GRANT UPDATE(id) ON TABLE app.membership_plans TO gympro_foc_owner;


--
-- Name: TABLE payment_charges; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.payment_charges TO gympro_payment_owner;


--
-- Name: COLUMN payment_charges.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.payment_charges TO gympro_payment_owner;


--
-- Name: TABLE payment_receipts; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.payment_receipts TO gympro_payment_owner;


--
-- Name: COLUMN payment_receipts.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.payment_receipts TO gympro_payment_owner;


--
-- Name: TABLE payment_reconciliations; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.payment_reconciliations TO gympro_payment_owner;


--
-- Name: TABLE payment_reversals; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.payment_reversals TO gympro_payment_owner;


--
-- Name: TABLE permissions; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.permissions TO gympro_introspect;


--
-- Name: COLUMN permissions.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id) ON TABLE app.permissions TO gympro_rbac_owner;


--
-- Name: COLUMN permissions.permission_code; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(permission_code) ON TABLE app.permissions TO gympro_rbac_owner;


--
-- Name: COLUMN permissions.is_active; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(is_active) ON TABLE app.permissions TO gympro_rbac_owner;


--
-- Name: TABLE plan_prices; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.plan_prices TO gympro_membership_owner;
GRANT SELECT ON TABLE app.plan_prices TO gympro_foc_owner;


--
-- Name: COLUMN plan_prices.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.plan_prices TO gympro_membership_owner;
GRANT UPDATE(id) ON TABLE app.plan_prices TO gympro_foc_owner;


--
-- Name: TABLE pos_sale_items; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.pos_sale_items TO gympro_pos_owner;
GRANT SELECT ON TABLE app.pos_sale_items TO gympro_pos_return_owner;


--
-- Name: TABLE pos_sale_return_items; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.pos_sale_return_items TO gympro_pos_return_owner;


--
-- Name: TABLE pos_sale_returns; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.pos_sale_returns TO gympro_pos_return_owner;
GRANT SELECT ON TABLE app.pos_sale_returns TO gympro_payment_owner;


--
-- Name: TABLE pos_sales; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE app.pos_sales TO gympro_pos_owner;
GRANT SELECT ON TABLE app.pos_sales TO gympro_pos_return_owner;
GRANT SELECT ON TABLE app.pos_sales TO gympro_payment_owner;


--
-- Name: COLUMN pos_sales.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT UPDATE(id) ON TABLE app.pos_sales TO gympro_pos_return_owner;
GRANT UPDATE(id) ON TABLE app.pos_sales TO gympro_payment_owner;


--
-- Name: TABLE role_assignments; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.role_assignments TO gympro_introspect;


--
-- Name: COLUMN role_assignments.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.role_assignments TO gympro_rbac_owner;


--
-- Name: COLUMN role_assignments.membership_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(membership_id) ON TABLE app.role_assignments TO gympro_rbac_owner;


--
-- Name: COLUMN role_assignments.role_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(role_id) ON TABLE app.role_assignments TO gympro_rbac_owner;


--
-- Name: COLUMN role_assignments.scope_type; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(scope_type) ON TABLE app.role_assignments TO gympro_rbac_owner;


--
-- Name: COLUMN role_assignments.branch_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(branch_id) ON TABLE app.role_assignments TO gympro_rbac_owner;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.role_permissions TO gympro_introspect;


--
-- Name: COLUMN role_permissions.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.role_permissions TO gympro_rbac_owner;


--
-- Name: COLUMN role_permissions.role_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(role_id) ON TABLE app.role_permissions TO gympro_rbac_owner;


--
-- Name: COLUMN role_permissions.permission_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(permission_id) ON TABLE app.role_permissions TO gympro_rbac_owner;


--
-- Name: TABLE roles; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.roles TO gympro_introspect;


--
-- Name: COLUMN roles.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id) ON TABLE app.roles TO gympro_rbac_owner;


--
-- Name: COLUMN roles.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.roles TO gympro_rbac_owner;


--
-- Name: COLUMN roles.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(status) ON TABLE app.roles TO gympro_rbac_owner;


--
-- Name: TABLE tenant_memberships; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.tenant_memberships TO gympro_introspect;


--
-- Name: COLUMN tenant_memberships.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id),UPDATE(id) ON TABLE app.tenant_memberships TO gympro_session_owner;
GRANT SELECT(id) ON TABLE app.tenant_memberships TO gympro_rbac_owner;
GRANT SELECT(id) ON TABLE app.tenant_memberships TO gympro_inventory_read_owner;


--
-- Name: COLUMN tenant_memberships.tenant_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(tenant_id) ON TABLE app.tenant_memberships TO gympro_session_owner;
GRANT SELECT(tenant_id) ON TABLE app.tenant_memberships TO gympro_rbac_owner;
GRANT SELECT(tenant_id) ON TABLE app.tenant_memberships TO gympro_inventory_read_owner;


--
-- Name: COLUMN tenant_memberships.user_id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(user_id) ON TABLE app.tenant_memberships TO gympro_session_owner;
GRANT SELECT(user_id) ON TABLE app.tenant_memberships TO gympro_rbac_owner;
GRANT SELECT(user_id) ON TABLE app.tenant_memberships TO gympro_inventory_read_owner;


--
-- Name: COLUMN tenant_memberships.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(status) ON TABLE app.tenant_memberships TO gympro_session_owner;
GRANT SELECT(status) ON TABLE app.tenant_memberships TO gympro_rbac_owner;


--
-- Name: TABLE users; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT ON TABLE app.users TO gympro_introspect;


--
-- Name: COLUMN users.id; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(id),UPDATE(id) ON TABLE app.users TO gympro_session_owner;
GRANT SELECT(id) ON TABLE app.users TO gympro_rbac_owner;
GRANT SELECT(id) ON TABLE app.users TO gympro_inventory_read_owner;


--
-- Name: COLUMN users.full_name; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(full_name) ON TABLE app.users TO gympro_inventory_read_owner;


--
-- Name: COLUMN users.status; Type: ACL; Schema: app; Owner: postgres
--

GRANT SELECT(status) ON TABLE app.users TO gympro_session_owner;
GRANT SELECT(status) ON TABLE app.users TO gympro_rbac_owner;


--
-- Name: TABLE tenants; Type: ACL; Schema: platform; Owner: postgres
--

GRANT SELECT ON TABLE platform.tenants TO gympro_introspect;


--
-- Name: COLUMN tenants.id; Type: ACL; Schema: platform; Owner: postgres
--

GRANT SELECT(id),UPDATE(id) ON TABLE platform.tenants TO gympro_session_owner;
GRANT SELECT(id) ON TABLE platform.tenants TO gympro_rbac_owner;


--
-- Name: COLUMN tenants.status; Type: ACL; Schema: platform; Owner: postgres
--

GRANT SELECT(status) ON TABLE platform.tenants TO gympro_session_owner;
GRANT SELECT(status) ON TABLE platform.tenants TO gympro_rbac_owner;


--
-- Name: COLUMN tenant_sessions.id; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(id) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- Name: COLUMN tenant_sessions.tenant_id; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(tenant_id),INSERT(tenant_id) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- Name: COLUMN tenant_sessions.membership_id; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(membership_id),INSERT(membership_id) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- Name: COLUMN tenant_sessions.session_token_hash; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(session_token_hash),INSERT(session_token_hash) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- Name: COLUMN tenant_sessions.expires_at; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(expires_at),INSERT(expires_at) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- Name: COLUMN tenant_sessions.revoked_at; Type: ACL; Schema: security; Owner: postgres
--

GRANT SELECT(revoked_at),UPDATE(revoked_at) ON TABLE security.tenant_sessions TO gympro_session_owner;


--
-- PostgreSQL database dump complete
--

\unrestrict ppruGTshysybdfqqc6YPIKDcit8uMxxYddaIE1ma0gTUTmMywC7GfKGG05G9feH

