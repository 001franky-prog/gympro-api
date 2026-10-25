import {createRequire} from 'node:module';
import {join,resolve} from 'node:path';
import {readFileSync,writeFileSync,existsSync,mkdirSync,renameSync,openSync,closeSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createInterface} from 'node:readline/promises';
import assert from 'node:assert/strict';
const [rootArg,reportArg,candidateArg,previousArg,candidateCommit]=process.argv.slice(2);
const root=resolve(rootArg),report=resolve(reportArg),candidate=resolve(candidateArg),previous=resolve(previousArg),source=join(root,'source');
assert.equal(root.toLowerCase(),'c:\\projects\\gympro-staging');
assert.match(candidateCommit,/^[a-f0-9]{40}$/);
for(const path of [candidate,previous,report])assert.ok(path.toLowerCase().startsWith((root+'\\').toLowerCase()),'Release paths must remain in the identified staging folder');
assert.ok(existsSync(source)&&existsSync(candidate)&&!existsSync(previous));
const meta=JSON.parse(readFileSync(join(root,'installation.json'),'utf8'));
const owner=JSON.parse(readFileSync(join(root,'owner.json'),'utf8'));
assert.equal(meta.databasePort,55440);assert.equal(meta.apiPort,3200);
const inputs=JSON.parse(readFileSync(join(report,'tracked-inputs.json'),'utf8').replace(/^\uFEFF/,''));
const {Client}=createRequire(join(source,'package.json'))('pg');
const password={admin:process.env.GYMPRO_RELEASE_ADMIN,app:process.env.GYMPRO_RELEASE_APP,auth:process.env.GYMPRO_RELEASE_AUTH,session:process.env.GYMPRO_RELEASE_SESSION};
for(const value of Object.values(password))assert.match(value||'',/^[a-f0-9]{64}$/);
const noBrowser=process.env.GYMPRO_RELEASE_NO_BROWSER==='1';
for(const key of Object.keys(process.env))if(key.startsWith('GYMPRO_RELEASE_'))delete process.env[key];
// // normally absent; interactive acceptance is the default
const base='http://127.0.0.1:3200';
let c,api,originalParked=false,passed=false,rollbackDone=false,candidateReady=false,originalReady=false;
let candidatePause=false,rollbackPause=false;let abortRequested=false;
const abort=new AbortController();
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>{abortRequested=true;abort.abort();});
const checks=[];
async function check(name,fn){if(abortRequested)throw Error('Release rehearsal cancelled');await fn();checks.push({name,result:'PASS'});console.log('PASS: '+name);}
const sha=path=>createHash('sha256').update(readFileSync(path)).digest('hex');
function verifyInputs(path){for(const entry of inputs)assert.equal(sha(join(path,entry.file)),entry.sha256,'Tracked application input changed: '+entry.file);}
function state(phase){writeFileSync(join(report,'release-state.json'),JSON.stringify({phase,originalSourceCommit:meta.sourceCommit,candidateCommit,source,candidate,previous,originalParked,apiPid:api?.pid||null},null,2)+'\n');}
function apiEnv(){
 const env={...process.env};
 for(const key of Object.keys(env))if(/^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_ENV$|NODE_OPTIONS$|PORT$)/.test(key))delete env[key];
 Object.assign(env,{NODE_ENV:'production',GYMPRO_SESSION_MODE:'persistent',PORT:'3200',PGSSLMODE:'disable',DATABASE_URL:`postgresql://gympro_app:${password.app}@127.0.0.1:55440/gympro_saas`,AUTH_DATABASE_URL:`postgresql://gympro_auth:${password.auth}@127.0.0.1:55440/gympro_saas`,SESSION_DATABASE_URL:`postgresql://gympro_session:${password.session}@127.0.0.1:55440/gympro_saas`});
 return env;
}
async function stopApi(){
 if(!api)return;
 if(api.exitCode===null&&api.signalCode===null){
  const done=once(api,'exit');api.kill();await Promise.race([done,new Promise(r=>setTimeout(r,10000))]);
  if(api.exitCode===null&&api.signalCode===null)throw Error('Owned API did not stop; retain release paths for diagnosis');
 }
 api=null;
}
async function startApi(path,label){
 await stopApi();verifyInputs(path);
 const entry=['dist/src/main.js','dist/main.js'].map(f=>join(path,f)).find(existsSync);assert.ok(entry,'Built release entry missing');
 const out=openSync(join(report,label+'-api.log'),'a'),err=openSync(join(report,label+'-api-errors.log'),'a');
 api=spawn(process.execPath,[entry],{cwd:path,env:apiEnv(),stdio:['ignore',out,err],windowsHide:true});closeSync(out);closeSync(err);
 let failed=false;api.once('error',()=>{failed=true;});
 let ready=false;
 for(let i=0;i<60;i++){
  if(failed||api.exitCode!==null||api.signalCode!==null)throw Error(label+' API stopped during startup; inspect its private error log');
  try{if((await fetch(base+'/auth/me',{signal:AbortSignal.timeout(1000)})).status===401){ready=true;break;}}catch{}
  await new Promise(r=>setTimeout(r,500));
 }
 assert.ok(ready,label+' API readiness timeout');
 for(const route of ['/operator','/operator/app.js','/operator/style.css','/account/sessions'])assert.equal((await fetch(base+route,{signal:AbortSignal.timeout(5000)})).status,200,'Public staging asset: '+route);
 state(label+'-api-ready');
}
async function pause(label,commit){
 console.log(`\n${label}: ${base}/operator\nRelease commit: ${commit}\nTenant ID: ${owner.tenantId}\nBranch ID: ${owner.branchId}\nEmail: ${owner.email}\nPassword: use your existing staging-owner password.\nFirst action: sign in only and report the result. Keep this terminal open.\nThis rehearsal permits sign-in, viewing the attendance summary, and sign-out only.`);
 if(noBrowser){console.log('Browser pause explicitly skipped; no manual acceptance claimed.');return false;}
 const reader=createInterface({input:process.stdin,output:process.stdout});
 try{await reader.question('Press Enter ONLY after this browser phase is signed out and the assistant asks you to continue: ',{signal:abort.signal});}finally{reader.close();}
 return true;
}
function restoreOriginal(){
 if(!originalParked)return;
 if(existsSync(source)){
  assert.ok(!existsSync(candidate),'Candidate retention path unexpectedly occupied');
  renameSync(source,candidate);
 }
 assert.ok(existsSync(previous),'Original release folder is missing');
 renameSync(previous,source);originalParked=false;rollbackDone=true;verifyInputs(source);state('original-restored');
}
let expandDefaults=true;
function aclSource(x){
 if(!expandDefaults)return x;
 const defaults={
  nspacl:"COALESCE(nspacl,acldefault('n',nspowner))",
  datacl:"COALESCE(datacl,acldefault('d',datdba))",
  'c.relacl':`COALESCE(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner))`,
  'p.proacl':"COALESCE(p.proacl,acldefault('f',p.proowner))"
 };
 return defaults[x]||x;
}
const acl=x=>`COALESCE((SELECT jsonb_agg(jsonb_build_array(pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type) FROM aclexplode(CASE WHEN cardinality(${aclSource(x)})=0 THEN NULL::aclitem[] ELSE ${aclSource(x)} END) a),'[]'::jsonb)`;
async function catalog(c){
 const queries={
  database:`SELECT pg_get_userbyid(datdba) owner,encoding,datlocprovider,datcollate,datctype,datconnlimit,datallowconn,${acl('datacl')} acl FROM pg_database WHERE datname=current_database()`,
  extensions:`SELECT e.extname,e.extversion,n.nspname,pg_get_userbyid(e.extowner) owner FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace ORDER BY 1`,
  defaultPrivileges:`SELECT pg_get_userbyid(d.defaclrole) role,coalesce(n.nspname,'') schema,d.defaclobjtype,${acl('d.defaclacl')} acl FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE d.defaclnamespace=0 OR n.nspname IN ('app','platform','security','migration_control') ORDER BY 1,2,3`,
  views:`SELECT n.nspname,c.relname,c.relkind,pg_get_userbyid(c.relowner) owner,pg_get_viewdef(c.oid,true) definition,${acl('c.relacl')} acl FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') AND c.relkind IN ('v','m') ORDER BY 1,2`,
  permissionSeeds:"SELECT id::text,module_code,resource_code,action_code,description,is_active FROM app.permissions ORDER BY id",
  schemas:`SELECT nspname,pg_get_userbyid(nspowner) owner,${acl('nspacl')} acl FROM pg_namespace WHERE nspname IN ('app','platform','security','migration_control') ORDER BY nspname`,
  tables:`SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner) owner,c.relrowsecurity,c.relforcerowsecurity,${acl('c.relacl')} acl FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') AND c.relkind='r' ORDER BY 1,2`,
  columns:`SELECT n.nspname,c.relname,a.attname,a.attnum,format_type(a.atttypid,a.atttypmod) type,a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid) default_expr,${acl('a.attacl')} acl FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname IN ('app','platform','security','migration_control') AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped ORDER BY 1,2,4`,
  constraints:`SELECT n.nspname,c.relname,k.conname,pg_get_constraintdef(k.oid) definition,k.convalidated FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') ORDER BY 1,2,3`,
  indexes:`SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes WHERE schemaname IN ('app','platform','security','migration_control') ORDER BY 1,2,3`,
  policies:`SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname IN ('app','platform','security','migration_control') ORDER BY 1,2,3`,
  functions:`SELECT p.oid::regprocedure::text identity,pg_get_userbyid(p.proowner) owner,p.prosecdef,p.provolatile,p.proparallel,p.proconfig,pg_get_functiondef(p.oid) definition,${acl('p.proacl')} acl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('app','platform','security','migration_control') ORDER BY 1`,
  triggers:`SELECT n.nspname,c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) definition FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname IN ('app','platform','security','migration_control') ORDER BY 1,2,3`,
  sequences:`SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner) owner,s.seqstart::text,s.seqincrement::text,s.seqmax::text,s.seqmin::text,s.seqcache::text,s.seqcycle,${acl('c.relacl')} acl FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') ORDER BY 1,2`
 };const result={};for(const [name,sql] of Object.entries(queries))result[name]=(await c.query(sql)).rows;return result;
}
function compare(actual,expected){const differences=[];for(const key of Object.keys(expected))if(JSON.stringify(actual[key])!==JSON.stringify(expected[key]))differences.push(key);if(differences.length)throw Error('Schema/security drift in: '+differences.join(', '));}
async function fingerprints(c){const tables=(await c.query("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') AND c.relkind='r' ORDER BY 1,2")).rows;const out=[];for(const t of tables){if(t.nspname==='security'&&t.relname==='tenant_sessions')continue;const id='"'+t.nspname.replaceAll('"','""')+'"."'+t.relname.replaceAll('"','""')+'"';const {rows:[r]}=await c.query(`SELECT count(*)::text count,encode(sha256(convert_to(coalesce(string_agg(h,'' ORDER BY h),''),'UTF8')),'hex') fingerprint FROM (SELECT encode(sha256(convert_to(to_jsonb(x)::text,'UTF8')),'hex') h FROM ${id} x) q`);out.push({table:t.nspname+'.'+t.relname,...r});}const seq=[];for(const s of (await c.query("SELECT schemaname,sequencename FROM pg_sequences WHERE schemaname IN ('app','platform','security','migration_control') ORDER BY 1,2")).rows){const id='"'+s.schemaname.replaceAll('"','""')+'"."'+s.sequencename.replaceAll('"','""')+'"';seq.push({sequence:s.schemaname+'.'+s.sequencename,...(await c.query(`SELECT last_value::text,is_called FROM ${id}`)).rows[0]});}return {tables:out,sequences:seq};}


