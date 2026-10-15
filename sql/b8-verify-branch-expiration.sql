\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b8e_context AS
SELECT
    gen_random_uuid() AS user_id,
    gen_random_uuid() AS membership_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS branch_id,
    gen_random_uuid() AS other_branch_id,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date AS today;

CREATE TEMP TABLE b8e_fixtures AS
SELECT kind, gen_random_uuid() AS member_id,
       gen_random_uuid() AS subscription_id
FROM unnest(ARRAY['due', 'other', 'future', 'blacklisted']) kinds(kind);

CREATE TEMP TABLE b8e_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO app.users(id, email, full_name, status)
SELECT user_id, user_id::text || '@example.invalid',
       'B8 expiration staff fixture', 'active'
FROM b8e_context;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status, joined_at
)
SELECT membership_id, tenant_id, user_id, 'active', CURRENT_TIMESTAMP
FROM b8e_context;

INSERT INTO app.branches (
    id, tenant_id, branch_code, branch_name, status
)
SELECT f.id, c.tenant_id,
       'B8E_' || left(upper(replace(f.id::text, '-', '')), 16),
       'B8 expiration branch fixture', 'active'
FROM b8e_context c
CROSS JOIN LATERAL (
    VALUES (c.branch_id), (c.other_branch_id)
) f(id);

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B8E_' || left(upper(replace(role_id::text, '-', '')), 16),
       'B8 expiration branch-only role', false, 'active'
FROM b8e_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b8e_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.manage'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'branch', branch_id
FROM b8e_context;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b8e_context;

INSERT INTO app.members (
    id, tenant_id, branch_id, full_name, email, status
)
SELECT f.member_id, c.tenant_id,
       CASE WHEN f.kind = 'other' THEN c.other_branch_id ELSE c.branch_id END,
       'B8 expiration member fixture',
       f.member_id::text || '@example.invalid',
       CASE WHEN f.kind = 'blacklisted' THEN 'blacklisted' ELSE 'active' END
FROM b8e_fixtures f CROSS JOIN b8e_context c;

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, branch_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount, currency_code,
    status, starts_on, ends_on, activated_at, suspended_at
)
SELECT f.subscription_id, c.tenant_id, f.member_id,
       CASE WHEN f.kind = 'other' THEN c.other_branch_id ELSE c.branch_id END,
       c.plan_id, c.price_id, 1, 'months', 50000, 'MMK',
       CASE WHEN f.kind = 'blacklisted' THEN 'suspended' ELSE 'active' END,
       c.today - 30,
       CASE WHEN f.kind = 'future' THEN c.today + 30 ELSE c.today END,
       statement_timestamp() - interval '31 days',
       CASE WHEN f.kind = 'blacklisted'
            THEN statement_timestamp() - interval '1 day' ELSE NULL END
FROM b8e_fixtures f CROSS JOIN b8e_context c;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8e_context;

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', NULL
    ) IS DISTINCT FROM false
    OR security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', v.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Branch-only permission matrix mismatch.';
    END IF;

    INSERT INTO b8e_results
    VALUES ('01_branch_only_permission_matrix', 'PASS');
END;
$$;

GRANT SELECT ON b8e_context, b8e_fixtures TO gympro_app;
GRANT SELECT, INSERT ON b8e_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_case record;
    v_subscription uuid;
    v_state text;
    v_receipt record;
    v_retry record;
