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

    IF to_regclass('app.subscription_expirations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM pg_roles
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
        'security.expire_member_subscription(bytea,uuid,uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION 'Expiration function already exists. Inspect before retrying.';
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

GRANT SELECT, INSERT ON app.subscription_expirations
    TO gympro_membership_owner;

GRANT UPDATE (status, suspended_at, updated_at)
    ON app.member_subscriptions
    TO gympro_membership_owner;

CREATE POLICY expirations_membership_owner_select
    ON app.subscription_expirations
    FOR SELECT
    TO gympro_membership_owner
    USING (true);

CREATE POLICY expirations_membership_owner_insert
    ON app.subscription_expirations
    FOR INSERT
    TO gympro_membership_owner
    WITH CHECK (true);

CREATE FUNCTION security.expire_member_subscription(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_subscription_id uuid
)
RETURNS SETOF app.subscription_expirations
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

ALTER FUNCTION security.expire_member_subscription(
    bytea, uuid, uuid
)
OWNER TO gympro_membership_owner;

REVOKE ALL ON FUNCTION security.expire_member_subscription(
    bytea, uuid, uuid
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.expire_member_subscription(
    bytea, uuid, uuid
)
TO gympro_app;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.expire_member_subscription(bytea,uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime expiration function access is missing.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime must not have direct expiration history access.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.expire_member_subscription(
            decode(repeat('00', 32), 'hex'),
            NULL::uuid,
            NULL::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Runtime expiration function access verified.';
    RAISE NOTICE 'PASS: Direct expiration history access denied.';
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
    'security.expire_member_subscription(bytea,uuid,uuid)'
);