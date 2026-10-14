$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$gymProAdminSecret = Read-Host 'Password for admin.a@example.com' -AsSecureString
$gymProDbSecret = Read-Host 'Local PostgreSQL postgres password' -AsSecureString

$gymProAdminCredential = [System.Management.Automation.PSCredential]::new(
    'admin.a@example.com', $gymProAdminSecret
)

$gymProDbCredential = [System.Management.Automation.PSCredential]::new(
    'postgres', $gymProDbSecret
)

$gymProScript = @'
import pg from 'pg';
import { randomUUID } from 'node:crypto';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';

const member = randomUUID();
const subscription = randomUUID();
const blacklistRequest = randomUUID();
const removalRequest = randomUUID();
const email = `b6-api-${member}@example.invalid`;

const client = new pg.Client({
    host: '127.0.0.1',
    port: 5432,
    database: 'gympro_saas',
    user: 'postgres',
    password: process.env.GYMPRO_B6_DB_PASSWORD,
    connectionTimeoutMillis: 5000,
});

const results = [];
let authorization;
let connected = false;
let transactionOpen = false;
let fixturesSaved = false;
let revoked = false;
let originalDemo;
let originalSubscription;
let blacklistReceipt;
let removalReceipt;

function requireCheck(value, message) {
    if (!value) throw new Error(message);
}

async function check(name, action) {
    try {
        await action();
        results.push({ test: name, result: 'PASS', detail: '' });
    } catch (error) {
        results.push({ test: name, result: 'FAIL', detail: error.message });
    }
}

