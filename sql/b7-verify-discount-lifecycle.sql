\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_lifecycle_context AS
SELECT
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS promotion_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS revoked_session_id,
    gen_random_uuid() AS expired_session_id,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS token_hash,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS revoked_hash,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS expired_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date AS today;

CREATE TEMP TABLE b7_lifecycle_fixtures (
    kind text PRIMARY KEY,
    member_id uuid NOT NULL,
    subscription_id uuid NOT NULL
);

INSERT INTO b7_lifecycle_fixtures
SELECT kind, gen_random_uuid(), gen_random_uuid()
FROM unnest(ARRAY['foc', 'suspended', 'blacklisted']) AS kinds(kind);

CREATE TEMP TABLE b7_lifecycle_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash,
    created_at, expires_at, revoked_at
)
SELECT
    f.id, c.tenant_id, c.membership_id, f.hash,
    CURRENT_TIMESTAMP - interval '2 hours',
    CASE WHEN f.kind = 'expired'
         THEN CURRENT_TIMESTAMP - interval '1 hour'
         ELSE CURRENT_TIMESTAMP + interval '30 minutes' END,
    CASE WHEN f.kind = 'revoked'
         THEN CURRENT_TIMESTAMP ELSE NULL END
FROM b7_lifecycle_context c
CROSS JOIN LATERAL (
    VALUES
        (c.session_id, c.token_hash, 'active'),
        (c.revoked_session_id, c.revoked_hash, 'revoked'),
        (c.expired_session_id, c.expired_hash, 'expired')
) f(id, hash, kind);

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B7L_' || left(upper(replace(role_id::text, '-', '')), 20),
       'B7 transaction-only lifecycle role', false, 'active'
FROM b7_lifecycle_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_lifecycle_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.apply_discount'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_lifecycle_context;

INSERT INTO app.membership_promotions (
    id, tenant_id, promotion_code, promotion_name,
    discount_kind, discount_value, starts_on, status
)
SELECT promotion_id, tenant_id,
       'B7L_' || left(upper(replace(promotion_id::text, '-', '')), 20),
       'B7 lifecycle fixture', 'percentage', 10, today, 'active'
FROM b7_lifecycle_context;

INSERT INTO app.members(id, tenant_id, full_name, email, status)
SELECT f.member_id, c.tenant_id, 'B7 lifecycle member',
       f.member_id::text || '@example.invalid',
       CASE WHEN f.kind = 'blacklisted'
            THEN 'blacklisted' ELSE 'active' END
FROM b7_lifecycle_fixtures f
CROSS JOIN b7_lifecycle_context c;

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit,
    agreed_price_amount, currency_code, membership_kind,
    status, starts_on, ends_on, activated_at, suspended_at
)
SELECT
    f.subscription_id, c.tenant_id, f.member_id, c.plan_id, c.price_id,
    1, 'months',
    CASE WHEN f.kind = 'foc' THEN 0 ELSE 50000 END,
    'MMK',
    CASE WHEN f.kind = 'foc' THEN 'foc' ELSE 'standard' END,
    CASE WHEN f.kind = 'suspended' THEN 'suspended' ELSE 'active' END,
    c.today, (c.today + interval '1 month')::date,
    statement_timestamp() - interval '1 minute',
    CASE WHEN f.kind = 'suspended'
         THEN statement_timestamp() ELSE NULL END
FROM b7_lifecycle_fixtures f
CROSS JOIN b7_lifecycle_context c;

CREATE TEMP TABLE b7_lifecycle_baseline AS
SELECT
    (
        SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
        FROM app.members m
        JOIN b7_lifecycle_fixtures f ON f.member_id = m.id
    ) AS members,
    (
        SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
        FROM app.member_subscriptions s
        JOIN b7_lifecycle_fixtures f ON f.subscription_id = s.id
    ) AS subscriptions;

GRANT SELECT ON b7_lifecycle_context, b7_lifecycle_fixtures
    TO gympro_app;
