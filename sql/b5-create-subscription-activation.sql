\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Run this installation in gympro_saas as postgres.';
    END IF;

    IF to_regclass('app.member_subscriptions') IS NULL
       OR to_regprocedure(
           'security.verify_tenant_session(bytea)'
       ) IS NULL
       OR to_regprocedure(
           'security.has_tenant_permission(uuid,uuid,text,uuid)'
       ) IS NULL THEN
        RAISE EXCEPTION 'Required earlier objects are missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM app.permissions
        WHERE permission_code = 'gym.memberships.manage'
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Active gym.memberships.manage permission is missing.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'gympro_membership_owner'
    ) THEN
        RAISE EXCEPTION
            'Membership owner already exists. Inspect before retrying.';
    END IF;
END;
$$;

CREATE ROLE gympro_membership_owner
    NOLOGIN
    NOINHERIT
    NOSUPERUSER
    NOBYPASSRLS
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;

GRANT USAGE ON SCHEMA app, security
    TO gympro_membership_owner;

GRANT EXECUTE ON FUNCTION
    security.verify_tenant_session(bytea)
    TO gympro_membership_owner;

GRANT EXECUTE ON FUNCTION
    security.has_tenant_permission(uuid, uuid, text, uuid)
    TO gympro_membership_owner;

GRANT SELECT ON
    app.members,
    app.membership_plans,
    app.plan_prices,
    app.member_subscriptions
    TO gympro_membership_owner;

GRANT INSERT ON app.member_subscriptions
    TO gympro_membership_owner;

GRANT UPDATE (status, updated_at) ON app.members
    TO gympro_membership_owner;

-- PostgreSQL row locks require UPDATE privilege.
-- These column grants are only for the non-login function owner.
GRANT UPDATE (id) ON app.membership_plans, app.plan_prices
    TO gympro_membership_owner;

CREATE POLICY members_membership_owner_select
    ON app.members
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY members_membership_owner_update
    ON app.members
    FOR UPDATE
    TO gympro_membership_owner
    USING (true)
    WITH CHECK (true);

CREATE POLICY plans_membership_owner_select
    ON app.membership_plans
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY plans_membership_owner_lock
    ON app.membership_plans
    FOR UPDATE
    TO gympro_membership_owner
    USING (true)
    WITH CHECK (true);

CREATE POLICY prices_membership_owner_select
    ON app.plan_prices
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY prices_membership_owner_lock
    ON app.plan_prices
    FOR UPDATE
    TO gympro_membership_owner
    USING (true)
    WITH CHECK (true);

CREATE POLICY subscriptions_membership_owner_select
    ON app.member_subscriptions
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY subscriptions_membership_owner_insert
    ON app.member_subscriptions
    FOR INSERT
    TO gympro_membership_owner
    WITH CHECK (true);

CREATE FUNCTION security.activate_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
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

ALTER FUNCTION security.activate_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
OWNER TO gympro_membership_owner;

REVOKE ALL ON FUNCTION security.activate_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
FROM PUBLIC;

GRANT USAGE ON SCHEMA security TO gympro_app;

GRANT EXECUTE ON FUNCTION security.activate_member_subscription(
    bytea, uuid, uuid, uuid, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_role record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO v_role
    FROM pg_roles
    WHERE rolname = 'gympro_membership_owner';

    IF v_role.rolcanlogin
       OR v_role.rolsuper
       OR v_role.rolbypassrls
       OR v_role.rolcreatedb
       OR v_role.rolcreaterole
       OR v_role.rolreplication
       OR v_role.rolinherit THEN
        RAISE EXCEPTION 'Unsafe membership owner role configuration.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_auth_members
        WHERE roleid = v_role.oid
           OR member = v_role.oid
    ) THEN
        RAISE EXCEPTION 'Membership owner must have no role memberships.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_app',
        'security.activate_member_subscription(bytea,uuid,uuid,uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime activation function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime must not have direct subscription access.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.activate_member_subscription(
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

    RAISE NOTICE 'PASS: Owner role restrictions verified.';
    RAISE NOTICE 'PASS: Runtime function access verified.';
    RAISE NOTICE 'PASS: Direct subscription access denied.';
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
    'security.activate_member_subscription(bytea,uuid,uuid,uuid,uuid)'
);