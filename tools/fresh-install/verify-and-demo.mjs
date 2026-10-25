import {createRequire} from 'node:module';import {resolve,join} from 'node:path';import {readFileSync,writeFileSync,existsSync,openSync,closeSync} from 'node:fs';import {randomUUID} from 'node:crypto';import {spawn,spawnSync} from 'node:child_process';import {once} from 'node:events';import {createInterface} from 'node:readline/promises';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';import {provisionTenant,removeFixture} from './provision.mjs';
const [projectArg,portArg,bootstrap,apiPortArg,report]=process.argv.slice(2);const project=resolve(projectArg),port=Number(portArg),apiPort=Number(apiPortArg);
if(!Number.isInteger(port)||port<55432||port>55462||!Number.isInteger(apiPort)||apiPort<3151||apiPort>3181||!/^gympro_bootstrap_\d{14}_[a-f0-9]{6}$/.test(bootstrap))throw Error('Invalid isolated rehearsal arguments');
const password=process.env.GYMPRO_1F_PASSWORD;delete process.env.GYMPRO_1F_PASSWORD;if(typeof password!=='string'||password.length<12||password.length>256)throw Error('A separate 12-256 character rehearsal password is required');
const {Client}=createRequire(join(project,'package.json'))('pg');const argon2=createRequire(join(project,'package.json'))('argon2');
const {prepare,registerBaseline,apply}=await import(pathToFileURL(join(project,'tools/migrations/migrate.mjs')).href);
const connect=async(database)=>{const c=new Client({host:'127.0.0.1',port,user:'postgres',database,ssl:false,connectionTimeoutMillis:5000});await c.connect();await c.query("SET statement_timeout='20s'");return c;};
let pendingId;let c,api,apiClosed=false,context;const receipts=[],clients=[],checks=[];let clean=false,automaticPassed=false,stopRequested=false;
const abort=new AbortController();const requestStop=()=>{stopRequested=true;abort.abort();};process.once('SIGINT',requestStop);process.once('SIGTERM',requestStop);
const check=async(name,fn)=>{if(stopRequested)throw Error('Rehearsal cancelled');try{await fn();}catch(error){error.message=name+': '+error.message;throw error;}checks.push({name,result:'PASS'});console.log('PASS: '+name);};
const base=`http://127.0.0.1:${apiPort}`;const call=async(path,method='GET',body,token)=>{const r=await fetch(base+path,{method,headers:{...(body===undefined?{}:{'Content-Type':'application/json'}),...(token?{Authorization:'Bearer '+token}:{})},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(10000)});let data;try{data=await r.json();}catch{}return {status:r.status,data};};
try{
 const bootstrapClient=await connect(bootstrap);clients.push(bootstrapClient);const manifest=JSON.parse(readFileSync(join(project,'sql/migrations/manifest.json'),'utf8').replace(/^\uFEFF/,''));const plan=prepare(project,manifest);
 const registered=(await bootstrapClient.query("SELECT to_regclass('migration_control.ledger') IS NOT NULL present")).rows[0].present;if(!registered)await registerBaseline(bootstrapClient,plan);else assert.deepEqual((await bootstrapClient.query('SELECT position,id,sha256 FROM migration_control.ledger ORDER BY position')).rows,[plan.baseline,...plan.migrations].map(({position,id,sha256})=>({position,id,sha256})));await apply(bootstrapClient,plan);await bootstrapClient.end();clients.splice(clients.indexOf(bootstrapClient),1);
 const control=await connect('postgres');clients.push(control);const alreadyExists=(await control.query("SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='gympro_saas') present")).rows[0].present;if(!alreadyExists)await control.query(`CREATE DATABASE gympro_saas TEMPLATE ${bootstrap}`);await control.end();clients.splice(clients.indexOf(control),1);
 c=await connect('gympro_saas');clients.push(c);for(const t of (await c.query("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') AND c.relkind='r' AND NOT(n.nspname='app' AND c.relname='permissions')")).rows){const name='\"'+t.nspname+'\".\"'+t.relname+'\"';assert.equal((await c.query('SELECT count(*)::int n FROM '+name)).rows[0].n,0,'Retained fresh database must have no business fixtures: '+t.relname);}assert.equal((await c.query('SELECT count(*)::int n FROM app.permissions')).rows[0].n,39);assert.deepEqual((await c.query('SELECT position,id,sha256 FROM migration_control.ledger ORDER BY position')).rows,[plan.baseline,...plan.migrations].map(({position,id,sha256})=>({position,id,sha256})));const {rows:[identity]}=await c.query('SELECT (pg_control_system()).system_identifier::text system_id');context={port,systemIdentifier:identity.system_id};
 const nonce=randomUUID().replaceAll('-','').slice(0,12).toUpperCase();const input={requestId:randomUUID(),tenantCode:'F1_'+nonce,tenantName:'Isolated provisioning gym',tenantType:'independent',branchCode:'MAIN',branchName:'Main rehearsal branch',email:'f1_'+nonce.toLowerCase()+'@example.invalid',fullName:'Rehearsal administrator',password};let first;
 await check('01_atomic_tenant_branch_owner_provisioning',async()=>{first=await provisionTenant(c,input,argon2,context);receipts.push(first);assert.equal(first.permissions.length,8);});
 await check('02_retry_returns_original_receipt',async()=>assert.deepEqual(await provisionTenant(c,input,argon2,context),first));
 await check('03_changed_request_rejected_without_password_reset',async()=>{await assert.rejects(()=>provisionTenant(c,{...input,tenantName:'Changed'},argon2,context),/conflict/);await assert.rejects(()=>provisionTenant(c,{...input,password:password+'different'},argon2,context),/conflict/);assert.deepEqual(await provisionTenant(c,input,argon2,context),first);});
 await check('04_argon2id_hash_and_active_relationships',async()=>{const {rows:[u]}=await c.query('SELECT password_hash,status,email_verified_at FROM app.users WHERE id=$1',[first.userId]);assert.match(u.password_hash,/^\$argon2id\$/);assert.ok(await argon2.verify(u.password_hash,password));assert.equal(u.status,'active');assert.equal(u.email_verified_at,null);});
 await check('05_duplicate_identity_rolls_back_new_tenant',async()=>{const before=(await c.query('SELECT count(*)::int AS n FROM platform.tenants')).rows[0].n;await assert.rejects(()=>provisionTenant(c,{...input,requestId:randomUUID(),tenantCode:'OTHER_'+nonce},argon2,context),e=>e.code==='23505');assert.equal((await c.query('SELECT count(*)::int AS n FROM platform.tenants')).rows[0].n,before);});
 await check('06_basic_role_has_no_finance_foc_or_discount',async()=>{for(const permission of ['finance.payments.record','finance.reconciliation.manage','gym.memberships.grant_foc','gym.memberships.apply_discount'])assert.equal((await c.query('SELECT security.has_tenant_permission($1,$2,$3,$4) AS allowed',[first.tenantId,first.membershipId,permission,first.branchId])).rows[0].allowed,false);});
 await check('07_concurrent_same_request_saved_once',async()=>{const other=await connect('gympro_saas');clients.push(other);const [a,b]=await Promise.all([provisionTenant(c,input,argon2,context),provisionTenant(other,input,argon2,context)]);assert.deepEqual(a,b);assert.equal((await c.query('SELECT count(*)::int AS n FROM migration_control.provisioning_receipts WHERE request_id=$1',[input.requestId])).rows[0].n,1);});
 await check('08_runtime_cannot_provision_or_read_private_receipts',async()=>{await c.query('SET ROLE gympro_app');try{await assert.rejects(()=>c.query('SELECT * FROM migration_control.provisioning_receipts'),e=>e.code==='42501');await assert.rejects(()=>c.query("INSERT INTO platform.tenants(tenant_code,tenant_name) VALUES('DENIED','Denied')"),e=>e.code==='42501');}finally{await c.query('RESET ROLE');}});
 let second;await check('09_independent_second_tenant',async()=>{second=await provisionTenant(c,{...input,requestId:randomUUID(),tenantCode:'F2_'+nonce,email:'f2_'+nonce.toLowerCase()+'@example.invalid'},argon2,context);receipts.push(second);assert.notEqual(second.tenantId,first.tenantId);assert.notEqual(second.userId,first.userId);});
 await check('10_rehearsal_migration_recorded_once',async()=>{const rows=(await c.query('SELECT id FROM migration_control.ledger ORDER BY position')).rows;assert.deepEqual(rows.map(x=>x.id),['0001_recovered_schema_and_permissions','0002_tenant_provisioning','0003_self_session_management','0004_password_change']);});
 const pendingEmail='pending_'+nonce.toLowerCase()+'@example.invalid';
 pendingId=(await c.query("INSERT INTO app.users(email,full_name,status) VALUES($1,'Pending integration fixture','pending') RETURNING id",[pendingEmail])).rows[0].id;
 await c.query("INSERT INTO app.tenant_memberships(tenant_id,user_id,status) VALUES($1,$2,'invited')",[second.tenantId,pendingId]);
 const fixture={ownerEmail:input.email,ownerId:first.userId,tenantId:first.tenantId,membershipId:first.membershipId,otherTenantId:second.tenantId,pendingEmail,pendingId,unknownEmail:'unknown_'+nonce.toLowerCase()+'@example.invalid'};
 const entry=['dist/src/main.js','dist/main.js'].map(x=>join(project,x)).find(existsSync);if(!entry)throw Error('Built application entry not found');
 const out=openSync(join(report,'api.log'),'a'),err=openSync(join(report,'api-errors.log'),'a');const env={...process.env,NODE_ENV:'production',PORT:String(apiPort),DATABASE_URL:`postgresql://gympro_app@127.0.0.1:${port}/gympro_saas`,AUTH_DATABASE_URL:`postgresql://gympro_auth@127.0.0.1:${port}/gympro_saas`,SESSION_DATABASE_URL:`postgresql://gympro_session@127.0.0.1:${port}/gympro_saas`,GYMPRO_SESSION_MODE:'persistent'};
 for(const key of ['PGPASSWORD','GYMPRO_B8_DB_PASSWORD','GYMPRO_1F_PASSWORD','PGOPTIONS','PGSERVICE','PGSERVICEFILE'])delete env[key];
 env.GYMPRO_AUTH_TEST_FIXTURE=JSON.stringify(fixture);
 const unitEnv={...env,NODE_ENV:'test'};delete unitEnv.GYMPRO_DEV_SESSION_WRITES;delete unitEnv.GYMPRO_DEV_SESSION_CONFIRM;delete unitEnv.GYMPRO_SESSION_MODE;
 const suite=spawnSync(process.execPath,[join(project,'node_modules/vitest/vitest.mjs'),'run','--reporter=default','--reporter=json','--outputFile='+join(report,'full-suite-results.json')],{cwd:project,env:unitEnv,stdio:'inherit',windowsHide:true,timeout:180000});if(suite.error||suite.status!==0)throw Error('Full suite failed against isolated fixtures');
 const suiteResult=JSON.parse(readFileSync(join(report,'full-suite-results.json'),'utf8'));if(!suiteResult.success||suiteResult.numPendingTests!==0||suiteResult.numFailedTests!==0||suiteResult.numPassedTests<1567)throw Error('Full suite incomplete or skipped tests detected');
 for(const [label,extra] of [['missing-mode',{GYMPRO_SESSION_MODE:''}],['invalid-mode',{GYMPRO_SESSION_MODE:'invalid'}],['mixed-dev-flags',{GYMPRO_DEV_SESSION_WRITES:'enabled'}]]){
  const rejected=spawnSync(process.execPath,[entry],{cwd:project,env:{...env,...extra},encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:2000000});
  if(rejected.error||rejected.status===0||!String(rejected.stderr).includes('Production authentication requires'))throw Error('Production startup rejection not verified: '+label);
  console.log('PASS: Production startup rejects '+label);
 }
 const e2e=spawnSync(process.execPath,[join(project,'node_modules/vitest/vitest.mjs'),'run','--config','vitest.config.e2e.ts','--reporter=default','--reporter=json','--outputFile='+join(report,'root-e2e-results.json')],{cwd:project,env,stdio:'inherit',windowsHide:true,timeout:120000});if(e2e.error||e2e.status!==0)throw Error('Root e2e failed against isolated database');
 api=spawn(process.execPath,[entry],{cwd:project,env,stdio:['ignore',out,err],windowsHide:true});api.once('exit',()=>apiClosed=true);closeSync(out);closeSync(err);api.once('error',()=>{apiClosed=true;});
 let ready=false;for(let i=0;i<60;i++){if(apiClosed)throw Error('Isolated API stopped during startup; inspect api-errors.log');try{const r=await fetch(base+'/auth/me',{signal:AbortSignal.timeout(1000)});if(r.status===401){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,500));}if(!ready)throw Error('Isolated API readiness timeout');
 let token;
 await check('11_unauthenticated_identity_rejected',async()=>assert.equal((await call('/auth/me')).status,401));
 await check('12_wrong_password_rejected',async()=>assert.equal((await call('/auth/login','POST',{tenantId:first.tenantId,email:input.email,password:password+'wrong'})).status,401));
 await check('13_new_owner_login_and_identity',async()=>{const login=await call('/auth/login','POST',{tenantId:first.tenantId,email:input.email,password});assert.equal(login.status,200);token=login.data.accessToken;assert.equal(typeof token,'string');const me=await call('/auth/me','GET',undefined,token);assert.equal(me.status,200);assert.equal(me.data.tenantId,first.tenantId);assert.equal(me.data.membershipId,first.membershipId);});
 await check('14_cross_tenant_access_rejected',async()=>assert.equal((await call('/auth/tenants/'+second.tenantId+'/check','GET',undefined,token)).status,403));
 await check('15_owner_branch_member_lookup_allowed',async()=>{const result=await call(`/tenants/${first.tenantId}/branches/${first.branchId}/members/lookup?q=demo`,'GET',undefined,token);assert.equal(result.status,200);});
 await check('16_operator_assets_available',async()=>{const r=await fetch(base+'/operator');assert.equal(r.status,200);assert.ok((await r.text()).includes('password'));});
 await check('17_logout_revokes_session',async()=>{assert.equal((await call('/auth/logout','POST',undefined,token)).status,204);assert.equal((await call('/auth/me','GET',undefined,token)).status,401);token=undefined;});
 const newToken=async(receipt)=>{const {createHash,randomBytes}=await import('node:crypto');const raw=randomBytes(32).toString('base64url');const digest=createHash('sha256').update(raw).digest();
  const credential=(await c.query('SELECT u.password_hash FROM app.users u JOIN app.tenant_memberships m ON m.user_id=u.id WHERE m.id=$1',[receipt.membershipId])).rows[0].password_hash;await c.query('SET ROLE gympro_session');try{await c.query(`SELECT security.create_credential_bound_session($1,$2,$3)`,[receipt.membershipId,digest,credential]);}finally{await c.query('RESET ROLE');}return raw;};
 const otherToken=await newToken(first),foreignToken=await newToken(second);
 const ownHash=async(raw)=>(await import('node:crypto')).createHash('sha256').update(raw).digest();
 let listToken=otherToken, foreignSession;
 await check('S01_unauthenticated_list_denied',async()=>assert.equal((await call('/auth/sessions')).status,401));
 await check('S02_list_only_own_membership_and_public_fields',async()=>{
  const response=await call('/auth/sessions','GET',undefined,listToken);assert.equal(response.status,200);assert.ok(response.data.items.length>=1);assert.equal(response.data.items.filter(x=>x.current).length,1);for(const item of response.data.items)assert.deepEqual(Object.keys(item).sort(),['createdAt','current','expiresAt','sessionId']);
  foreignSession=(await c.query('SELECT id FROM security.tenant_sessions WHERE session_token_hash=$1',[await ownHash(foreignToken)])).rows[0].id;assert.ok(!response.data.items.some(x=>x.sessionId===foreignSession));
 });
 await check('S03_other_tenant_session_cannot_be_revoked',async()=>{const response=await call('/auth/sessions/'+foreignSession+'/revoke','POST',{},listToken);assert.equal(response.status,200);assert.equal(response.data.revokedCount,0);assert.equal((await call('/auth/me','GET',undefined,foreignToken)).status,200);});
 await check('S04_body_identity_and_malformed_target_rejected',async()=>{assert.equal((await call('/auth/sessions/revoke-others','POST',{tenantId:second.tenantId},listToken)).status,400);assert.equal((await call('/auth/sessions/bad/revoke','POST',{},listToken)).status,400);});
 const victim=await newToken(first);
 let victimId=(await c.query('SELECT id FROM security.tenant_sessions WHERE session_token_hash=$1',[await ownHash(victim)])).rows[0].id;
 await check('S05_specific_session_revoked_and_retry_safe',async()=>{const path='/auth/sessions/'+victimId+'/revoke';assert.equal((await call(path,'POST',{},listToken)).data.revokedCount,1);assert.equal((await call(path,'POST',{},listToken)).data.revokedCount,0);assert.equal((await call('/auth/me','GET',undefined,victim)).status,401);});
 const extraToken=await newToken(first);
 await check('S06_revoke_others_preserves_current',async()=>{const response=await call('/auth/sessions/revoke-others','POST',{},listToken);assert.equal(response.status,200);assert.ok(response.data.revokedCount>=1);assert.equal((await call('/auth/me','GET',undefined,extraToken)).status,401);assert.equal((await call('/auth/me','GET',undefined,listToken)).status,200);});
 await check('S07_current_session_revocation_signs_out',async()=>{const list=await call('/auth/sessions','GET',undefined,listToken);const current=list.data.items.find(x=>x.current);const response=await call('/auth/sessions/'+current.sessionId+'/revoke','POST',{},listToken);assert.equal(response.data.currentRevoked,true);assert.equal((await call('/auth/sessions','GET',undefined,listToken)).status,401);});
 await check('S08_unknown_hash_rejected_by_database',async()=>{await c.query('SET ROLE gympro_auth');try{await assert.rejects(()=>c.query("SELECT security.manage_own_sessions($1,'list',NULL)",[Buffer.alloc(32,0)]),e=>e.code==='28000');}finally{await c.query('RESET ROLE');}});
 await check('S09_runtime_direct_access_and_execution_denied',async()=>{await c.query('SET ROLE gympro_app');try{await assert.rejects(()=>c.query('SELECT id FROM security.tenant_sessions'),e=>e.code==='42501');await assert.rejects(()=>c.query("SELECT security.manage_own_sessions($1,'list',NULL)",[Buffer.alloc(32)]),e=>e.code==='42501');}finally{await c.query('RESET ROLE');}});
 await check('S10_account_UI_assets_available',async()=>{for(const path of ['/account/sessions','/account/sessions/app.js','/account/sessions/style.css'])assert.equal((await fetch(base+path)).status,200);});
 const sameTenantMembership=(await c.query("INSERT INTO app.tenant_memberships(tenant_id,user_id,status,joined_at) VALUES($1,$2,'active',clock_timestamp()) RETURNING id",[first.tenantId,second.userId])).rows[0].id;
 const sameTenantToken=await newToken({membershipId:sameTenantMembership});
 const sameTenantId=(await c.query('SELECT id FROM security.tenant_sessions WHERE session_token_hash=$1',[await ownHash(sameTenantToken)])).rows[0].id;
 const caller=await newToken(first);
 await check('S11_other_user_in_same_tenant_is_protected',async()=>{
  const list=await call('/auth/sessions','GET',undefined,caller);assert.ok(!list.data.items.some(x=>x.sessionId===sameTenantId));const revoke=await call('/auth/sessions/'+sameTenantId+'/revoke','POST',{},caller);assert.equal(revoke.data.revokedCount,0);assert.equal((await call('/auth/me','GET',undefined,sameTenantToken)).status,200);
 });
 const expired=await newToken(first);const expiredHash=await ownHash(expired);
 await c.query("UPDATE security.tenant_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE session_token_hash=$1",[expiredHash]);
 await check('S12_expired_session_cannot_manage_sessions',async()=>{
  assert.equal((await call('/auth/sessions','GET',undefined,expired)).status,401);await c.query('SET ROLE gympro_auth');try{await assert.rejects(()=>c.query("SELECT security.manage_own_sessions($1,'revoke_others',NULL)",[expiredHash]),e=>e.code==='28000');}finally{await c.query('RESET ROLE');}
 });
 const sessionCountBefore=(await c.query('SELECT count(*)::int n FROM security.tenant_sessions')).rows[0].n;
 const abuseEmail='abuse_'+nonce.toLowerCase()+'@example.invalid';
 const badLogin=async(email,headers={})=>{const response=await fetch(base+'/auth/login',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify({tenantId:first.tenantId,email,password:'wrong-password'}),signal:AbortSignal.timeout(10000)});return response;};
 await check('18_login_budget_and_forwarding_spoof_rejection',async()=>{
  for(let i=0;i<5;i++)assert.equal((await badLogin(abuseEmail)).status,401);
  const rejected=await badLogin(abuseEmail,{'X-Forwarded-For':'198.51.100.1'});assert.equal(rejected.status,429);const retry=Number(rejected.headers.get('retry-after'));assert.ok(retry>=1&&retry<=60);
 });
 await check('19_concurrent_login_budget_enforced',async()=>{
  const responses=await Promise.all(Array.from({length:8},()=>badLogin('parallel_'+nonce.toLowerCase()+'@example.invalid')));
  assert.equal(responses.filter(x=>x.status===401).length,5);assert.equal(responses.filter(x=>x.status===429).length,3);
 });
 await check('20_peer_budget_blocks_identity_rotation',async()=>{
  for(let i=0;i<3;i++)assert.equal((await badLogin('rotate'+i+'_'+nonce.toLowerCase()+'@example.invalid')).status,401);
  assert.equal((await badLogin('rotate4_'+nonce.toLowerCase()+'@example.invalid',{'X-Forwarded-For':'203.0.113.77'})).status,429);
 });
 await check('21_rejections_create_no_sessions',async()=>assert.equal((await c.query('SELECT count(*)::int n FROM security.tenant_sessions')).rows[0].n,sessionCountBefore));
 // Restart only our isolated API to reset the intentionally exhausted login-test budget.
 if(!apiClosed){const exited=once(api,'exit');api.kill();await exited;}apiClosed=false;
 const newOut=openSync(join(report,'password-api.log'),'a'),newErr=openSync(join(report,'password-api-errors.log'),'a');api=spawn(process.execPath,[entry],{cwd:project,env,stdio:['ignore',newOut,newErr],windowsHide:true});api.once('exit',()=>apiClosed=true);api.once('error',()=>apiClosed=true);closeSync(newOut);closeSync(newErr);
 let passwordReady=false;for(let i=0;i<60;i++){if(apiClosed)throw Error('Password test API startup failed');try{if((await fetch(base+'/auth/me',{signal:AbortSignal.timeout(1000)})).status===401){passwordReady=true;break;}}catch{}await new Promise(r=>setTimeout(r,500));}if(!passwordReady)throw Error('Password test API not ready');
 const passwordToken=await newToken(first),oldCredential=(await c.query('SELECT password_hash FROM app.users WHERE id=$1',[first.userId])).rows[0].password_hash;
 const crossMembership=(await c.query("INSERT INTO app.tenant_memberships(tenant_id,user_id,status,joined_at) VALUES($1,$2,'active',clock_timestamp()) RETURNING id",[second.tenantId,first.userId])).rows[0].id;
 const crossToken=await newToken({membershipId:crossMembership});const nextPassword=password+'-changed';const changeBody={currentPassword:password,newPassword:nextPassword,confirmPassword:nextPassword};
 await check('P01_unauthenticated_change_rejected',async()=>assert.equal((await call('/auth/password/change','POST',changeBody)).status,401));
 await check('P02_client_identity_rejected',async()=>assert.equal((await call('/auth/password/change','POST',{...changeBody,userId:second.userId},passwordToken)).status,400));
 await check('P03_wrong_current_password_rejected',async()=>assert.equal((await call('/auth/password/change','POST',{...changeBody,currentPassword:'wrong'},passwordToken)).status,401));
 await check('P04_rejections_preserve_hash_and_sessions',async()=>{assert.equal((await c.query('SELECT password_hash FROM app.users WHERE id=$1',[first.userId])).rows[0].password_hash===oldCredential,true);assert.equal((await call('/auth/me','GET',undefined,passwordToken)).status,200);assert.equal((await call('/auth/me','GET',undefined,crossToken)).status,200);});
 await check('P05_password_reuse_rejected',async()=>assert.equal((await call('/auth/password/change','POST',{currentPassword:password,newPassword:password,confirmPassword:password},passwordToken)).status,400));
 await check('P06_atomic_password_change_and_public_receipt',async()=>{const result=await call('/auth/password/change','POST',changeBody,passwordToken);assert.equal(result.status,200);assert.deepEqual(Object.keys(result.data).sort(),['changed','revokedCount','signedOut']);assert.equal(result.data.changed,true);assert.ok(result.data.revokedCount>=2);});
 await check('P07_all_tenant_sessions_revoked',async()=>{for(const raw of [passwordToken,crossToken])assert.equal((await call('/auth/me','GET',undefined,raw)).status,401);assert.equal((await c.query('SELECT count(*)::int n FROM security.tenant_sessions s JOIN app.tenant_memberships m ON m.id=s.membership_id AND m.tenant_id=s.tenant_id WHERE m.user_id=$1 AND s.revoked_at IS NULL',[first.userId])).rows[0].n,0);});
 await check('P08_old_password_login_rejected',async()=>assert.equal((await call('/auth/login','POST',{tenantId:first.tenantId,email:input.email,password})).status,401));
 let freshToken,newCredential;
 await check('P09_new_password_login_and_argon2id',async()=>{const login=await call('/auth/login','POST',{tenantId:first.tenantId,email:input.email,password:nextPassword});assert.equal(login.status,200);freshToken=login.data.accessToken;newCredential=(await c.query('SELECT password_hash FROM app.users WHERE id=$1',[first.userId])).rows[0].password_hash;assert.ok(await argon2.verify(newCredential,nextPassword));assert.equal((await call('/auth/me','GET',undefined,freshToken)).status,200);});
 await check('P10_revoked_change_request_cannot_replay',async()=>assert.equal((await call('/auth/password/change','POST',changeBody,passwordToken)).status,401));
 await check('P11_stale_credential_and_unbound_issuance_denied',async()=>{await c.query('SET ROLE gympro_session');try{await assert.rejects(()=>c.query('SELECT security.create_credential_bound_session($1,$2,$3)',[first.membershipId,Buffer.alloc(32,9),oldCredential]),e=>e.code==='28000');await assert.rejects(()=>c.query('SELECT security.create_tenant_session($1,$2)',[first.membershipId,Buffer.alloc(32,10)]),e=>e.code==='42501');}finally{await c.query('RESET ROLE');}});
 await check('P12_concurrent_change_blocks_stale_issuance',async()=>{
  const locker=await connect('gympro_saas'),issuer=await connect('gympro_saas');clients.push(locker,issuer);const nextHash=await argon2.hash(nextPassword+'-second',{type:argon2.argon2id,memoryCost:19456,timeCost:2,parallelism:1,hashLength:32});
  const pid=(await issuer.query('SELECT pg_backend_pid() pid')).rows[0].pid;await locker.query('BEGIN');let committed=false;
  try{await locker.query('SELECT id FROM app.users WHERE id=$1 FOR UPDATE',[first.userId]);await locker.query('SELECT security.change_own_password($1,$2,$3)',[await ownHash(freshToken),newCredential,nextHash]);await issuer.query('SET ROLE gympro_session');
   const attempt=issuer.query('SELECT security.create_credential_bound_session($1,$2,$3)',[first.membershipId,Buffer.alloc(32,11),newCredential]).then(()=>({code:'unexpected-success'}),e=>({code:e.code}));
   let waiting=false;for(let i=0;i<60;i++){const state=(await c.query('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1',[pid])).rows[0];if(state?.wait_event_type==='Lock'){waiting=true;break;}await new Promise(r=>setTimeout(r,50));}
   await locker.query('COMMIT');committed=true;const outcome=await attempt;assert.equal(waiting,true);assert.equal(outcome.code,'28000');assert.equal((await call('/auth/me','GET',undefined,freshToken)).status,401);
  }finally{if(!committed)await locker.query('ROLLBACK');await issuer.query('RESET ROLE');}
 });
 await check('P13_other_accounts_unchanged',async()=>assert.equal((await call('/auth/me','GET',undefined,foreignToken)).status,200));

 // Reset only this runner's API so earlier rate-limit tests do not affect manual acceptance.
 if(!apiClosed){const done=once(api,'exit');api.kill();await Promise.race([done,new Promise(r=>setTimeout(r,5000))]);if(!apiClosed)throw Error('Owned API did not stop before browser phase');}
 apiClosed=false;const freshOut=openSync(join(report,'browser-api.log'),'a'),freshErr=openSync(join(report,'browser-api-errors.log'),'a');
 api=spawn(process.execPath,[entry],{cwd:project,env,stdio:['ignore',freshOut,freshErr],windowsHide:true});api.once('exit',()=>apiClosed=true);api.once('error',()=>apiClosed=true);closeSync(freshOut);closeSync(freshErr);
 let browserReady=false;for(let n=0;n<60;n++){if(apiClosed)throw Error('Fresh API stopped');try{if((await fetch(base+'/auth/me',{signal:AbortSignal.timeout(1000)})).status===401){browserReady=true;break;}}catch{}await new Promise(r=>setTimeout(r,500));}if(!browserReady)throw Error('Fresh API readiness timeout');
 const browser=await provisionTenant(c,{...input,requestId:randomUUID(),tenantCode:'CLEAN_'+nonce,email:'clean_'+nonce.toLowerCase()+'@example.invalid'},argon2,context);receipts.push(browser);
 writeFileSync(join(report,'browser-context.json'),JSON.stringify({tenantId:browser.tenantId,branchId:browser.branchId,email:browser.email,url:base+'/operator'},null,2));
 if(process.env.GYMPRO_FRESH_NO_BROWSER==='1')console.log('Browser phase skipped by explicit -NoBrowser; manual acceptance remains pending.');
 else{
  console.log('\nBROWSER TEST: '+base+'/operator\nTenant ID: '+browser.tenantId+'\nBranch ID: '+browser.branchId+'\nEmail: '+browser.email+'\nPassword: use the temporary rehearsal password you chose.\nFirst action: sign in only and report the result. Keep this terminal open.');
  const reader=createInterface({input:process.stdin,output:process.stdout});try{await reader.question('Press Enter ONLY after browser checks to remove fixtures and stop: ',{signal:abort.signal});}finally{reader.close();}
 }
 automaticPassed=true;
 console.log('PASS: Fresh-install automated checks and selected browser phase completed.');

}catch(error){console.error('FAIL: 1F verification stopped. SQLSTATE:',error.code||'none','Reason:',error.message);process.exitCode=1;}finally{
 if(api&&!apiClosed){const closed=once(api,'exit');api.kill();await Promise.race([closed,new Promise(r=>setTimeout(r,5000))]);if(!apiClosed){console.error('FAIL: Own isolated API did not stop');process.exitCode=1;}}
 if(c&&context){try{for(const receipt of receipts)await c.query('DELETE FROM security.tenant_sessions WHERE tenant_id=$1',[receipt.tenantId]);for(const owner of receipts)for(const tenant of receipts)if(owner.tenantId!==tenant.tenantId)await c.query('DELETE FROM app.tenant_memberships WHERE tenant_id=$1 AND user_id=$2',[tenant.tenantId,owner.userId]);for(const receipt of [...receipts].reverse())await removeFixture(c,receipt,context);if(pendingId){await c.query('DELETE FROM app.users WHERE id=$1',[pendingId]);assert.equal((await c.query('SELECT count(*)::int n FROM app.users WHERE id=$1',[pendingId])).rows[0].n,0);}clean=true;console.log('PASS: Isolated tenant/admin fixtures and sessions removed.');}catch(error){console.error('FAIL: Fixture cleanup failed; retain stopped-cluster files for diagnosis. SQLSTATE:',error.code||'none');process.exitCode=1;}}
 await Promise.all(clients.map(client=>client.end()));
 const summary={step:'Fresh committed-source installation rehearsal',automaticChecksPassed:automaticPassed,automaticCheckCount:checks.length,checks,fixtureCleanupPassed:clean,ownApiStopped:!api||apiClosed,manualBrowserAcceptance:'pending-user-confirmation',workingDatabaseChanged:false,productionAuthenticationChanged:false,kbzPayDeferred:true};writeFileSync(join(report,'provisioning-results.json'),JSON.stringify(summary,null,2));
 if(stopRequested)process.exitCode=1;
}
