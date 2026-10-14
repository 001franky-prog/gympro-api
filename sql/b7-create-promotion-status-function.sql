\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

GRANT UPDATE (status, updated_at)
    ON app.membership_promotions
    TO gympro_promotion_owner;

CREATE POLICY promotion_owner_status_update
    ON app.membership_promotions
    FOR UPDATE TO gympro_promotion_owner
    USING (true)
    WITH CHECK (true);

GRANT CREATE ON SCHEMA security TO gympro_promotion_owner;

CREATE FUNCTION security.set_membership_promotion_status(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_promotion_id uuid,
    p_status text
)
RETURNS SETOF app.membership_promotions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
SET timezone = 'Asia/Yangon'
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

ALTER FUNCTION security.set_membership_promotion_status(
    bytea,uuid,uuid,text
) OWNER TO gympro_promotion_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_promotion_owner;

REVOKE ALL ON FUNCTION security.set_membership_promotion_status(
    bytea,uuid,uuid,text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.set_membership_promotion_status(
    bytea,uuid,uuid,text
) TO gympro_app;

DO $$
BEGIN
    IF NOT has_function_privilege(
        'gympro_app',
        'security.set_membership_promotion_status(bytea,uuid,uuid,text)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.membership_promotions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime function-only boundary failed.';
    END IF;

    IF has_column_privilege(
        'gympro_promotion_owner',
        'app.membership_promotions',
        'discount_value',
        'UPDATE'
    ) OR has_column_privilege(
        'gympro_promotion_owner',
        'app.membership_promotions',
        'tenant_id',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION 'Owner has unexpected promotion update privileges.';
    END IF;

    RAISE NOTICE 'PASS: Runtime function-only status access verified.';
    RAISE NOTICE 'PASS: Owner cannot update discount values or tenant identity.';
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
  AND p.proname = 'set_membership_promotion_status';