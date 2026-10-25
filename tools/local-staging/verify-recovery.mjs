import {createRequire} from 'node:module';
import {join,resolve} from 'node:path';
import {readFileSync,writeFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const [sourceArg,stageArg,reportArg,mode,restored]=process.argv.slice(2);
const source=resolve(sourceArg),stage=resolve(stageArg),report=resolve(reportArg);
assert.ok(['before','verify'].includes(mode));
const meta=JSON.parse(readFileSync(join(stage,'installation.json'),'utf8'));
assert.equal(meta.databasePort,55440);assert.equal(meta.apiPort,3200);
if(mode==='verify')assert.match(restored,/^gympro_stage_restore_\d{14}_[a-f0-9]{6}$/);
const {Client}=createRequire(join(source,'package.json'))('pg');
const clients=[];
async function connect(database){
 const c=new Client({host:'127.0.0.1',port:55440,user:'postgres',database,ssl:false,connectionTimeoutMillis:5000,application_name:'gympro-staging-backup-verifier'});
 await c.connect();clients.push(c);
 await c.query("SET statement_timeout='60s';SET lock_timeout='5s';SET search_path=pg_catalog;SET TIME ZONE 'UTC'");
 const {rows:[r]}=await c.query('SELECT current_database() db,current_user role,inet_server_port() port,(pg_control_system()).system_identifier::text system_id');
 assert.equal(r.db,database);assert.equal(r.role,'postgres');assert.equal(r.port,55440);assert.equal(r.system_id,meta.systemIdentifier);
 await c.query('BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ');
 return c;
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
async function fingerprints(c){const tables=(await c.query("SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security','migration_control') AND c.relkind='r' ORDER BY 1,2")).rows;const out=[];for(const t of tables){const id='"'+t.nspname.replaceAll('"','""')+'"."'+t.relname.replaceAll('"','""')+'"';const {rows:[r]}=await c.query(`SELECT count(*)::text count,encode(sha256(convert_to(coalesce(string_agg(h,'' ORDER BY h),''),'UTF8')),'hex') fingerprint FROM (SELECT encode(sha256(convert_to(to_jsonb(x)::text,'UTF8')),'hex') h FROM ${id} x) q`);out.push({table:t.nspname+'.'+t.relname,...r});}const seq=[];for(const s of (await c.query("SELECT schemaname,sequencename FROM pg_sequences WHERE schemaname IN ('app','platform','security','migration_control') ORDER BY 1,2")).rows){const id='"'+s.schemaname.replaceAll('"','""')+'"."'+s.sequencename.replaceAll('"','""')+'"';seq.push({sequence:s.schemaname+'.'+s.sequencename,...(await c.query(`SELECT last_value::text,is_called FROM ${id}`)).rows[0]});}return {tables:out,sequences:seq};}


async function verifyAclSemantics(c){
 const role="(SELECT oid FROM pg_roles WHERE rolname='postgres')";
 const runtime="(SELECT oid FROM pg_roles WHERE rolname='gympro_app')";
 async function schema(expression){return (await c.query(`SELECT ${acl('nspacl')} acl FROM (SELECT ${expression} nspacl,${role} nspowner) q`)).rows[0].acl;}
 const owner=await schema(`acldefault('n',${role})`),implicit=await schema('NULL::aclitem[]');
 assert.deepEqual(owner,implicit,'NULL schema ACL must expand to owner defaults');
 assert.notDeepEqual(await schema("'{}'::aclitem[]"),owner,'Explicit empty ACL must stay distinct');
 assert.notDeepEqual(await schema(`acldefault('n',${role})||makeaclitem(0,${role},'USAGE',false)`),owner,'PUBLIC grant must stay visible');
 assert.notDeepEqual(await schema(`acldefault('n',${role})||makeaclitem(${runtime},${role},'USAGE',false)`),owner,'Runtime grant must stay visible');
 const f=(await c.query(`SELECT EXISTS(SELECT 1 FROM aclexplode(COALESCE(NULL::aclitem[],acldefault('f',${role}))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE') allowed`)).rows[0].allowed;
 assert.equal(f,true,'NULL function ACL must preserve default PUBLIC execution');
 const expected={tables:[{owner:'postgres',relrowsecurity:true,relforcerowsecurity:true,acl:owner}]};
 assert.throws(()=>compare({tables:[{...expected.tables[0],owner:'gympro_app'}]},expected),/drift/);
 assert.throws(()=>compare({tables:[{...expected.tables[0],relforcerowsecurity:false}]},expected),/drift/);
 console.log('PASS: Seven ACL/owner/RLS regression checks; explicit empty, PUBLIC and runtime grants remain distinct.');
}

async function snapshot(c){return {catalog:await catalog(c),content:await fingerprints(c)};}
try{
 const original=await connect('gympro_saas');
 const active=(await original.query("SELECT count(*)::int n FROM pg_stat_activity WHERE datname='gympro_saas' AND pid<>pg_backend_pid() AND backend_type='client backend'")).rows[0].n;
 assert.equal(active,0,'Stop all other staging database clients before backup verification');
 const prior=mode==='verify'?JSON.parse(readFileSync(join(report,'before.json'),'utf8')):null;
 expandDefaults=mode==='before'||prior?.aclComparisonVersion>=2;
 const state=await snapshot(original);
 assert.equal(state.catalog.tables.filter(t=>['app','platform','security'].includes(t.nspname)).length,36);
 assert.ok(state.catalog.tables.filter(t=>t.relforcerowsecurity).length>=28);
 assert.equal(state.catalog.functions.filter(f=>f.identity.startsWith('security.')).length,68);
 if(mode==='before'){
  writeFileSync(join(report,'before.json'),JSON.stringify({...state,aclComparisonVersion:3},null,2)+'\n');
  console.log('PASS: Named staging cluster identity, schema/security and content fingerprints captured.');
 }else{
  const before=prior;
  compare(state.catalog,before.catalog);assert.deepEqual(state.content,before.content,'Original staging data or sequence values changed');
  // Preserve the original raw-ACL baseline check above before expanding defaults.
  expandDefaults=true;
  const canonical=await catalog(original);
  await verifyAclSemantics(original);
  const copy=await connect(restored);const recovered=await snapshot(copy);
  compare(recovered.catalog,canonical);assert.deepEqual(recovered.content,before.content,'Restored content/sequence fingerprints differ');
  await copy.query('SET ROLE gympro_auth');
  const unknown=(await copy.query("SELECT count(*)::int n FROM security.verify_tenant_session(decode(repeat('00',32),'hex'))")).rows[0].n;
  assert.equal(unknown,0);await copy.query('RESET ROLE');
  assert.equal((await copy.query("SELECT has_function_privilege('gympro_app','security.verify_tenant_session(bytea)','EXECUTE') allowed")).rows[0].allowed,false);
  writeFileSync(join(report,'comparison-summary.json'),JSON.stringify({sourceCatalogUnchanged:true,sourceRowsAndSequencesUnchanged:true,restoredCatalogMatches:true,restoredRowsAndSequencesMatch:true,tableCount:state.catalog.tables.length,securityFunctionCount:68,unknownSessionRejected:true,privateVerifierExecutionDenied:true,restoredDatabase:restored,aclComparisonVersion:3,aclRegressionChecksPassed:7},null,2)+'\n');
  console.log('PASS: Original staging schema, security, rows and sequences unchanged.');
  console.log('PASS: Restored schema/owners/RLS/privileges/functions, all row fingerprints and sequences match.');
  console.log('PASS: Restored unknown-session and private-verifier boundaries verified.');
 }
}catch(e){console.error('FAIL: Staging recovery comparison:',e.message);process.exitCode=1;}finally{for(const c of clients){try{await c.query('ROLLBACK');}catch{}await c.end();}}
