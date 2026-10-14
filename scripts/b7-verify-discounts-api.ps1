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

    $env:GYMPRO_B7_ADMIN_PASSWORD = $gymProAdminCredential.GetNetworkCredential().Password
    $env:GYMPRO_B7_DB_PASSWORD = $gymProDbCredential.GetNetworkCredential().Password
    $env:GYMPRO_B7_BASE_URL = $BaseUrl

    @'
import pg from 'pg';
import { randomUUID } from 'node:crypto';

const { Client } = pg;
const base = process.env.GYMPRO_B7_BASE_URL.replace(/\/$/, '');
const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const membership = '3b318e89-f3bc-4ac5-a04d-09fdb3d626de';
const user = '059e261a-226a-4f9e-93ee-86d374430406';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const demoMembers = [
  '3113ab9f-8edd-41f4-afe6-c8f03e291f89',
  '41f45bd6-114c-4241-9be0-0a949dc5f2b6',
];
const demoSubscription = '8a28fa97-e41f-4053-be61-8162ff3d387d';
const member = randomUUID();
const rejectedMember = randomUUID();
const role = randomUUID();
const code = `B7_API_${role.replaceAll('-', '').slice(0, 16).toUpperCase()}`;
const activationRequest = randomUUID();
const renewalRequest = randomUUID();
const results = [];

let authorization;
let promotion;
let activation;
let renewal;
let baseline;
let connected = false;
let failed = false;