BEGIN
    SELECT * INTO v FROM pg_temp.b8e_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('02_unknown_session', 'session', 'due', '28000'),
            ('03_wrong_tenant', 'tenant', 'due', '42501'),
            ('04_missing_branch', 'branch_null', 'due', '42501'),
            ('05_unassigned_branch', 'unassigned', 'other', '42501'),
            ('06_subscription_route_mismatch', 'mismatch', 'other', '42501'),
            ('07_future_end_rejected', 'future', 'future', '22023')
        ) cases(test_name, kind, fixture_kind, expected_state)
    LOOP
        SELECT subscription_id INTO v_subscription
        FROM pg_temp.b8e_fixtures WHERE kind = v_case.fixture_kind;

        v_state := NULL;
        BEGIN
            PERFORM * FROM security.expire_branch_member_subscription(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'branch_null' THEN NULL
                     WHEN v_case.kind = 'unassigned' THEN v.other_branch_id
                     ELSE v.branch_id END,
                v_subscription
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b8e_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    SELECT subscription_id INTO v_subscription
    FROM pg_temp.b8e_fixtures WHERE kind = 'due';

    SELECT * INTO STRICT v_receipt
    FROM security.expire_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id, v_subscription
    );

    IF v_receipt.subscription_id <> v_subscription
       OR v_receipt.coverage_starts_on <> v.today - 30
       OR v_receipt.coverage_ends_on <> v.today
       OR v_receipt.processed_on <> v.today THEN
        RAISE EXCEPTION 'Expiration receipt or server date mismatch.';
    END IF;

    INSERT INTO pg_temp.b8e_results
    VALUES ('08_branch_staff_due_expiration', 'PASS');

    SELECT * INTO STRICT v_retry
    FROM security.expire_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id, v_subscription
    );

    IF to_jsonb(v_retry) IS DISTINCT FROM to_jsonb(v_receipt) THEN
        RAISE EXCEPTION 'Repeated expiration changed the receipt.';
    END IF;

    INSERT INTO pg_temp.b8e_results
    VALUES ('09_repeat_returns_original_receipt', 'PASS');

    SELECT subscription_id INTO v_subscription
    FROM pg_temp.b8e_fixtures WHERE kind = 'blacklisted';

    PERFORM * FROM security.expire_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id, v_subscription
    );

    INSERT INTO pg_temp.b8e_results
    VALUES ('10_suspended_blacklisted_coverage_processed', 'PASS');
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8e_context;

    IF (
        SELECT count(*) FROM app.subscription_expirations h
        JOIN b8e_fixtures f ON f.subscription_id = h.subscription_id
    ) <> 2 OR EXISTS (
        SELECT 1
        FROM b8e_fixtures f
        JOIN app.member_subscriptions s ON s.id = f.subscription_id
        JOIN app.members m ON m.id = f.member_id
        WHERE
            (f.kind = 'due' AND (
                s.status <> 'expired' OR m.status <> 'inactive'
            ))
            OR (f.kind = 'blacklisted' AND (
                s.status <> 'expired'
                OR s.suspended_at IS NOT NULL
                OR m.status <> 'blacklisted'
            ))
            OR (f.kind IN ('other', 'future') AND (
                s.status <> 'active' OR m.status <> 'active'
            ))
            OR s.starts_on <> v.today - 30
            OR s.ends_on <> CASE
                WHEN f.kind = 'future' THEN v.today + 30 ELSE v.today
            END
    ) OR EXISTS (
        SELECT 1
        FROM app.subscription_expirations h
        JOIN b8e_fixtures f ON f.subscription_id = h.subscription_id
        WHERE h.previous_subscription_snapshot->>'expired_by_membership_id'
              IS DISTINCT FROM v.membership_id::text
    ) THEN
        RAISE EXCEPTION 'History, dates, actor, or member-status mismatch.';
    END IF;

    INSERT INTO b8e_results
    VALUES ('11_dates_blacklist_actor_and_counts_preserved', 'PASS');
END;
$$;

UPDATE security.tenant_sessions
SET revoked_at = statement_timestamp()
WHERE id = (SELECT session_id FROM b8e_context);

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_subscription uuid;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b8e_context;
    SELECT subscription_id INTO v_subscription
    FROM pg_temp.b8e_fixtures WHERE kind = 'due';

    BEGIN
        PERFORM * FROM security.expire_branch_member_subscription(
            v.token_hash, v.tenant_id, v.branch_id, v_subscription
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '28000' THEN
        RAISE EXCEPTION 'Revoked session repeat was not rejected.';
    END IF;

    INSERT INTO pg_temp.b8e_results
    VALUES ('12_revoked_session_repeat_rejected', 'PASS');
END;
$$;

RESET ROLE;

SELECT test_name, result FROM b8e_results ORDER BY test_name;

SELECT user_id::text AS user_id,
       membership_id::text AS membership_id,
       role_id::text AS role_id,
       session_id::text AS session_id,
       branch_id::text AS branch_id,
       other_branch_id::text AS other_branch_id
FROM b8e_context
\gset b8e_

SELECT string_agg(member_id::text, ',') AS member_ids,
       string_agg(subscription_id::text, ',') AS subscription_ids
FROM b8e_fixtures
\gset b8e_

ROLLBACK;

SELECT 'branch_expiration_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.users WHERE id = :'b8e_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b8e_membership_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b8e_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b8e_session_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.branches
            WHERE id IN (
                :'b8e_branch_id'::uuid, :'b8e_other_branch_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id = ANY(string_to_array(:'b8e_member_ids', ',')::uuid[])
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = ANY(
                string_to_array(:'b8e_subscription_ids', ',')::uuid[]
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_expirations
            WHERE subscription_id = ANY(
                string_to_array(:'b8e_subscription_ids', ',')::uuid[]
            )
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b8e_user_id
\unset b8e_membership_id
\unset b8e_role_id
\unset b8e_session_id
\unset b8e_branch_id
\unset b8e_other_branch_id
\unset b8e_member_ids
\unset b8e_subscription_ids