\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

BEGIN;

-- Require an existing active tenant.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM platform.tenants
        WHERE status = 'active'
    ) THEN
        RAISE EXCEPTION
            'No active tenant exists. Roll back and report this message before continuing.';
    END IF;
END
$$;

-- Create one test member using an existing active tenant.
-- Leave branch_id empty because it is optional.
-- Let PostgreSQL generate the ID, member number and status.
INSERT INTO app.members (
    tenant_id,
    full_name,
    phone,
    email
)
SELECT
    id,
    'Gym Pro B2 Test Member',
    '+959000000000',
    'gympro-b2-test@example.com'
FROM platform.tenants
WHERE status = 'active'
ORDER BY created_at, id
LIMIT 1
RETURNING
    id,
    member_number,
    status
\gset b2_test_

-- Show the generated values.
SELECT
    :'b2_test_id'::UUID AS test_member_id,
    :'b2_test_member_number' AS generated_member_number,
    :'b2_test_status' AS default_status;

-- Verify the stored record and defaults.
SELECT
    CASE
        WHEN member_number ~ '^GP-[0-9]{10}$'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS member_number_test,

    CASE
        WHEN status = 'pending'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS default_status_test,

    CASE
        WHEN branch_id IS NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END AS optional_branch_test,

    CASE
        WHEN created_at IS NOT NULL
         AND updated_at IS NOT NULL
        THEN 'PASS'
        ELSE 'FAIL'
    END AS timestamps_test
FROM app.members
WHERE id = :'b2_test_id'::UUID;

-- Remove the test record by rolling back the transaction.
ROLLBACK;

-- Confirm that the exact test record no longer exists.
SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.members
            WHERE id = :'b2_test_id'::UUID
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS rollback_test;