const db = new Client({
  host: '127.0.0.1',
  port: 5432,
  database: 'gympro_saas',
  user: 'postgres',
  password: process.env.GYMPRO_B7_DB_PASSWORD,
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

async function snapshot() {
  return (await db.query(`
    SELECT jsonb_build_object(
      'members', (
        SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id)
        FROM app.members m WHERE id = ANY($1::uuid[])
      ),
      'subscription', (
        SELECT to_jsonb(s) FROM app.member_subscriptions s WHERE id = $2::uuid
      ),
      'renewals', (
        SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id)
        FROM app.subscription_renewals r WHERE subscription_id = $2::uuid
      )
    )::text AS snapshot
  `, [demoMembers, demoSubscription])).rows[0].snapshot;
}

async function permissions() {
  return (await db.query(`
    SELECT
      security.has_tenant_permission(
        $1::uuid, $2::uuid, 'gym.promotions.manage', NULL::uuid
      ) AS manage,
      security.has_tenant_permission(
        $1::uuid, $2::uuid, 'gym.memberships.apply_discount', NULL::uuid
      ) AS discount
  `, [tenant, membership])).rows[0];
}

async function addPermission(permissionCode) {
  const result = await db.query(`
    INSERT INTO app.role_permissions(tenant_id, role_id, permission_id)
    SELECT $1::uuid, $2::uuid, id FROM app.permissions
    WHERE permission_code = $3::text AND is_active
    RETURNING id
  `, [tenant, role, permissionCode]);
  assert(result.rowCount === 1, 'Active permission missing.');
}

function activatePath(id = member, tenantId = tenant) {
  return `/tenants/${tenantId}/members/${id}/subscriptions/activate-discounted`;
}

function activationBody(requestId = activationRequest) {
  return {
    planId: plan,
    planPriceId: price,
    promotionId: promotion.id,
    requestId,
  };
}

function renewalPath() {
  return `/tenants/${tenant}/subscriptions/${activation.subscriptionId}/renew-discounted`;
}

function renewalBody(requestId = renewalRequest) {
  return { planPriceId: price, promotionId: promotion.id, requestId };
}

try {
  await test('01_login_and_session', async () => {
    const login = await http('/auth/login', {
      email: 'admin.a@example.com',
      password: process.env.GYMPRO_B7_ADMIN_PASSWORD,
      tenantId: tenant,
    }, null);
    assert([200, 201].includes(login.status),
      `Login failed: HTTP ${login.status}. ${login.data?.message ?? ''}`);
    assert(typeof login.data?.accessToken === 'string', 'Access token missing.');
    authorization = `Bearer ${login.data.accessToken}`;
    const me = await http('/auth/me', undefined, authorization, 'GET');
    assert(me.status === 200 && me.data.tenantId === tenant &&
      me.data.membershipId === membership && me.data.userId === user,
      'Verified session identity mismatch.');
  });

  await db.connect();
  connected = true;
  baseline = await snapshot();

  await test('02_permission_baseline_and_fixture_setup', async () => {
    const p = await permissions();
    assert(p.manage === false && p.discount === false,
      'Demo administrator already has B7 permissions.');
    const pricing = await db.query(`
      SELECT pp.price_amount::text AS amount
      FROM app.plan_prices pp
      JOIN app.membership_plans p ON p.tenant_id = pp.tenant_id AND p.id = pp.plan_id
      WHERE pp.tenant_id = $1::uuid AND pp.id = $2::uuid AND p.id = $3::uuid
        AND pp.status = 'active' AND p.status = 'active' AND pp.branch_id IS NULL
        AND p.duration_value = 1 AND p.duration_unit = 'months'
    `, [tenant, price, plan]);
    assert(pricing.rowCount === 1 && pricing.rows[0].amount === '50000.00',
      'Expected demo plan and price changed.');
    for (const id of [member, rejectedMember]) {
      await db.query(`
        INSERT INTO app.members(id, tenant_id, full_name, email)
        VALUES($1::uuid, $2::uuid, 'B7 API fixture', $3::text)
      `, [id, tenant, `${id}@example.invalid`]);
    }
  });

  const createBody = {
    promotionCode: code,
    promotionName: 'B7 API verification promotion',
    discountKind: 'percentage',
    discountValue: '10',
    startsOn: new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Yangon',
      year: 'numeric', month: '2-digit', day: '2-digit',
    }).format(new Date()),
  };

  await test('03_unauthenticated_promotion_creation', async () => {
    assert((await http(`/tenants/${tenant}/promotions`, createBody, null)).status === 401,
      'Expected HTTP 401.');
  });

  await test('04_promotion_permission_required', async () => {
    assert((await http(`/tenants/${tenant}/promotions`, createBody)).status === 403,
      'Expected HTTP 403.');
  });

  await test('05_temporary_management_permission', async () => {
    await db.query('BEGIN');
    try {
      await db.query(`
        INSERT INTO app.roles(id, tenant_id, role_code, role_name, is_system_role, status)
        VALUES($1::uuid, $2::uuid, $3::text, 'Temporary B7 API role', false, 'active')
      `, [role, tenant, code]);
      await addPermission('gym.promotions.manage');
      await db.query(`
        INSERT INTO app.role_assignments(tenant_id, membership_id, role_id, scope_type, branch_id)
        VALUES($1::uuid, $2::uuid, $3::uuid, 'tenant', NULL)
      `, [tenant, membership, role]);
      await db.query('COMMIT');
    } catch (error) {
      await db.query('ROLLBACK');
      throw error;
    }
  });

  await test('06_promotion_created_as_draft', async () => {
    const result = await http(`/tenants/${tenant}/promotions`, createBody);
    assert(result.status === 201, `Expected HTTP 201; received ${result.status}.`);
    promotion = result.data;
    assert(promotion.tenantId === tenant && promotion.promotionCode === code &&
      promotion.discountValue === '10.00' && promotion.status === 'draft',
      'Promotion defaults mismatch.');
  });

  await test('07_client_status_rejected', async () => {
    assert((await http(`/tenants/${tenant}/promotions`, {
      ...createBody, promotionCode: `${code}_X`, status: 'active',
    })).status === 400, 'Expected HTTP 400.');
  });

  await test('08_promotion_activation_and_retry', async () => {
    const path = `/tenants/${tenant}/promotions/${promotion.id}/activate`;
    const first = await http(path, {});
    const retry = await http(path, {});
    assert(first.status === 200 && first.data.status === 'active' &&
      retry.status === 200 && JSON.stringify(first.data) === JSON.stringify(retry.data),
      'Promotion activation or retry failed.');
  });

  await test('09_discount_permission_required', async () => {
    assert((await http(activatePath(), activationBody())).status === 403,
      'Expected HTTP 403.');
  });

  await test('10_temporary_discount_permission', async () => {
    await addPermission('gym.memberships.apply_discount');
    const p = await permissions();
    assert(p.manage === true && p.discount === true,
      'Temporary permissions are ineffective.');
  });

  await test('11_unauthenticated_purchase_rejected', async () => {
    assert((await http(activatePath(), activationBody(), null)).status === 401,
      'Expected HTTP 401.');
  });

  await test('12_cross_tenant_purchase_rejected', async () => {
    assert((await http(activatePath(member, otherTenant), activationBody())).status === 403,
      'Expected HTTP 403.');
  });

  await test('13_client_price_and_dates_rejected', async () => {
    for (const extra of [
      { agreedPriceAmount: '1.00' },
      { startsOn: '2026-01-01' },
      { discountAmount: '50000.00' },
    ]) {
      assert((await http(activatePath(rejectedMember), {
        ...activationBody(randomUUID()), ...extra,
      })).status === 400, 'Expected HTTP 400.');
    }
  });

  await test('14_discounted_activation', async () => {
    const result = await http(activatePath(), activationBody());
    assert(result.status === 200, `Expected HTTP 200; received ${result.status}.`);
    activation = result.data;
    assert(activation.tenantId === tenant && activation.promotionId === promotion.id &&
      activation.requestId === activationRequest && activation.purchaseKind === 'activation' &&
      activation.renewalId === null && activation.listedPriceAmount === '50000.00' &&
      activation.discountAmount === '5000.00' && activation.agreedPriceAmount === '45000.00',
      'Discounted activation receipt mismatch.');
    assert(!('actorSnapshot' in activation) && !('actor_snapshot' in activation) &&
      !('promotionSnapshot' in activation), 'Private audit snapshot leaked.');
  });

  await test('15_activation_retry', async () => {
    const result = await http(activatePath(), activationBody());
    assert(result.status === 200 &&
      JSON.stringify(result.data) === JSON.stringify(activation),
      'Activation retry changed the receipt.');
  });

  await test('16_discounted_renewal', async () => {
    const result = await http(renewalPath(), renewalBody());
    assert(result.status === 200, `Expected HTTP 200; received ${result.status}.`);
    renewal = result.data;
    assert(renewal.subscriptionId === activation.subscriptionId &&
      renewal.requestId === renewalRequest && renewal.purchaseKind === 'renewal' &&
      renewal.renewalId && renewal.listedPriceAmount === '50000.00' &&
      renewal.discountAmount === '5000.00' && renewal.agreedPriceAmount === '45000.00',
      'Discounted renewal receipt mismatch.');
  });

  await test('17_renewal_retry', async () => {
    const result = await http(renewalPath(), renewalBody());
    assert(result.status === 200 &&
      JSON.stringify(result.data) === JSON.stringify(renewal),
      'Renewal retry changed the receipt.');
  });

  await test('18_saved_prices_coverage_and_audit', async () => {
    const saved = await db.query(`
      SELECT s.agreed_price_amount::text AS subscription_price,
        s.membership_kind, s.status, m.status AS member_status,
        r.agreed_price_amount::text AS renewal_price,
        (r.renewal_starts_on = r.previous_ends_on
         AND r.renewal_ends_on = (r.renewal_starts_on + interval '1 month')::date
         AND s.ends_on = r.renewal_ends_on) AS correct_coverage,
        (SELECT count(*)::int FROM app.membership_discounts d
         WHERE d.tenant_id = s.tenant_id AND d.subscription_id = s.id) AS discounts,
        (SELECT count(*)::int FROM app.subscription_renewals x
         WHERE x.tenant_id = s.tenant_id AND x.subscription_id = s.id) AS renewals,
        (SELECT bool_and(
            d.agreed_price_amount = 45000
            AND d.actor_snapshot->>'membership_id' = $4::text
            AND d.promotion_snapshot->>'promotion_code' = $5::text
          ) FROM app.membership_discounts d
          WHERE d.subscription_id = s.id AND d.tenant_id = s.tenant_id) AS correct_audit
      FROM app.member_subscriptions s
      JOIN app.members m ON m.tenant_id = s.tenant_id AND m.id = s.member_id
      JOIN app.subscription_renewals r
        ON r.tenant_id = s.tenant_id AND r.subscription_id = s.id
      WHERE s.tenant_id = $1::uuid AND s.id = $2::uuid AND r.id = $3::uuid
    `, [tenant, activation.subscriptionId, renewal.renewalId, membership, code]);
    assert(saved.rowCount === 1, 'Saved purchase missing.');
    const row = saved.rows[0];
    assert(row.subscription_price === '45000.00' && row.renewal_price === '45000.00' &&
      row.membership_kind === 'standard' && row.status === 'active' &&
      row.member_status === 'active' && row.correct_coverage && row.correct_audit &&
      row.discounts === 2 && row.renewals === 1, 'Database purchase or audit mismatch.');
  });

  await test('19_promotion_deactivation_and_retry', async () => {
    const path = `/tenants/${tenant}/promotions/${promotion.id}/deactivate`;
    const first = await http(path, {});
    const retry = await http(path, {});
    assert(first.status === 200 && first.data.status === 'inactive' &&
      retry.status === 200 && JSON.stringify(first.data) === JSON.stringify(retry.data),
      'Promotion deactivation or retry failed.');
  });

  await test('20_inactive_promotion_purchase_rolls_back', async () => {
    assert((await http(activatePath(rejectedMember),
      activationBody(randomUUID()))).status === 400, 'Expected HTTP 400.');
    const state = (await db.query(`
      SELECT status,
        (SELECT count(*)::int FROM app.member_subscriptions
         WHERE tenant_id = $1::uuid AND member_id = $2::uuid) AS subscriptions
      FROM app.members WHERE tenant_id = $1::uuid AND id = $2::uuid
    `, [tenant, rejectedMember])).rows[0];
    assert(state.status === 'pending' && state.subscriptions === 0,
      'Rejected promotion left a partial activation.');
  });

  await test('21_old_retries_preserve_purchases_after_deactivation', async () => {
    const a = await http(activatePath(), activationBody());
    const r = await http(renewalPath(), renewalBody());
    assert(a.status === 200 && r.status === 200 &&
      JSON.stringify(a.data) === JSON.stringify(activation) &&
      JSON.stringify(r.data) === JSON.stringify(renewal),
      'Promotion deactivation changed purchase retries.');
  });

  await test('22_logout', async () => {
    assert((await http('/auth/logout')).status === 204, 'Expected HTTP 204.');
  });

  await test('23_revoked_session_purchase_rejected', async () => {
    assert((await http(activatePath(), activationBody())).status === 401 &&
      (await http(renewalPath(), renewalBody())).status === 401,
      'Expected HTTP 401 for both purchases.');
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
      for (const id of [member, rejectedMember]) {
        const owned = await db.query(`
          SELECT id FROM app.members
          WHERE id = $1::uuid AND tenant_id = $2::uuid AND email = $3::text
          FOR UPDATE
        `, [id, tenant, `${id}@example.invalid`]);
        if (owned.rowCount !== 1) continue;

        for (const table of [
          'membership_discounts', 'subscription_foc_grants',
          'subscription_expirations', 'subscription_suspensions', 'subscription_renewals',
        ]) {
          await db.query(`
            DELETE FROM app.${table} h USING app.member_subscriptions s
            WHERE h.tenant_id = s.tenant_id AND h.subscription_id = s.id
              AND s.tenant_id = $1::uuid AND s.member_id = $2::uuid
          `, [tenant, id]);
        }
        await db.query(`
          DELETE FROM app.member_blacklist_events
          WHERE tenant_id = $1::uuid AND member_id = $2::uuid
        `, [tenant, id]);
        await db.query(`
          DELETE FROM app.member_subscriptions
          WHERE tenant_id = $1::uuid AND member_id = $2::uuid
        `, [tenant, id]);
        await db.query(`
          DELETE FROM app.members
          WHERE tenant_id = $1::uuid AND id = $2::uuid AND email = $3::text
        `, [tenant, id, `${id}@example.invalid`]);
      }

      await db.query(`
        DELETE FROM app.membership_promotions
        WHERE tenant_id = $1::uuid AND promotion_code IN ($2::text, $3::text)
      `, [tenant, code, `${code}_X`]);
      await db.query(`
        DELETE FROM app.role_assignments WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.role_permissions WHERE tenant_id = $1::uuid AND role_id = $2::uuid
      `, [tenant, role]);
      await db.query(`
        DELETE FROM app.roles WHERE tenant_id = $1::uuid AND id = $2::uuid AND role_code = $3::text
      `, [tenant, role, code]);
      await db.query('COMMIT');

      await test('24_fixtures_and_temporary_role_removed', async () => {
        const remaining = (await db.query(`
          SELECT
            (SELECT count(*)::int FROM app.members WHERE id = ANY($1::uuid[])) AS members,
            (SELECT count(*)::int FROM app.member_subscriptions
             WHERE member_id = ANY($1::uuid[])) AS subscriptions,
            (SELECT count(*)::int FROM app.membership_discounts
             WHERE request_id IN ($2::uuid, $3::uuid)) AS discounts,
            (SELECT count(*)::int FROM app.roles WHERE id = $4::uuid) AS roles,
            (SELECT count(*)::int FROM app.role_assignments WHERE role_id = $4::uuid) AS assignments,
            (SELECT count(*)::int FROM app.role_permissions WHERE role_id = $4::uuid) AS permissions,
            (SELECT count(*)::int FROM app.membership_promotions
             WHERE tenant_id = $5::uuid AND promotion_code IN ($6::text, $7::text)) AS promotions
        `, [[member, rejectedMember], activationRequest, renewalRequest, role, tenant, code, `${code}_X`])).rows[0];
        assert(Object.values(remaining).every(value => value === 0),
          'Fixture or role records remain.');
      });

      await test('25_demo_permissions_restored', async () => {
        const p = await permissions();
        assert(p.manage === false && p.discount === false,
          'Temporary B7 permissions remain.');
      });

      if (baseline !== undefined) {
        await test('26_existing_demo_records_unchanged', async () => {
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
    console.error(`Fixture members: ${member}, ${rejectedMember}`);
    console.error(`Temporary role: ${role}`);
    console.error(`Promotion code: ${code}`);
    process.exitCode = 1;
  } else {
    console.log('PASS: Combined B7 discounts API verification completed.');
    console.log('PASS: Session revoked, fixtures and temporary role removed, demo records unchanged.');
  }
}
'@ | node.exe --input-type=module -

    if ($LASTEXITCODE -ne 0) {
        throw 'Combined B7 verification failed. Review the results table.'
    }
}
finally {
    Remove-Item Env:\GYMPRO_B7_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_B7_DB_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\GYMPRO_B7_BASE_URL -ErrorAction SilentlyContinue
    $gymProAdminSecret = $null
    $gymProDbSecret = $null
    $gymProAdminCredential = $null
    $gymProDbCredential = $null
}