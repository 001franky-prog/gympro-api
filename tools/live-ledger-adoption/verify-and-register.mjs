import {compareReviewed} from './reviewed-equivalence.mjs';
import {createRequire} from 'node:module';import {resolve,join} from 'node:path';import {readFileSync,writeFileSync} from 'node:fs';import {createHash,randomUUID} from 'node:crypto';import {pathToFileURL} from 'node:url';import assert from 'node:assert/strict';
const [projectArg,target,reference,report,mode]=process.argv.slice(2),project=resolve(projectArg);
if(!((mode==='live'&&target==='gympro_saas')||(mode==='rehearsal'&&/^gympro_adopt_\d{14}_[a-f0-9]{6}$/.test(target)))||!/^gympro_bootstrap_\d{14}_[a-f0-9]{6}$/.test(reference))throw Error('Invalid live adoption arguments');
const {Client}=createRequire(join(project,'package.json'))('pg');
const {prepare}=await import(pathToFileURL(join(project,'tools/migrations/migrate.mjs')).href);
const manifest=JSON.parse(readFileSync(join(project,'sql/migrations/manifest.json'),'utf8').replace(/^\uFEFF/,'')),plan=prepare(project,manifest);
assert.deepEqual(plan.migrations.map(m=>m.id),['0002_tenant_provisioning','0003_self_session_management','0004_password_change']);
const expectedHistory=[plan.baseline,...plan.migrations].map(({position,id,sha256})=>({position,id,sha256}));
const digest=v=>createHash('sha256').update(JSON.stringify(v)).digest('hex');
const clients=[];const connect=async(db)=>{const c=new Client({host:'127.0.0.1',port:5432,database:db,user:'postgres',ssl:false,connectionTimeoutMillis:5000,application_name:'gympro-controlled-ledger-adoption'});await c.connect();await c.query("SET statement_timeout='60s';SET lock_timeout='5s';SET search_path=pg_catalog");clients.push(c);return c;};
const checks=[];const check=async(name,fn)=>{try{await fn();checks.push({name,result:'PASS'});console.log('PASS: '+name);}catch(e){e.message=name+': '+e.message;throw e;}};
const acl=x=>`COALESCE((SELECT jsonb_agg(jsonb_build_array(pg_get_userbyid(a.grantor),CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,a.privilege_type,a.is_grantable) ORDER BY a.grantor::regrole::text,a.grantee::regrole::text,a.privilege_type) FROM aclexplode(${x}) a),'[]'::jsonb)`;
async function catalog(c){
 const queries={
  permissionSeeds:"SELECT id::text,module_code,resource_code,action_code,description,is_active FROM app.permissions ORDER BY id",
  schemas:`SELECT nspname,pg_get_userbyid(nspowner) owner,${acl('nspacl')} acl FROM pg_namespace WHERE nspname IN ('app','platform','security') ORDER BY nspname`,
  tables:`SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner) owner,c.relrowsecurity,c.relforcerowsecurity,${acl('c.relacl')} acl FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') AND c.relkind='r' ORDER BY 1,2`,
  columns:`SELECT n.nspname,c.relname,a.attname,a.attnum,format_type(a.atttypid,a.atttypmod) type,a.attnotnull,a.attidentity,a.attgenerated,pg_get_expr(d.adbin,d.adrelid) default_expr,${acl('a.attacl')} acl FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum WHERE n.nspname IN ('app','platform','security') AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped ORDER BY 1,2,4`,
  constraints:`SELECT n.nspname,c.relname,k.conname,pg_get_constraintdef(k.oid) definition,k.convalidated FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') ORDER BY 1,2,3`,
  indexes:`SELECT schemaname,tablename,indexname,indexdef FROM pg_indexes WHERE schemaname IN ('app','platform','security') ORDER BY 1,2,3`,
  policies:`SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname IN ('app','platform','security') ORDER BY 1,2,3`,
  functions:`SELECT p.oid::regprocedure::text identity,pg_get_userbyid(p.proowner) owner,p.prosecdef,p.provolatile,p.proparallel,p.proconfig,pg_get_functiondef(p.oid) definition,${acl('p.proacl')} acl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('app','platform','security') ORDER BY 1`,
  triggers:`SELECT n.nspname,c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) definition FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname IN ('app','platform','security') ORDER BY 1,2,3`,
  sequences:`SELECT n.nspname,c.relname,pg_get_userbyid(c.relowner) owner,s.seqstart::text,s.seqincrement::text,s.seqmax::text,s.seqmin::text,s.seqcache::text,s.seqcycle,${acl('c.relacl')} acl FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') ORDER BY 1,2`
 };const result={};for(const [name,sql] of Object.entries(queries))result[name]=(await c.query(sql)).rows;return result;
}
const compare=compareReviewed;
async function fingerprints(c){const tables=(await c.query("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') AND c.relkind='r' ORDER BY 1,2")).rows;const out=[];for(const t of tables){const id='"'+t.nspname.replaceAll('"','""')+'"."'+t.relname.replaceAll('"','""')+'"';const {rows:[r]}=await c.query(`SELECT count(*)::text count,encode(sha256(convert_to(coalesce(string_agg(h,'' ORDER BY h),''),'UTF8')),'hex') fingerprint FROM (SELECT encode(sha256(convert_to(to_jsonb(x)::text,'UTF8')),'hex') h FROM ${id} x) q`);out.push({table:t.nspname+'.'+t.relname,...r});}const seq=[];for(const s of (await c.query("SELECT schemaname,sequencename FROM pg_sequences WHERE schemaname IN ('app','platform','security') ORDER BY 1,2")).rows){const id='"'+s.schemaname.replaceAll('"','""')+'"."'+s.sequencename.replaceAll('"','""')+'"';seq.push({sequence:s.schemaname+'.'+s.sequencename,...(await c.query(`SELECT last_value::text,is_called FROM ${id}`)).rows[0]});}return {tables:out,sequences:seq};}

