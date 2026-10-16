import {readFileSync,existsSync,writeFileSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {createRequire} from 'node:module';
const project=resolve(process.argv[2]||'.'), report=process.argv[3];
const checks=[];
const check=(name,ok)=>checks.push({name,result:ok?'PASS':'FAIL'});
let env={};
try { const require=createRequire(join(project,'package.json'));env={...require('dotenv').parse(readFileSync(join(project,'.env'))),...process.env};check('dotenv_and_environment_loaded',true); }catch{check('dotenv_and_environment_loaded',false);}
for(const [key,role] of [['DATABASE_URL','gympro_app'],['AUTH_DATABASE_URL','gympro_auth'],['SESSION_DATABASE_URL','gympro_session']]) {
 let valid=false;try{const u=new URL(env[key]);valid=['postgres:','postgresql:'].includes(u.protocol)&&decodeURIComponent(u.username)===role&&decodeURIComponent(u.pathname)==='/gympro_saas'&&Boolean(u.password);}catch{}
 check(key+'_restricted_role_and_database',valid);
}
for(const file of ['package-lock.json','src/main.ts','src/auth/session-security-policy.ts','sql/e1-install-payment-foundation.sql','src/pos/pos-history.service.ts','test/app.e2e-spec.ts'])check('required_file:'+file,existsSync(join(project,file)));
check('local_node_modules',existsSync(join(project,'node_modules')));
check('node_24_or_newer',Number(process.versions.node.split('.')[0])>=24);
const status={step:'Batch 1A foundation baseline',passed:checks.every(x=>x.result==='PASS'),checks,verifiedAt:new Date().toISOString(),databaseConnectionTested:false,productionReady:false,cleanInstallVerified:false,kbzPayDeferred:true};
console.table(checks);console.log('No credential values were printed. Database connectivity and production readiness are not established by this preflight.');
if(report)writeFileSync(report,JSON.stringify(status,null,2));
if(!status.passed)process.exitCode=1;
