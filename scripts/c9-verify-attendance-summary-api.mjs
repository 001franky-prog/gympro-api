import QRCode from 'qrcode';
import jsQR from 'jsqr';
import {createRequire} from 'node:module';
const requireQr=createRequire(createRequire(import.meta.url).resolve('qrcode'));
const {PNG}=requireQr('pngjs');
import pg from 'pg';
import argon2 from 'argon2';
import { randomUUID, randomBytes } from 'node:crypto';

const { Client } = pg;
const base = process.env.GYMPRO_B8_BASE_URL.replace(/\/$/, '');
const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const summaryPath=(b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/attendance/summary`;
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
const lookupMember = randomUUID();
const tag = `B8_${user.replaceAll('-', '').slice(0, 16).toUpperCase()}`;
const email = `${user}@example.invalid`;
const registrationEmail = `registered-${user}@example.invalid`;
const memberEmails = [member, otherMember, tenantMember, lookupMember]
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

  await test('C6_public_operator_assets_and_headers',async()=>{
    const page=await fetch(base+'/operator');const html=await page.text();
    assert(page.status===200&&page.headers.get('content-type').includes('text/html')&&html.includes('id="login-form"')&&html.includes('id="scan-form"'),'Operator page missing');
    assert(page.headers.get('cache-control')==='no-store'&&page.headers.get('content-security-policy').includes("frame-ancestors 'none'")&&!page.headers.get('content-security-policy').includes('unsafe-inline'),'Operator security headers missing');
    for(const [path,type]of[['app.js','javascript'],['style.css','text/css'],['vendor/jsqr.js','javascript']]){const r=await fetch(base+'/operator/'+path);assert(r.status===200&&r.headers.get('content-type').includes(type),'Operator asset unavailable: '+path);}
    const app=await(await fetch(base+'/operator/app.js')).text();assert(!/innerHTML|localStorage|sessionStorage/.test(app),'Unsafe operator rendering/storage pattern');
  });
  await test('C6_real_qr_image_decoder_roundtrip',async()=>{
    const payload=`GP1:${tenant}:fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c:3113ab9f-8edd-41f4-afe6-c8f03e291f89`;
    const png=PNG.sync.read(await QRCode.toBuffer(payload,{type:'png',errorCorrectionLevel:'M',margin:4,scale:6}));
    const decoded=jsQR(new Uint8ClampedArray(png.data),png.width,png.height,{inversionAttempts:'attemptBoth'});
    assert(decoded?.data===payload,'QR image encoding/decoding mismatch');
  });

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

  const lookupPath=(b=branch,t=tenant,q='B8')=>`/tenants/${t}/branches/${b}/members/lookup?q=${encodeURIComponent(q)}`;
  await test('C7_01_unauthenticated_lookup',async()=>{assert((await http(lookupPath(),undefined,null,'GET')).status===401,'Expected 401');});
  await test('C7_02_member_read_permission_required',async()=>{assert((await http(lookupPath(),undefined,authorization,'GET')).status===403,'Existing management permission authorized lookup');});
  await test('C7_03_temporary_branch_read_permission',async()=>{
    const r=await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.members.read' AND is_active RETURNING id`,[tenant,role]);assert(r.rowCount===1,'Member read permission missing');
    await db.query(`INSERT INTO app.members(id,tenant_id,branch_id,full_name,email) VALUES($1,$2,$3,'B8 Lookup မြန်မာ %',$4)`,[lookupMember,tenant,branch,`${lookupMember}@example.invalid`]);
  });
  await test('C7_04_branch_search_public_fields',async()=>{const r=await http(lookupPath(),undefined,authorization,'GET');assert(r.status===200&&r.data.items.length===2&&r.data.nextCursor===null,'Expected only two assigned branch members');assert(r.data.items.some(x=>x.id===member)&&r.data.items.some(x=>x.id===lookupMember),'Wrong branch members');for(const x of r.data.items)assert(Object.keys(x).sort().join(',')==='fullName,id,memberNumber,status','Private fields exposed');});
  await test('C7_05_number_and_unicode_search',async()=>{const number=(await db.query('SELECT member_number FROM app.members WHERE id=$1',[member])).rows[0].member_number;for(const [q,expected]of [[number,member],['မြန်မာ',lookupMember]]){const r=await http(lookupPath(branch,tenant,q),undefined,authorization,'GET');assert(r.status===200&&r.data.items.length===1&&r.data.items[0].id===expected,'Exact number/Unicode search failed');}});
  await test('C7_06_literal_wildcards',async()=>{const r=await http(lookupPath(branch,tenant,'%'),undefined,authorization,'GET');assert(r.status===400,'One-character search accepted');const found=await http(lookupPath(branch,tenant,' %'),undefined,authorization,'GET');assert(found.status===400,'Trimmed one-character search accepted');const two=await http(lookupPath(branch,tenant,'မြန်မာ %'),undefined,authorization,'GET');assert(two.status===200&&two.data.items.length===1,'Literal percent search failed');const empty=await http(lookupPath(branch,tenant,'%%'),undefined,authorization,'GET');assert(empty.status===200&&empty.data.items.length===0,'Percent was treated as wildcard');});
  await test('C7_07_pagination_without_duplicates',async()=>{const a=await http(lookupPath()+'&limit=1',undefined,authorization,'GET');assert(a.status===200&&a.data.items.length===1&&a.data.nextCursor===a.data.items[0].id,'First page failed');const b=await http(lookupPath()+'&limit=1&cursor='+a.data.nextCursor,undefined,authorization,'GET');assert(b.status===200&&b.data.items.length===1&&b.data.nextCursor===null&&a.data.items[0].id!==b.data.items[0].id,'Continuation failed');});
  await test('C7_08_unassigned_branch_and_other_tenant_denied',async()=>{for(const p of [lookupPath(otherBranch),lookupPath(branch,otherTenant)])assert((await http(p,undefined,authorization,'GET')).status===403,'Scope bypass');});
  await test('C7_09_invalid_query_rejected',async()=>{for(const suffix of ['&limit=51','&cursor=bad','&tenantId='+tenant,'&q=again'])assert((await http(lookupPath()+suffix,undefined,authorization,'GET')).status===400,'Invalid query accepted');});
  await test('C7_10_runtime_SQL_scope_and_privileges',async()=>{
    const hash=(await db.query('SELECT session_token_hash FROM security.tenant_sessions WHERE membership_id=$1 AND revoked_at IS NULL',[membership])).rows[0].session_token_hash;
    await db.query('BEGIN');try{await db.query('SET LOCAL ROLE gympro_app');const r=await db.query('SELECT * FROM security.search_branch_members($1,$2,$3,$4,$5,$6)',[hash,tenant,branch,'B8',25,null]);assert(r.rows.length===2&&r.rows.every(x=>x.branch_id===branch),'SQL branch scope failed');}finally{await db.query('ROLLBACK');}
    for(const [hashValue,t,b,code] of [[Buffer.alloc(32),tenant,branch,'28000'],[hash,otherTenant,branch,'42501'],[hash,tenant,otherBranch,'42501']]){await db.query('BEGIN');let received;try{await db.query('SET LOCAL ROLE gympro_app');await db.query('SELECT * FROM security.search_branch_members($1,$2,$3,$4,$5,$6)',[hashValue,t,b,'B8',25,null]);}catch(e){received=e.code;}finally{await db.query('ROLLBACK');}assert(received===code,'SQL bypass rejection failed');}
    const safe=(await db.query(`SELECT NOT has_table_privilege('gympro_app','app.members','SELECT,INSERT,UPDATE,DELETE') AS safe`)).rows[0].safe;assert(safe,'Runtime gained direct member access');
  });
  await test('C7_11_inactive_branch_denied',async()=>{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[branch]);try{assert((await http(lookupPath(),undefined,authorization,'GET')).status===403,'Inactive branch lookup permitted');}finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[branch]);}});
  await test('C7_12_lookup_has_no_write_effects',async()=>{const r=(await db.query('SELECT status,(SELECT count(*)::int FROM app.member_subscriptions WHERE member_id=$1) AS subscriptions,(SELECT count(*)::int FROM app.member_cards WHERE member_id=$1) AS cards FROM app.members WHERE id=$1',[lookupMember])).rows[0];assert(r.status==='pending'&&r.subscriptions===0&&r.cards===0,'Lookup changed fixture');});

  await test('C7_14_expired_session_lookup_denied',async()=>{
    const old=(await db.query('SELECT id,created_at,expires_at FROM security.tenant_sessions WHERE membership_id=$1 AND revoked_at IS NULL',[membership])).rows[0];
    assert(old,'Fixture session missing');
    try{
      await db.query("UPDATE security.tenant_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1",[old.id]);
      assert((await http(lookupPath(),undefined,authorization,'GET')).status===401,'Expired session lookup permitted');
      assert((await http(summaryPath(),undefined,authorization,'GET')).status===401,'Expired session summary permitted');
    }finally{
      await db.query('UPDATE security.tenant_sessions SET created_at=$2,expires_at=$3 WHERE id=$1',[old.id,old.created_at,old.expires_at]);
    }
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

  const attendancePath=(b=branch,m=member,t=tenant)=>`/tenants/${t}/branches/${b}/members/${m}/attendance/check-in`;
  const attendanceRequest=randomUUID();
  await test('C1_record_permission_required',async()=>{
    assert((await http(attendancePath(),{requestId:attendanceRequest})).status===403,'Expected attendance permission denial');
    await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.attendance.record' AND is_active`,[tenant,role]);
  });
  await test('C1_unauthenticated',async()=>assert((await http(attendancePath(),{requestId:randomUUID()},null)).status===401,'Expected 401'));
  await test('C1_scope_boundaries',async()=>{
    for(const p of [attendancePath(otherBranch),attendancePath(branch,otherMember),attendancePath(branch,member,otherTenant)])assert((await http(p,{requestId:randomUUID()})).status===403,'Expected 403');
  });
  await test('C1_client_fields_rejected',async()=>{
    for(const extra of [{checkedInAt:'2026-01-01'},{businessDate:'2026-01-01'},{status:'active'},{branchId:branch},{memberId:member}])assert((await http(attendancePath(),{requestId:randomUUID(),...extra})).status===400,'Expected 400');
    for(const body of [{},{requestId:'invalid'},null,[]])assert((await http(attendancePath(),body)).status===400,'Expected invalid body rejection');
  });
  const beforeAttendance=(await db.query('SELECT * FROM app.member_subscriptions WHERE id=$1',[activation.id])).rows[0];
  for(const status of ['pending','inactive','blacklisted']){
    await test(`C1_${status}_member_denied`,async()=>{
      try{await db.query('UPDATE app.members SET status=$2 WHERE id=$1',[member,status]);assert((await http(attendancePath(),{requestId:randomUUID()})).status===400,'Expected member eligibility denial');}
      finally{await db.query("UPDATE app.members SET status='active' WHERE id=$1",[member]);}
    });
  }
  for(const state of ['suspended','elapsed','future']){
    await test(`C1_${state}_coverage_denied`,async()=>{
      try{
        if(state==='suspended')await db.query("UPDATE app.member_subscriptions SET status='suspended',suspended_at=clock_timestamp() WHERE id=$1",[activation.id]);
        if(state==='elapsed')await db.query("UPDATE app.member_subscriptions SET starts_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date-30,ends_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date WHERE id=$1",[activation.id]);
        if(state==='future')await db.query("UPDATE app.member_subscriptions SET starts_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date+1,ends_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date+30 WHERE id=$1",[activation.id]);
        assert((await http(attendancePath(),{requestId:randomUUID()})).status===400,'Expected coverage denial');
      }finally{await db.query("UPDATE app.member_subscriptions SET status='active',suspended_at=NULL,starts_on=$2,ends_on=$3 WHERE id=$1",[activation.id,beforeAttendance.starts_on,beforeAttendance.ends_on]);}
    });
  }
  let visit;
  await test('C1_concurrent_same_request_saved_once',async()=>{
    const replies=await Promise.all([http(attendancePath(),{requestId:attendanceRequest}),http(attendancePath(),{requestId:attendanceRequest})]);
    assert(replies.every(r=>r.status===200),'Expected both retries to succeed');visit=replies[0].data;
    assert(JSON.stringify(visit)===JSON.stringify(replies[1].data),'Concurrent retry receipt differs');
    assert(visit.tenantId===tenant && visit.branchId===branch && visit.memberId===member && visit.subscriptionId===activation.id && visit.requestId===attendanceRequest && visit.checkedOutAt===null,'Receipt mismatch');
    assert(!('actor_snapshot' in visit) && !('actorSnapshot' in visit),'Private audit exposed');
  });
  await test('C1_new_requests_cannot_duplicate_open_visit',async()=>{
    const replies=await Promise.all([http(attendancePath(),{requestId:randomUUID()}),http(attendancePath(),{requestId:randomUUID()})]);
    assert(replies.every(r=>r.status===400),'Duplicate open visit accepted');
  });
  await test('C1_database_receipt_and_actor',async()=>{
    const rows=(await db.query(`SELECT *,business_date=(checked_in_at AT TIME ZONE 'Asia/Yangon')::date AS correct_date FROM app.attendance_visits WHERE tenant_id=$1 AND member_id=$2`,[tenant,member])).rows;
    assert(rows.length===1 && rows[0].id===visit.id && rows[0].correct_date && rows[0].actor_membership_id===membership && rows[0].actor_snapshot.user_id===user,'Stored visit or audit differs');
  });
  await test('C1_runtime_direct_access_denied_and_rls',async()=>{
    const r=(await db.query(`SELECT relrowsecurity AND relforcerowsecurity AS rls,has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') AS direct FROM pg_class WHERE oid='app.attendance_visits'::regclass`)).rows[0];
    assert(r.rls && !r.direct,'Attendance table boundary failed');
    try{await db.query('BEGIN');await db.query('SET LOCAL ROLE gympro_app');
      for(const operation of ['SELECT * FROM app.attendance_visits','DELETE FROM app.attendance_visits']){
        await db.query('SAVEPOINT denied');let code;try{await db.query(operation);}catch(e){code=e.code;await db.query('ROLLBACK TO SAVEPOINT denied');}assert(code==='42501','Runtime table operation accepted');
      }
    }finally{await db.query('ROLLBACK');}
  });
  await test('C1_foc_coverage_allowed',async()=>{
    try{
      await db.query('DELETE FROM app.attendance_visits WHERE tenant_id=$1 AND member_id=$2',[tenant,member]);
      await db.query("UPDATE app.member_subscriptions SET membership_kind='foc',agreed_price_amount=0 WHERE id=$1",[activation.id]);
      assert((await http(attendancePath(),{requestId:randomUUID()})).status===200,'FOC coverage should qualify');
    }finally{await db.query('UPDATE app.member_subscriptions SET membership_kind=$2,agreed_price_amount=$3 WHERE id=$1',[activation.id,beforeAttendance.membership_kind,beforeAttendance.agreed_price_amount]);}
  });

  const checkoutPath=(v,b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/attendance/${v}/check-out`;
  const openVisit=(await db.query('SELECT * FROM app.attendance_visits WHERE tenant_id=$1 AND member_id=$2 AND checked_out_at IS NULL',[tenant,member])).rows[0];
  const checkoutRequest=randomUUID();let checkoutReceipt;let secondVisit;
  await test('C2_unauthenticated_checkout',async()=>assert((await http(checkoutPath(openVisit.id),{requestId:checkoutRequest},null)).status===401,'Expected 401'));
  await test('C2_record_permission_required',async()=>{
    try{await db.query(`DELETE FROM app.role_permissions WHERE tenant_id=$1 AND role_id=$2 AND permission_id=(SELECT id FROM app.permissions WHERE permission_code='gym.attendance.record')`,[tenant,role]);assert((await http(checkoutPath(openVisit.id),{requestId:checkoutRequest})).status===403,'Expected permission denial');}
    finally{await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.attendance.record' ON CONFLICT DO NOTHING`,[tenant,role]);}
  });
  await test('C2_scope_and_unknown_visit_denied',async()=>{
    for(const p of [checkoutPath(openVisit.id,otherBranch),checkoutPath(openVisit.id,branch,otherTenant),checkoutPath(randomUUID())])assert((await http(p,{requestId:randomUUID()})).status===403,'Expected 403');
  });
  await test('C2_client_fields_rejected',async()=>{
    for(const extra of [{checkedOutAt:'2026-01-01'},{visitId:openVisit.id},{memberId:member},{branchId:branch}])assert((await http(checkoutPath(openVisit.id),{requestId:randomUUID(),...extra})).status===400,'Expected 400');
    for(const body of [{},null,[],{requestId:'bad'}])assert((await http(checkoutPath(openVisit.id),body)).status===400,'Expected invalid body denial');
  });
  await test('C2_blacklisted_elapsed_coverage_can_checkout_with_concurrent_retry',async()=>{
    try{
      await db.query("UPDATE app.members SET status='blacklisted' WHERE id=$1",[member]);
      await db.query("UPDATE app.member_subscriptions SET status='expired',starts_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date-30,ends_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date WHERE id=$1",[activation.id]);
      const replies=await Promise.all([http(checkoutPath(openVisit.id),{requestId:checkoutRequest}),http(checkoutPath(openVisit.id),{requestId:checkoutRequest})]);
      assert(replies.every(r=>r.status===200),'Expected successful check-out even after eligibility changes');
      checkoutReceipt=replies[0].data;assert(JSON.stringify(checkoutReceipt)===JSON.stringify(replies[1].data),'Concurrent receipt differs');
      assert(checkoutReceipt.visitId===openVisit.id && checkoutReceipt.memberId===member && checkoutReceipt.branchId===branch && checkoutReceipt.tenantId===tenant && checkoutReceipt.requestId===checkoutRequest && Date.parse(checkoutReceipt.checkedOutAt)>=Date.parse(checkoutReceipt.checkedInAt),'Invalid check-out receipt');
      assert(!('actorSnapshot' in checkoutReceipt)&&!('actor_snapshot' in checkoutReceipt),'Private audit exposed');
      const state=(await db.query('SELECT m.status AS member_status,s.status AS sub_status FROM app.members m JOIN app.member_subscriptions s ON s.member_id=m.id AND s.tenant_id=m.tenant_id WHERE s.id=$1',[activation.id])).rows[0];
      assert(state.member_status==='blacklisted' && state.sub_status==='expired','Checkout changed membership eligibility');
    }finally{
      await db.query("UPDATE app.members SET status='active' WHERE id=$1",[member]);
      await db.query("UPDATE app.member_subscriptions SET status='active',starts_on=$2,ends_on=$3 WHERE id=$1",[activation.id,beforeAttendance.starts_on,beforeAttendance.ends_on]);
    }
  });
  await test('C2_saved_once_actor_and_timestamp',async()=>{
    const rows=(await db.query(`SELECT c.*,v.checked_out_at=c.checked_out_at AS dates_match FROM app.attendance_checkouts c JOIN app.attendance_visits v ON v.id=c.visit_id AND v.tenant_id=c.tenant_id WHERE c.tenant_id=$1 AND c.visit_id=$2`,[tenant,openVisit.id])).rows;
    assert(rows.length===1 && rows[0].id===checkoutReceipt.id && rows[0].dates_match && rows[0].actor_membership_id===membership && rows[0].actor_snapshot.user_id===user,'Check-out storage or actor mismatch');
  });
  await test('C2_new_request_for_closed_visit_rejected',async()=>assert((await http(checkoutPath(openVisit.id),{requestId:randomUUID()})).status===400,'Closed visit accepted a second check-out'));
  await test('C2_original_checkin_retry_does_not_reopen_visit',async()=>{
    const r=await http(attendancePath(),{requestId:openVisit.request_id});assert(r.status===200 && r.data.id===openVisit.id && r.data.checkedOutAt===checkoutReceipt.checkedOutAt,'Old check-in retry reopened or replaced visit');
  });
  await test('C2_new_checkin_after_closure',async()=>{
    const r=await http(attendancePath(),{requestId:randomUUID()});assert(r.status===200 && r.data.id!==openVisit.id && r.data.checkedOutAt===null,'New check-in blocked after closure');secondVisit=r.data;
  });
  await test('C2_request_reuse_for_different_visit_rejected',async()=>assert((await http(checkoutPath(secondVisit.id),{requestId:checkoutRequest})).status===400,'Request conflict accepted'));
  await test('C2_competing_checkout_requests_close_once',async()=>{
    const replies=await Promise.all([http(checkoutPath(secondVisit.id),{requestId:randomUUID()}),http(checkoutPath(secondVisit.id),{requestId:randomUUID()})]);
    assert(replies.filter(r=>r.status===200).length===1 && replies.filter(r=>r.status===400).length===1,'Expected exactly one check-out winner');
    const c=(await db.query('SELECT count(*)::int AS n FROM app.attendance_checkouts WHERE tenant_id=$1 AND visit_id=$2',[tenant,secondVisit.id])).rows[0];assert(c.n===1,'Duplicate check-out history');
  });
  await test('C2_old_checkout_retry_after_later_visit',async()=>{
    const r=await http(checkoutPath(openVisit.id),{requestId:checkoutRequest});assert(r.status===200 && JSON.stringify(r.data)===JSON.stringify(checkoutReceipt),'Old receipt changed after later visit');
  });
  await test('C2_inactive_branch_checkout_denied',async()=>{
    try{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[branch]);assert((await http(checkoutPath(openVisit.id),{requestId:checkoutRequest})).status===403,'Inactive branch retry permitted');}
    finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[branch]);}
  });
  await test('C2_runtime_direct_checkout_history_access_denied',async()=>{
    const r=(await db.query(`SELECT relrowsecurity AND relforcerowsecurity AS rls,has_table_privilege('gympro_app','app.attendance_checkouts','SELECT,INSERT,UPDATE,DELETE') AS direct FROM pg_class WHERE oid='app.attendance_checkouts'::regclass`)).rows[0];assert(r.rls && !r.direct,'Checkout table boundary failed');
    try{await db.query('BEGIN');await db.query('SET LOCAL ROLE gympro_app');let code;try{await db.query('SELECT * FROM app.attendance_checkouts');}catch(e){code=e.code;}assert(code==='42501','Runtime history read accepted');}finally{await db.query('ROLLBACK');}
  });

  const readPath=(b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/attendance`;
  const getAttendance=(suffix='',auth=authorization)=>http(readPath()+suffix,undefined,auth,'GET');
  await test('C9_01_summary_unauthenticated',async()=>{assert((await http(summaryPath(),undefined,null,'GET')).status===401,'Expected 401');});
  await test('C9_02_record_permission_cannot_read_summary',async()=>{assert((await http(summaryPath(),undefined,authorization,'GET')).status===403,'Record permission authorized summary');});
  await test('C3_record_permission_does_not_authorize_read',async()=>{
    assert((await getAttendance()).status===403,'Recording permission authorized history');assert((await getAttendance('/current')).status===403,'Recording permission authorized occupancy');
    await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.attendance.read' AND is_active`,[tenant,role]);
    assert((await db.query(`SELECT security.has_tenant_permission($1,$2,'gym.attendance.read',NULL) AS allowed`,[tenant,membership])).rows[0].allowed===false,'Reader role gained tenant scope');
  });
  await test('C3_unauthenticated_read_denied',async()=>{for(const suffix of ['','/current'])assert((await getAttendance(suffix,null)).status===401,'Expected 401');});
  await test('C3_read_scope_boundaries',async()=>{
    for(const p of [readPath(otherBranch),readPath(branch,otherTenant)])assert((await http(p,undefined,authorization,'GET')).status===403,'Expected read scope denial');
  });
  await test('C3_default_history_and_public_fields',async()=>{
    const r=await getAttendance();assert(r.status===200&&r.data.items.length===2&&r.data.nextCursor===null,'Expected two fixture visits');
    for(const v of r.data.items)assert(v.tenantId===tenant&&v.branchId===branch&&v.memberId===member&&v.fullName&&v.memberNumber&&!('actorSnapshot'in v)&&!('actor_snapshot'in v)&&!('cursor_at'in v),'Unexpected public fields');
  });
  await test('C9_03_known_daily_counts_and_distinct_members',async()=>{const r=await http(summaryPath(),undefined,authorization,'GET');const today=(await db.query("SELECT ((clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date)::text AS d")).rows[0].d;assert(r.status===200&&r.data.day===today&&r.data.timeZone==='Asia/Yangon'&&r.data.checkIns===2&&r.data.distinctMembers===1&&r.data.checkOuts===2&&r.data.currentOccupancy===0,'Known daily counts failed');assert(Object.keys(r.data).sort().join(',')==='branchId,checkIns,checkOuts,currentOccupancy,day,distinctMembers,generatedAt,tenantId,timeZone','Unexpected summary fields');});
  await test('C9_04_other_branch_and_tenant_denied',async()=>{for(const p of [summaryPath(otherBranch),summaryPath(branch,otherTenant)])assert((await http(p,undefined,authorization,'GET')).status===403,'Summary scope bypass');});
  await test('C9_05_query_validation',async()=>{for(const q of ['?day=2026-02-30','?day=infinity','?day=0000-01-01','?day=2026-10-15&day=2026-10-16','?tenantId='+otherTenant,'?limit=1'])assert((await http(summaryPath()+q,undefined,authorization,'GET')).status===400,'Invalid summary query accepted');});
  await test('C9_06_empty_day',async()=>{const r=await http(summaryPath()+'?day=2000-01-01',undefined,authorization,'GET');assert(r.status===200&&r.data.checkIns===0&&r.data.distinctMembers===0&&r.data.checkOuts===0&&r.data.currentOccupancy===0,'Empty historical day failed');});
  await test('C9_07_direct_SQL_permission_boundary',async()=>{const hash=(await db.query('SELECT session_token_hash FROM security.tenant_sessions WHERE membership_id=$1 AND revoked_at IS NULL',[membership])).rows[0].session_token_hash;await db.query('BEGIN');try{await db.query('SET LOCAL ROLE gympro_app');const r=await db.query('SELECT * FROM security.summarize_branch_attendance($1,$2,$3,$4)',[hash,tenant,branch,null]);assert(r.rows.length===1&&r.rows[0].check_ins===2&&r.rows[0].distinct_members===1,'SQL aggregate failed');}finally{await db.query('ROLLBACK');}let code;await db.query('BEGIN');try{await db.query('SET LOCAL ROLE gympro_app');await db.query('SELECT * FROM security.summarize_branch_attendance($1,$2,$3,$4)',[hash,tenant,otherBranch,null]);}catch(e){code=e.code;}finally{await db.query('ROLLBACK');}assert(code==='42501','SQL summary scope bypass');});
  await test('C3_precise_cursor_pagination',async()=>{
    const a=await getAttendance('?limit=1');assert(a.status===200&&a.data.items.length===1&&a.data.nextCursor,'Expected first page');
    const b=await getAttendance('?limit=1&cursor='+encodeURIComponent(a.data.nextCursor));assert(b.status===200&&b.data.items.length===1&&b.data.nextCursor===null,'Expected final page');assert(a.data.items[0].id!==b.data.items[0].id,'Pagination repeated visit');
    const all=(await getAttendance()).data.items.map(v=>v.id);assert(JSON.stringify([a.data.items[0].id,b.data.items[0].id])===JSON.stringify(all),'Pagination skipped or reordered visits');
  });
  await test('C3_date_filters_and_empty_range',async()=>{
    const dates=(await db.query(`SELECT ((clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date)::text AS today,((clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date+1)::text AS tomorrow,((clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date+2)::text AS later`)).rows[0];
    const a=await getAttendance(`?from=${dates.today}&to=${dates.tomorrow}`);assert(a.status===200&&a.data.items.length===2,'Date range missed visits');
    const b=await getAttendance(`?from=${dates.tomorrow}&to=${dates.later}`);assert(b.status===200&&b.data.items.length===0&&b.data.nextCursor===null,'Empty range did not return empty page');
  });
  await test('C3_invalid_filters_limits_and_cursors',async()=>{
    for(const q of ['?limit=0','?limit=101','?limit=1.5','?limit=1&limit=2','?from=2026-02-30&to=2026-03-02','?from=2026-01-01','?from=2026-02-01&to=2026-01-01','?from=2026-01-01&to=2027-01-01','?tenantId='+otherTenant,'?cursor=bad','?cursor='+Buffer.from(JSON.stringify({at:'bad',id:member})).toString('base64url')])assert((await getAttendance(q)).status===400,'Invalid query accepted: '+q);
    assert((await getAttendance('/current?from=2026-01-01&to=2026-01-02')).status===400,'Occupancy accepted date filter');
  });
  await test('C3_closed_visits_absent_from_occupancy',async()=>{const r=await getAttendance('/current');assert(r.status===200&&r.data.items.length===0,'Closed visits counted as present');});
  await test('C3_read_only_permission_cannot_record',async()=>{
    try{
      await db.query(`DELETE FROM app.role_permissions WHERE tenant_id=$1 AND role_id=$2 AND permission_id=(SELECT id FROM app.permissions WHERE permission_code='gym.attendance.record')`,[tenant,role]);
      assert((await getAttendance()).status===200,'Read-only permission cannot read');assert((await http(attendancePath(),{requestId:randomUUID()})).status===403,'Read-only permission recorded check-in');assert((await http(checkoutPath(openVisit.id),{requestId:randomUUID()})).status===403,'Read-only permission recorded checkout');
    }finally{await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.attendance.record' ON CONFLICT DO NOTHING`,[tenant,role]);}
  });
  let occupancyVisit;
  await test('C3_occupancy_includes_open_overnight_visit',async()=>{
    const checkin=await http(attendancePath(),{requestId:randomUUID()});assert(checkin.status===200,'Could not create occupancy fixture');occupancyVisit=checkin.data;
    await db.query(`UPDATE app.attendance_visits SET checked_in_at=checked_in_at-interval '1 day',business_date=business_date-1 WHERE id=$1`,[occupancyVisit.id]);
    const r=await getAttendance('/current');assert(r.status===200&&r.data.items.length===1&&r.data.items[0].id===occupancyVisit.id&&r.data.items[0].checkedOutAt===null,'Overnight open visit missing');
    await test('C9_08_overnight_occupancy_is_independent_of_selected_day',async()=>{const r=await http(summaryPath()+'?day=2000-01-01',undefined,authorization,'GET');assert(r.status===200&&r.data.checkIns===0&&r.data.checkOuts===0&&r.data.currentOccupancy===1,'Overnight occupancy was filtered out by summary day');});
    assert((await http(checkoutPath(occupancyVisit.id),{requestId:randomUUID()})).status===200,'Could not close occupancy fixture');
    assert((await getAttendance('/current')).data.items.length===0,'Occupancy did not clear after checkout');
  });
  await test('C9_09_overnight_checkout_counted_on_checkout_day',async()=>{const today=await http(summaryPath(),undefined,authorization,'GET');assert(today.status===200&&today.data.checkIns===2&&today.data.distinctMembers===1&&today.data.checkOuts===3&&today.data.currentOccupancy===0,'Overnight departure day incorrect');const yesterday=(await db.query("SELECT ((clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date-1)::text AS d")).rows[0].d;const r=await http(summaryPath()+'?day='+yesterday,undefined,authorization,'GET');assert(r.status===200&&r.data.checkIns===1&&r.data.distinctMembers===1&&r.data.checkOuts===0,'Overnight arrival day incorrect');});
  await test('C9_10_inactive_branch_denied',async()=>{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[branch]);try{assert((await http(summaryPath(),undefined,authorization,'GET')).status===403,'Inactive branch summary allowed');}finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[branch]);}});
  await test('C3_inactive_branch_read_denied',async()=>{
    try{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[branch]);assert((await getAttendance()).status===403,'Inactive branch history permitted');assert((await getAttendance('/current')).status===403,'Inactive branch occupancy permitted');}
    finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[branch]);}
  });
  await test('C3_reader_has_no_write_or_direct_runtime_access',async()=>{
    const r=(await db.query(`SELECT has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') AS direct,has_table_privilege('gympro_attendance_reader','app.attendance_visits','INSERT,UPDATE,DELETE') AS reader_write,rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole AS unsafe FROM pg_roles WHERE rolname='gympro_attendance_reader'`)).rows[0];assert(!r.direct&&!r.reader_write&&!r.unsafe,'Reader privileges unsafe');
  });

  const issueCardPath=(m=member,b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/members/${m}/cards/issue`;
  const cardPath=(c,b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/cards/${c}`;
  const memberCardPath=(m=member,b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/members/${m}/cards/current`;
  await test('C8_01_unauthenticated_card_lookup',async()=>{assert((await http(memberCardPath(),undefined,null,'GET')).status===401,'Expected 401');});
  await test('C8_02_member_read_does_not_authorize_card_lookup',async()=>{assert((await http(memberCardPath(),undefined,authorization,'GET')).status===403,'Member reading implicitly authorized card lookup');});
  const issueCardRequest=randomUUID();const revokeCardRequest=randomUUID();let issuedCard,revokedCard,replacementCard;
  await test('C4_existing_permissions_do_not_authorize_cards',async()=>{
    assert((await http(issueCardPath(),{requestId:issueCardRequest})).status===403,'Attendance or membership permission issued a card');
    const assigned=(await db.query(`SELECT count(*)::int AS n FROM app.role_permissions WHERE role_id=$1 AND permission_id IN(SELECT id FROM app.permissions WHERE permission_code IN('gym.cards.manage','gym.cards.read'))`,[role])).rows[0];assert(assigned.n===0,'Card permissions implicitly assigned');
    const g=await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.cards.manage' AND is_active RETURNING id`,[tenant,role]);assert(g.rowCount===1,'Card management permission missing');
    assert((await db.query(`SELECT security.has_tenant_permission($1,$2,'gym.cards.manage',NULL) AS allowed`,[tenant,membership])).rows[0].allowed===false,'Card role gained tenant scope');
  });
  await test('C4_unauthenticated_issue_denied',async()=>assert((await http(issueCardPath(),{requestId:issueCardRequest},null)).status===401,'Expected 401'));
  await test('C4_issue_scope_denied',async()=>{
    for(const p of [issueCardPath(member,otherBranch),issueCardPath(otherMember),issueCardPath(member,branch,otherTenant)])assert((await http(p,{requestId:randomUUID()})).status===403,'Expected 403');
  });
  await test('C4_client_card_fields_rejected',async()=>{
    for(const extra of [{cardId:randomUUID()},{status:'active'},{issuedAt:'2026-01-01'},{memberId:member}])assert((await http(issueCardPath(),{requestId:randomUUID(),...extra})).status===400,'Expected 400');
  });
  for(const state of ['pending','inactive','blacklisted'])await test(`C4_${state}_issuance_denied`,async()=>{
    try{await db.query('UPDATE app.members SET status=$2 WHERE id=$1',[member,state]);assert((await http(issueCardPath(),{requestId:randomUUID()})).status===400,'Ineligible member received card');}finally{await db.query("UPDATE app.members SET status='active' WHERE id=$1",[member]);}
  });
  await test('C4_concurrent_issue_retry_saved_once',async()=>{
    const r=await Promise.all([http(issueCardPath(),{requestId:issueCardRequest}),http(issueCardPath(),{requestId:issueCardRequest})]);assert(r.every(x=>x.status===200),'Issue failed');assert(JSON.stringify(r[0].data)===JSON.stringify(r[1].data),'Issue retry changed receipt');issuedCard=r[0].data;
    assert(issuedCard.tenantId===tenant&&issuedCard.branchId===branch&&issuedCard.memberId===member&&issuedCard.requestId===issueCardRequest&&issuedCard.eventType==='issued'&&issuedCard.reason===null&&issuedCard.cardId,'Invalid issuance receipt');assert(!('actorSnapshot'in issuedCard)&&!('token'in issuedCard),'Private data exposed');
  });
  await test('C4_manage_does_not_implicitly_allow_read',async()=>{
    assert((await http(cardPath(issuedCard.cardId),undefined,authorization,'GET')).status===403,'Manage implicitly read card');
    const g=await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.cards.read' AND is_active RETURNING id`,[tenant,role]);assert(g.rowCount===1,'Card read permission missing');
  });
  await test('C8_03_active_card_discovered_without_UUID_input',async()=>{const r=await http(memberCardPath(),undefined,authorization,'GET');assert(r.status===200&&r.data.card.id===issuedCard.cardId&&r.data.card.memberId===member&&r.data.card.status==='active','Active card discovery failed');assert(!('actor_snapshot'in r.data.card)&&!('phone'in r.data.card),'Private fields exposed');});
  await test('C8_04_no_card_returns_null_without_issuance',async()=>{const r=await http(memberCardPath(lookupMember),undefined,authorization,'GET');assert(r.status===200&&r.data.card===null,'No-card lookup failed');assert((await db.query('SELECT count(*)::int AS n FROM app.member_cards WHERE member_id=$1',[lookupMember])).rows[0].n===0,'Lookup issued a card');});
  await test('C4_card_details_active_and_scope_protected',async()=>{
    const r=await http(cardPath(issuedCard.cardId),undefined,authorization,'GET');assert(r.status===200&&r.data.id===issuedCard.cardId&&r.data.status==='active'&&r.data.memberId===member&&r.data.revokedAt===null,'Card details mismatch');
    for(const p of [cardPath(issuedCard.cardId,otherBranch),cardPath(issuedCard.cardId,branch,otherTenant),cardPath(randomUUID())])assert((await http(p,undefined,authorization,'GET')).status===403,'Card read scope failed');
    assert((await http(cardPath(issuedCard.cardId),undefined,null,'GET')).status===401,'Unauthenticated card read accepted');
  });
  await test('C4_second_active_card_denied',async()=>assert((await http(issueCardPath(),{requestId:randomUUID()})).status===400,'Second active card issued'));
  await test('C4_revoke_validation_and_scope',async()=>{
    assert((await http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'Lost card'},null)).status===401,'Unauthenticated revoke accepted');
    assert((await http(cardPath(issuedCard.cardId,otherBranch)+'/revoke',{requestId:revokeCardRequest,reason:'Lost card'})).status===403,'Other branch revoked card');
    assert((await http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:' '})).status===400,'Blank reason accepted');
    assert((await http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'Lost card',revokedAt:'2026-01-01'})).status===400,'Client timestamp accepted');
  });
  await test('C4_revoke_blacklisted_member_and_retry',async()=>{
    try{
      await db.query("UPDATE app.members SET status='blacklisted' WHERE id=$1",[member]);
      const r=await Promise.all([http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'  Lost card  '}),http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'Lost card'})]);assert(r.every(x=>x.status===200),'Revocation failed');revokedCard=r[0].data;assert(JSON.stringify(revokedCard)===JSON.stringify(r[1].data)&&revokedCard.eventType==='revoked'&&revokedCard.reason==='Lost card','Revocation receipt differs');
    }finally{await db.query("UPDATE app.members SET status='active' WHERE id=$1",[member]);}
  });
  await test('C4_revocation_state_conflicts_and_old_issue_retry',async()=>{
    const details=await http(cardPath(issuedCard.cardId),undefined,authorization,'GET');assert(details.status===200&&details.data.status==='revoked'&&details.data.revokedAt===revokedCard.eventAt,'Card was not revoked');
    assert((await http(cardPath(issuedCard.cardId)+'/revoke',{requestId:randomUUID(),reason:'Lost card'})).status===400,'Second revocation accepted');
    assert((await http(cardPath(issuedCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'Different reason'})).status===400,'Conflicting retry accepted');
    const old=await http(issueCardPath(),{requestId:issueCardRequest});assert(old.status===200&&JSON.stringify(old.data)===JSON.stringify(issuedCard),'Old issue receipt changed');assert((await http(cardPath(issuedCard.cardId),undefined,authorization,'GET')).data.status==='revoked','Old issue retry reactivated card');
  });
  await test('C8_05_latest_revoked_card_is_read_only',async()=>{const r=await http(memberCardPath(),undefined,authorization,'GET');assert(r.status===200&&r.data.card.id===issuedCard.cardId&&r.data.card.status==='revoked'&&r.data.card.revokedAt===revokedCard.eventAt,'Revoked card lookup failed');});
  await test('C4_replacement_card_and_request_conflicts',async()=>{
    const r=await http(issueCardPath(),{requestId:randomUUID()});assert(r.status===200&&r.data.cardId!==issuedCard.cardId,'Replacement card failed');replacementCard=r.data;
    assert((await http(cardPath(replacementCard.cardId)+'/revoke',{requestId:revokeCardRequest,reason:'Lost card'})).status===400,'Request reused on another card');
    assert((await http(cardPath(replacementCard.cardId)+'/revoke',{requestId:issueCardRequest,reason:'Lost card'})).status===400,'Issue request reused for revocation');
  });
  await test('C8_06_replacement_active_card_is_selected',async()=>{const r=await http(memberCardPath(),undefined,authorization,'GET');assert(r.status===200&&r.data.card.id===replacementCard.cardId&&r.data.card.status==='active','Replacement lookup returned old card');});
  await test('C8_07_member_branch_and_tenant_scope_enforced',async()=>{for(const p of [memberCardPath(otherMember),memberCardPath(member,otherBranch),memberCardPath(member,branch,otherTenant),memberCardPath(randomUUID())])assert((await http(p,undefined,authorization,'GET')).status===403,'Card lookup scope bypass');});
  await test('C8_08_query_fields_rejected',async()=>{for(const suffix of ['?status=active','?memberId='+otherMember])assert((await http(memberCardPath()+suffix,undefined,authorization,'GET')).status===400,'Query override accepted');});
  await test('C8_09_inactive_branch_denied',async()=>{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[branch]);try{assert((await http(memberCardPath(),undefined,authorization,'GET')).status===403,'Inactive branch allowed');}finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[branch]);}});
  await test('C8_10_runtime_function_only_lookup',async()=>{const hash=(await db.query('SELECT session_token_hash FROM security.tenant_sessions WHERE membership_id=$1 AND revoked_at IS NULL',[membership])).rows[0].session_token_hash;await db.query('BEGIN');try{await db.query('SET LOCAL ROLE gympro_app');const r=await db.query('SELECT * FROM security.find_member_card($1,$2,$3,$4)',[hash,tenant,branch,member]);assert(r.rows.length===1&&r.rows[0].card_id===replacementCard.cardId,'Runtime function lookup failed');}finally{await db.query('ROLLBACK');}let code;await db.query('BEGIN');try{await db.query('SET LOCAL ROLE gympro_app');await db.query('SELECT * FROM security.find_member_card($1,$2,$3,$4)',[hash,tenant,branch,otherMember]);}catch(e){code=e.code;}finally{await db.query('ROLLBACK');}assert(code==='42501','SQL member scope bypass');});
  await test('C4_read_only_permission_cannot_manage',async()=>{
    try{await db.query(`DELETE FROM app.role_permissions WHERE tenant_id=$1 AND role_id=$2 AND permission_id=(SELECT id FROM app.permissions WHERE permission_code='gym.cards.manage')`,[tenant,role]);assert((await http(cardPath(replacementCard.cardId),undefined,authorization,'GET')).status===200,'Read-only role cannot read');assert((await http(cardPath(replacementCard.cardId)+'/revoke',{requestId:randomUUID(),reason:'Test reason'})).status===403,'Read-only role revoked');}
    finally{await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.cards.manage' ON CONFLICT DO NOTHING`,[tenant,role]);}
  });
  await test('C4_card_counts_audit_and_runtime_boundary',async()=>{
    const c=(await db.query(`SELECT (SELECT count(*)::int FROM app.member_cards WHERE tenant_id=$1 AND member_id=$2) AS cards,(SELECT count(*)::int FROM app.member_card_events WHERE tenant_id=$1 AND member_id=$2) AS events,(SELECT count(*)::int FROM app.member_cards WHERE tenant_id=$1 AND member_id=$2 AND status='active') AS active,(SELECT bool_and(actor_membership_id=$3 AND actor_snapshot->>'user_id'=$4::text) FROM app.member_card_events WHERE tenant_id=$1 AND member_id=$2) AS audit`,[tenant,member,membership,user])).rows[0];assert(c.cards===2&&c.events===3&&c.active===1&&c.audit,'Card history counts or actor mismatch');
    const r=(await db.query(`SELECT bool_and(relrowsecurity AND relforcerowsecurity) AS rls,bool_or(has_table_privilege('gympro_app',oid,'SELECT,INSERT,UPDATE,DELETE')) AS direct FROM pg_class WHERE oid IN('app.member_cards'::regclass,'app.member_card_events'::regclass)`)).rows[0];assert(r.rls&&!r.direct,'Card runtime boundary failed');
  });

  const qrPath=c=>cardPath(c)+'/qr';
  const scanPath=(b=branch,t=tenant)=>`/tenants/${t}/branches/${b}/attendance/scan-card`;
  let cardQr,scanVisit;const scanRequest=randomUUID();
  await test('C5_qr_rendering_and_identifier_payload',async()=>{
    const r=await http(qrPath(replacementCard.cardId),undefined,authorization,'GET');assert(r.status===200&&r.data.cardId===replacementCard.cardId&&r.data.payload===`GP1:${tenant}:${branch}:${replacementCard.cardId}`&&r.data.svg.includes('<svg'),'QR generation failed');cardQr=r.data;
    assert(!cardQr.payload.includes(email)&&!cardQr.payload.includes('Bearer'),'QR leaked personal data or credentials');
    assert((await http(qrPath(replacementCard.cardId),undefined,null,'GET')).status===401,'Unauthenticated QR rendering permitted');
    assert((await http(qrPath(issuedCard.cardId),undefined,authorization,'GET')).status===400,'Revoked QR rendered');
  });
  await test('C5_read_permission_required_for_qr',async()=>{
    try{await db.query(`DELETE FROM app.role_permissions WHERE role_id=$1 AND permission_id=(SELECT id FROM app.permissions WHERE permission_code='gym.cards.read')`,[role]);assert((await http(qrPath(replacementCard.cardId),undefined,authorization,'GET')).status===403,'QR rendered without card read permission');}
    finally{await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.cards.read' ON CONFLICT DO NOTHING`,[tenant,role]);}
  });
  await test('C5_scan_requires_authenticated_attendance_recorder',async()=>{
    assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()},null)).status===401,'Unauthenticated scan accepted');
    try{await db.query(`DELETE FROM app.role_permissions WHERE role_id=$1 AND permission_id=(SELECT id FROM app.permissions WHERE permission_code='gym.attendance.record')`,[role]);assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===403,'Card management permission authorized scanning');}
    finally{await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='gym.attendance.record' ON CONFLICT DO NOTHING`,[tenant,role]);}
  });
  await test('C5_payload_scope_and_input_protection',async()=>{
    for(const p of [scanPath(otherBranch),scanPath(branch,otherTenant)])assert((await http(p,{payload:cardQr.payload,requestId:randomUUID()})).status===403,'Wrong scope scan accepted');
    assert((await http(scanPath(),{payload:`GP1:${otherTenant}:${branch}:${replacementCard.cardId}`,requestId:randomUUID()})).status===403,'QR tenant mismatch accepted');
    assert((await http(scanPath(),{payload:`GP1:${tenant}:${otherBranch}:${replacementCard.cardId}`,requestId:randomUUID()})).status===403,'QR branch mismatch accepted');
    assert((await http(scanPath(),{payload:`GP1:${tenant}:${branch}:${randomUUID()}`,requestId:randomUUID()})).status===403,'Unknown card accepted');
    for(const body of [{},{payload:'bad',requestId:randomUUID()},{payload:cardQr.payload,requestId:'bad'},{payload:cardQr.payload,requestId:randomUUID(),checkedInAt:'2026-01-01'}])assert((await http(scanPath(),body)).status===400,'Invalid scan input accepted');
  });
  await test('C5_blacklisted_member_scan_denied',async()=>{
    try{await db.query("UPDATE app.members SET status='blacklisted' WHERE id=$1",[member]);assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===400,'Blacklisted member scanned');}
    finally{await db.query("UPDATE app.members SET status='active' WHERE id=$1",[member]);}
  });
  await test('C5_suspended_or_elapsed_coverage_scan_denied',async()=>{
    try{
      await db.query("UPDATE app.member_subscriptions SET status='suspended',suspended_at=clock_timestamp() WHERE id=$1",[activation.id]);assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===400,'Suspended coverage scanned');
      await db.query("UPDATE app.member_subscriptions SET status='active',suspended_at=NULL,starts_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date-30,ends_on=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date WHERE id=$1",[activation.id]);assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===400,'Elapsed coverage scanned');
    }finally{await db.query("UPDATE app.member_subscriptions SET status='active',suspended_at=NULL,starts_on=$2,ends_on=$3 WHERE id=$1",[activation.id,beforeAttendance.starts_on,beforeAttendance.ends_on]);}
  });
  await test('C5_manual_request_cannot_be_relabelled_as_scan',async()=>assert((await http(scanPath(),{payload:cardQr.payload,requestId:openVisit.request_id})).status===400,'Manual request relabelled as scan'));
  await test('C5_concurrent_scans_save_one_visit_and_receipt',async()=>{
    const replies=await Promise.all([http(scanPath(),{payload:cardQr.payload,requestId:scanRequest}),http(scanPath(),{payload:cardQr.payload,requestId:scanRequest})]);assert(replies.every(r=>r.status===200),'Scan failed');scanVisit=replies[0].data;assert(JSON.stringify(scanVisit)===JSON.stringify(replies[1].data),'Concurrent scan receipts differ');assert(scanVisit.memberId===member&&scanVisit.tenantId===tenant&&scanVisit.branchId===branch&&scanVisit.requestId===scanRequest,'Scan recorded wrong member');
    const r=(await db.query(`SELECT count(*)::int AS n,bool_and(card_id=$3 AND visit_id=$4 AND actor_membership_id=$5 AND actor_snapshot->>'user_id'=$6::text) AS correct FROM app.card_scan_receipts WHERE tenant_id=$1 AND request_id=$2`,[tenant,scanRequest,replacementCard.cardId,scanVisit.id,membership,user])).rows[0];assert(r.n===1&&r.correct,'Scan provenance not saved once');
  });
  await test('C5_repeated_scan_with_new_request_cannot_duplicate_open_visit',async()=>assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===400,'Duplicate open visit created'));
  await test('C5_scan_checkout_cycle',async()=>{
    assert((await http(checkoutPath(scanVisit.id),{requestId:randomUUID()})).status===200,'Scanned visit cannot check out');
    const r=await http(scanPath(),{payload:cardQr.payload,requestId:scanRequest});assert(r.status===200&&r.data.id===scanVisit.id&&r.data.checkedOutAt,'Old scan retry reopened visit');
  });
  await test('C5_revoked_card_scan_and_retry_denied',async()=>{
    assert((await http(cardPath(replacementCard.cardId)+'/revoke',{requestId:randomUUID(),reason:'C5 scan revocation verification'})).status===200,'Could not revoke scanned card');
    for(const requestId of [randomUUID(),scanRequest])assert((await http(scanPath(),{payload:cardQr.payload,requestId})).status===400,'Revoked card scanned');
  });
  await test('C5_scan_request_cannot_switch_to_replacement_card',async()=>{
    const issued=await http(issueCardPath(),{requestId:randomUUID()});assert(issued.status===200,'Could not issue next card');
    const qr=await http(qrPath(issued.data.cardId),undefined,authorization,'GET');assert(qr.status===200,'Could not render next card QR');
    assert((await http(scanPath(),{payload:qr.data.payload,requestId:scanRequest})).status===400,'Scan request switched cards');
    const r=await http(scanPath(),{payload:qr.data.payload,requestId:randomUUID()});assert(r.status===200&&r.data.id!==scanVisit.id,'New scan after checkout failed');assert((await http(checkoutPath(r.data.id),{requestId:randomUUID()})).status===200,'Final scan checkout failed');
  });
  await test('C5_scan_history_runtime_boundary',async()=>{
    const r=(await db.query(`SELECT relrowsecurity AND relforcerowsecurity AS rls,has_table_privilege('gympro_app','app.card_scan_receipts','SELECT,INSERT,UPDATE,DELETE') AS direct FROM pg_class WHERE oid='app.card_scan_receipts'::regclass`)).rows[0];assert(r.rls&&!r.direct,'Scan audit boundary failed');
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

  const branchSuspensionPath =
    `/tenants/${tenant}/branches/${branch}/subscriptions/${activation.id}/suspend`;
  const branchSuspensionRequest = randomUUID();
  const branchSuspensionReason = 'B8 branch suspension API verification';
  const branchSuspensionInput = {
    reason: branchSuspensionReason,
    requestId: branchSuspensionRequest,
  };
  let branchSuspensionReceipt;

  await test('16sa_unauthenticated_suspension', async () => {
    assert((await http(
      branchSuspensionPath, branchSuspensionInput, null
    )).status === 401, 'Expected HTTP 401.');
  });

  await test('16sb_tenant_suspension_denied', async () => {
    assert((await http(
      `/tenants/${tenant}/subscriptions/${activation.id}/suspend`,
      branchSuspensionInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16sc_unassigned_branch_suspension_denied', async () => {
    assert((await http(
      `/tenants/${tenant}/branches/${otherBranch}/subscriptions/${activation.id}/suspend`,
      branchSuspensionInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16sd_suspension_route_branch_mismatch', async () => {
    assert((await http(
      `/tenants/${tenant}/branches/${branch}/subscriptions/8a28fa97-e41f-4053-be61-8162ff3d387d/suspend`,
      branchSuspensionInput
    )).status === 403, 'Expected HTTP 403.');
  });

  await test('16se_client_suspension_fields_rejected', async () => {
    for (const extra of [
      { branchId: branch },
      { suspendedAt: '2026-01-01T00:00:00Z' },
      { endsOn: '2099-01-01' },
    ]) {
      assert((await http(branchSuspensionPath, {
        ...branchSuspensionInput, ...extra,
      })).status === 400, 'Expected HTTP 400.');
    }
  });

  await test('16sf_blank_suspension_reason_rejected', async () => {
    assert((await http(branchSuspensionPath, {
      ...branchSuspensionInput, reason: '   ',
    })).status === 400, 'Expected HTTP 400.');
  });

  await test('16sg_branch_staff_suspension_allowed', async () => {
    const result = await http(branchSuspensionPath, {
      ...branchSuspensionInput,
      reason: ` ${branchSuspensionReason} `,
    });
    assert(result.status === 200,
      `Expected HTTP 200; received ${result.status}.`);
    branchSuspensionReceipt = result.data;
    assert(
      branchSuspensionReceipt.tenantId === tenant &&
      branchSuspensionReceipt.subscriptionId === activation.id &&
      branchSuspensionReceipt.requestId === branchSuspensionRequest &&
      branchSuspensionReceipt.reason === branchSuspensionReason &&
      branchSuspensionReceipt.id &&
      branchSuspensionReceipt.suspendedAt,
      'Branch suspension receipt mismatch.'
    );
  });

  await test('16sh_branch_suspension_retry', async () => {
    const result = await http(branchSuspensionPath, branchSuspensionInput);
    assert(
      result.status === 200 &&
      JSON.stringify(result.data) === JSON.stringify(branchSuspensionReceipt),
      'Retry changed the original suspension receipt.'
    );
  });

  await test('16si_suspension_saved_once_and_dates_preserved', async () => {
    const saved = await db.query(`
      SELECT
        s.status,
        s.starts_on::text AS starts_on,
        s.ends_on::text AS ends_on,
        s.agreed_price_amount::text AS amount,
        m.status AS member_status,
        h.id::text AS history_id,
        (s.suspended_at = h.suspended_at) AS timestamp_matches,
        h.previous_subscription_snapshot->>'suspended_by_membership_id'
          AS actor_membership,
        h.previous_subscription_snapshot->>'suspended_by_user_id'
          AS actor_user,
        (
          SELECT count(*)::int FROM app.subscription_suspensions x
          WHERE x.tenant_id = s.tenant_id AND x.subscription_id = s.id
        ) AS suspension_count,
        (
          SELECT count(*)::int FROM app.subscription_renewals x
          WHERE x.tenant_id = s.tenant_id AND x.subscription_id = s.id
        ) AS renewal_count
      FROM app.member_subscriptions s
      JOIN app.members m ON m.tenant_id = s.tenant_id AND m.id = s.member_id
      JOIN app.subscription_suspensions h
        ON h.tenant_id = s.tenant_id AND h.subscription_id = s.id
      WHERE s.tenant_id = $1::uuid AND s.id = $2::uuid
        AND h.request_id = $3::uuid
    `, [tenant, activation.id, branchSuspensionRequest]);

    assert(saved.rowCount === 1, 'Saved suspension missing.');
    const row = saved.rows[0];
    assert(
      row.status === 'suspended' &&
      row.starts_on === activation.startsOn &&
      row.ends_on === branchRenewalReceipt.renewalEndsOn &&
      row.amount === '50000.00' &&
      row.member_status === 'active' &&
      row.history_id === branchSuspensionReceipt.id &&
      row.timestamp_matches &&
      row.actor_membership === membership &&
      row.actor_user === user &&
      row.suspension_count === 1 &&
      row.renewal_count === 1,
      'Suspension dates, audit, or purchase counts mismatch.'
    );
  });

  await test('16sj_suspension_request_reuse_conflict', async () => {
    assert((await http(branchSuspensionPath, {
      ...branchSuspensionInput,
      reason: 'Different suspension reason',
    })).status === 400, 'Expected HTTP 400.');
  });

  await test('16sk_new_renewal_while_suspended_rejected', async () => {
    assert((await http(branchRenewalPath, {
      planPriceId: generalPrice,
      requestId: randomUUID(),
    })).status === 400, 'Expected HTTP 400.');

    const count = (await db.query(`
      SELECT count(*)::int AS count FROM app.subscription_renewals
      WHERE tenant_id = $1::uuid AND subscription_id = $2::uuid
    `, [tenant, activation.id])).rows[0].count;
    assert(count === 1, 'Rejected renewal created purchase history.');
  });


  const extraRoot = `/tenants/${tenant}/branches/${branch}`;
  const extraFocMember = randomUUID();
  const extraDiscountMember = randomUUID();
  const extraDueMember = randomUUID();
  const extraDueSub = randomUUID();
  const extraPromotionCode = `${tag}_P`;
  let extraPromotion;
  let extraDiscountReceipt;
  let extraFocReceipt;
  let extraExpirationReceipt;
  const extraToday = (await db.query(`SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date::text AS today`)).rows[0].today;
  for (const id of [extraFocMember, extraDiscountMember, extraDueMember]) {
    memberEmails.push(`${id}@example.invalid`);
    await db.query(`INSERT INTO app.members(id,tenant_id,branch_id,full_name,email,status)
      VALUES($1::uuid,$2::uuid,$3::uuid,'B8 automated remaining fixture',$4::text,$5::text)`,
      [id,tenant,branch,`${id}@example.invalid`,id===extraDueMember?'active':'pending']);
  }
  await db.query(`INSERT INTO app.member_subscriptions(id,tenant_id,member_id,branch_id,plan_id,plan_price_id,
    duration_value,duration_unit,agreed_price_amount,currency_code,status,starts_on,ends_on,activated_at)
    VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,$5::uuid,$6::uuid,1,'months',50000,'MMK','active',
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date-30,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date,statement_timestamp()-interval '31 days')`,
    [extraDueSub,tenant,extraDueMember,branch,plan,generalPrice]);
  const promotionBody = {promotionCode:extraPromotionCode,promotionName:'B8 automated branch promotion',
    discountKind:'percentage',discountValue:'10',startsOn:extraToday};
  const focBody = {planId:plan,planPriceId:generalPrice,reason:'B8 automated FOC',requestId:randomUUID()};
  const discountBody = {planId:plan,planPriceId:generalPrice,promotionId:randomUUID(),requestId:randomUUID()};
  await test('B8_remaining_dedicated_permissions_required',async()=>{
    for(const [path,body] of [
      [`${extraRoot}/promotions`,promotionBody],
      [`${extraRoot}/members/${extraFocMember}/subscriptions/grant-foc`,focBody],
      [`${extraRoot}/members/${extraDiscountMember}/subscriptions/activate-discounted`,discountBody],
      [`${extraRoot}/members/${extraDiscountMember}/blacklist`,{reason:'B8 permission test',requestId:randomUUID()}],
    ]) assert((await http(path,body)).status===403,'Dedicated branch permission was not required.');
  });
  const added = await db.query(`INSERT INTO app.role_permissions(tenant_id,role_id,permission_id)
    SELECT $1::uuid,$2::uuid,id FROM app.permissions WHERE is_active AND permission_code IN
    ('gym.promotions.manage','gym.memberships.apply_discount','gym.memberships.grant_foc','gym.members.update') RETURNING id`,[tenant,role]);
  assert(added.rowCount===4,'Dedicated permissions missing.');
  await test('B8_remaining_branch_role_still_has_no_tenant_scope',async()=>{
    const p=await db.query(`SELECT permission_code,security.has_tenant_permission($1::uuid,$2::uuid,permission_code,NULL::uuid) AS allowed
      FROM app.permissions WHERE permission_code IN ('gym.promotions.manage','gym.memberships.apply_discount','gym.memberships.grant_foc','gym.members.update')`,[tenant,membership]);
    assert(p.rows.length===4&&p.rows.every(x=>x.allowed===false),'Branch role gained tenant-wide access.');
  });
  await test('B8_remaining_unauthenticated_routes',async()=>{
    for(const [path,body] of [
      [`${extraRoot}/subscriptions/${extraDueSub}/expire`,{}],
      [`${extraRoot}/promotions`,promotionBody],
      [`${extraRoot}/members/${extraFocMember}/subscriptions/grant-foc`,focBody],
      [`${extraRoot}/members/${extraDiscountMember}/subscriptions/activate-discounted`,discountBody],
      [`${extraRoot}/members/${extraDiscountMember}/blacklist`,{reason:'B8 test',requestId:randomUUID()}],
    ]) assert((await http(path,body,null)).status===401,'Expected HTTP 401.');
  });
  await test('B8_branch_promotion_creation',async()=>{
    const result=await http(`${extraRoot}/promotions`,promotionBody);
    assert(result.status===201,`Promotion creation HTTP ${result.status}.`);extraPromotion=result.data;
    assert(extraPromotion.branchId===branch&&extraPromotion.status==='draft'&&extraPromotion.discountValue==='10.00','Promotion branch/default mismatch.');
    discountBody.promotionId=extraPromotion.id;
  });
  await test('B8_branch_promotion_body_branch_rejected',async()=>{
    assert((await http(`${extraRoot}/promotions`,{...promotionBody,promotionCode:`${extraPromotionCode}_X`,branchId:otherBranch})).status===400,'Expected HTTP 400.');
  });
  await test('B8_branch_promotion_activation',async()=>{
    const path=`${extraRoot}/promotions/${extraPromotion.id}/activate`;
    const a=await http(path,{}),b=await http(path,{});
    assert(a.status===200&&a.data.status==='active'&&b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data),'Promotion activation/retry failed.');
  });
  await test('B8_remaining_member_branch_mismatches',async()=>{
    for(const [path,body] of [
      [`${extraRoot}/members/${otherMember}/blacklist`,{reason:'B8 mismatch',requestId:randomUUID()}],
      [`${extraRoot}/members/${otherMember}/subscriptions/grant-foc`,focBody],
      [`${extraRoot}/members/${otherMember}/subscriptions/activate-discounted`,discountBody],
    ]) assert((await http(path,body)).status===403,'Member route branch mismatch allowed.');
  });
  await test('B8_branch_discounted_activation_and_retry',async()=>{
    const path=`${extraRoot}/members/${extraDiscountMember}/subscriptions/activate-discounted`;
    const a=await http(path,discountBody);assert(a.status===200,`Discount activation HTTP ${a.status}.`);
    extraDiscountReceipt=a.data;const b=await http(path,discountBody);
    assert(b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data)&&a.data.agreedPriceAmount==='45000.00','Discount receipt/retry mismatch.');
  });
  await test('B8_branch_discounted_renewal_and_retry',async()=>{
    const path=`${extraRoot}/subscriptions/${extraDiscountReceipt.subscriptionId}/renew-discounted`;
    const body={planPriceId:generalPrice,promotionId:extraPromotion.id,requestId:randomUUID()};
    const a=await http(path,body),b=await http(path,body);
    assert(a.status===200&&b.status===200&&a.data.agreedPriceAmount==='45000.00'&&JSON.stringify(a.data)===JSON.stringify(b.data),'Discount renewal/retry failed.');
    const q=(await db.query(`SELECT s.agreed_price_amount::text AS price,s.branch_id::text AS branch,
      (SELECT count(*)::int FROM app.membership_discounts WHERE subscription_id=s.id) AS discounts
      FROM app.member_subscriptions s WHERE id=$1::uuid`,[extraDiscountReceipt.subscriptionId])).rows[0];
    assert(q.price==='45000.00'&&q.branch===branch&&q.discounts===2,'Saved discount purchase mismatch.');
  });
  await test('B8_branch_blacklist_and_retry',async()=>{
    const path=`${extraRoot}/members/${extraDiscountMember}/blacklist`;
    const body={reason:'B8 branch blacklist verification',requestId:randomUUID()};
    const a=await http(path,body),b=await http(path,body);
    assert(a.status===200&&a.data.resultingStatus==='blacklisted'&&b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data),'Blacklist/retry failed.');
  });
  await test('B8_blacklisted_discounted_renewal_denied',async()=>{
    assert((await http(`${extraRoot}/subscriptions/${extraDiscountReceipt.subscriptionId}/renew-discounted`,
      {planPriceId:generalPrice,promotionId:extraPromotion.id,requestId:randomUUID()})).status===400,'Expected HTTP 400.');
  });
  await test('B8_branch_blacklist_removal_and_retry',async()=>{
    const path=`${extraRoot}/members/${extraDiscountMember}/unblacklist`;
    const body={reason:'B8 branch blacklist removal',requestId:randomUUID()};
    const a=await http(path,body),b=await http(path,body);
    assert(a.status===200&&a.data.resultingStatus==='active'&&b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data),'Blacklist removal/retry failed.');
  });
  await test('B8_branch_foc_grant_and_retry',async()=>{
    const path=`${extraRoot}/members/${extraFocMember}/subscriptions/grant-foc`;
    const a=await http(path,focBody),b=await http(path,focBody);
    assert(a.status===200&&b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data),'FOC grant/retry failed.');extraFocReceipt=a.data;
    const q=(await db.query(`SELECT branch_id::text AS branch,membership_kind,agreed_price_amount::text AS price
      FROM app.member_subscriptions WHERE id=$1::uuid`,[a.data.subscriptionId])).rows[0];
    assert(q.branch===branch&&q.membership_kind==='foc'&&q.price==='0.00','Saved FOC membership mismatch.');
  });
  await test('B8_branch_foc_ordinary_renewal_denied',async()=>{
    assert((await http(`${extraRoot}/subscriptions/${extraFocReceipt.subscriptionId}/renew`,
      {planPriceId:generalPrice,requestId:randomUUID()})).status===400,'Expected HTTP 400.');
  });
  await test('B8_branch_future_expiration_denied',async()=>{
    assert((await http(`${extraRoot}/subscriptions/${activation.id}/expire`,{})).status===400,'Expected HTTP 400.');
  });
  await test('B8_branch_expiration_client_date_denied',async()=>{
    assert((await http(`${extraRoot}/subscriptions/${extraDueSub}/expire`,{processedOn:extraToday})).status===400,'Expected HTTP 400.');
  });
  await test('B8_branch_due_expiration_and_retry',async()=>{
    const path=`${extraRoot}/subscriptions/${extraDueSub}/expire`;
    const a=await http(path,{}),b=await http(path,{});
    assert(a.status===200&&b.status===200&&JSON.stringify(a.data)===JSON.stringify(b.data)&&a.data.coverageEndsOn===extraToday,'Due expiration/retry failed.');extraExpirationReceipt=a.data;
    const q=(await db.query(`SELECT s.status,m.status AS member_status,
      (SELECT count(*)::int FROM app.subscription_expirations WHERE subscription_id=s.id) AS histories
      FROM app.member_subscriptions s JOIN app.members m ON m.id=s.member_id WHERE s.id=$1::uuid`,[extraDueSub])).rows[0];
    assert(q.status==='expired'&&q.member_status==='inactive'&&q.histories===1,'Saved expiration mismatch.');
  });
  await test('B8_remaining_unassigned_branch_and_cross_tenant_denied',async()=>{
    assert((await http(`/tenants/${tenant}/branches/${otherBranch}/subscriptions/${extraDueSub}/expire`,{})).status===403,'Unassigned branch allowed.');
    assert((await http(`/tenants/${otherTenant}/branches/${branch}/members/${extraFocMember}/subscriptions/grant-foc`,focBody)).status===403,'Other tenant allowed.');
  });
  await test('B8_branch_promotion_deactivation',async()=>{
    const q=await http(`${extraRoot}/promotions/${extraPromotion.id}/deactivate`,{});
    assert(q.status===200&&q.data.status==='inactive','Promotion deactivation failed.');
  });

  await test('16_inactive_branch_denied', async () => {
    await db.query(`UPDATE app.branches SET status = 'inactive' WHERE id = $1::uuid`, [branch]);
    assert((await http(activationPath(), input)).status === 403, 'Expected HTTP 403.');
  });

  await test('17_logout', async () => {
    assert((await http('/auth/logout')).status === 204, 'Expected HTTP 204.');
  });

  await test('C7_13_revoked_session_lookup_denied',async()=>{assert((await http(lookupPath(),undefined,authorization,'GET')).status===401,'Revoked session lookup permitted');});
  await test('18_revoked_session_denied', async () => {
    assert((await http(activationPath(), input)).status === 401, 'Expected HTTP 401.');
  });

  await test('C9_11_revoked_session_summary_denied',async()=>{assert((await http(summaryPath(),undefined,authorization,'GET')).status===401,'Revoked summary accepted');});
  await test('C8_11_revoked_session_card_lookup_denied',async()=>{assert((await http(memberCardPath(),undefined,authorization,'GET')).status===401,'Revoked session lookup permitted');});
  await test('C5_revoked_session_qr_and_scan_denied',async()=>{assert((await http(qrPath(replacementCard.cardId),undefined,authorization,'GET')).status===401,'Revoked session rendered QR');assert((await http(scanPath(),{payload:cardQr.payload,requestId:randomUUID()})).status===401,'Revoked session scanned');});
  await test('C4_revoked_session_card_access_denied',async()=>{assert((await http(issueCardPath(),{requestId:randomUUID()})).status===401,'Revoked session issued card');assert((await http(cardPath(issuedCard.cardId),undefined,authorization,'GET')).status===401,'Revoked session read card');assert((await http(cardPath(replacementCard.cardId)+'/revoke',{requestId:randomUUID(),reason:'Test reason'})).status===401,'Revoked session revoked card');});
  await test('C3_revoked_session_cannot_read',async()=>{assert((await getAttendance()).status===401,'Revoked history read permitted');assert((await getAttendance('/current')).status===401,'Revoked occupancy read permitted');});
  await test('C2_revoked_checkout_and_checkin_denied',async()=>{assert((await http(checkoutPath(openVisit.id),{requestId:checkoutRequest})).status===401,'Revoked checkout accepted');assert((await http(attendancePath(),{requestId:randomUUID()})).status===401,'Revoked check-in accepted');});
  await test('18b_revoked_session_suspension_denied', async () => {
    assert((await http(
      branchSuspensionPath, branchSuspensionInput
    )).status === 401, 'Expected HTTP 401.');
  });
  await test('B8_remaining_revoked_session_routes',async()=>{
    for(const [path,body] of [
      [`${extraRoot}/subscriptions/${extraDueSub}/expire`,{}],
      [`${extraRoot}/members/${extraFocMember}/subscriptions/grant-foc`,focBody],
      [`${extraRoot}/members/${extraDiscountMember}/blacklist`,{reason:'B8 revoked',requestId:randomUUID()}],
      [`${extraRoot}/members/${extraDiscountMember}/subscriptions/activate-discounted`,discountBody],
    ]) assert((await http(path,body)).status===401,'Revoked session allowed.');
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
      await db.query(`DELETE FROM app.card_scan_receipts c USING app.members m WHERE c.tenant_id=m.tenant_id AND c.member_id=m.id AND m.tenant_id=$1 AND m.email=ANY($2::text[])`,[tenant,memberEmails]);
      await db.query(`DELETE FROM app.member_card_events c USING app.members m WHERE c.tenant_id=m.tenant_id AND c.member_id=m.id AND m.tenant_id=$1 AND m.email=ANY($2::text[])`,[tenant,memberEmails]);
      await db.query(`DELETE FROM app.member_cards c USING app.members m WHERE c.tenant_id=m.tenant_id AND c.member_id=m.id AND m.tenant_id=$1 AND m.email=ANY($2::text[])`,[tenant,memberEmails]);
      await db.query(`DELETE FROM app.attendance_checkouts c USING app.members m WHERE c.tenant_id=m.tenant_id AND c.member_id=m.id AND m.tenant_id=$1 AND m.email=ANY($2::text[])`,[tenant,memberEmails]);
      await db.query(`DELETE FROM app.attendance_visits v USING app.members m WHERE v.tenant_id=m.tenant_id AND v.member_id=m.id AND m.tenant_id=$1 AND m.email=ANY($2::text[])`,[tenant,memberEmails]);
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
      await db.query(`DELETE FROM app.membership_promotions WHERE tenant_id=$1::uuid AND promotion_code IN ($2::text,$3::text)`,[tenant,`${tag}_P`,`${tag}_P_X`]);
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
    console.log('PASS: Combined C9 attendance summary, C8 selected-member card lookup, C7 member lookup, C6 operator assets and QR decoding, C5/C4/C3/C2/C1 and B8 regression verification completed.');
    console.log('PASS: Test session revoked, fixture records removed, demo records unchanged.');
  }
}