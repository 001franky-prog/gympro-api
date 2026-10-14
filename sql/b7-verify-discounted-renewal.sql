\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_renew_context AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS subscription_id,
    gen_random_uuid() AS promotion_id,
    gen_random_uuid() AS inactive_id,
    gen_random_uuid() AS request_id,
    gen_random_uuid() AS ordinary_request_id,
    decode(
        md5(gen_random_uuid()::text) ||
        md5(gen_random_uuid()::text), 'hex'
    ) AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date AS today;

CREATE TEMP TABLE b7_renew_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b7_renew_context;

INSERT INTO app.members(id, tenant_id, full_name, email, status)
SELECT member_id, tenant_id, 'B7 renewal fixture',
       member_id::text || '@example.invalid', 'active'
FROM b7_renew_context;

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount, currency_code,
    status, starts_on, ends_on, activated_at
)
SELECT subscription_id, tenant_id, member_id, plan_id, price_id,
       1, 'months', 50000, 'MMK',
       'active', today, (today + interval '1 month')::date,
       statement_timestamp()
FROM b7_renew_context;

INSERT INTO app.membership_promotions (
    id, tenant_id, promotion_code, promotion_name,
    discount_kind, discount_value, starts_on, status
)
SELECT f.id, c.tenant_id,
       'B7R_' || left(upper(replace(f.id::text, '-', '')), 20),
       'B7 renewal promotion', 'fixed_amount', 5000,
       c.today, f.status
FROM b7_renew_context c
CROSS JOIN LATERAL (
    VALUES (c.promotion_id, 'active'), (c.inactive_id, 'inactive')
) f(id, status);

GRANT SELECT ON b7_renew_context TO gympro_app;
GRANT SELECT, INSERT ON b7_renew_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_denied boolean := false;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_renew_context;

    BEGIN
        PERFORM * FROM security.renew_discounted_membership(
            v.token_hash, v.tenant_id, v.subscription_id,
            v.price_id, v.promotion_id, v.request_id
        );
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM <> 'Membership discount permission denied' THEN
                RAISE;
            END IF;
            v_denied := true;
    END;

    IF NOT v_denied THEN
        RAISE EXCEPTION 'Missing discount permission was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('01_missing_discount_permission', 'PASS');
END;
$$;

RESET ROLE;

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B7R_' || left(upper(replace(role_id::text, '-', '')), 20),
       'B7 transaction-only renewal role', false, 'active'
FROM b7_renew_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_renew_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.apply_discount'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_renew_context;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_case record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_renew_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('02_unknown_session', 'session', '28000'),
            ('03_wrong_tenant', 'tenant', '42501'),
            ('04_inactive_promotion', 'inactive', '22023'),
            ('05_unknown_promotion', 'unknown', '22023')
        ) cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;
        BEGIN
            PERFORM * FROM security.renew_discounted_membership(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                v.subscription_id, v.price_id,
                CASE WHEN v_case.kind = 'inactive' THEN v.inactive_id
                     WHEN v_case.kind = 'unknown' THEN gen_random_uuid()
                     ELSE v.promotion_id END,
                gen_random_uuid()
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b7_renew_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_renew_context;

    IF NOT EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE id = v.subscription_id
          AND ends_on = (v.today + interval '1 month')::date
          AND agreed_price_amount = 50000
    ) OR EXISTS (
        SELECT 1 FROM app.subscription_renewals
        WHERE subscription_id = v.subscription_id
    ) OR EXISTS (
        SELECT 1 FROM app.membership_discounts
        WHERE subscription_id = v.subscription_id
    ) THEN
        RAISE EXCEPTION 'Rejected renewal left partial purchase changes.';
    END IF;

    INSERT INTO b7_renew_results
    VALUES ('06_rejected_purchase_fully_rolled_back', 'PASS');
