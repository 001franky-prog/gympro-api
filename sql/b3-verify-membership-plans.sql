\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM platform.tenants
        WHERE status = 'active'
    ) THEN
        RAISE EXCEPTION 'No active tenant exists for this test.';
    END IF;
END
$$;

CREATE TEMP TABLE b3_test_results (
    test_name TEXT PRIMARY KEY,
    result TEXT NOT NULL
) ON COMMIT DROP;

-- Create a temporary plan using an existing active tenant.
INSERT INTO app.membership_plans (
    tenant_id,
    plan_code,
    plan_name,
    duration_value,
    duration_unit
)
SELECT
    id,
    'B3-' || SUBSTRING(
        REPLACE(gen_random_uuid()::TEXT, '-', ''),
        1,
        24
    ),
    'B3 Verification Plan',
    3,
    'months'
FROM platform.tenants
WHERE status = 'active'
ORDER BY created_at, id
LIMIT 1
RETURNING id AS plan_id, tenant_id
\gset b3_

-- Create a temporary general price.
INSERT INTO app.plan_prices (
    tenant_id,
    plan_id,
    price_amount
)
VALUES (
    :'b3_tenant_id'::UUID,
    :'b3_plan_id'::UUID,
    50000.00
)
RETURNING id AS price_id
\gset b3_

-- Check the plan values and default status.
INSERT INTO b3_test_results
SELECT
    '01_plan_defaults',
    CASE
        WHEN duration_value = 3
         AND duration_unit = 'months'
         AND status = 'draft'
        THEN 'PASS'
        ELSE 'FAIL'
    END
FROM app.membership_plans
WHERE id = :'b3_plan_id'::UUID;

-- Check the price, currency and defaults.
INSERT INTO b3_test_results
SELECT
    '02_price_defaults',
    CASE
        WHEN price_amount = 50000.00
         AND currency_code = 'MMK'
         AND status = 'inactive'
         AND branch_id IS NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END
FROM app.plan_prices
WHERE id = :'b3_price_id'::UUID;

-- Activate the test price to check active-price uniqueness.
UPDATE app.plan_prices
SET status = 'active'
WHERE id = :'b3_price_id'::UUID;

-- Temporary helper: verify that a statement is rejected
-- by the exact expected constraint.
CREATE FUNCTION pg_temp.b3_expect_rejection(
    statement_text TEXT,
    expected_constraint TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    actual_constraint TEXT;
BEGIN
    BEGIN
        EXECUTE statement_text;
    EXCEPTION
        WHEN check_violation
          OR unique_violation
          OR foreign_key_violation THEN

            GET STACKED DIAGNOSTICS
                actual_constraint = CONSTRAINT_NAME;

            IF actual_constraint <> expected_constraint THEN
                RAISE EXCEPTION
                    'Expected constraint %, received %.',
                    expected_constraint,
                    actual_constraint;
            END IF;

            RETURN 'PASS';
    END;

    RAISE EXCEPTION
        'Statement was accepted; expected rejection by %.',
        expected_constraint;
END
$$;

-- Reject a second active general price for the same plan.
INSERT INTO b3_test_results
VALUES (
    '03_duplicate_active_price_rejected',
    pg_temp.b3_expect_rejection(
        FORMAT(
            'INSERT INTO app.plan_prices
             (tenant_id, plan_id, price_amount, status)
             VALUES (%L::uuid, %L::uuid, 60000, %L)',
            :'b3_tenant_id',
            :'b3_plan_id',
            'active'
        ),
        'uq_plan_prices_active_general'
    )
);

-- Reject negative prices.
INSERT INTO b3_test_results
VALUES (
    '04_negative_price_rejected',
    pg_temp.b3_expect_rejection(
        FORMAT(
            'INSERT INTO app.plan_prices
             (tenant_id, plan_id, price_amount)
             VALUES (%L::uuid, %L::uuid, -1)',
            :'b3_tenant_id',
            :'b3_plan_id'
        ),
        'chk_plan_prices_amount'
    )
);

-- Reject a price whose tenant differs from its plan owner.
INSERT INTO b3_test_results
VALUES (
    '05_mismatched_tenant_rejected',
    pg_temp.b3_expect_rejection(
        FORMAT(
            'INSERT INTO app.plan_prices
             (tenant_id, plan_id, price_amount)
             VALUES (%L::uuid, %L::uuid, 50000)',
            gen_random_uuid(),
            :'b3_plan_id'
        ),
        'fk_plan_prices_plan'
    )
);

SELECT test_name, result
FROM b3_test_results
ORDER BY test_name;

-- Remove the test plan, price and temporary helper.
ROLLBACK;

-- Verify removal of the exact test records.
SELECT
    '06_plan_rollback' AS test_name,
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.membership_plans
            WHERE id = :'b3_plan_id'::UUID
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result

UNION ALL

SELECT
    '07_price_rollback',
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.plan_prices
            WHERE id = :'b3_price_id'::UUID
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END;