import {createRequire} from 'node:module';import {join,resolve} from 'node:path';import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';import assert from 'node:assert/strict';import {prepare,registerBaseline,apply,sha256} from './migrate.mjs';
const [project,portText,database,report]=process.argv.slice(2);const port=Number(portText);
if(!project||!report||!Number.isInteger(port)||port<55432||port>55462||!/^gympro_bootstrap_\d{14}_[a-f0-9]{6}$/.test(database))throw Error('Invalid isolated rehearsal arguments');
const {Client}=createRequire(join(resolve(project),'package.json'))('pg');const connect=async()=>{const c=new Client({host:'127.0.0.1',port,database,user:'postgres',ssl:false,connectionTimeoutMillis:5000});await c.connect();await c.query("SET statement_timeout='20s'");return c;};
const checks=[];const clients=[];const check=async(name,fn)=>{await fn();checks.push({name,result:'PASS'});console.log('PASS: '+name);};
try{
 const c=await connect();clients.push(c);const manifest=JSON.parse(readFileSync(join(report,'approved-manifest.json'),'utf8'));const plan=prepare(project,manifest);let original;
 await check('01_register_verified_baseline',async()=>{original=await registerBaseline(c,plan);assert.equal(original.position,1);});
 await check('02_baseline_retry_is_immutable',async()=>{const receipt=await registerBaseline(c,plan);assert.deepEqual(receipt,original);});
 await check('03_runtime_cannot_read_or_write_ledger',async()=>{await c.query('SET ROLE gympro_app');try{await assert.rejects(()=>c.query('SELECT * FROM migration_control.ledger'),e=>e.code==='42501');await assert.rejects(()=>c.query("INSERT INTO migration_control.ledger(position,id,sha256) VALUES(9,'x',repeat('0',64))"),e=>e.code==='42501');}finally{await c.query('RESET ROLE');}});
 const fixture=join(report,'fixtures');mkdirSync(fixture,{recursive:true});
 for(const [name,body] of [['schema.sql','SELECT 1;'],['roles.sql','SELECT 1;'],['seed.sql','SELECT 1;']])writeFileSync(join(fixture,name),body);
 // Fixture manifest retains the verified baseline identity while migrations live only outside the repository.
 const fixturePlan=sql=>({baseline:plan.baseline,migrations:[{position:2,id:'0002_rehearsal_probe',sha256:sha256(sql),sql}]});
 const sql='CREATE TABLE migration_control.rehearsal_probe(id integer PRIMARY KEY); INSERT INTO migration_control.rehearsal_probe VALUES(1);';const change=fixturePlan(sql);
 await check('04_atomic_apply_and_record',async()=>{const rows=await apply(c,change);assert.equal(rows.length,2);assert.equal((await c.query('SELECT count(*)::int AS n FROM migration_control.rehearsal_probe')).rows[0].n,1);});
 await check('05_retry_does_not_rerun_migration',async()=>{const first=await apply(c,change);const second=await apply(c,change);assert.deepEqual(second,first);});
 await check('06_applied_checksum_change_rejected',async()=>{await assert.rejects(()=>apply(c,fixturePlan('SELECT 1;')),/differs/);});
 await check('07_removed_history_rejected',async()=>{await assert.rejects(()=>apply(c,plan),/prefix/);});
 const bad={...change,migrations:[...change.migrations,{position:3,id:'0003_fail_probe',sha256:sha256('bad-fixture'),sql:'CREATE TABLE migration_control.rollback_probe(id int); SELECT 1/0;'}]};
 await check('08_failed_migration_rolls_back_ddl_and_ledger',async()=>{await assert.rejects(()=>apply(c,bad),e=>e.code==='22012');assert.equal((await c.query("SELECT to_regclass('migration_control.rollback_probe') AS value")).rows[0].value,null);assert.equal((await c.query('SELECT count(*)::int AS n FROM migration_control.ledger')).rows[0].n,2);});
 const next={...change,migrations:[...change.migrations,{position:3,id:'0003_concurrent_probe',sha256:sha256('concurrent-fixture'),sql:'CREATE TABLE migration_control.concurrent_probe(id int PRIMARY KEY); INSERT INTO migration_control.concurrent_probe VALUES(1);'}]};
 await check('09_concurrent_runs_apply_once',async()=>{const a=await connect(),b=await connect();clients.push(a,b);const [first,second]=await Promise.all([apply(a,next),apply(b,next)]);assert.deepEqual(first,second);assert.equal((await c.query('SELECT count(*)::int AS n FROM migration_control.concurrent_probe')).rows[0].n,1);});
 await check('10_real_manifest_remains_without_test_migrations',async()=>{assert.equal(manifest.migrations.length,0);assert.equal(prepare(project,manifest).migrations.length,0);});
 const summary={step:'1E isolated migration ledger verification',passed:true,checks,liveDatabaseChanged:false,workingDatabaseLedgerInstalled:false,productionReady:false,kbzPayDeferred:true};writeFileSync(join(report,'migration-results.json'),JSON.stringify(summary,null,2));
}catch(error){console.error('FAIL: Migration verification stopped. SQLSTATE:',error.code||'none','Reason:',error.message);process.exitCode=1;}finally{await Promise.all(clients.map(c=>c.end()));}
