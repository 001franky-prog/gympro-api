\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_context AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS role_id,
    decode(
        md5(gen_random_uuid()::text) ||
        md5(gen_random_uuid()::text),
        'hex'
    ) AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    'B7_' || left(
        upper(replace(gen_random_uuid()::text, '-', '')), 20
    ) AS code;

CREATE TEMP TABLE b7_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id,
    session_token_hash, expires_at
)
SELECT
    session_id, tenant_id, membership_id,
    token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b7_context;

GRANT SELECT ON b7_context TO gympro_app;
GRANT SELECT, INSERT ON b7_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_context;

    BEGIN
        PERFORM * FROM security.create_membership_promotion(
            v.token_hash, v.tenant_id,
            v.code, 'Permission denial fixture', NULL,
            NULL, NULL, 'percentage', 10,
            DATE '2026-10-14', NULL
        );
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM <> 'Promotion management permission denied' THEN
                RAISE;
            END IF;
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Missing permission was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_results
    VALUES ('01_missing_permission_rejected', 'PASS');
END;
$$;

RESET ROLE;

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT
    role_id, tenant_id, code,
    'B7 transaction-only promotion role', false, 'active'
FROM b7_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.promotions.manage'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_context;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_row record;
    v_case record;
    v_state text;
    v_expected text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_context;

    SELECT * INTO STRICT v_row
    FROM security.create_membership_promotion(
        v.token_hash, v.tenant_id,
        ' ' || v.code || ' ', ' B7 percentage promotion ',
        ' Test description ',
        NULL, NULL, 'percentage', 10.25,
        DATE '2026-10-14', DATE '2026-11-14'
    );

    IF v_row.tenant_id <> v.tenant_id
       OR v_row.promotion_code <> v.code
       OR v_row.promotion_name <> 'B7 percentage promotion'
       OR v_row.description <> 'Test description'
       OR v_row.discount_value <> 10.25
       OR v_row.discount_kind <> 'percentage'
       OR v_row.status <> 'draft'
       OR v_row.currency_code <> 'MMK'
       OR v_row.plan_id IS NOT NULL
       OR v_row.branch_id IS NOT NULL THEN
        RAISE EXCEPTION 'Created promotion values mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_results
    VALUES ('02_percentage_creation_and_normalization', 'PASS');

    SELECT * INTO STRICT v_row
    FROM security.create_membership_promotion(
        v.token_hash, v.tenant_id,
        v.code || '_F', 'B7 scoped fixed promotion', '   ',
        '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
        'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid,
        'fixed_amount', 5000,
        DATE '2026-10-14', NULL
    );

    IF v_row.status <> 'draft'
       OR v_row.discount_value <> 5000
       OR v_row.description IS NOT NULL
       OR v_row.ends_on IS NOT NULL
       OR v_row.plan_id <>
            '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid
       OR v_row.branch_id <>
            'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid THEN
        RAISE EXCEPTION 'Scoped promotion values mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_results
    VALUES ('03_scoped_fixed_amount_creation', 'PASS');

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('04_unknown_session', 'session'),
            ('05_wrong_tenant', 'tenant'),
            ('06_duplicate_code', 'duplicate'),
            ('07_invalid_code', 'code'),
            ('08_short_name', 'name'),
            ('09_zero_discount', 'zero'),
            ('10_percentage_above_100', 'above'),
            ('11_excess_decimal_precision', 'precision'),
            ('12_nan_discount', 'nan'),
            ('13_reversed_dates', 'dates'),
            ('14_unknown_plan', 'plan'),
            ('15_unknown_branch', 'branch')
        ) AS cases(test_name, kind)
    LOOP
        v_state := NULL;
        v_expected := CASE
            WHEN v_case.kind = 'session' THEN '28000'
            WHEN v_case.kind = 'tenant' THEN '42501'
            ELSE '22023'
        END;

        BEGIN
            PERFORM * FROM security.create_membership_promotion(
                CASE WHEN v_case.kind = 'session'
                    THEN decode(repeat('00', 32), 'hex')
                    ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                    THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                    ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'duplicate' THEN v.code
                     WHEN v_case.kind = 'code' THEN 'bad-code'
                     ELSE v.code || '_X' END,
                CASE WHEN v_case.kind = 'name' THEN 'A'
                     ELSE 'B7 rejection fixture' END,
                NULL,
                CASE WHEN v_case.kind = 'plan'
                     THEN gen_random_uuid() ELSE NULL END,
                CASE WHEN v_case.kind = 'branch'
                     THEN gen_random_uuid() ELSE NULL END,
                'percentage',
                CASE WHEN v_case.kind = 'zero' THEN 0::numeric
                     WHEN v_case.kind = 'above' THEN 100.01::numeric
                     WHEN v_case.kind = 'precision' THEN 10.001::numeric
                     WHEN v_case.kind = 'nan' THEN 'NaN'::numeric
                     ELSE 10::numeric END,
                DATE '2026-10-14',
                CASE WHEN v_case.kind = 'dates'
                     THEN DATE '2026-10-13' ELSE NULL END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        -- Invalid branch may be denied by the permission resolver first.
        IF v_case.kind = 'branch' AND v_state = '42501' THEN
            v_expected := '42501';
        END IF;

        IF v_state IS DISTINCT FROM v_expected THEN
            RAISE EXCEPTION
                'Test %: expected SQLSTATE %, received %',
                v_case.test_name, v_expected, v_state;
        END IF;

        INSERT INTO pg_temp.b7_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    BEGIN
        PERFORM 1 FROM app.membership_promotions LIMIT 1;
        RAISE EXCEPTION 'Runtime direct SELECT unexpectedly succeeded.';
    EXCEPTION
        WHEN insufficient_privilege THEN
            INSERT INTO pg_temp.b7_results
            VALUES ('16_direct_select_denied', 'PASS');
    END;
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
    v_count integer;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_context;

    SELECT count(*) INTO v_count
    FROM app.membership_promotions
    WHERE tenant_id = v.tenant_id
      AND promotion_code IN (v.code, v.code || '_F', v.code || '_X');

    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Rejected requests saved unexpected promotions.';
    END IF;

    INSERT INTO pg_temp.b7_results
    VALUES ('17_rejections_saved_nothing', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_results
ORDER BY test_name;

-- Preserve identifiers in psql variables, outside transaction rollback.
SELECT
    code AS fixture_code,
    role_id::text AS fixture_role,
    session_id::text AS fixture_session
FROM b7_context
\gset b7_

ROLLBACK;

SELECT
    'promotion_function_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE promotion_code IN (
                :'b7_fixture_code',
                :'b7_fixture_code' || '_F',
                :'b7_fixture_code' || '_X'
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles
            WHERE id = :'b7_fixture_role'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b7_fixture_session'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7_fixture_code
\unset b7_fixture_role
\unset b7_fixture_session