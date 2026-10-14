\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_calc_context AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS percentage_id,
    gen_random_uuid() AS fixed_id,
    gen_random_uuid() AS future_id,
    gen_random_uuid() AS ended_id,
    gen_random_uuid() AS draft_id,
    gen_random_uuid() AS scoped_id,
    decode(
        md5(gen_random_uuid()::text) ||
        md5(gen_random_uuid()::text), 'hex'
    ) AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid AS branch_id;

CREATE TEMP TABLE b7_calc_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b7_calc_context;

INSERT INTO app.membership_promotions (
    id, tenant_id, promotion_code, promotion_name,
    plan_id, branch_id, discount_kind, discount_value,
    starts_on, ends_on, status
)
SELECT
    f.id, c.tenant_id,
    'B7C_' || left(upper(replace(f.id::text, '-', '')), 20),
    'B7 calculator fixture',
    CASE WHEN f.kind = 'scoped' THEN c.plan_id ELSE NULL END,
    CASE WHEN f.kind = 'scoped' THEN c.branch_id ELSE NULL END,
    CASE WHEN f.kind = 'fixed' THEN 'fixed_amount' ELSE 'percentage' END,
    CASE WHEN f.kind = 'fixed' THEN 60000 ELSE 10.25 END,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date
        + CASE WHEN f.kind = 'future' THEN 1 ELSE -1 END,
    CASE WHEN f.kind = 'ended'
         THEN (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date
         ELSE NULL END,
    CASE WHEN f.kind = 'draft' THEN 'draft' ELSE 'active' END
FROM b7_calc_context c
CROSS JOIN LATERAL (
    VALUES
        (c.percentage_id, 'percentage'),
        (c.fixed_id, 'fixed'),
        (c.future_id, 'future'),
        (c.ended_id, 'ended'),
        (c.draft_id, 'draft'),
        (c.scoped_id, 'scoped')
) f(id, kind);

GRANT SELECT ON b7_calc_context TO gympro_membership_owner;
GRANT SELECT, INSERT ON b7_calc_results TO gympro_membership_owner;

SET LOCAL ROLE gympro_membership_owner;

DO $$
DECLARE
    v record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_calc_context;

    BEGIN
        PERFORM * FROM security.calculate_membership_discount(
            v.token_hash, v.tenant_id, v.plan_id,
            NULL, 50000, v.percentage_id
        );
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM <> 'Membership discount permission denied' THEN
                RAISE;
            END IF;
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Discount permission was not required.';
    END IF;

    INSERT INTO pg_temp.b7_calc_results
    VALUES ('01_management_alone_cannot_apply_discount', 'PASS');
END;
$$;

RESET ROLE;

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT
    role_id, tenant_id,
    'B7C_' || left(upper(replace(role_id::text, '-', '')), 20),
    'B7 transaction-only discount role', false, 'active'
FROM b7_calc_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_calc_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.apply_discount'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_calc_context;

SET LOCAL ROLE gympro_membership_owner;

DO $$
DECLARE
    v record;
    v_result record;
    v_case record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_calc_context;

    SELECT * INTO STRICT v_result
    FROM security.calculate_membership_discount(
        v.token_hash, v.tenant_id, v.plan_id,
        NULL, 50000, v.percentage_id
    );

    IF v_result.discount_amount <> 5125
       OR v_result.agreed_price_amount <> 44875
       OR (v_result.promotion_snapshot->>'id')::uuid <> v.percentage_id
       OR (v_result.actor_snapshot->>'membership_id')::uuid <> v.membership_id
       OR (v_result.actor_snapshot->>'session_id')::uuid <> v.session_id THEN
        RAISE EXCEPTION 'Percentage calculation or snapshot mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_calc_results
    VALUES ('02_percentage_and_actor_snapshot', 'PASS');

    SELECT * INTO STRICT v_result
    FROM security.calculate_membership_discount(
        v.token_hash, v.tenant_id, v.plan_id,
        NULL, 99.99, v.percentage_id
    );

    IF v_result.discount_amount <> 10.25
       OR v_result.agreed_price_amount <> 89.74 THEN
        RAISE EXCEPTION 'Percentage rounding failed.';
    END IF;

    INSERT INTO pg_temp.b7_calc_results
    VALUES ('03_percentage_rounding', 'PASS');

    SELECT * INTO STRICT v_result
    FROM security.calculate_membership_discount(
        v.token_hash, v.tenant_id, v.plan_id,
        NULL, 50000, v.fixed_id
    );

    IF v_result.discount_amount <> 50000
       OR v_result.agreed_price_amount <> 0 THEN
        RAISE EXCEPTION 'Fixed discount cap failed.';
    END IF;

    INSERT INTO pg_temp.b7_calc_results
    VALUES ('04_fixed_discount_capped_at_price', 'PASS');

    SELECT * INTO STRICT v_result
    FROM security.calculate_membership_discount(
        v.token_hash, v.tenant_id, v.plan_id,
        v.branch_id, 50000, v.scoped_id
    );

    IF v_result.discount_amount <> 5125 THEN
        RAISE EXCEPTION 'Matching scoped promotion failed.';
    END IF;

    INSERT INTO pg_temp.b7_calc_results
    VALUES ('05_matching_plan_and_branch', 'PASS');

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('06_unknown_session', 'session', '28000'),
            ('07_wrong_tenant', 'tenant', '42501'),
            ('08_future_promotion', 'future', '22023'),
            ('09_ended_promotion', 'ended', '22023'),
            ('10_draft_promotion', 'draft', '22023'),
            ('11_wrong_plan', 'plan', '22023'),
            ('12_wrong_branch', 'branch', '22023'),
            ('13_unknown_promotion', 'unknown', '22023'),
            ('14_negative_price', 'negative', '22023'),
            ('15_excess_price_precision', 'precision', '22023')
        ) AS cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;

        BEGIN
            PERFORM * FROM security.calculate_membership_discount(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'plan'
                     THEN gen_random_uuid() ELSE v.plan_id END,
                CASE WHEN v_case.kind = 'plan'
                     THEN v.branch_id ELSE NULL END,
                CASE WHEN v_case.kind = 'negative' THEN -1::numeric
                     WHEN v_case.kind = 'precision' THEN 50.001::numeric
                     ELSE 50000::numeric END,
                CASE WHEN v_case.kind = 'future' THEN v.future_id
                     WHEN v_case.kind = 'ended' THEN v.ended_id
                     WHEN v_case.kind = 'draft' THEN v.draft_id
                     WHEN v_case.kind IN ('plan', 'branch') THEN v.scoped_id
                     WHEN v_case.kind = 'unknown' THEN gen_random_uuid()
                     ELSE v.percentage_id END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b7_calc_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;
END;
$$;

RESET ROLE;

DO $$
BEGIN
    IF has_function_privilege(
        'gympro_app',
        'security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'Runtime can call the internal calculator.';
    END IF;

    INSERT INTO b7_calc_results
    VALUES ('16_runtime_calculator_access_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_calc_results
ORDER BY test_name;

SELECT
    session_id::text AS session_id,
    role_id::text AS role_id,
    percentage_id::text AS percentage_id,
    fixed_id::text AS fixed_id,
    future_id::text AS future_id,
    ended_id::text AS ended_id,
    draft_id::text AS draft_id,
    scoped_id::text AS scoped_id
FROM b7_calc_context
\gset b7c_

ROLLBACK;

SELECT
    'calculator_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id IN (
                :'b7c_percentage_id'::uuid, :'b7c_fixed_id'::uuid,
                :'b7c_future_id'::uuid, :'b7c_ended_id'::uuid,
                :'b7c_draft_id'::uuid, :'b7c_scoped_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b7c_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b7c_session_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7c_session_id
\unset b7c_role_id
\unset b7c_percentage_id
\unset b7c_fixed_id
\unset b7c_future_id
\unset b7c_ended_id
\unset b7c_draft_id
\unset b7c_scoped_id