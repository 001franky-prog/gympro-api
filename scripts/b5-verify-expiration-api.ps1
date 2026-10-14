param(
    [Parameter(Mandatory = $true)]
    [string]$Authorization
)

$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)

if ([string]::IsNullOrWhiteSpace($Authorization)) {
    throw 'Authenticated session is missing. Log in first.'
}

$gymProDatabaseSecret = Read-Host 'Local PostgreSQL postgres password' -AsSecureString

$gymProDatabaseCredential = [System.Management.Automation.PSCredential]::new(
    'postgres',
    $gymProDatabaseSecret
)

$gymProVerificationScript = @'
import pg from 'pg';
import { randomUUID } from 'node:crypto';

const tenantId = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenantId = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const planId = '838d86b2-9665-414d-865a-8f5fb559e39c';
const priceId = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const demoSubscriptionId = '8a28fa97-e41f-4053-be61-8162ff3d387d';

const memberId = randomUUID();
const subscriptionId = randomUUID();
const fixtureEmail = `b5-expiration-api-${memberId}@example.invalid`;

const client = new pg.Client({
    host: '127.0.0.1',
    port: 5432,
    database: 'gympro_saas',
    user: 'postgres',
    password: process.env.GYMPRO_EXPIRATION_DB_PASSWORD,
    connectionTimeoutMillis: 5000,
});

const authorization = process.env.GYMPRO_EXPIRATION_AUTHORIZATION;
const results = [];

let connected = false;
let setupCommitted = false;
let transactionOpen = false;
let sessionRevoked = false;
let originalDemo;
let today;
let firstReceipt;

function requireCondition(condition, message) {
    if (!condition) {
        throw new Error(message);
    }
}

async function check(name, action) {
    try {
        await action();
        results.push({ test: name, result: 'PASS', detail: '' });
    } catch (error) {
        results.push({
            test: name,
            result: 'FAIL',
            detail: error.message,
        });
    }
}

async function http(path, body, authenticated = true) {
    const headers = { 'Content-Type': 'application/json' };

    if (authenticated) {
        headers.Authorization = authorization;
    }

    const response = await fetch(`http://127.0.0.1:3000${path}`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
    });

    const text = await response.text();
    let data = null;

    if (text) {
        try {
            data = JSON.parse(text);
        } catch {
            data = null;
        }
    }

    return { status: response.status, data };
}

const expirePath =
    `/tenants/${tenantId}/subscriptions/${subscriptionId}/expire`;

async function revokeSession() {
    const response = await http('/auth/logout', {});
    requireCondition(response.status === 204, `Expected logout 204; got ${response.status}.`);
    sessionRevoked = true;
}