GRANT SELECT, INSERT ON b7_lifecycle_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_case record;
    v_subscription uuid;
    v_member uuid;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_lifecycle_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('01_foc_renewal_rejected', 'foc', 'active', 'renewal', '22023'),
            ('02_suspended_renewal_rejected', 'suspended', 'active', 'renewal', '22023'),
            ('03_blacklisted_renewal_rejected', 'blacklisted', 'active', 'renewal', '22023'),
            ('04_revoked_session_renewal_rejected', 'blacklisted', 'revoked', 'renewal', '28000'),
            ('05_expired_session_renewal_rejected', 'blacklisted', 'expired', 'renewal', '28000'),
            ('06_blacklisted_activation_rejected', 'blacklisted', 'active', 'activation', '22023'),
            ('07_revoked_session_activation_rejected', 'blacklisted', 'revoked', 'activation', '28000'),
            ('08_expired_session_activation_rejected', 'blacklisted', 'expired', 'activation', '28000')
        ) cases(test_name, fixture_kind, session_kind, operation, expected_state)
    LOOP
        SELECT subscription_id, member_id
        INTO v_subscription, v_member
        FROM pg_temp.b7_lifecycle_fixtures
        WHERE kind = v_case.fixture_kind;

        v_state := NULL;

        BEGIN
            IF v_case.operation = 'renewal' THEN
                PERFORM * FROM security.renew_discounted_membership(
                    CASE WHEN v_case.session_kind = 'revoked' THEN v.revoked_hash
                         WHEN v_case.session_kind = 'expired' THEN v.expired_hash
                         ELSE v.token_hash END,
                    v.tenant_id, v_subscription,
                    v.price_id, v.promotion_id, gen_random_uuid()
                );
            ELSE
                PERFORM * FROM security.activate_discounted_membership(
                    CASE WHEN v_case.session_kind = 'revoked' THEN v.revoked_hash
                         WHEN v_case.session_kind = 'expired' THEN v.expired_hash
                         ELSE v.token_hash END,
                    v.tenant_id, v_member, v.plan_id,
                    v.price_id, v.promotion_id, gen_random_uuid()
                );
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b7_lifecycle_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v_members jsonb;
    v_subscriptions jsonb;
    v_baseline record;
BEGIN
    SELECT * INTO v_baseline FROM pg_temp.b7_lifecycle_baseline;

    SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) INTO v_members
    FROM app.members m
    JOIN pg_temp.b7_lifecycle_fixtures f ON f.member_id = m.id;

    SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) INTO v_subscriptions
    FROM app.member_subscriptions s
    JOIN pg_temp.b7_lifecycle_fixtures f ON f.subscription_id = s.id;

    IF v_members IS DISTINCT FROM v_baseline.members
       OR v_subscriptions IS DISTINCT FROM v_baseline.subscriptions THEN
        RAISE EXCEPTION 'Rejected requests changed fixture records.';
    END IF;

    INSERT INTO b7_lifecycle_results
    VALUES ('09_member_and_subscription_snapshots_unchanged', 'PASS');

    IF EXISTS (
        SELECT 1 FROM app.subscription_renewals r
        JOIN pg_temp.b7_lifecycle_fixtures f
          ON f.subscription_id = r.subscription_id
    ) OR EXISTS (
        SELECT 1 FROM app.membership_discounts d
        JOIN pg_temp.b7_lifecycle_fixtures f
          ON f.subscription_id = d.subscription_id
    ) THEN
        RAISE EXCEPTION 'Rejected requests created purchase history.';
    END IF;

    INSERT INTO b7_lifecycle_results
    VALUES ('10_rejections_created_no_purchase_history', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_lifecycle_results
ORDER BY test_name;

SELECT
    role_id::text AS role_id,
    promotion_id::text AS promotion_id,
    session_id::text AS session_id,
    revoked_session_id::text AS revoked_id,
    expired_session_id::text AS expired_id
FROM b7_lifecycle_context
\gset b7l_

SELECT
    string_agg(member_id::text, ',') AS member_ids,
    string_agg(subscription_id::text, ',') AS subscription_ids
FROM b7_lifecycle_fixtures
\gset b7l_

ROLLBACK;

SELECT 'discount_lifecycle_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id = ANY(string_to_array(:'b7l_member_ids', ',')::uuid[])
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = ANY(string_to_array(:'b7l_subscription_ids', ',')::uuid[])
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE subscription_id = ANY(
                string_to_array(:'b7l_subscription_ids', ',')::uuid[]
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_discounts
            WHERE promotion_id = :'b7l_promotion_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id = :'b7l_promotion_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b7l_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b7l_session_id'::uuid,
                :'b7l_revoked_id'::uuid,
                :'b7l_expired_id'::uuid
            )
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7l_role_id
\unset b7l_promotion_id
\unset b7l_session_id
\unset b7l_revoked_id
\unset b7l_expired_id
\unset b7l_member_ids
\unset b7l_subscription_ids