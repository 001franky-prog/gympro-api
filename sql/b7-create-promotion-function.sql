\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF to_regclass('app.membership_promotions') IS NULL THEN
        RAISE EXCEPTION 'Promotion schema is missing.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'gympro_promotion_owner'
    ) THEN
        RAISE EXCEPTION
            'Promotion owner already exists. Inspect before rerunning.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.promotions.manage'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Active promotion management permission missing.';
    END IF;
END;
$$;

CREATE ROLE gympro_promotion_owner
    NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS
    NOCREATEDB NOCREATEROLE NOREPLICATION;

GRANT USAGE ON SCHEMA app, security TO gympro_promotion_owner;
GRANT CREATE ON SCHEMA security TO gympro_promotion_owner;

GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea)
    TO gympro_promotion_owner;

GRANT EXECUTE ON FUNCTION
    security.has_tenant_permission(uuid,uuid,text,uuid)
    TO gympro_promotion_owner;

GRANT SELECT, INSERT ON app.membership_promotions
    TO gympro_promotion_owner;

GRANT SELECT ON app.membership_plans, app.branches
    TO gympro_promotion_owner;

CREATE POLICY promotion_owner_read
    ON app.membership_promotions
    FOR SELECT TO gympro_promotion_owner
    USING (true);

CREATE POLICY promotion_owner_insert
    ON app.membership_promotions
    FOR INSERT TO gympro_promotion_owner
    WITH CHECK (true);

CREATE POLICY promotion_owner_plan_read
    ON app.membership_plans
    FOR SELECT TO gympro_promotion_owner
    USING (true);

CREATE POLICY promotion_owner_branch_read
    ON app.branches
    FOR SELECT TO gympro_promotion_owner
    USING (true);

CREATE FUNCTION security.create_membership_promotion(
    p_token_hash bytea,
    p_tenant_id uuid,
    p_promotion_code text,
    p_promotion_name text,
    p_description text,
    p_plan_id uuid,
    p_branch_id uuid,
    p_discount_kind text,
    p_discount_value numeric,
    p_starts_on date,
    p_ends_on date
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
$$;

ALTER FUNCTION security.create_membership_promotion(
    bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date
) OWNER TO gympro_promotion_owner;

REVOKE CREATE ON SCHEMA security FROM gympro_promotion_owner;

REVOKE ALL ON FUNCTION security.create_membership_promotion(
    bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION security.create_membership_promotion(
    bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date
) TO gympro_app;

DO $$
DECLARE
    v_rejected boolean := false;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'gympro_promotion_owner'
          AND (
              rolcanlogin OR rolsuper OR rolbypassrls
              OR rolcreatedb OR rolcreaterole OR rolreplication
              OR rolinherit
          )
    ) OR EXISTS (
        SELECT 1
        FROM pg_auth_members am
        JOIN pg_roles r ON r.oid = am.member OR r.oid = am.roleid
        WHERE r.rolname = 'gympro_promotion_owner'
    ) THEN
        RAISE EXCEPTION 'Promotion owner restrictions failed.';
    END IF;

    IF has_schema_privilege(
        'gympro_promotion_owner', 'security', 'CREATE'
    ) THEN
        RAISE EXCEPTION 'Owner retains schema CREATE privilege.';
    END IF;

    IF NOT has_function_privilege(
        'gympro_app',
        'security.create_membership_promotion(bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date)',
        'EXECUTE'
    ) OR has_table_privilege(
        'gympro_app',
        'app.membership_promotions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime function-only boundary failed.';
    END IF;

    BEGIN
        PERFORM *
        FROM security.create_membership_promotion(
            decode(repeat('00', 32), 'hex'),
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            'B7_INVALID_SESSION',
            'Invalid session fixture',
            NULL::text,
            NULL::uuid,
            NULL::uuid,
            'percentage',
            10::numeric,
            CURRENT_DATE,
            NULL::date
        );
    EXCEPTION
        WHEN SQLSTATE '28000' THEN
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was not rejected.';
    END IF;

    RAISE NOTICE 'PASS: Restricted promotion owner verified.';
    RAISE NOTICE 'PASS: Runtime function-only access verified.';
    RAISE NOTICE 'PASS: Invalid session rejected.';
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
  AND p.proname = 'create_membership_promotion';