try {
    requireCondition(
        typeof authorization === 'string' && authorization.startsWith('Bearer '),
        'A valid local Bearer header is required.',
    );

    await client.connect();
    connected = true;

    const demo = await client.query(
        `SELECT to_jsonb(s) AS snapshot
         FROM app.member_subscriptions AS s
         WHERE tenant_id = $1::uuid AND id = $2::uuid`,
        [tenantId, demoSubscriptionId],
    );

    requireCondition(demo.rowCount === 1, 'Expected demo subscription is missing.');
    originalDemo = demo.rows[0].snapshot;

    await client.query('BEGIN');
    transactionOpen = true;

    const dateResult = await client.query(
        `SELECT
             (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date::text
             AS today`,
    );

    today = dateResult.rows[0].today;

    await client.query(
        `INSERT INTO app.members (
             id, tenant_id, full_name, email, status
         )
         VALUES ($1::uuid, $2::uuid, $3, $4, 'active')`,
        [
            memberId,
            tenantId,
            'B5 Expiration API Verification Member',
            fixtureEmail,
        ],
    );

    const subscription = await client.query(
        `INSERT INTO app.member_subscriptions (
             id, tenant_id, member_id,
             plan_id, plan_price_id,
             duration_value, duration_unit,
             agreed_price_amount, currency_code,
             status, starts_on, ends_on, activated_at
         )
         SELECT
             $1::uuid, p.tenant_id, $2::uuid,
             p.id, pp.id,
             p.duration_value, p.duration_unit,
             pp.price_amount, pp.currency_code,
             'active',
             ($5::date - INTERVAL '1 month')::date,
             $5::date,
             statement_timestamp() - INTERVAL '1 month'
         FROM app.membership_plans AS p
         JOIN app.plan_prices AS pp
           ON pp.tenant_id = p.tenant_id
          AND pp.plan_id = p.id
         WHERE p.tenant_id = $6::uuid
           AND p.id = $3::uuid
           AND pp.id = $4::uuid
           AND p.status = 'active'
           AND pp.status = 'active'
           AND pp.branch_id IS NULL
         RETURNING id`,
        [
            subscriptionId,
            memberId,
            planId,
            priceId,
            today,
            tenantId,
        ],
    );

    requireCondition(subscription.rowCount === 1, 'Active demo plan and general price were not found.');

    await client.query('COMMIT');
    transactionOpen = false;
    setupCommitted = true;

    await check('01_unauthenticated_request', async () => {
        const response = await http(expirePath, {}, false);
        requireCondition(response.status === 401, `Expected 401; got ${response.status}.`);
    });

    await check('02_cross_tenant_request', async () => {
        const response = await http(
            `/tenants/${otherTenantId}/subscriptions/${subscriptionId}/expire`,
            {},
        );
        requireCondition(response.status === 403, `Expected 403; got ${response.status}.`);
    });

    await check('03_client_processing_date_rejected', async () => {
        const response = await http(expirePath, { processedOn: '2099-01-01' });
        requireCondition(response.status === 400, `Expected 400; got ${response.status}.`);
    });

    await check('04_client_status_rejected', async () => {
        const response = await http(expirePath, { status: 'expired' });
        requireCondition(response.status === 400, `Expected 400; got ${response.status}.`);
    });

    await check('05_rejections_changed_nothing', async () => {
        const result = await client.query(
            `SELECT s.status, m.status AS member_status,
                 (SELECT count(*)::integer
                  FROM app.subscription_expirations AS h
                  WHERE h.subscription_id = s.id) AS history_rows
             FROM app.member_subscriptions AS s
             JOIN app.members AS m
               ON m.tenant_id = s.tenant_id AND m.id = s.member_id
             WHERE s.id = $1::uuid`,
            [subscriptionId],
        );

        const row = result.rows[0];

        requireCondition(
            result.rowCount === 1 &&
            row.status === 'active' &&
            row.member_status === 'active' &&
            row.history_rows === 0,
            'Rejected requests changed the fixture.',
        );
    });

    await check('06_successful_expiration', async () => {
        const response = await http(expirePath, {});
        const receipt = response.data;

        requireCondition(response.status === 200, `Expected 200; got ${response.status}.`);
        requireCondition(
            receipt &&
            receipt.tenantId === tenantId &&
            receipt.subscriptionId === subscriptionId &&
            receipt.coverageEndsOn === today &&
            receipt.processedOn >= today &&
            typeof receipt.id === 'string',
            'Unexpected expiration receipt.',
        );
        requireCondition(
            !Object.prototype.hasOwnProperty.call(receipt, 'previous_subscription_snapshot'),
            'Internal snapshot appeared in the API response.',
        );

        firstReceipt = receipt;
    });

    await check('07_repeat_returns_original_receipt', async () => {
        requireCondition(Boolean(firstReceipt), 'Successful first receipt is unavailable.');

        const response = await http(expirePath, {});

        requireCondition(response.status === 200, `Expected 200; got ${response.status}.`);
        requireCondition(
            JSON.stringify(response.data) === JSON.stringify(firstReceipt),
            'Repeated processing changed the receipt.',
        );
    });

    await check('08_database_status_history_and_dates', async () => {
        requireCondition(Boolean(firstReceipt), 'Successful first receipt is unavailable.');

        const result = await client.query(
            `SELECT
                 s.status,
                 m.status AS member_status,
                 s.starts_on::text AS starts_on,
                 s.ends_on::text AS ends_on,
                 s.suspended_at,
                 h.id AS history_id,
                 h.coverage_starts_on::text AS history_starts_on,
                 h.coverage_ends_on::text AS history_ends_on,
                 h.previous_subscription_snapshot ->> 'status'
                     AS previous_status,
                 h.previous_subscription_snapshot ->> 'expired_by_membership_id'
                     AS actor_membership,
                 (SELECT count(*)::integer
                  FROM app.subscription_expirations AS x
                  WHERE x.subscription_id = s.id) AS history_rows
             FROM app.member_subscriptions AS s
             JOIN app.members AS m
               ON m.tenant_id = s.tenant_id AND m.id = s.member_id
             JOIN app.subscription_expirations AS h
               ON h.tenant_id = s.tenant_id AND h.subscription_id = s.id
             WHERE s.id = $1::uuid`,
            [subscriptionId],
        );

        const row = result.rows[0];

        requireCondition(
            result.rowCount === 1 &&
            row.status === 'expired' &&
            row.member_status === 'inactive' &&
            row.suspended_at === null &&
            row.history_rows === 1 &&
            row.history_id === firstReceipt.id &&
            row.starts_on === row.history_starts_on &&
            row.ends_on === today &&
            row.ends_on === row.history_ends_on &&
            row.previous_status === 'active' &&
            row.actor_membership === '3b318e89-f3bc-4ac5-a04d-09fdb3d626de',
            'Saved expiration, member status, or audit history is incorrect.',
        );
    });

    await check('09_logout', revokeSession);

    if (sessionRevoked) {
        await check('10_revoked_session_rejected', async () => {
            const response = await http(expirePath, {});
            requireCondition(response.status === 401, `Expected 401; got ${response.status}.`);
        });
    } else {
        results.push({
            test: '10_revoked_session_rejected',
            result: 'FAIL',
            detail: 'Logout was not confirmed.',
        });
    }

    await check('11_existing_demo_unchanged', async () => {
        const result = await client.query(
            `SELECT to_jsonb(s) AS snapshot
             FROM app.member_subscriptions AS s
             WHERE tenant_id = $1::uuid AND id = $2::uuid`,
            [tenantId, demoSubscriptionId],
        );

        requireCondition(
            result.rowCount === 1 &&
            JSON.stringify(result.rows[0].snapshot) === JSON.stringify(originalDemo),
            'Existing demo subscription changed.',
        );
    });
} catch (error) {
    results.push({
        test: 'setup_or_execution',
        result: 'FAIL',
        detail: error.message,
    });
} finally {
    if (transactionOpen && connected) {
        await client.query('ROLLBACK').catch(() => {});
        transactionOpen = false;
    }

    // Attempt logout even if an earlier verification failed.
    if (!sessionRevoked && authorization) {
        await check('session_cleanup', revokeSession);
    }

    if (setupCommitted && connected) {
        await check('12_fixture_cleanup', async () => {
            try {
                await client.query('BEGIN');

                const owner = await client.query(
                    `SELECT id FROM app.members
                     WHERE id = $1::uuid
                       AND tenant_id = $2::uuid
                       AND email = $3
                     FOR UPDATE`,
                    [memberId, tenantId, fixtureEmail],
                );

                requireCondition(owner.rowCount === 1, 'Fixture ownership check failed; cleanup stopped.');

                await client.query(
                    `DELETE FROM app.subscription_expirations
                     WHERE tenant_id = $1::uuid
                       AND subscription_id = $2::uuid`,
                    [tenantId, subscriptionId],
                );

                const deletedSubscription = await client.query(
                    `DELETE FROM app.member_subscriptions
                     WHERE id = $1::uuid
                       AND tenant_id = $2::uuid
                       AND member_id = $3::uuid`,
                    [subscriptionId, tenantId, memberId],
                );

                requireCondition(deletedSubscription.rowCount === 1, 'Expected fixture subscription was not removed.');

                const deletedMember = await client.query(
                    `DELETE FROM app.members
                     WHERE id = $1::uuid
                       AND tenant_id = $2::uuid
                       AND email = $3`,
                    [memberId, tenantId, fixtureEmail],
                );

                requireCondition(deletedMember.rowCount === 1, 'Expected fixture member was not removed.');

                await client.query('COMMIT');
            } catch (error) {
                await client.query('ROLLBACK').catch(() => {});
                throw error;
            }

            const remaining = await client.query(
                `SELECT
                     EXISTS (
                         SELECT 1 FROM app.members WHERE id = $1::uuid
                     )
                     OR EXISTS (
                         SELECT 1 FROM app.member_subscriptions WHERE id = $2::uuid
                     )
                     OR EXISTS (
                         SELECT 1 FROM app.subscription_expirations
                         WHERE subscription_id = $2::uuid
                     ) AS fixtures_remain`,
                [memberId, subscriptionId],
            );

            requireCondition(
                remaining.rows[0].fixtures_remain === false,
                'Fixture records remain.',
            );
        });
    }

    await client.end().catch(() => {});

    console.table(results);

    const failed = results.some((row) => row.result !== 'PASS');

    if (failed) {
        console.log('FAIL: Review the failed verification rows.');
        console.log('Fixture member UUID:', memberId);
        console.log('Fixture subscription UUID:', subscriptionId);
        process.exitCode = 1;
    } else {
        console.log('PASS: Combined expiration verification completed.');
        console.log('PASS: Test session revoked and fixture records removed.');
    }
}
'@

try {
    $env:GYMPRO_EXPIRATION_DB_PASSWORD =
        $gymProDatabaseCredential.GetNetworkCredential().Password

    $env:GYMPRO_EXPIRATION_AUTHORIZATION = $Authorization

    $gymProVerificationScript | node.exe --input-type=module -

    $gymProVerificationExitCode = $LASTEXITCODE

    if ($gymProVerificationExitCode -ne 0) {
        throw 'Combined verification reported a failure. Review its results table.'
    }
}
finally {
    Remove-Item Env:\GYMPRO_EXPIRATION_DB_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_EXPIRATION_AUTHORIZATION -ErrorAction SilentlyContinue

    $gymProDatabaseSecret = $null
    $gymProDatabaseCredential = $null
    $gymProVerificationScript = $null
    $Authorization = $null
}