let c,committed=false,success=false,existing=false;const receiptId=randomUUID();
try{
 c=await connect(target);const ref=await connect(reference);const expected=await catalog(ref);
 await check('01_named_target_and_reference_verified',async()=>{const r=(await c.query('SELECT current_database() db,current_user role,host(inet_server_addr()) host,inet_server_port() port')).rows[0];assert.equal(r.db,target);assert.equal(r.role,'postgres');assert.equal(r.host,'127.0.0.1');assert.equal(r.port,5432);assert.equal(expected.tables.length,36);assert.equal(expected.functions.filter(x=>x.identity.startsWith('security.')).length,68);});
 await c.query('BEGIN');
 await c.query("SELECT pg_advisory_xact_lock(hashtextextended('gympro-controlled-ledger-adoption',0))");
 const active=(await c.query("SELECT count(*)::int n FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND (state='active' OR state LIKE 'idle in transaction%')")).rows[0].n;
 if(active)throw Error('Other active database work exists; stop the API/jobs and finish open transactions before retrying');
 // SHARE locks block business DML for the short comparison/registration transaction.
 const names=expected.tables.map(t=>'"'+t.nspname.replaceAll('"','""')+'"."'+t.relname.replaceAll('"','""')+'"');
 await c.query('LOCK TABLE '+names.join(',')+' IN SHARE MODE');
 await check('02_exact_catalog_and_permission_seeds_match',async()=>compare(await catalog(c),expected));
 let before;
 await check('03_business_content_and_sequences_recorded',async()=>{before=await fingerprints(c);assert.equal(before.tables.length,36);writeFileSync(join(report,'business-fingerprints-before.json'),JSON.stringify(before,null,2));});
 async function register(){
  const present=(await c.query("SELECT to_regclass('migration_control.ledger') IS NOT NULL present")).rows[0].present;
  if(present){
   assert.deepEqual((await c.query('SELECT position,id,sha256 FROM migration_control.ledger ORDER BY position')).rows,expectedHistory);
   const r=(await c.query('SELECT id,details FROM migration_control.adoption_receipts')).rows;assert.equal(r.length,1);
   assert.equal(r[0].details.registrationTimeIsNotHistoricExecutionTime,true);assert.equal(r[0].details.catalogSha256,digest(expected));
   assert.equal((await c.query('SELECT count(*)::int n FROM migration_control.provisioning_receipts')).rows[0].n,0);
   return false;
  }
  if((await c.query("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='migration_control') present")).rows[0].present)throw Error('Unexpected migration_control schema; stop for review');
  await c.query('CREATE SCHEMA migration_control AUTHORIZATION postgres;REVOKE ALL ON SCHEMA migration_control FROM PUBLIC');
  await c.query(`CREATE TABLE migration_control.ledger(position integer PRIMARY KEY CHECK(position>0),id text NOT NULL UNIQUE,sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),applied_by name NOT NULL DEFAULT current_user);ALTER TABLE migration_control.ledger ENABLE ROW LEVEL SECURITY;ALTER TABLE migration_control.ledger FORCE ROW LEVEL SECURITY;REVOKE ALL ON migration_control.ledger FROM PUBLIC`);
  await c.query(plan.migrations[0].sql);
  await c.query('CREATE TABLE migration_control.adoption_receipts(id uuid PRIMARY KEY,details jsonb NOT NULL,registered_at timestamptz NOT NULL DEFAULT clock_timestamp());ALTER TABLE migration_control.adoption_receipts ENABLE ROW LEVEL SECURITY;ALTER TABLE migration_control.adoption_receipts FORCE ROW LEVEL SECURITY;REVOKE ALL ON migration_control.adoption_receipts FROM PUBLIC');
  for(const row of expectedHistory)await c.query('INSERT INTO migration_control.ledger(position,id,sha256) VALUES($1,$2,$3)',[row.position,row.id,row.sha256]);
  await c.query('INSERT INTO migration_control.adoption_receipts(id,details) VALUES($1,$2)',[receiptId,JSON.stringify({registrationTimeIsNotHistoricExecutionTime:true,baseline:'adopted after exact comparison','0002_tenant_provisioning':'executed now: previously absent','0003_self_session_management':'existing, verified, not replayed','0004_password_change':'existing, verified, not replayed',catalogSha256:digest(expected),sourceCheckpoint:'31ae525',reportFolder:report})]);return true;
 }
 await check('04_metadata_registered_without_function_replay',async()=>{existing=!(await register());});
 await check('05_four_manifest_checksums_match',async()=>assert.deepEqual((await c.query('SELECT position,id,sha256 FROM migration_control.ledger ORDER BY position')).rows,expectedHistory));
 await check('06_runtime_metadata_access_denied_and_forced_RLS',async()=>{
  const tables=(await c.query("SELECT c.relname,c.relrowsecurity,c.relforcerowsecurity,pg_get_userbyid(c.relowner) owner FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='migration_control' AND c.relkind='r' ORDER BY c.relname")).rows;
  assert.deepEqual(tables.map(t=>t.relname),['adoption_receipts','ledger','provisioning_receipts']);
  for(const t of tables){assert.equal(t.owner,'postgres');assert.equal(t.relrowsecurity,true);assert.equal(t.relforcerowsecurity,true);for(const role of ['gympro_app','gympro_auth','gympro_session']){const r=(await c.query("SELECT has_schema_privilege($1,'migration_control','USAGE') usage,has_table_privilege($1,$2,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') crud",[role,'migration_control.'+t.relname])).rows[0];assert.equal(r.usage,false);assert.equal(r.crud,false);}}
 });
 await check('07_retry_preserves_exact_metadata_receipt',async()=>{const read=async()=>({ledger:(await c.query('SELECT * FROM migration_control.ledger ORDER BY position')).rows,receipts:(await c.query('SELECT * FROM migration_control.adoption_receipts ORDER BY id')).rows});const a=await read();assert.equal(await register(),false);assert.deepEqual(await read(),a);});
 await check('08_business_schema_content_sequences_unchanged',async()=>{compare(await catalog(c),expected);const after=await fingerprints(c);assert.deepEqual(after,before);writeFileSync(join(report,'business-fingerprints-after.json'),JSON.stringify(after,null,2));});
 await c.query('COMMIT');committed=true;
 await check('09_committed_ledger_readback_matches',async()=>assert.deepEqual((await c.query('SELECT position,id,sha256 FROM migration_control.ledger ORDER BY position')).rows,expectedHistory));
 writeFileSync(join(report,'ledger-receipt.json'),JSON.stringify({rows:(await c.query('SELECT * FROM migration_control.ledger ORDER BY position')).rows,adoption:(await c.query('SELECT * FROM migration_control.adoption_receipts')).rows,catalogSha256:digest(expected)},null,2));success=true;
}catch(e){if(c&&!committed)try{await c.query('ROLLBACK');}catch{}console.error('FAIL:',e.code??'none',e.message);console.error(committed?'Ledger COMMIT completed before this error. Do not assume rollback or rerun blindly.':'The adoption transaction was not committed; inspect reports before retrying.');process.exitCode=1;}
finally{await Promise.allSettled(clients.map(c=>c.end()));writeFileSync(join(report,'live-adoption-results.json'),JSON.stringify({success,committed,alreadyInstalledAtStart:existing,checks,checkCount:checks.length,workingLedgerInstalled:mode==='live'&&committed,mode,businessDataChanged:false,businessFunctionsReplayed:false,productionFeaturesEnabled:false,kbzPayDeferred:true},null,2));}
