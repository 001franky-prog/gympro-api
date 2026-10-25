import {readFileSync,realpathSync} from 'node:fs';
import {resolve,relative,isAbsolute,sep} from 'node:path';
import {createHash} from 'node:crypto';
export const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
const fail=message=>{throw Error(message);};
// Only top-level commands are inspected. Quoted bodies/comments are skipped.
export function checkSql(text){
 let i=0,bare='';
 while(i<text.length){
  const tail=text.slice(i);
  if(tail.startsWith('--')){const end=text.indexOf('\n',i+2);i=end<0?text.length:end+1;bare+=' ';continue;}
  if(tail.startsWith('/*')){let depth=1;i+=2;while(i<text.length&&depth){if(text.startsWith('/*',i)){depth++;i+=2;}else if(text.startsWith('*/',i)){depth--;i+=2;}else i++;}if(depth)fail('Unclosed SQL comment');bare+=' ';continue;}
  const dollar=tail.match(/^\$(?:[a-zA-Z_][a-zA-Z0-9_]*)?\$/)?.[0];
  if(dollar){const end=text.indexOf(dollar,i+dollar.length);if(end<0)fail('Unclosed SQL dollar quote');i=end+dollar.length;bare+=' quoted ';continue;}
  if(text[i]==="'"||text[i]==='"'){const quote=text[i++];let closed=false;while(i<text.length){if(text[i]===quote){if(text[i+1]===quote){i+=2;continue;}i++;closed=true;break;}if(text[i]==='\\'&&quote==="'"){i+=2;continue;}i++;}if(!closed)fail('Unclosed SQL quote');bare+=' quoted ';continue;}
  if(text[i]==='\\')fail('psql meta commands are not allowed in tracked migrations');
  bare+=text[i++];
 }
 for(const statement of bare.split(';').map(s=>s.trim()).filter(Boolean)){
  if(/^(?:begin\b|start\s+transaction\b|commit\b|end\b|rollback\b|abort\b|savepoint\b|release\b|prepare\s+transaction\b|vacuum\b|(?:create|drop)\s+database\b|alter\s+system\b|(?:create|alter|drop)\s+role\b|copy\b)/i.test(statement))fail('Transaction control, global role/database changes or nontransactional command rejected');
 }
 if(!bare.trim())fail('Empty migration rejected');
}
function source(root,item){
 if(typeof item?.file!=='string'||isAbsolute(item.file)||!/^\w[\w./-]*$/.test(item.file)||! /^[a-f0-9]{64}$/.test(item.sha256||''))fail('Invalid migration source metadata');
 const path=realpathSync(resolve(root,item.file));const rel=relative(root,path);
 if(rel==='..'||rel.startsWith('..'+sep)||isAbsolute(rel))fail('Migration path escapes project');
 const bytes=readFileSync(path);if(sha256(bytes)!==item.sha256)fail('Migration source checksum mismatch: '+item.file);
 return new TextDecoder('utf-8',{fatal:true}).decode(bytes);
}
export function prepare(root,manifest){
 root=realpathSync(root);
 if(manifest?.version!==1||manifest?.baseline?.id!=='0001_recovered_schema_and_permissions'||manifest.baseline.position!==1||!Array.isArray(manifest.baseline.sources)||manifest.baseline.sources.length!==3||!Array.isArray(manifest.migrations))fail('Invalid migration manifest');
 for(const s of manifest.baseline.sources)source(root,s);
 const base={position:1,id:manifest.baseline.id,sha256:sha256(JSON.stringify(manifest.baseline.sources.map(({file,sha256})=>({file,sha256}))))};
 const changes=manifest.migrations.map((m,index)=>{
  if(m.position!==index+2||typeof m.id!=='string'||!/^\d{4}_[a-z][a-z0-9_]*$/.test(m.id)||Number(m.id.slice(0,4))!==m.position)fail('Migrations must have unique contiguous IDs in approved order');
  const sql=source(root,m);checkSql(sql);return {position:m.position,id:m.id,sha256:m.sha256,sql};
 });
 if(new Set([base.id,...changes.map(x=>x.id)]).size!==changes.length+1)fail('Duplicate migration ID');
 return {baseline:base,migrations:changes};
}
async function transaction(client,fn){
 await client.query('BEGIN');try{await client.query('SELECT pg_advisory_xact_lock(81272,1)');const r=await fn();await client.query('COMMIT');return r;}catch(error){await client.query('ROLLBACK');throw error;}
}
async function guard(client){
 const {rows:[r]}=await client.query("SELECT current_database() AS db,current_user AS role,inet_server_port() AS port");
 if(r.role!=='postgres'||!/^gympro_bootstrap_\d{14}_[a-f0-9]{6}$/.test(r.db)||r.port<55432||r.port>55462)fail('Migration tool currently permits only isolated bootstrap rehearsals');
}
export async function registerBaseline(client,plan){
 await guard(client);
 return transaction(client,async()=>{
  const {rows:[state]}=await client.query("SELECT (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') AND c.relkind='r') AS tables,(SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security') AS functions,(SELECT count(*)::int FROM app.permissions) AS permissions,(SELECT count(*)::int FROM app.users) AS users,(SELECT count(*)::int FROM platform.tenants) AS tenants");
  if(state.tables!==36||state.functions!==64||state.permissions!==39||state.users!==0||state.tenants!==0)fail('Baseline registration requires the verified empty-business schema and permission seeds');
  await client.query(`CREATE SCHEMA IF NOT EXISTS migration_control AUTHORIZATION postgres;
   REVOKE ALL ON SCHEMA migration_control FROM PUBLIC;
   CREATE TABLE IF NOT EXISTS migration_control.ledger (
    position integer PRIMARY KEY CHECK(position>0),id text NOT NULL UNIQUE,
    sha256 text NOT NULL CHECK(sha256 ~ '^[a-f0-9]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),applied_by name NOT NULL DEFAULT current_user
   );
   ALTER TABLE migration_control.ledger ENABLE ROW LEVEL SECURITY;
   ALTER TABLE migration_control.ledger FORCE ROW LEVEL SECURITY;
   REVOKE ALL ON migration_control.ledger FROM PUBLIC;`);
  const existing=await client.query('SELECT position,id,sha256,applied_at FROM migration_control.ledger ORDER BY position');
  if(existing.rows.length){const first=existing.rows[0];if(first.position!==1||first.id!==plan.baseline.id||first.sha256!==plan.baseline.sha256)fail('Registered baseline differs');return first;}
  const b=plan.baseline;return (await client.query('INSERT INTO migration_control.ledger(position,id,sha256) VALUES($1,$2,$3) RETURNING position,id,sha256,applied_at',[b.position,b.id,b.sha256])).rows[0];
 });
}
export async function apply(client,plan){
 await guard(client);
 return transaction(client,async()=>{
  const expected=[plan.baseline,...plan.migrations];const history=(await client.query('SELECT position,id,sha256,applied_at FROM migration_control.ledger ORDER BY position')).rows;
  if(!history.length||history.length>expected.length)fail('Ledger is not an approved manifest prefix');
  history.forEach((h,i)=>{const e=expected[i];if(h.position!==e.position||h.id!==e.id||h.sha256!==e.sha256)fail('Applied migration history or checksum differs');});
  for(const m of expected.slice(history.length)){
   await client.query(m.sql);
   await client.query('INSERT INTO migration_control.ledger(position,id,sha256) VALUES($1,$2,$3)',[m.position,m.id,m.sha256]);
  }
  return (await client.query('SELECT position,id,sha256,applied_at FROM migration_control.ledger ORDER BY position')).rows;
 });
}
