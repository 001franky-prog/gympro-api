\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_activation_context AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS rejected_member_id,
    gen_random_uuid() AS promotion_id,
    gen_random_uuid() AS inactive_promotion_id,
    gen_random_uuid() AS request_id,
    decode(
        md5(gen_random_uuid()::text) ||
        md5(gen_random_uuid()::text), 'hex'
    ) AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id;

CREATE TEMP TABLE b7_activation_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b7_activation_context;

INSERT INTO app.members(id, tenant_id, full_name, email)
SELECT f.id, c.tenant_id, 'B7 activation fixture',
       f.id::text || '@example.invalid'
FROM b7_activation_context c
CROSS JOIN LATERAL (
    VALUES (c.member_id), (c.rejected_member_id)
) f(id);

INSERT INTO app.membership_promotions (
    id, tenant_id, promotion_code, promotion_name,
    discount_kind, discount_value, starts_on, status
)
SELECT f.id, c.tenant_id,
       'B7A_' || left(upper(replace(f.id::text, '-', '')), 20),
       'B7 activation promotion', 'percentage', 10,
       (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date,
       f.status
FROM b7_activation_context c
CROSS JOIN LATERAL (
    VALUES
        (c.promotion_id, 'active'),
        (c.inactive_promotion_id, 'inactive')
) f(id, status);

GRANT SELECT ON b7_activation_context TO gympro_app;
GRANT SELECT, INSERT ON b7_activation_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_activation_context;
    BEGIN
        PERFORM * FROM security.activate_discounted_membership(
            v.token_hash, v.tenant_id, v.member_id,
            v.plan_id, v.price_id, v.promotion_id, v.request_id
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

    INSERT INTO pg_temp.b7_activation_results
    VALUES ('01_missing_discount_permission_rejected', 'PASS');
END;
$$;

RESET ROLE;

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B7A_' || left(upper(replace(role_id::text, '-', '')), 20),
       'B7 transaction-only discount role', false, 'active'
FROM b7_activation_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_activation_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.apply_discount'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_activation_context;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_receipt record;
    v_retry record;
    v_case record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_activation_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('02_unknown_session', 'session', '28000'),
            ('03_wrong_tenant', 'tenant', '42501'),
            ('04_inactive_promotion', 'inactive', '22023'),
            ('05_unknown_promotion', 'unknown', '22023'),
            ('06_missing_request_id', 'request', '22023')
        ) cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;
        BEGIN
            PERFORM * FROM security.activate_discounted_membership(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                v.rejected_member_id, v.plan_id, v.price_id,
                CASE WHEN v_case.kind = 'inactive'
                     THEN v.inactive_promotion_id
                     WHEN v_case.kind = 'unknown'
                     THEN gen_random_uuid()
                     ELSE v.promotion_id END,
                CASE WHEN v_case.kind = 'request'
                     THEN NULL ELSE gen_random_uuid() END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b7_activation_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    SELECT * INTO STRICT v_receipt
    FROM security.activate_discounted_membership(
        v.token_hash, v.tenant_id, v.member_id,
        v.plan_id, v.price_id, v.promotion_id, v.request_id
    );

    IF v_receipt.purchase_kind <> 'activation'
       OR v_receipt.listed_price_amount <> 50000
       OR v_receipt.discount_amount <> 5000
       OR v_receipt.agreed_price_amount <> 45000
       OR v_receipt.promotion_id <> v.promotion_id
       OR v_receipt.request_id <> v.request_id THEN
        RAISE EXCEPTION 'Discounted activation receipt mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_activation_results
    VALUES ('07_activation_agreed_values', 'PASS');

    SELECT * INTO STRICT v_retry
    FROM security.activate_discounted_membership(
        v.token_hash, v.tenant_id, v.member_id,
        v.plan_id, v.price_id, v.promotion_id, v.request_id
    );

    IF to_jsonb(v_retry) IS DISTINCT FROM to_jsonb(v_receipt) THEN
        RAISE EXCEPTION 'Retry changed the original receipt.';
    END IF;

    INSERT INTO pg_temp.b7_activation_results
    VALUES ('08_retry_returns_original_receipt', 'PASS');

    v_state := NULL;
    BEGIN
        PERFORM * FROM security.activate_discounted_membership(
            v.token_hash, v.tenant_id, v.member_id,
            v.plan_id, v.price_id, v.inactive_promotion_id, v.request_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'Conflicting request reuse was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_activation_results
    VALUES ('09_request_reuse_conflict', 'PASS');

    v_state := NULL;
    BEGIN
        PERFORM * FROM security.activate_discounted_membership(
            v.token_hash, v.tenant_id, v.member_id,
            v.plan_id, v.price_id, v.promotion_id, gen_random_uuid()
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '22023' THEN
        RAISE EXCEPTION 'Second current subscription was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_activation_results
    VALUES ('10_second_activation_rejected', 'PASS');
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_activation_context;

    IF NOT EXISTS (
        SELECT 1 FROM app.members
        WHERE id = v.rejected_member_id AND status = 'pending'
    ) OR EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE tenant_id = v.tenant_id AND member_id = v.rejected_member_id
    ) THEN
        RAISE EXCEPTION 'Rejected promotion left partial activation.';
    END IF;

    INSERT INTO b7_activation_results
    VALUES ('11_rejected_purchase_fully_rolled_back', 'PASS');

    IF (
        SELECT count(*) FROM app.member_subscriptions
        WHERE tenant_id = v.tenant_id AND member_id = v.member_id
    ) <> 1 OR NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions s
        JOIN app.membership_discounts d
          ON d.tenant_id = s.tenant_id AND d.subscription_id = s.id
        JOIN app.members m
          ON m.tenant_id = s.tenant_id AND m.id = s.member_id
        WHERE s.tenant_id = v.tenant_id
          AND s.member_id = v.member_id
          AND s.status = 'active'
          AND s.membership_kind = 'standard'
          AND s.agreed_price_amount = 45000
          AND m.status = 'active'
          AND d.request_id = v.request_id
          AND d.actor_snapshot->>'membership_id' = v.membership_id::text
          AND d.promotion_snapshot->>'discount_value' = '10.00'
    ) OR (
        SELECT count(*) FROM app.membership_discounts
        WHERE promotion_id = v.promotion_id
    ) <> 1 THEN
        RAISE EXCEPTION 'Saved purchase, audit, or retry count mismatch.';
    END IF;

    INSERT INTO b7_activation_results
    VALUES ('12_purchase_and_audit_saved_once', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_activation_results
ORDER BY test_name;

SELECT
    member_id::text AS member_id,
    rejected_member_id::text AS rejected_member_id,
    promotion_id::text AS promotion_id,
    inactive_promotion_id::text AS inactive_id,
    session_id::text AS session_id,
    role_id::text AS role_id
FROM b7_activation_context
\gset b7a_

ROLLBACK;

SELECT 'discounted_activation_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b7a_member_id'::uuid, :'b7a_rejected_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE member_id IN (
                :'b7a_member_id'::uuid, :'b7a_rejected_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id IN (
                :'b7a_promotion_id'::uuid, :'b7a_inactive_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_discounts
            WHERE promotion_id = :'b7a_promotion_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b7a_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b7a_session_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7a_member_id
\unset b7a_rejected_member_id
\unset b7a_promotion_id
\unset b7a_inactive_id
\unset b7a_session_id
\unset b7a_role_id