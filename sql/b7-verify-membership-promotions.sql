\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_promotion_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
    v_tenant uuid := 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
    v_other_tenant uuid := 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
    v_plan uuid := '838d86b2-9665-414d-865a-8f5fb559e39c';
    v_branch uuid := 'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c';
    v_code text := 'B7_TEST_' || upper(replace(gen_random_uuid()::text, '-', ''));
    v_row app.membership_promotions%ROWTYPE;
    v_rejected boolean;
    v_case record;
BEGIN
    -- Keep fixture codes within varchar(32).
    v_code := left(v_code, 28);

    INSERT INTO app.membership_promotions (
        tenant_id, promotion_code, promotion_name,
        discount_kind, discount_value, starts_on
    )
    VALUES (
        v_tenant, v_code, 'B7 percentage fixture',
        'percentage', 10, DATE '2026-10-14'
    )
    RETURNING * INTO v_row;

    IF v_row.status <> 'draft'
       OR v_row.currency_code <> 'MMK'
       OR v_row.plan_id IS NOT NULL
       OR v_row.branch_id IS NOT NULL
       OR v_row.ends_on IS NOT NULL
       OR v_row.created_at IS NULL
       OR v_row.updated_at IS NULL THEN
        RAISE EXCEPTION 'Promotion defaults failed.';
    END IF;

    INSERT INTO b7_promotion_results
    VALUES ('01_percentage_defaults', 'PASS');

    INSERT INTO app.membership_promotions (
        tenant_id, promotion_code, promotion_name,
        plan_id, branch_id,
        discount_kind, discount_value,
        starts_on, ends_on, status
    )
    VALUES (
        v_tenant, v_code || '_F', 'B7 fixed amount fixture',
        v_plan, v_branch,
        'fixed_amount', 5000,
        DATE '2026-10-14', DATE '2026-11-14', 'active'
    );

    INSERT INTO b7_promotion_results
    VALUES ('02_fixed_amount_plan_and_branch', 'PASS');

    INSERT INTO app.membership_promotions (
        tenant_id, promotion_code, promotion_name,
        discount_kind, discount_value, starts_on
    )
    VALUES (
        v_tenant, v_code || '_P', 'B7 full percentage fixture',
        'percentage', 100, DATE '2026-10-14'
    );

    INSERT INTO b7_promotion_results
    VALUES ('03_percentage_100_boundary', 'PASS');

    FOR v_case IN
        SELECT *
        FROM (
            VALUES
                ('04_zero_discount_rejected', 'percentage', 0::numeric),
                ('05_negative_discount_rejected', 'fixed_amount', -1::numeric),
                ('06_percentage_above_100_rejected', 'percentage', 100.01::numeric),
                ('07_invalid_discount_kind_rejected', 'unknown', 10::numeric),
                ('08_nan_discount_rejected', 'percentage', 'NaN'::numeric)
        ) AS cases(test_name, kind, amount)
    LOOP
        v_rejected := false;

        BEGIN
            INSERT INTO app.membership_promotions (
                tenant_id, promotion_code, promotion_name,
                discount_kind, discount_value, starts_on
            )
            VALUES (
                v_tenant, v_code || '_X', 'B7 invalid discount fixture',
                v_case.kind, v_case.amount, DATE '2026-10-14'
            );
        EXCEPTION
            WHEN check_violation THEN
                v_rejected := true;
        END;

        IF NOT v_rejected THEN
            RAISE EXCEPTION 'Expected rejection: %', v_case.test_name;
        END IF;

        INSERT INTO b7_promotion_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    FOR v_case IN
        SELECT *
        FROM (
            VALUES
                ('09_duplicate_code_rejected', 'duplicate'),
                ('10_padded_code_rejected', 'padded'),
                ('11_invalid_currency_rejected', 'currency'),
                ('12_reversed_dates_rejected', 'dates'),
                ('13_infinite_start_rejected', 'infinite'),
                ('14_other_tenant_plan_rejected', 'plan'),
                ('15_other_tenant_branch_rejected', 'branch'),
                ('16_invalid_status_rejected', 'status')
        ) AS cases(test_name, kind)
    LOOP
        v_rejected := false;

        BEGIN
            INSERT INTO app.membership_promotions (
                tenant_id, promotion_code, promotion_name,
                plan_id, branch_id,
                discount_kind, discount_value, currency_code,
                starts_on, ends_on, status
            )
            VALUES (
                CASE WHEN v_case.kind IN ('plan', 'branch')
                     THEN v_other_tenant ELSE v_tenant END,
                CASE WHEN v_case.kind = 'duplicate' THEN v_code
                     WHEN v_case.kind = 'padded' THEN ' PADDED '
                     ELSE v_code || '_X' END,
                'B7 invalid fixture',
                CASE WHEN v_case.kind = 'plan' THEN v_plan ELSE NULL END,
                CASE WHEN v_case.kind = 'branch' THEN v_branch ELSE NULL END,
                'percentage', 10,
                CASE WHEN v_case.kind = 'currency' THEN 'USD' ELSE 'MMK' END,
                CASE WHEN v_case.kind = 'infinite'
                     THEN 'infinity'::date ELSE DATE '2026-10-14' END,
                CASE WHEN v_case.kind = 'dates'
                     THEN DATE '2026-10-13' ELSE NULL END,
                CASE WHEN v_case.kind = 'status'
                     THEN 'unknown' ELSE 'draft' END
            );
        EXCEPTION
            WHEN unique_violation THEN
                IF v_case.kind <> 'duplicate' THEN RAISE; END IF;
                v_rejected := true;
            WHEN check_violation THEN
                IF v_case.kind NOT IN (
                    'padded', 'currency', 'dates', 'infinite', 'status'
                ) THEN RAISE; END IF;
                v_rejected := true;
            WHEN foreign_key_violation THEN
                IF v_case.kind NOT IN ('plan', 'branch') THEN RAISE; END IF;
                v_rejected := true;
        END;

        IF NOT v_rejected THEN
            RAISE EXCEPTION 'Expected rejection: %', v_case.test_name;
        END IF;

        INSERT INTO b7_promotion_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    IF has_table_privilege(
        'gympro_app', 'app.membership_promotions',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime has direct promotion privileges.';
    END IF;

    INSERT INTO b7_promotion_results
    VALUES ('17_runtime_direct_access_denied', 'PASS');

    IF EXISTS (
        SELECT 1
        FROM app.role_permissions rp
        JOIN app.permissions p ON p.id = rp.permission_id
        WHERE p.permission_code IN (
            'gym.promotions.manage',
            'gym.memberships.apply_discount'
        )
    ) THEN
        RAISE EXCEPTION 'New permissions have already been assigned to roles.';
    END IF;

    INSERT INTO b7_promotion_results
    VALUES ('18_permissions_not_implicitly_assigned', 'PASS');

    -- Save exact fixture identifiers for the post-rollback check.
    PERFORM set_config(
        'gympro.b7_fixture_code', v_code, false
    );
END;
$$;

SELECT test_name, result
FROM b7_promotion_results
ORDER BY test_name;

ROLLBACK;

SELECT
    'promotion_fixture_rollback_test' AS test_name,
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM app.membership_promotions
WHERE promotion_code IN (
    current_setting('gympro.b7_fixture_code'),
    current_setting('gympro.b7_fixture_code') || '_F',
    current_setting('gympro.b7_fixture_code') || '_P',
    current_setting('gympro.b7_fixture_code') || '_X'
);