END;
$$;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_receipt record;
    v_retry record;
    v_ordinary record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_renew_context;

    SELECT * INTO STRICT v_receipt
    FROM security.renew_discounted_membership(
        v.token_hash, v.tenant_id, v.subscription_id,
        v.price_id, v.promotion_id, v.request_id
    );

    IF v_receipt.purchase_kind <> 'renewal'
       OR v_receipt.renewal_id IS NULL
       OR v_receipt.listed_price_amount <> 50000
       OR v_receipt.discount_amount <> 5000
       OR v_receipt.agreed_price_amount <> 45000 THEN
        RAISE EXCEPTION 'Discounted renewal receipt mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('07_discounted_renewal_agreed_values', 'PASS');

    SELECT * INTO STRICT v_retry
    FROM security.renew_discounted_membership(
        v.token_hash, v.tenant_id, v.subscription_id,
        v.price_id, v.promotion_id, v.request_id
    );

    IF to_jsonb(v_retry) IS DISTINCT FROM to_jsonb(v_receipt) THEN
        RAISE EXCEPTION 'Discounted retry receipt changed.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('08_retry_returns_original_discount_receipt', 'PASS');

    v_state := NULL;
    BEGIN
        PERFORM * FROM security.renew_discounted_membership(
            v.token_hash, v.tenant_id, v.subscription_id,
            v.price_id, v.inactive_id, v.request_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'Request reuse conflict was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('09_request_reuse_conflict', 'PASS');

    -- Ordinary retry of the same purchase must preserve its agreed price.
    SELECT * INTO STRICT v_ordinary
    FROM security.renew_member_subscription(
        v.token_hash, v.tenant_id, v.subscription_id,
        v.price_id, v.request_id
    );

    IF v_ordinary.id <> v_receipt.renewal_id
       OR v_ordinary.agreed_price_amount <> 45000 THEN
        RAISE EXCEPTION 'Ordinary retry changed the discounted receipt.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('10_ordinary_retry_preserves_discounted_purchase', 'PASS');

    SELECT * INTO STRICT v_ordinary
    FROM security.renew_member_subscription(
        v.token_hash, v.tenant_id, v.subscription_id,
        v.price_id, v.ordinary_request_id
    );

    IF v_ordinary.agreed_price_amount <> 50000 THEN
        RAISE EXCEPTION 'New ordinary renewal did not use the listed price.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('11_new_ordinary_renewal_still_works', 'PASS');

    v_state := NULL;
    BEGIN
        PERFORM * FROM security.renew_discounted_membership(
            v.token_hash, v.tenant_id, v.subscription_id,
            v.price_id, v.promotion_id, v.ordinary_request_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'Ordinary purchase was retroactively discounted.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('12_ordinary_purchase_cannot_be_converted', 'PASS');

    SELECT * INTO STRICT v_retry
    FROM security.renew_discounted_membership(
        v.token_hash, v.tenant_id, v.subscription_id,
        v.price_id, v.promotion_id, v.request_id
    );

    IF to_jsonb(v_retry) IS DISTINCT FROM to_jsonb(v_receipt) THEN
        RAISE EXCEPTION 'Old discount retry changed after a later renewal.';
    END IF;

    INSERT INTO pg_temp.b7_renew_results
    VALUES ('13_old_retry_preserves_original_receipt', 'PASS');
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_renew_context;

    IF (
        SELECT count(*) FROM app.subscription_renewals
        WHERE subscription_id = v.subscription_id
    ) <> 2 OR (
        SELECT count(*) FROM app.membership_discounts
        WHERE subscription_id = v.subscription_id
    ) <> 1 OR NOT EXISTS (
        SELECT 1
        FROM app.membership_discounts d
        JOIN app.subscription_renewals r
          ON r.tenant_id = d.tenant_id
         AND r.subscription_id = d.subscription_id
         AND r.id = d.renewal_id
        WHERE d.subscription_id = v.subscription_id
          AND d.request_id = v.request_id
          AND r.previous_ends_on = (v.today + interval '1 month')::date
          AND r.renewal_starts_on = r.previous_ends_on
          AND r.renewal_ends_on =
              (r.renewal_starts_on + interval '1 month')::date
          AND r.agreed_price_amount = 45000
          AND d.actor_snapshot->>'membership_id' = v.membership_id::text
    ) THEN
        RAISE EXCEPTION 'Purchase counts, coverage, or audit mismatch.';
    END IF;

    INSERT INTO b7_renew_results
    VALUES ('14_coverage_audit_and_purchase_counts', 'PASS');
END;
$$;

SELECT test_name, result FROM b7_renew_results ORDER BY test_name;

SELECT member_id::text AS member_id,
       subscription_id::text AS subscription_id,
       promotion_id::text AS promotion_id,
       inactive_id::text AS inactive_id,
       role_id::text AS role_id,
       session_id::text AS session_id
FROM b7_renew_context
\gset b7r_

ROLLBACK;

SELECT 'discounted_renewal_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.members WHERE id = :'b7r_member_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = :'b7r_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE subscription_id = :'b7r_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_discounts
            WHERE subscription_id = :'b7r_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id IN (
                :'b7r_promotion_id'::uuid, :'b7r_inactive_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b7r_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b7r_session_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7r_member_id
\unset b7r_subscription_id
\unset b7r_promotion_id
\unset b7r_inactive_id
\unset b7r_role_id
\unset b7r_session_id