\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_discount_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

CREATE TEMP TABLE b7_discount_context AS
SELECT
    gen_random_uuid() AS promotion_id,
    gen_random_uuid() AS activation_request,
    gen_random_uuid() AS renewal_request,
    gen_random_uuid() AS other_subscription_id;

DO $$
DECLARE
    v record;
    v_tenant uuid := 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
    v_subscription uuid := '8a28fa97-e41f-4053-be61-8162ff3d387d';
    v_renewal uuid := 'd64de483-cc72-4bd6-84ed-6f131f0a724d';
    v_row app.membership_discounts%ROWTYPE;
    v_case record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_discount_context;

    IF NOT EXISTS (
        SELECT 1 FROM app.subscription_renewals
        WHERE tenant_id = v_tenant
          AND subscription_id = v_subscription
          AND id = v_renewal
    ) THEN
        RAISE EXCEPTION 'Expected demo renewal receipt is missing.';
    END IF;

    INSERT INTO app.membership_promotions (
        id, tenant_id, promotion_code, promotion_name,
        discount_kind, discount_value, starts_on
    )
    VALUES (
        v.promotion_id, v_tenant,
        'B7D_' || left(
            upper(replace(v.promotion_id::text, '-', '')), 20
        ),
        'B7 discount history fixture',
        'percentage', 10, DATE '2026-10-14'
    );

    -- Separate pending subscription to test renewal/subscription mismatch.
    INSERT INTO app.member_subscriptions (
        id, tenant_id, member_id, branch_id,
        plan_id, plan_price_id,
        duration_value, duration_unit,
        agreed_price_amount, currency_code
    )
    VALUES (
        v.other_subscription_id,
        v_tenant,
        '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid,
        'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid,
        '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
        'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
        1, 'months', 50000, 'MMK'
    );

    INSERT INTO app.membership_discounts (
        tenant_id, subscription_id, promotion_id, request_id,
        purchase_kind,
        listed_price_amount, discount_amount, agreed_price_amount,
        promotion_snapshot, actor_snapshot
    )
    VALUES (
        v_tenant, v_subscription, v.promotion_id, v.activation_request,
        'activation',
        50000, 5000, 45000,
        '{"discount_kind":"percentage","discount_value":10}'::jsonb,
        '{"test_actor":"rollback_fixture"}'::jsonb
    )
    RETURNING * INTO v_row;

    IF v_row.currency_code <> 'MMK'
       OR v_row.renewal_id IS NOT NULL
       OR v_row.applied_at IS NULL
       OR v_row.created_at IS NULL
       OR v_row.agreed_price_amount <> 45000 THEN
        RAISE EXCEPTION 'Discount history defaults failed.';
    END IF;

    INSERT INTO b7_discount_results
    VALUES ('01_activation_history_and_defaults', 'PASS');

    INSERT INTO app.membership_discounts (
        tenant_id, subscription_id, promotion_id, request_id,
        purchase_kind, renewal_id,
        listed_price_amount, discount_amount, agreed_price_amount,
        promotion_snapshot, actor_snapshot
    )
    VALUES (
        v_tenant, v_subscription, v.promotion_id, v.renewal_request,
        'renewal', v_renewal,
        50000, 5000, 45000,
        '{"discount_kind":"percentage","discount_value":10}'::jsonb,
        '{"test_actor":"rollback_fixture"}'::jsonb
    );

    INSERT INTO b7_discount_results
    VALUES ('02_renewal_history_relationship', 'PASS');

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('03_duplicate_request_rejected', 'request', '23505'),
            ('04_duplicate_activation_rejected', 'activation', '23505'),
            ('05_duplicate_renewal_rejected', 'renewal', '23505'),
            ('06_negative_discount_rejected', 'negative', '23514'),
            ('07_discount_above_price_rejected', 'excess', '23514'),
            ('08_incorrect_final_price_rejected', 'arithmetic', '23514'),
            ('09_invalid_currency_rejected', 'currency', '23514'),
            ('10_missing_renewal_rejected', 'missing_renewal', '23514'),
            ('11_empty_promotion_snapshot_rejected', 'empty', '23514'),
            ('12_array_actor_snapshot_rejected', 'array', '23514'),
            ('13_infinite_timestamp_rejected', 'infinite', '23514'),
            ('14_unknown_promotion_rejected', 'promotion', '23503'),
            ('15_other_tenant_rejected', 'tenant', '23503'),
            ('16_renewal_subscription_mismatch_rejected', 'mismatch', '23503')
        ) AS cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;

            BEGIN
            -- Remove the conflicting fixture receipt for this test only.
            -- The expected exception rolls this deletion back automatically.
            IF v_case.kind = 'mismatch' THEN
                DELETE FROM app.membership_discounts
                WHERE tenant_id = v_tenant
                  AND request_id = v.renewal_request;
            END IF;

            INSERT INTO app.membership_discounts (
                tenant_id, subscription_id, promotion_id, request_id,
                purchase_kind, renewal_id,
                listed_price_amount, discount_amount, agreed_price_amount,
                currency_code, promotion_snapshot, actor_snapshot,
                applied_at
            )
            VALUES (
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v_tenant END,
                CASE WHEN v_case.kind IN (
                        'request', 'activation', 'renewal', 'tenant'
                     )
                     THEN v_subscription
                     ELSE v.other_subscription_id END,
                CASE WHEN v_case.kind = 'promotion'
                     THEN gen_random_uuid() ELSE v.promotion_id END,
                CASE WHEN v_case.kind = 'request'
                     THEN v.activation_request ELSE gen_random_uuid() END,
                CASE WHEN v_case.kind IN (
                        'renewal', 'missing_renewal', 'mismatch'
                     )
                     THEN 'renewal' ELSE 'activation' END,
                CASE WHEN v_case.kind IN ('renewal', 'mismatch')
                     THEN v_renewal ELSE NULL END,
                50000,
                CASE WHEN v_case.kind = 'negative' THEN -1
                     WHEN v_case.kind = 'excess' THEN 50001
                     ELSE 5000 END,
                CASE WHEN v_case.kind = 'negative' THEN 50001
                     WHEN v_case.kind = 'excess' THEN -1
                     WHEN v_case.kind = 'arithmetic' THEN 44000
                     ELSE 45000 END,
                CASE WHEN v_case.kind = 'currency'
                     THEN 'USD' ELSE 'MMK' END,
                CASE WHEN v_case.kind = 'empty'
                     THEN '{}'::jsonb ELSE '{"fixture":true}'::jsonb END,
                CASE WHEN v_case.kind = 'array'
                     THEN '[]'::jsonb ELSE '{"fixture":true}'::jsonb END,
                CASE WHEN v_case.kind = 'infinite'
                     THEN 'infinity'::timestamptz
                     ELSE statement_timestamp() END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO b7_discount_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    IF has_table_privilege(
        'gympro_app', 'app.membership_discounts',
        'SELECT,INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'Runtime has direct discount-history access.';
    END IF;

    INSERT INTO b7_discount_results
    VALUES ('17_runtime_history_access_denied', 'PASS');

    IF (
        SELECT count(*) FROM app.membership_discounts
        WHERE promotion_id = v.promotion_id
    ) <> 2 THEN
        RAISE EXCEPTION 'Rejected requests saved history.';
    END IF;

    INSERT INTO b7_discount_results
    VALUES ('18_rejections_saved_no_extra_history', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_discount_results
ORDER BY test_name;

SELECT
    promotion_id::text AS promotion_id,
    other_subscription_id::text AS subscription_id
FROM b7_discount_context
\gset b7d_

ROLLBACK;

SELECT
    'discount_history_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.membership_discounts
            WHERE promotion_id = :'b7d_promotion_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id = :'b7d_promotion_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = :'b7d_subscription_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7d_promotion_id
\unset b7d_subscription_id