async function snapshot(){
 await c.query('BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ');
 try{return {catalog:await catalog(c),content:await fingerprints(c)};}finally{await c.query('ROLLBACK');}
}
async function sessionRows(){return (await c.query("SELECT s.id,s.tenant_id,s.membership_id,s.revoked_at IS NOT NULL revoked,encode(sha256(convert_to(to_jsonb(s)::text,'UTF8')),'hex') fingerprint FROM security.tenant_sessions s ORDER BY s.id")).rows;}
let before,sessionsBefore,membershipId;
try{
 verifyInputs(source);verifyInputs(candidate);
 c=new Client({host:'127.0.0.1',port:55440,user:'postgres',password:password.admin,database:'gympro_saas',ssl:false,connectionTimeoutMillis:5000,application_name:'gympro-controlled-staging-release'});
 await c.connect();await c.query("SET statement_timeout='60s';SET lock_timeout='5s';SET search_path=pg_catalog;SET TIME ZONE 'UTC'");
 const identity=(await c.query('SELECT (pg_control_system()).system_identifier::text id,inet_server_port() port')).rows[0];
 assert.equal(identity.id,meta.systemIdentifier);assert.equal(identity.port,55440);
 assert.equal((await c.query("SELECT count(*)::int n FROM pg_stat_activity WHERE datname='gympro_saas' AND pid<>pg_backend_pid() AND backend_type='client backend'")).rows[0].n,0,'Other staging clients are connected');
 membershipId=(await c.query('SELECT m.id FROM app.tenant_memberships m JOIN app.users u ON u.id=m.user_id WHERE m.tenant_id=$1 AND lower(u.email)=lower($2)',[owner.tenantId,owner.email])).rows[0]?.id;assert.ok(membershipId);
 before=await snapshot();sessionsBefore=await sessionRows();
 writeFileSync(join(report,'business-before.json'),JSON.stringify(before,null,2)+'\n');
 await check('01_candidate_build_passive_startup',async()=>{await startApi(candidate,'candidate-preflight');candidateReady=true;await stopApi();});
 await check('02_controlled_source_switch',async()=>{
  state('before-switch');renameSync(source,previous);originalParked=true;state('original-parked');renameSync(candidate,source);state('candidate-active');verifyInputs(source);
 });
 await check('03_candidate_active_passive_startup',()=>startApi(source,'candidate-active'));
 candidatePause=await pause('CANDIDATE BROWSER TEST',candidateCommit);
 await stopApi();
 await check('04_candidate_preserves_business_schema_and_records',async()=>{const after=await snapshot();compare(after.catalog,before.catalog);assert.deepEqual(after.content,before.content);});
 await check('05_controlled_rollback_to_original',async()=>restoreOriginal());
 await check('06_original_release_passive_startup',async()=>{await startApi(source,'rollback-original');originalReady=true;});
 rollbackPause=await pause('ROLLED-BACK ORIGINAL BROWSER TEST',meta.sourceCommit);
 await stopApi();
 await check('07_rollback_preserves_business_schema_and_records',async()=>{const after=await snapshot();compare(after.catalog,before.catalog);assert.deepEqual(after.content,before.content);writeFileSync(join(report,'business-after.json'),JSON.stringify(after,null,2)+'\n');});
 await check('08_existing_sessions_preserved_new_sessions_scoped_and_revoked',async()=>{
  const after=await sessionRows(),old=new Map(sessionsBefore.map(s=>[s.id,s]));
  const observed=new Map(after.map(s=>[s.id,s]));
  for(const [id,row] of old)assert.deepEqual(observed.get(id),row,'A pre-existing session changed');
  const added=after.filter(s=>!old.has(s.id));
  for(const row of added){assert.equal(row.tenant_id,owner.tenantId);assert.equal(row.membership_id,membershipId);assert.equal(row.revoked,true,'Sign out of the browser before continuing');}
  writeFileSync(join(report,'session-check.json'),JSON.stringify({existingSessionRowsUnchanged:true,newSessions:added.length,newSessionsScopedToStagingOwner:true,newSessionsRevoked:true},null,2)+'\n');
 });
 verifyInputs(source);assert.ok(!existsSync(previous));assert.ok(existsSync(candidate));passed=true;
}catch(error){console.error('FAIL: Controlled release rehearsal:',error.message);process.exitCode=1;}finally{
 let safeToRestore=true;
 try{await stopApi();}catch(e){safeToRestore=false;console.error('FAIL:',e.message);process.exitCode=1;}
 if(safeToRestore)try{restoreOriginal();}catch(e){console.error('FAIL: Original release restoration requires review:',e.message);process.exitCode=1;}
 if(c)await c.end();
 for(const key of Object.keys(password))password[key]=null;
 state(passed?'completed-original-restored':'failed-retain-for-diagnosis');
 const summary={scope:'Application-only staging version switch and rollback rehearsal',candidateCommit,originalSourceCommit:meta.sourceCommit,candidateReady,originalReady,rollbackDone,originalSourceRestored:!originalParked&&existsSync(source),automaticChecksPassed:passed,automaticCheckCount:checks.length,checks,candidateBrowserPauseCompleted:candidatePause,rollbackBrowserPauseCompleted:rollbackPause,manualBrowserAcceptance:'pending-user-confirmation',businessSnapshotExcludesOnlyTenantSessionRows:true,stagingApiStopped:!api,permissionsChanged:false,databaseMigrationsApplied:false,workingDatabaseUsed:false,candidateRetainedAt:candidate,kbzPayDeferred:true};
 writeFileSync(join(report,'release-summary.json'),JSON.stringify(summary,null,2)+'\n');
 if(!passed||originalParked)process.exitCode=1;
}