async function http(path, body, authenticated = true, method = 'POST') {
    const headers = { 'Content-Type': 'application/json' };
    if (authenticated && authorization) headers.Authorization = authorization;

    const response = await fetch(`http://127.0.0.1:3000${path}`, {
        method,
        headers,
        ...(method === 'GET' ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(10000),
    });

    const text = await response.text();
    let data = null;
    if (text) {
        try { data = JSON.parse(text); } catch {}
    }
    return { status: response.status, data };
}

async function expectStatus(path, body, status, authenticated = true) {
    const response = await http(path, body, authenticated);
    requireCheck(response.status === status, `Expected HTTP ${status}; got ${response.status}.`);
    return response.data;
}

async function demoSnapshot() {
    const result = await client.query(
        `SELECT jsonb_build_object(
            'members', (
                SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
                FROM app.members AS m
                WHERE m.id IN (
                    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
                    '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid
                )
            ),
            'subscription', (
                SELECT to_jsonb(s)
                FROM app.member_subscriptions AS s
                WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
            )
        ) AS snapshot`,
    );
    return result.rows[0].snapshot;
}

async function logout() {
    await expectStatus('/auth/logout', {}, 204);
    revoked = true;
}

const base = `/tenants/${tenant}/members/${member}`;
const blacklistBody = {
    reason: 'Combined blacklist API verification',
    requestId: blacklistRequest,
};
const removalBody = {
    reason: 'Combined blacklist removal verification',
    requestId: removalRequest,
};

try {
    const login = await http('/auth/login', {
        email: 'admin.a@example.com',
        password: process.env.GYMPRO_B6_ADMIN_PASSWORD,
        tenantId: tenant,
    }, false);

    requireCheck(login.status === 200 && login.data?.accessToken, `Login failed: HTTP ${login.status}.`);
    authorization = `Bearer ${login.data.accessToken}`;

    const me = await http('/auth/me', undefined, true, 'GET');
    requireCheck(
        me.status === 200 &&
        me.data?.tenantId === tenant &&
        me.data?.membershipId === '3b318e89-f3bc-4ac5-a04d-09fdb3d626de' &&
        me.data?.userId === '059e261a-226a-4f9e-93ee-86d374430406',
        'Session identity verification failed.',
    );
    results.push({ test: '01_login_and_session', result: 'PASS', detail: '' });

    await client.connect();
    connected = true;
    originalDemo = await demoSnapshot();

    await client.query('BEGIN');
    transactionOpen = true;

    await client.query(
        `INSERT INTO app.members (id, tenant_id, full_name, email, status)
         VALUES ($1::uuid, $2::uuid, 'B6 Combined API Test', $3, 'active')`,
        [member, tenant, email],
    );

    const inserted = await client.query(
        `INSERT INTO app.member_subscriptions (
            id, tenant_id, member_id, plan_id, plan_price_id,
            duration_value, duration_unit, agreed_price_amount,
            currency_code, status, starts_on, ends_on, activated_at
         )
         SELECT
            $1::uuid, p.tenant_id, $2::uuid, p.id, pp.id,
            p.duration_value, p.duration_unit, pp.price_amount,
            pp.currency_code, 'active',
            (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date,
            (
                (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
                + INTERVAL '1 month'
            )::date,
            statement_timestamp()
         FROM app.membership_plans AS p
         JOIN app.plan_prices AS pp
           ON pp.tenant_id = p.tenant_id AND pp.plan_id = p.id
         WHERE p.tenant_id = $3::uuid AND p.id = $4::uuid
           AND pp.id = $5::uuid
           AND p.status = 'active' AND pp.status = 'active'
           AND pp.branch_id IS NULL
         RETURNING to_jsonb(member_subscriptions) AS snapshot`,
        [subscription, member, tenant, plan, price],
    );

    requireCheck(inserted.rowCount === 1, 'Active demo plan/price is missing.');
    originalSubscription = inserted.rows[0].snapshot;

    await client.query('COMMIT');
    transactionOpen = false;
    fixturesSaved = true;

    await check('02_unauthenticated_blacklist', async () => {
        await expectStatus(`${base}/blacklist`, blacklistBody, 401, false);
    });

    await check('03_unauthenticated_removal', async () => {
        await expectStatus(`${base}/unblacklist`, removalBody, 401, false);
    });

    await check('04_cross_tenant_rejected', async () => {
        await expectStatus(
            `/tenants/${otherTenant}/members/${member}/blacklist`,
            blacklistBody, 403,
        );
    });

    await check('05_blank_reason_rejected', async () => {
        await expectStatus(`${base}/blacklist`, {
            reason: '   ', requestId: randomUUID(),
        }, 400);
    });

    await check('06_client_status_rejected', async () => {
        await expectStatus(`${base}/blacklist`, {
            ...blacklistBody, resultingStatus: 'active',
        }, 400);
    });

    await check('07_blacklist_success', async () => {
        blacklistReceipt = await expectStatus(`${base}/blacklist`, blacklistBody, 200);
        requireCheck(
            blacklistReceipt?.tenantId === tenant &&
            blacklistReceipt.memberId === member &&
            blacklistReceipt.requestId === blacklistRequest &&
            blacklistReceipt.eventType === 'blacklist' &&
            blacklistReceipt.reason === blacklistBody.reason &&
            blacklistReceipt.previousStatus === 'active' &&
            blacklistReceipt.resultingStatus === 'blacklisted' &&
            !Object.hasOwn(blacklistReceipt, 'previous_member_snapshot'),
            'Unexpected blacklist receipt.',
        );
    });

    await check('08_saved_blacklist_and_audit', async () => {
        const result = await client.query(
            `SELECT m.status, h.id,
                h.previous_member_snapshot ->> 'status' AS previous_status,
                h.previous_member_snapshot ->> 'changed_by_membership_id' AS actor
             FROM app.members AS m
             JOIN app.member_blacklist_events AS h
               ON h.tenant_id = m.tenant_id AND h.member_id = m.id
             WHERE m.id = $1::uuid AND h.request_id = $2::uuid`,
            [member, blacklistRequest],
        );
        requireCheck(
            result.rowCount === 1 &&
            result.rows[0].status === 'blacklisted' &&
            result.rows[0].id === blacklistReceipt?.id &&
            result.rows[0].previous_status === 'active' &&
            result.rows[0].actor === '3b318e89-f3bc-4ac5-a04d-09fdb3d626de',
            'Blacklist database state or audit is incorrect.',
        );
    });

    await check('09_blacklist_retry', async () => {
        requireCheck(Boolean(blacklistReceipt), 'First receipt unavailable.');
        const retry = await expectStatus(`${base}/blacklist`, blacklistBody, 200);
        requireCheck(JSON.stringify(retry) === JSON.stringify(blacklistReceipt), 'Retry changed the receipt.');
    });

    await check('10_request_reuse_conflict', async () => {
        await expectStatus(`${base}/blacklist`, {
            ...blacklistBody, reason: 'Different reason',
        }, 400);
    });

    await check('11_renewal_blocked_while_blacklisted', async () => {
        await expectStatus(
            `/tenants/${tenant}/subscriptions/${subscription}/renew`,
            { planPriceId: price, requestId: randomUUID() }, 400,
        );
    });

    await check('12_suspension_blocked_while_blacklisted', async () => {
        await expectStatus(
            `/tenants/${tenant}/subscriptions/${subscription}/suspend`,
            { reason: 'Verification attempt', requestId: randomUUID() }, 400,
        );
    });

    await check('13_removal_restores_active', async () => {
        removalReceipt = await expectStatus(`${base}/unblacklist`, removalBody, 200);
        requireCheck(
            removalReceipt?.tenantId === tenant &&
            removalReceipt.memberId === member &&
            removalReceipt.requestId === removalRequest &&
            removalReceipt.eventType === 'unblacklist' &&
            removalReceipt.previousStatus === 'blacklisted' &&
            removalReceipt.resultingStatus === 'active',
            'Removal did not restore active coverage status.',
        );
    });

    await check('14_removal_retry', async () => {
        requireCheck(Boolean(removalReceipt), 'Removal receipt unavailable.');
        const retry = await expectStatus(`${base}/unblacklist`, removalBody, 200);
        requireCheck(JSON.stringify(retry) === JSON.stringify(removalReceipt), 'Removal retry changed the receipt.');
    });

    await check('15_old_retry_does_not_reapply_blacklist', async () => {
        requireCheck(Boolean(blacklistReceipt), 'First receipt unavailable.');
        const retry = await expectStatus(`${base}/blacklist`, blacklistBody, 200);
        requireCheck(JSON.stringify(retry) === JSON.stringify(blacklistReceipt), 'Old retry changed the receipt.');

        const memberResult = await client.query(
            'SELECT status FROM app.members WHERE id = $1::uuid', [member],
        );
        requireCheck(memberResult.rows[0]?.status === 'active', 'Old retry reapplied the blacklist.');
    });

    await check('16_history_once_and_subscription_unchanged', async () => {
        const result = await client.query(
            `SELECT
                (SELECT count(*)::integer FROM app.member_blacklist_events
                 WHERE member_id = $1::uuid) AS event_rows,
                (SELECT to_jsonb(s) FROM app.member_subscriptions AS s
                 WHERE id = $2::uuid) AS snapshot,
                (SELECT count(*)::integer FROM app.subscription_renewals
                 WHERE subscription_id = $2::uuid) AS renewal_rows,
                (SELECT count(*)::integer FROM app.subscription_suspensions
                 WHERE subscription_id = $2::uuid) AS suspension_rows`,
            [member, subscription],
        );
        const row = result.rows[0];
        requireCheck(
            row.event_rows === 2 &&
            row.renewal_rows === 0 &&
            row.suspension_rows === 0 &&
            JSON.stringify(row.snapshot) === JSON.stringify(originalSubscription),
            'History duplicates or unexpected subscription changes found.',
        );
    });

    await check('17_logout', logout);

    if (revoked) {
        await check('18_revoked_session_rejected', async () => {
            await expectStatus(`${base}/blacklist`, {
                reason: 'Revoked session check', requestId: randomUUID(),
            }, 401);
        });
    } else {
        results.push({ test: '18_revoked_session_rejected', result: 'FAIL', detail: 'Logout not confirmed.' });
    }

    await check('19_existing_demo_unchanged', async () => {
        requireCheck(
            JSON.stringify(await demoSnapshot()) === JSON.stringify(originalDemo),
            'Existing demo records changed.',
        );
    });
} catch (error) {
    results.push({ test: 'setup_or_execution', result: 'FAIL', detail: error.message });
} finally {
    if (transactionOpen && connected) {
        await client.query('ROLLBACK').catch(() => {});
    }

    if (authorization && !revoked) {
        await check('session_cleanup', logout);
    }

    if (fixturesSaved && connected) {
        await check('20_fixture_cleanup', async () => {
            try {
                await client.query('BEGIN');

                const owned = await client.query(
                    `SELECT id FROM app.members
                     WHERE id = $1::uuid AND tenant_id = $2::uuid AND email = $3
                     FOR UPDATE`,
                    [member, tenant, email],
                );
                requireCheck(owned.rowCount === 1, 'Fixture ownership check failed.');

                for (const table of [
                    'subscription_expirations',
                    'subscription_suspensions',
                    'subscription_renewals',
                ]) {
                    await client.query(
                        `DELETE FROM app.${table}
                         WHERE tenant_id = $1::uuid AND subscription_id = $2::uuid`,
                        [tenant, subscription],
                    );
                }

                await client.query(
                    `DELETE FROM app.member_blacklist_events
                     WHERE tenant_id = $1::uuid AND member_id = $2::uuid`,
                    [tenant, member],
                );

                const removedSubscription = await client.query(
                    `DELETE FROM app.member_subscriptions
                     WHERE id = $1::uuid AND tenant_id = $2::uuid AND member_id = $3::uuid`,
                    [subscription, tenant, member],
                );
                requireCheck(removedSubscription.rowCount === 1, 'Fixture subscription removal failed.');

                const removedMember = await client.query(
                    `DELETE FROM app.members
                     WHERE id = $1::uuid AND tenant_id = $2::uuid AND email = $3`,
                    [member, tenant, email],
                );
                requireCheck(removedMember.rowCount === 1, 'Fixture member removal failed.');

                await client.query('COMMIT');
            } catch (error) {
                await client.query('ROLLBACK').catch(() => {});
                throw error;
            }

            const remaining = await client.query(
                `SELECT
                    EXISTS (SELECT 1 FROM app.members WHERE id = $1::uuid)
                    OR EXISTS (
                        SELECT 1 FROM app.member_subscriptions WHERE id = $2::uuid
                    )
                    OR EXISTS (
                        SELECT 1 FROM app.member_blacklist_events WHERE member_id = $1::uuid
                    ) AS fixtures_remain`,
                [member, subscription],
            );
            requireCheck(!remaining.rows[0].fixtures_remain, 'Fixture records remain.');
        });
    }

    await client.end().catch(() => {});
    console.table(results);

    if (results.some(row => row.result !== 'PASS')) {
        console.log('FAIL: Review failed verification rows.');
        console.log('Fixture member UUID:', member);
        console.log('Fixture subscription UUID:', subscription);
        process.exitCode = 1;
    } else {
        console.log('PASS: Combined blacklist verification completed.');
        console.log('PASS: Session revoked, fixtures removed, and demo records unchanged.');
    }
}
'@

try {
    $env:GYMPRO_B6_ADMIN_PASSWORD = $gymProAdminCredential.GetNetworkCredential().Password
    $env:GYMPRO_B6_DB_PASSWORD = $gymProDbCredential.GetNetworkCredential().Password

    $gymProScript | node.exe --input-type=module -

    if ($LASTEXITCODE -ne 0) {
        throw 'Combined verification reported a failure. Review the results table.'
    }
}
finally {
    Remove-Item Env:\GYMPRO_B6_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_B6_DB_PASSWORD -ErrorAction SilentlyContinue

    $gymProAdminSecret = $null
    $gymProDbSecret = $null
    $gymProAdminCredential = $null
    $gymProDbCredential = $null
    $gymProScript = $null
}