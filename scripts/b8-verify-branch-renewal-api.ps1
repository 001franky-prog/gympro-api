param(
    [string]$BaseUrl = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

try {
    $gymProDbSecret = Read-Host 'Local PostgreSQL postgres password' -AsSecureString
    $gymProDbCredential = [System.Management.Automation.PSCredential]::new(
        'postgres', $gymProDbSecret
    )

    $env:GYMPRO_B8_DB_PASSWORD = $gymProDbCredential.GetNetworkCredential().Password
    $env:GYMPRO_B8_BASE_URL = $BaseUrl

    @'
import pg from 'pg';
import argon2 from 'argon2';
import { randomUUID, randomBytes } from 'node:crypto';

const { Client } = pg;
const base = process.env.GYMPRO_B8_BASE_URL.replace(/\/$/, '');
const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const generalPrice = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const user = randomUUID();
const membership = randomUUID();
const role = randomUUID();
const branch = randomUUID();
const otherBranch = randomUUID();
const otherBranchPrice = randomUUID();
const member = randomUUID();
const otherMember = randomUUID();
const tenantMember = randomUUID();
const tag = `B8_${user.replaceAll('-', '').slice(0, 16).toUpperCase()}`;
const email = `${user}@example.invalid`;
const registrationEmail = `registered-${user}@example.invalid`;
const memberEmails = [member, otherMember, tenantMember]
  .map(id => `${id}@example.invalid`).concat(registrationEmail);
const password = randomBytes(32).toString('base64url');
const results = [];
let authorization;
let activation;
let baseline;
let connected = false;
let failed = false;

const db = new Client({
  host: '127.0.0.1', port: 5432,
  database: 'gympro_saas', user: 'postgres',
  password: process.env.GYMPRO_B8_DB_PASSWORD,
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
    method, headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : undefined; } catch {}
  return { status: response.status, data };
}

function activationPath(branchId = branch, memberId = member, tenantId = tenant) {
  return `/tenants/${tenantId}/branches/${branchId}/members/${memberId}/subscriptions/activate`;
}

const input = { planId: plan, planPriceId: generalPrice };

async function snapshot() {
  return (await db.query(`
    SELECT jsonb_build_object(
      'members', (
        SELECT jsonb_agg(to_jsonb(m) ORDER BY id)
        FROM app.members m WHERE id = ANY($1::uuid[])
      ),
      'subscription', (
        SELECT to_jsonb(s) FROM app.member_subscriptions s WHERE id = $2::uuid
      )
    )::text AS snapshot
  `, [[
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89',
    '41f45bd6-114c-4241-9be0-0a949dc5f2b6',
  ], '8a28fa97-e41f-4053-be61-8162ff3d387d'])).rows[0].snapshot;
}

try {
  await db.connect();
  connected = true;
  baseline = await snapshot();

  await test('01_isolated_branch_staff_setup', async () => {
    const prerequisites = await db.query(`
      SELECT pp.price_amount::text AS amount
      FROM app.plan_prices pp
      JOIN app.membership_plans p ON p.tenant_id = pp.tenant_id AND p.id = pp.plan_id
      WHERE pp.tenant_id = $1::uuid AND pp.id = $2::uuid AND p.id = $3::uuid
        AND pp.status = 'active' AND p.status = 'active' AND pp.branch_id IS NULL
    `, [tenant, generalPrice, plan]);
    assert(prerequisites.rowCount === 1 && prerequisites.rows[0].amount === '50000.00',
      'Expected active demo plan and price missing.');

    const hash = await argon2.hash(password, { type: argon2.argon2id });
    await db.query('BEGIN');
    try {
      await db.query(`
        INSERT INTO app.users(id, email, full_name, password_hash, status)
        VALUES($1::uuid, $2::text, 'B8 API branch staff', $3::text, 'active')
      `, [user, email, hash]);
      await db.query(`
        INSERT INTO app.tenant_memberships(id, tenant_id, user_id, status, joined_at)
        VALUES($1::uuid, $2::uuid, $3::uuid, 'active', CURRENT_TIMESTAMP)
      `, [membership, tenant, user]);
      for (const [id, suffix] of [[branch, 'A'], [otherBranch, 'B']]) {
        await db.query(`
          INSERT INTO app.branches(id, tenant_id, branch_code, branch_name, status)
          VALUES($1::uuid, $2::uuid, $3::text, 'B8 API fixture branch', 'active')
        `, [id, tenant, `${tag}_${suffix}`]);
      }
      await db.query(`
        INSERT INTO app.roles(id, tenant_id, role_code, role_name, is_system_role, status)
        VALUES($1::uuid, $2::uuid, $3::text, 'B8 API branch-only role', false, 'active')
      `, [role, tenant, tag]);
      const assigned = await db.query(`
        INSERT INTO app.role_permissions(tenant_id, role_id, permission_id)
        SELECT $1::uuid, $2::uuid, id FROM app.permissions
        WHERE permission_code IN ('gym.members.create', 'gym.memberships.manage')
          AND is_active
        RETURNING id
      `, [tenant, role]);
      assert(assigned.rowCount === 2, 'Required active permissions missing.');
      await db.query(`
        INSERT INTO app.role_assignments(tenant_id, membership_id, role_id, scope_type, branch_id)
        VALUES($1::uuid, $2::uuid, $3::uuid, 'branch', $4::uuid)
      `, [tenant, membership, role, branch]);

      for (const [id, branchId] of [
        [member, branch], [otherMember, otherBranch], [tenantMember, null],
      ]) {
        await db.query(`
          INSERT INTO app.members(id, tenant_id, branch_id, full_name, email)
          VALUES($1::uuid, $2::uuid, $3::uuid, 'B8 API member fixture', $4::text)
        `, [id, tenant, branchId, `${id}@example.invalid`]);
      }
      await db.query(`
        INSERT INTO app.plan_prices(id, tenant_id, plan_id, branch_id, price_amount, status)
        VALUES($1::uuid, $2::uuid, $3::uuid, $4::uuid, 55000, 'active')
      `, [otherBranchPrice, tenant, plan, otherBranch]);
      await db.query('COMMIT');
    } catch (error) {
      await db.query('ROLLBACK');
      throw error;
    }
  });

  await test('02_branch_staff_login_and_session', async () => {
    const login = await http('/auth/login', {
      email, password, tenantId: tenant,
    }, null);
    assert([200, 201].includes(login.status),
      `Login failed: HTTP ${login.status}. ${login.data?.message ?? ''}`);
    assert(typeof login.data?.accessToken === 'string', 'Access token missing.');
    authorization = `Bearer ${login.data.accessToken}`;
    const me = await http('/auth/me', undefined, authorization, 'GET');
    assert(me.status === 200 && me.data.tenantId === tenant &&
      me.data.membershipId === membership && me.data.userId === user,
      'Branch staff session identity mismatch.');
  });

  await test('03_branch_scope_permission_matrix', async () => {
    const p = (await db.query(`
      SELECT
        security.has_tenant_permission($1::uuid,$2::uuid,'gym.memberships.manage',NULL::uuid) AS tenant_scope,
        security.has_tenant_permission($1::uuid,$2::uuid,'gym.memberships.manage',$3::uuid) AS assigned_branch,
        security.has_tenant_permission($1::uuid,$2::uuid,'gym.memberships.manage',$4::uuid) AS other_branch
    `, [tenant, membership, branch, otherBranch])).rows[0];
    assert(p.tenant_scope === false && p.assigned_branch === true && p.other_branch === false,
      'Branch-only permission matrix mismatch.');
  });

  await test('04_unauthenticated_activation', async () => {
    assert((await http(activationPath(), input, null)).status === 401, 'Expected HTTP 401.');
  });

  await test('05_tenant_activation_denied', async () => {
    assert((await http(`/tenants/${tenant}/members/${member}/subscriptions/activate`,
      input)).status === 403, 'Expected HTTP 403.');
  });

  await test('06_unassigned_branch_denied', async () => {
    assert((await http(activationPath(otherBranch, otherMember), input)).status === 403,
      'Expected HTTP 403.');
  });

  await test('07_member_route_branch_mismatch', async () => {
    assert((await http(activationPath(branch, otherMember), input)).status === 403,
      'Expected HTTP 403.');
  });

  await test('08_tenant_member_on_branch_route_denied', async () => {
    assert((await http(activationPath(branch, tenantMember), input)).status === 403,
      'Expected HTTP 403.');
  });

  await test('09_cross_tenant_denied', async () => {
    assert((await http(activationPath(branch, member, otherTenant), input)).status === 403,
      'Expected HTTP 403.');
  });

  await test('10_client_branch_rejected', async () => {
    assert((await http(activationPath(), { ...input, branchId: branch })).status === 400,
      'Expected HTTP 400.');
  });

  await test('11_other_branch_price_rejected', async () => {
    assert((await http(activationPath(), {
      planId: plan, planPriceId: otherBranchPrice,
    })).status === 400, 'Expected HTTP 400.');
  });

  await test('12_branch_registration_allowed', async () => {
    const result = await http(`/tenants/${tenant}/branches/${branch}/members`, {
      fullName: 'B8 branch registration fixture',
      email: registrationEmail,
    });
    assert(result.status === 201 && result.data.tenantId === tenant &&
      result.data.branchId === branch && result.data.status === 'pending',
      `Branch registration failed: HTTP ${result.status}.`);
  });

  await test('13_tenant_registration_denied', async () => {
    assert((await http(`/tenants/${tenant}/members`, {
      fullName: 'B8 denied registration', email: `denied-${user}@example.invalid`,
    })).status === 403, 'Expected HTTP 403.');
  });

  await test('14_branch_activation_allowed', async () => {
    const result = await http(activationPath(), input);
    assert(result.status === 201, `Expected HTTP 201; received ${result.status}.`);
    activation = result.data;
    assert(activation.tenantId === tenant && activation.memberId === member &&
      activation.branchId === branch && activation.status === 'active' &&
      activation.agreedPriceAmount === '50000.00', 'Activation receipt mismatch.');
  });

  await test('15_saved_subscription_and_rejections', async () => {
    const state = (await db.query(`
      SELECT
        (SELECT count(*)::int FROM app.member_subscriptions
         WHERE tenant_id = $1::uuid AND member_id = ANY($2::uuid[])) AS subscriptions,
        EXISTS(
          SELECT 1 FROM app.member_subscriptions
          WHERE id = $3::uuid AND tenant_id = $1::uuid
            AND member_id = $4::uuid AND branch_id = $5::uuid
            AND status = 'active' AND agreed_price_amount = 50000
        ) AS saved,
        (SELECT bool_and(status = 'pending') FROM app.members
         WHERE id = ANY($6::uuid[])) AS rejected_members_pending,
        (SELECT count(*)::int FROM app.members
         WHERE tenant_id = $1::uuid AND email = $7::text) AS denied_registration_rows
    `, [tenant, [member, otherMember, tenantMember], activation.id,
      member, branch, [otherMember, tenantMember], `denied-${user}@example.invalid`])).rows[0];
    assert(state.subscriptions === 1 && state.saved &&
      state.rejected_members_pending && state.denied_registration_rows === 0,
      'Saved subscription or rejected-request state mismatch.');
  });

  const branchRenewalPath =
    `/tenants/${tenant}/branches/${branch}/subscriptions/${activation.id}/renew`;
  const branchRenewalRequest = randomUUID();
  const branchRenewalInput = {
    planPriceId: generalPrice,
    requestId: branchRenewalRequest,
  };
  let branchRenewalReceipt;

  await test('16a_unauthenticated_renewal', async () => {
    assert((await http(branchRenewalPath, branchRenewalInput, null)).status === 401,
      'Expected HTTP 401.');
  });

  await test('16b_tenant_renewal_denied', async () => {
    assert((await http(
      `/tenants/${tenant}/subscriptions/${activation.id}/renew`,
      branchRenewalInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16c_unassigned_branch_renewal_denied', async () => {
    assert((await http(
      `/tenants/${tenant}/branches/${otherBranch}/subscriptions/${activation.id}/renew`,
      branchRenewalInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16d_subscription_route_branch_mismatch', async () => {
    assert((await http(
      `/tenants/${tenant}/branches/${branch}/subscriptions/8a28fa97-e41f-4053-be61-8162ff3d387d/renew`,
      branchRenewalInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16e_client_renewal_fields_rejected', async () => {
    for (const extra of [
      { branchId: branch },
      { endsOn: '2099-01-01' },
      { agreedPriceAmount: '1.00' },
    ]) {
      assert((await http(branchRenewalPath, {
        ...branchRenewalInput, ...extra,
      })).status === 400, 'Expected HTTP 400.');
    }
  });

  await test('16f_branch_staff_renewal_allowed', async () => {
    const result = await http(branchRenewalPath, branchRenewalInput);
    assert(result.status === 200,
      `Expected HTTP 200; received ${result.status}.`);
    branchRenewalReceipt = result.data;

    assert(
      branchRenewalReceipt.tenantId === tenant &&
      branchRenewalReceipt.subscriptionId === activation.id &&
      branchRenewalReceipt.requestId === branchRenewalRequest &&
      branchRenewalReceipt.planPriceId === generalPrice &&
      branchRenewalReceipt.agreedPriceAmount === '50000.00' &&
      branchRenewalReceipt.currencyCode === 'MMK' &&
      branchRenewalReceipt.previousEndsOn === activation.endsOn &&
      branchRenewalReceipt.renewalStartsOn === activation.endsOn,
      'Branch renewal receipt mismatch.'
    );
  });

  await test('16g_branch_renewal_retry', async () => {
    const result = await http(branchRenewalPath, branchRenewalInput);
    assert(
      result.status === 200 &&
      JSON.stringify(result.data) === JSON.stringify(branchRenewalReceipt),
      'Retry changed the original renewal receipt.'
    );
  });

  await test('16h_renewal_saved_once_and_actor_preserved', async () => {
    const saved = await db.query(`
      SELECT
        s.ends_on::text AS ends_on,
        s.branch_id::text AS branch_id,
        s.agreed_price_amount::text AS amount,
        r.id::text AS renewal_id,
        r.renewal_ends_on::text AS renewal_ends_on,
        (
          r.renewal_starts_on = r.previous_ends_on
          AND r.renewal_ends_on =
            (r.renewal_starts_on + interval '1 month')::date
        ) AS correct_coverage,
        r.previous_subscription_snapshot->>'renewed_by_membership_id'
          AS actor_membership,
        r.previous_subscription_snapshot->>'renewed_by_user_id'
          AS actor_user,
        (
          SELECT count(*)::int
          FROM app.subscription_renewals x
          WHERE x.tenant_id = s.tenant_id AND x.subscription_id = s.id
        ) AS renewal_count
      FROM app.member_subscriptions s
      JOIN app.subscription_renewals r
        ON r.tenant_id = s.tenant_id AND r.subscription_id = s.id
      WHERE s.tenant_id = $1::uuid AND s.id = $2::uuid
        AND r.request_id = $3::uuid
    `, [tenant, activation.id, branchRenewalRequest]);

    assert(saved.rowCount === 1, 'Saved branch renewal missing.');
    const row = saved.rows[0];

    assert(
      row.ends_on === branchRenewalReceipt.renewalEndsOn &&
      row.renewal_ends_on === row.ends_on &&
      row.renewal_id === branchRenewalReceipt.id &&
      row.branch_id === branch &&
      row.amount === '50000.00' &&
      row.correct_coverage &&
      row.actor_membership === membership &&
      row.actor_user === user &&
      row.renewal_count === 1,
      'Saved coverage, actor audit, or retry count mismatch.'
    );
  });

  await test('16i_renewal_request_reuse_conflict', async () => {
    assert((await http(branchRenewalPath, {
      ...branchRenewalInput,
      planPriceId: otherBranchPrice,
    })).status === 400, 'Expected HTTP 400.');
  });

  await test('16j_cross_tenant_renewal_denied', async () => {
    assert((await http(
      `/tenants/${otherTenant}/branches/${branch}/subscriptions/${activation.id}/renew`,
      branchRenewalInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16_inactive_branch_denied', async () => {
    await db.query(`UPDATE app.branches SET status = 'inactive' WHERE id = $1::uuid`, [branch]);
    assert((await http(activationPath(), input)).status === 403, 'Expected HTTP 403.');
  });

  await test('17_logout', async () => {
    assert((await http('/auth/logout')).status === 204, 'Expected HTTP 204.');
  });

  await test('18_revoked_session_denied', async () => {
    assert((await http(activationPath(), input)).status === 401, 'Expected HTTP 401.');
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

  if (connected) {
    try {
      await db.query('BEGIN');
      for (const table of [
        'membership_discounts', 'subscription_foc_grants',
        'subscription_expirations', 'subscription_suspensions', 'subscription_renewals',
      ]) {
        await db.query(`
          DELETE FROM app.${table} h USING app.member_subscriptions s, app.members m
          WHERE h.tenant_id = s.tenant_id AND h.subscription_id = s.id
            AND m.tenant_id = s.tenant_id AND m.id = s.member_id
            AND m.tenant_id = $1::uuid AND m.email = ANY($2::text[])
        `, [tenant, memberEmails]);
      }
      await db.query(`
        DELETE FROM app.member_blacklist_events h USING app.members m
        WHERE h.tenant_id = m.tenant_id AND h.member_id = m.id
          AND m.tenant_id = $1::uuid AND m.email = ANY($2::text[])
      `, [tenant, memberEmails]);
      await db.query(`
        DELETE FROM app.member_subscriptions s USING app.members m
        WHERE m.tenant_id = s.tenant_id AND m.id = s.member_id
          AND m.tenant_id = $1::uuid AND m.email = ANY($2::text[])
      `, [tenant, memberEmails]);
      await db.query(`
        DELETE FROM app.members WHERE tenant_id = $1::uuid AND email = ANY($2::text[])
      `, [tenant, memberEmails]);
      await db.query(`
        DELETE FROM app.plan_prices WHERE tenant_id = $1::uuid AND id = $2::uuid
      `, [tenant, otherBranchPrice]);
      await db.query(`
        DELETE FROM app.role_assignments WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.role_permissions WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.roles WHERE tenant_id = $1::uuid AND id = $2::uuid AND role_code = $3::text
      `, [tenant, role, tag]);
      await db.query(`
        DELETE FROM security.tenant_sessions
        WHERE tenant_id = $1::uuid AND membership_id = $2::uuid
      `, [tenant, membership]);
      await db.query(`
        DELETE FROM app.tenant_memberships
        WHERE tenant_id = $1::uuid AND id = $2::uuid AND user_id = $3::uuid
      `, [tenant, membership, user]);
      await db.query(`
        DELETE FROM app.users WHERE id = $1::uuid AND email = $2::text
      `, [user, email]);
      await db.query(`
        DELETE FROM app.branches WHERE tenant_id = $1::uuid AND id = ANY($2::uuid[])
      `, [tenant, [branch, otherBranch]]);
      await db.query('COMMIT');

      await test('19_all_fixture_records_removed', async () => {
        const counts = (await db.query(`
          SELECT
            (SELECT count(*)::int FROM app.users WHERE id = $1::uuid) AS users,
            (SELECT count(*)::int FROM app.tenant_memberships WHERE id = $2::uuid) AS memberships,
            (SELECT count(*)::int FROM security.tenant_sessions WHERE membership_id = $2::uuid) AS sessions,
            (SELECT count(*)::int FROM app.roles WHERE id = $3::uuid) AS roles,
            (SELECT count(*)::int FROM app.role_assignments WHERE role_id = $3::uuid) AS assignments,
            (SELECT count(*)::int FROM app.role_permissions WHERE role_id = $3::uuid) AS permissions,
            (SELECT count(*)::int FROM app.branches WHERE id = ANY($4::uuid[])) AS branches,
            (SELECT count(*)::int FROM app.members WHERE email = ANY($5::text[])) AS members,
            (SELECT count(*)::int FROM app.member_subscriptions WHERE member_id = ANY($6::uuid[])) AS subscriptions,
            (SELECT count(*)::int FROM app.plan_prices WHERE id = $7::uuid) AS prices
        `, [user, membership, role, [branch, otherBranch], memberEmails,
          [member, otherMember, tenantMember], otherBranchPrice])).rows[0];
        assert(Object.values(counts).every(value => value === 0), 'Fixture records remain.');
      });

      if (baseline !== undefined) {
        await test('20_existing_demo_records_unchanged', async () => {
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
    console.error(`Fixture user: ${user}`);
    console.error(`Fixture membership: ${membership}`);
    console.error(`Fixture role: ${role}`);
    console.error(`Fixture branches: ${branch}, ${otherBranch}`);
    process.exitCode = 1;
  } else {
    console.log('PASS: Combined branch activation and renewal API verification completed.');
    console.log('PASS: Test session revoked, fixture records removed, demo records unchanged.');
  }
}
'@ | node.exe --input-type=module -

    if ($LASTEXITCODE -ne 0) {
        throw 'Combined branch activation and renewal verification failed. Review the results table.'
    }
}
finally {
    Remove-Item Env:\GYMPRO_B8_DB_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_B8_BASE_URL -ErrorAction SilentlyContinue
    $gymProDbSecret = $null
    $gymProDbCredential = $null
}