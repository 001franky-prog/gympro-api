param(
    [string]$BaseUrl = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

try {
    $gymProAdminSecret = Read-Host 'Password for admin.a@example.com' -AsSecureString
    $gymProDbSecret = Read-Host 'Local PostgreSQL postgres password' -AsSecureString

    $gymProAdminCredential = [System.Management.Automation.PSCredential]::new(
        'admin.a@example.com', $gymProAdminSecret
    )
    $gymProDbCredential = [System.Management.Automation.PSCredential]::new(
        'postgres', $gymProDbSecret
    )

    $env:GYMPRO_FOC_TEST_ADMIN_PASSWORD = $gymProAdminCredential.GetNetworkCredential().Password
    $env:GYMPRO_FOC_TEST_DB_PASSWORD = $gymProDbCredential.GetNetworkCredential().Password
    $env:GYMPRO_FOC_TEST_BASE_URL = $BaseUrl

    @'
import { randomUUID } from 'node:crypto';
import pg from 'pg';

const { Client } = pg;
const base = process.env.GYMPRO_FOC_TEST_BASE_URL.replace(/\/$/, '');
const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const membership = '3b318e89-f3bc-4ac5-a04d-09fdb3d626de';
const user = '059e261a-226a-4f9e-93ee-86d374430406';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const demos = [
  '3113ab9f-8edd-41f4-afe6-c8f03e291f89',
  '41f45bd6-114c-4241-9be0-0a949dc5f2b6',
];
const demoSubscription = '8a28fa97-e41f-4053-be61-8162ff3d387d';

const member = randomUUID();
const role = randomUUID();
const request = randomUUID();
const fixtureEmail = `foc-${member}@example.invalid`;
const roleCode = `FOC_TEST_${role.replaceAll('-', '').slice(0, 12).toUpperCase()}`;
const reason = 'Gym Pro combined FOC API verification';
const results = [];
let dbConnected = false;
let authorization;
let receipt;
let baseline;
let failed = false;

const db = new Client({
  host: '127.0.0.1',
  port: 5432,
  database: 'gympro_saas',
  user: 'postgres',
  password: process.env.GYMPRO_FOC_TEST_DB_PASSWORD,
  connectionTimeoutMillis: 5000,
});

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function test(name, action) {
  try {
    await action();
    results.push({ test: name, result: 'PASS', detail: '' });
  } catch (error) {
    failed = true;
    results.push({ test: name, result: 'FAIL', detail: error.message });
    throw error;
  }
}

async function http(path, body, auth = authorization, method = 'POST') {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (auth) headers.Authorization = auth;
  const response = await fetch(`${base}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : undefined; }
  catch { data = undefined; }
  return { status: response.status, data };
}

const grantPath = `/tenants/${tenant}/members/${member}/subscriptions/grant-foc`;
const input = { planId: plan, planPriceId: price, reason, requestId: request };

async function snapshot() {
  const result = await db.query(`
    SELECT jsonb_build_object(
      'members', (
        SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
        FROM app.members m WHERE m.id = ANY($1::uuid[])
      ),
      'subscription', (
        SELECT to_jsonb(s) FROM app.member_subscriptions s WHERE s.id = $2::uuid
      )
    )::text AS snapshot
  `, [demos, demoSubscription]);
  return result.rows[0].snapshot;
}

async function canGrant() {
  const result = await db.query(`
    SELECT security.has_tenant_permission(
      $1::uuid, $2::uuid, 'gym.memberships.grant_foc', NULL::uuid
    ) AS allowed
  `, [tenant, membership]);
  return result.rows[0].allowed;
}

async function fixtureState() {
  return (await db.query(`
    SELECT
      (SELECT status FROM app.members WHERE id = $1::uuid) AS member_status,
      (SELECT count(*)::int FROM app.member_subscriptions
       WHERE tenant_id = $2::uuid AND member_id = $1::uuid) AS subscriptions,
      (SELECT count(*)::int FROM app.subscription_foc_grants g
       JOIN app.member_subscriptions s
         ON s.tenant_id = g.tenant_id AND s.id = g.subscription_id
       WHERE s.tenant_id = $2::uuid AND s.member_id = $1::uuid) AS grants
  `, [member, tenant])).rows[0];
}

try {
  await test('01_login_and_verified_session', async () => {
    const login = await http('/auth/login', {
      email: 'admin.a@example.com',
      password: process.env.GYMPRO_FOC_TEST_ADMIN_PASSWORD,
      tenantId: tenant,
    }, undefined);
    assert(login.status === 200 || login.status === 201,
      `Login failed: HTTP ${login.status}. ${login.data?.message ?? ''}`);
    assert(typeof login.data?.accessToken === 'string', 'Access token missing.');
    authorization = `Bearer ${login.data.accessToken}`;
    const me = await http('/auth/me', undefined, authorization, 'GET');
    assert(me.status === 200, 'Session verification failed.');
    assert(me.data.tenantId === tenant &&
      me.data.membershipId === membership &&
      me.data.userId === user, 'Unexpected session identity.');
  });

  await db.connect();
  dbConnected = true;
  baseline = await snapshot();

  await test('02_setup_and_permission_baseline', async () => {
    assert(await canGrant() === false, 'Demo administrator already has FOC permission.');
    const prerequisites = await db.query(`
      SELECT p.duration_value, p.duration_unit, pp.price_amount::text AS amount
      FROM app.membership_plans p
      JOIN app.plan_prices pp ON pp.tenant_id = p.tenant_id AND pp.plan_id = p.id
      WHERE p.tenant_id = $1::uuid AND p.id = $2::uuid
        AND pp.id = $3::uuid AND p.status = 'active'
        AND pp.status = 'active' AND pp.branch_id IS NULL
    `, [tenant, plan, price]);
    assert(prerequisites.rowCount === 1, 'Active demo plan or general price missing.');
    assert(prerequisites.rows[0].amount === '50000.00',
      'Demo price changed; inspect before testing.');
    await db.query(`
      INSERT INTO app.members(id, tenant_id, full_name, email)
      VALUES($1::uuid, $2::uuid, 'Gym Pro FOC API Fixture', $3::text)
    `, [member, tenant, fixtureEmail]);
  });

  await test('03_unauthenticated_grant', async () => {
    assert((await http(grantPath, input, null)).status === 401,
      'Expected HTTP 401.');
  });

  await test('04_ordinary_admin_permission_denied', async () => {
    assert((await http(grantPath, input)).status === 403, 'Expected HTTP 403.');
    const state = await fixtureState();
    assert(state.member_status === 'pending' &&
      state.subscriptions === 0 && state.grants === 0,
      'Denied grant changed fixture records.');
  });

  await test('05_temporary_dedicated_permission', async () => {
    await db.query('BEGIN');
    try {
      await db.query(`
        INSERT INTO app.roles(id, tenant_id, role_code, role_name, is_system_role, status)
        VALUES($1::uuid, $2::uuid, $3::text, 'Temporary FOC API verification', false, 'active')
      `, [role, tenant, roleCode]);
      const assigned = await db.query(`
        INSERT INTO app.role_permissions(tenant_id, role_id, permission_id)
        SELECT $1::uuid, $2::uuid, id
        FROM app.permissions
        WHERE permission_code = 'gym.memberships.grant_foc' AND is_active
        RETURNING id
      `, [tenant, role]);
      assert(assigned.rowCount === 1, 'Dedicated active FOC permission missing.');
      await db.query(`
        INSERT INTO app.role_assignments(tenant_id, membership_id, role_id, scope_type, branch_id)
        VALUES($1::uuid, $2::uuid, $3::uuid, 'tenant', NULL)
      `, [tenant, membership, role]);
      assert(await canGrant() === true, 'Temporary permission is ineffective.');
      await db.query('COMMIT');
    } catch (error) {
      await db.query('ROLLBACK');
      throw error;
    }
  });

  await test('06_cross_tenant_rejected', async () => {
    const path = `/tenants/${otherTenant}/members/${member}/subscriptions/grant-foc`;
    assert((await http(path, input)).status === 403, 'Expected HTTP 403.');
  });

  await test('07_blank_reason_rejected', async () => {
    assert((await http(grantPath, { ...input, reason: '   ' })).status === 400,
      'Expected HTTP 400.');
  });

  await test('08_client_price_rejected', async () => {
    assert((await http(grantPath, { ...input, agreedPriceAmount: '0.00' })).status === 400,
      'Expected HTTP 400.');
  });

  await test('09_client_dates_rejected', async () => {
    assert((await http(grantPath, { ...input, startsOn: '2026-01-01' })).status === 400,
      'Expected HTTP 400.');
  });

  await test('10_missing_request_rejected', async () => {
    const { requestId, ...withoutRequest } = input;
    assert((await http(grantPath, withoutRequest)).status === 400, 'Expected HTTP 400.');
  });

  await test('11_rejections_saved_nothing', async () => {
    const state = await fixtureState();
    assert(state.member_status === 'pending' &&
      state.subscriptions === 0 && state.grants === 0, 'Unexpected fixture changes.');
  });

  await test('12_successful_foc_grant', async () => {
    const result = await http(grantPath, input);
    assert(result.status === 200, `Expected HTTP 200; received ${result.status}.`);
    receipt = result.data;
    assert(receipt?.tenantId === tenant && receipt.requestId === request &&
      receipt.reason === reason && receipt.listedPriceAmount === '50000.00' &&
      receipt.currencyCode === 'MMK' && receipt.subscriptionId && receipt.id,
      'Incorrect public FOC receipt.');
    assert(!('previousMemberSnapshot' in receipt) &&
      !('previous_member_snapshot' in receipt), 'Private snapshot leaked.');
  });

  await test('13_retry_returns_original_receipt', async () => {
    const retry = await http(grantPath, input);
    assert(retry.status === 200 &&
      JSON.stringify(retry.data) === JSON.stringify(receipt),
      'Retry did not return the original receipt.');
  });

  await test('14_zero_price_coverage_and_actor_audit', async () => {
    const saved = await db.query(`
      SELECT s.membership_kind, s.status,
        s.agreed_price_amount::text AS agreed,
        s.currency_code, s.duration_value, s.duration_unit,
        s.starts_on::text AS starts_on, s.ends_on::text AS ends_on,
        (s.starts_on = (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date
         AND s.ends_on = (
           s.starts_on + make_interval(months => 1)
         )::date) AS correct_dates,
        m.status AS member_status,
        g.listed_price_amount::text AS listed,
        g.reason, g.request_id::text AS request_id,
        g.previous_member_snapshot->>'status' AS previous_status,
        g.previous_member_snapshot->>'granted_by_membership_id' AS actor_membership,
        g.previous_member_snapshot->>'granted_by_user_id' AS actor_user
      FROM app.member_subscriptions s
      JOIN app.members m ON m.tenant_id = s.tenant_id AND m.id = s.member_id
      JOIN app.subscription_foc_grants g
        ON g.tenant_id = s.tenant_id AND g.subscription_id = s.id
      WHERE s.tenant_id = $1::uuid AND s.member_id = $2::uuid
        AND s.id = $3::uuid AND g.id = $4::uuid
    `, [tenant, member, receipt.subscriptionId, receipt.id]);
    assert(saved.rowCount === 1, 'Expected exactly one saved grant.');
    const row = saved.rows[0];
    assert(row.membership_kind === 'foc' && row.status === 'active' &&
      row.agreed === '0.00' && row.listed === '50000.00' &&
      row.currency_code === 'MMK' && row.duration_value === 1 &&
      row.duration_unit === 'months' && row.correct_dates &&
      row.member_status === 'active' && row.previous_status === 'pending' &&
      row.reason === reason && row.request_id === request &&
      row.actor_membership === membership && row.actor_user === user,
      'FOC values, coverage, or actor audit mismatch.');
  });

  await test('15_request_reuse_conflict', async () => {
    assert((await http(grantPath, { ...input, reason: 'Different verification reason' })).status === 400,
      'Expected HTTP 400.');
  });

  await test('16_second_current_grant_rejected', async () => {
    assert((await http(grantPath, { ...input, requestId: randomUUID() })).status === 400,
      'Expected HTTP 400.');
  });

  await test('17_ordinary_foc_renewal_rejected', async () => {
    const path = `/tenants/${tenant}/subscriptions/${receipt.subscriptionId}/renew`;
    assert((await http(path, { planPriceId: price, requestId: randomUUID() })).status === 400,
      'Expected HTTP 400.');
  });

  await test('18_grant_saved_once_and_renewal_absent', async () => {
    const state = await fixtureState();
    assert(state.member_status === 'active' &&
      state.subscriptions === 1 && state.grants === 1, 'Duplicate grant detected.');
    const renewals = await db.query(`
      SELECT count(*)::int AS count FROM app.subscription_renewals
      WHERE tenant_id = $1::uuid AND subscription_id = $2::uuid
    `, [tenant, receipt.subscriptionId]);
    assert(renewals.rows[0].count === 0, 'FOC renewal history was created.');
  });

  await test('19_logout', async () => {
    assert((await http('/auth/logout')).status === 204, 'Expected HTTP 204.');
  });

  await test('20_revoked_session_rejected', async () => {
    assert((await http(grantPath, input)).status === 401, 'Expected HTTP 401.');
  });
} catch (error) {
  failed = true;
  if (!results.some(row => row.result === 'FAIL')) {
    results.push({ test: 'setup_or_execution', result: 'FAIL', detail: error.message });
  }
} finally {
  if (authorization) {
    try {
      const result = await http('/auth/logout');
      assert([204, 401].includes(result.status), 'Session cleanup failed.');
    } catch (error) {
      failed = true;
      results.push({ test: 'session_cleanup', result: 'FAIL', detail: error.message });
    }
  }

  if (dbConnected) {
    try {
      await db.query('BEGIN');
      const owned = await db.query(`
        SELECT id FROM app.members
        WHERE id = $1::uuid AND tenant_id = $2::uuid AND email = $3::text
        FOR UPDATE
      `, [member, tenant, fixtureEmail]);
      if (owned.rowCount === 1) {
        for (const table of [
          'subscription_foc_grants',
          'subscription_expirations',
          'subscription_suspensions',
          'subscription_renewals',
        ]) {
          await db.query(`
            DELETE FROM app.${table} h
            USING app.member_subscriptions s
            WHERE h.tenant_id = s.tenant_id AND h.subscription_id = s.id
              AND s.tenant_id = $1::uuid AND s.member_id = $2::uuid
          `, [tenant, member]);
        }
        await db.query(`
          DELETE FROM app.member_blacklist_events
          WHERE tenant_id = $1::uuid AND member_id = $2::uuid
        `, [tenant, member]);
        await db.query(`
          DELETE FROM app.member_subscriptions
          WHERE tenant_id = $1::uuid AND member_id = $2::uuid
        `, [tenant, member]);
        await db.query(`
          DELETE FROM app.members
          WHERE tenant_id = $1::uuid AND id = $2::uuid AND email = $3::text
        `, [tenant, member, fixtureEmail]);
      }

      await db.query(`
        DELETE FROM app.role_assignments
        WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.role_permissions
        WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.roles
        WHERE tenant_id = $1::uuid AND id = $2::uuid AND role_code = $3::text
      `, [tenant, role, roleCode]);
      await db.query('COMMIT');

      await test('21_fixture_and_temporary_role_cleanup', async () => {
        const remaining = await db.query(`
          SELECT
            (SELECT count(*)::int FROM app.members WHERE id = $1::uuid) AS members,
            (SELECT count(*)::int FROM app.member_subscriptions WHERE member_id = $1::uuid) AS subscriptions,
            (SELECT count(*)::int FROM app.subscription_foc_grants WHERE request_id = $2::uuid) AS grants,
            (SELECT count(*)::int FROM app.roles WHERE id = $3::uuid) AS roles,
            (SELECT count(*)::int FROM app.role_assignments WHERE role_id = $3::uuid) AS assignments,
            (SELECT count(*)::int FROM app.role_permissions WHERE role_id = $3::uuid) AS permissions
        `, [member, request, role]);
        assert(Object.values(remaining.rows[0]).every(value => value === 0),
          'Fixture or temporary role records remain.');
      });

      await test('22_admin_foc_permission_restored', async () => {
        assert(await canGrant() === false, 'Temporary FOC authorization remains.');
      });

      if (baseline !== undefined) {
        await test('23_existing_demo_records_unchanged', async () => {
          assert(await snapshot() === baseline, 'Existing demo records changed.');
        });
      }
    } catch (error) {
      failed = true;
      try { await db.query('ROLLBACK'); } catch {}
      if (!results.some(row => row.result === 'FAIL' && row.detail === error.message)) {
        results.push({ test: 'database_cleanup', result: 'FAIL', detail: error.message });
      }
    }
    await db.end();
  }

  console.table(results);
  if (failed) {
    console.error('FAIL: Review failed verification rows.');
    console.error(`Fixture member UUID: ${member}`);
    console.error(`Temporary role UUID: ${role}`);
    process.exitCode = 1;
  } else {
    console.log('PASS: Combined FOC API verification completed.');
    console.log('PASS: Session revoked, fixtures and temporary role removed, demo records unchanged.');
  }
}
'@ | node.exe --input-type=module -

    if ($LASTEXITCODE -ne 0) {
        throw 'Combined FOC verification reported a failure. Review the results table.'
    }
}
finally {
    Remove-Item Env:\GYMPRO_FOC_TEST_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_FOC_TEST_DB_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_FOC_TEST_BASE_URL -ErrorAction SilentlyContinue
    $gymProAdminSecret = $null
    $gymProDbSecret = $null
    $gymProAdminCredential = $null
    $gymProDbCredential = $null
}