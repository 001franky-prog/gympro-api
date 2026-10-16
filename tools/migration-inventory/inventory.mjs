import {readdirSync,readFileSync,writeFileSync,mkdirSync,lstatSync} from 'node:fs';
import {resolve,join,relative} from 'node:path';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
export function inspect(name,bytes){
 const text=bytes.toString('utf8').replace(/^\uFEFF/,'');
 // Static evidence only: not a PostgreSQL parser, dependency resolver or safety verdict.
 const sql=text.replace(/\/\*[\s\S]*?\*\//g,' ').replace(/--[^\r\n]*/g,' ');
 const captures=(re)=>[...sql.matchAll(re)].map(m=>m[1].toLowerCase());
 const createdTables=[...new Set(captures(/\bCREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?((?:[a-z_][\w]*\.)?[a-z_][\w]*)/gi))];
 const functions=[...new Set(captures(/\bCREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+((?:[a-z_][\w]*\.)?[a-z_][\w]*)/gi))];
 let category=/verify|positive|rehearsal/.test(name)?'verification-candidate':/inspect|diagnostic|readiness/.test(name)?'inspection-candidate':/fix|protect/.test(name)?'correction-candidate':/create|install|complete/.test(name)?'installation-candidate':'manual-classification';
 const flags=[];
 for(const [flag,re] of [
 ['psql-connect',/^\s*\\(?:connect|c)(?:\s|$)/mi],['psql-include',/^\s*\\(?:i|ir)(?:\s|$)/mi],
 ['psql-shell-or-copy',/^\s*\\(?:!|copy|o|w)(?:\s|$)/mi],['psql-other-meta',/^\s*\\/m],
 ['explicit-commit',/\bCOMMIT\s*;/i],['rollback-present',/\bROLLBACK\b/i],['explicit-transaction',/\bBEGIN\s*;/i],
 ['data-mutation-present',/\b(?:INSERT\s+INTO|UPDATE\s+(?:app|security|platform)\.|DELETE\s+FROM)\b/i],
 ['role-or-grant-change',/\b(?:(?:CREATE|ALTER|DROP)\s+ROLE|GRANT|REVOKE)\b/i],
 ['drop-or-truncate',/\b(?:DROP|TRUNCATE)\b/i],['dynamic-sql-present',/\bEXECUTE\b/i],
 ['uuid-literals-present',/'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'/i]
 ])if(re.test(text))flags.push(flag);
 return {file:name,sha256:createHash('sha256').update(bytes).digest('hex'),bytes:bytes.length,category,createdTables,functions,flags,reviewStatus:'NOT_REVIEWED',approvedExecutionOrder:null};
}
export function inventory(project){
 const sqlRoot=join(project,'sql'), files=[];
 function walk(dir){for(const entry of readdirSync(dir,{withFileTypes:true})){const path=join(dir,entry.name);if(lstatSync(path).isSymbolicLink())continue;if(entry.isDirectory())walk(path);else if(entry.isFile()&&entry.name.endsWith('.sql'))files.push(path);}}
 walk(sqlRoot);files.sort((a,b)=>a<b?-1:a>b?1:0);
 if(!files.length)throw Error('No SQL files found.');
 const records=files.map(path=>inspect(relative(project,path).replaceAll('\\','/'),readFileSync(path)));
 const prerequisites=['platform.tenants','app.branches','app.users','app.tenant_memberships','app.roles','app.permissions','app.role_permissions','app.role_assignments','security.tenant_sessions'];
 const prerequisiteEvidence=prerequisites.map(table=>({table,staticCreateCandidates:records.filter(r=>r.createdTables.includes(table)).map(r=>r.file)}));
 return {step:'Batch 1B SQL inventory',inventoryCompleted:true,automaticExecutionAllowed:false,installationOrderValidated:false,cleanInstallVerified:false,migrationLedgerInstalled:false,kbzPayDeferred:true,files:records,prerequisiteEvidence};
}
export function markdown(result){
 const counts={};for(const r of result.files)counts[r.category]=(counts[r.category]||0)+1;
 return '# SQL inventory and installation blockers\n\nStatic source inventory only. No SQL executed. No script is approved for replay.\n\n'+
 'This is not an applied-migration ledger. File hashes record source bytes only; they do not establish database installation state.\n\n'+
 '## Summary\n\n'+Object.entries(counts).map(([k,v])=>'- '+k+': '+v).join('\n')+
 '\n\n## Core bootstrap evidence\n\nMissing static CREATE evidence does not prove absence from the live database. Dynamic SQL, quoted identifiers and scripts outside sql/ need manual review.\n\n| Object | Static CREATE candidate |\n|---|---|\n'+result.prerequisiteEvidence.map(r=>'| '+r.table+' | '+(r.staticCreateCandidates.join(', ')||'NOT FOUND in scanned SQL')+' |').join('\n')+
 '\n\n## Files requiring review\n\nCategory labels and flags are heuristics. Review function signatures, dependency order, grants, transactions, fixtures, environment-specific values and rerun behavior before approval.\n\n| File | Candidate category | Review flags |\n|---|---|---|\n'+result.files.map(r=>'| '+r.file+' | '+r.category+' | '+(r.flags.join(', ')||'none detected; still requires review')+' |').join('\n')+
 '\n\n## Next gate\n\nRecover and compare canonical core bootstrap DDL with a schema-only catalog export. Establish an explicit reviewed manifest, separate fixture tests from migrations, then rehearse on a uniquely named disposable database. Never run historical scripts in filename order or replace working tables. Production login policy remains unchanged.\n';
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 try{const project=resolve(process.argv[2]||'.'),out=resolve(process.argv[3]||'.');const result=inventory(project);mkdirSync(out,{recursive:true});writeFileSync(join(out,'sql-inventory.json'),JSON.stringify(result,null,2));writeFileSync(join(out,'sql-inventory.md'),markdown(result));console.log('PASS: '+result.files.length+' SQL files inventoried; SHA256 hashes recorded.');console.log('Core objects without static CREATE candidates: '+result.prerequisiteEvidence.filter(x=>!x.staticCreateCandidates.length).length);console.log('PENDING: reviewed installation order, core bootstrap reconstruction, migration ledger and clean-install rehearsal. No SQL executed.');}catch{console.error('FAIL: SQL inventory could not be completed. Check the project/sql path and file access.');process.exitCode=1;}
}
