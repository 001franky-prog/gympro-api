import {spawnSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdirSync,copyFileSync,existsSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
import {prepare} from '../migrations/migrate.mjs';

// This entry point is intentionally restricted to an ephemeral hosted Linux runner.
assert.equal(process.platform,'linux');
assert.equal(process.env.GITHUB_ACTIONS,'true');
assert.equal(process.env.RUNNER_ENVIRONMENT,'github-hosted');
const project=process.cwd(), report=join(project,'ci-results');
assert.ok(!existsSync(report),'Refuse to overwrite previous CI evidence');
mkdirSync(report);
const manifest=JSON.parse(readFileSync('sql/migrations/manifest.json','utf8').replace(/^\uFEFF/,''));
prepare(project,manifest); // Verify exact baseline and migration bytes before execution.
const nonce=randomBytes(3).toString('hex');
const stamp=new Date().toISOString().replace(/\D/g,'').slice(0,14);
const bootstrap=`gympro_bootstrap_${stamp}_${nonce}`;
const container=`gympro-ci-${nonce}`,port=55432;
const env={...process.env};
for(const key of Object.keys(env))if(/^(GYMPRO_|PG|PRISMA_|.*DATABASE_URL$|NODE_OPTIONS$)/.test(key))delete env[key];
env.PGSSLMODE='disable';
function run(exe,args,{input,timeout=120000,quiet=false}={}){
 const result=spawnSync(exe,args,{cwd:project,env,input,timeout,encoding:'utf8',maxBuffer:16*1024*1024,stdio:quiet||input!==undefined?'pipe':'inherit'});
 if(!quiet&&input!==undefined){process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');}
 if(result.error||result.status!==0)throw Error(`${exe} ${args[0]} failed (${result.status}): ${result.error?.message||''}`);
 return result.stdout;
}
function sql(file){console.log('CHECK: '+file);run('docker',['exec','-i',container,'psql','-X','-U','postgres','-p',String(port),'-d',bootstrap,'-v','ON_ERROR_STOP=1','-v',`target=${bootstrap}`],{input:readFileSync(file),timeout:120000});}
let owned=false,passed=false,removed=false;
try{
 run('docker',['pull','postgres:18'],{timeout:180000});
 run('docker',['create','--name',container,'--label','gympro.disposable-ci=true','-e','POSTGRES_HOST_AUTH_METHOD=trust','-p',`127.0.0.1:${port}:${port}`,'postgres:18','postgres','-p',String(port)]);
 owned=true;
 run('docker',['start',container]);
 let ready=false;
 for(let i=0;i<60;i++){
  const r=spawnSync('docker',['exec',container,'pg_isready','-h','127.0.0.1','-U','postgres','-p',String(port)],{env,stdio:'ignore',timeout:5000});
  if(r.status===0){ready=true;break;}
  await new Promise(r=>setTimeout(r,1000));
 }
 assert.ok(ready,'PostgreSQL readiness timeout');
 run('docker',['exec',container,'createdb','-U','postgres','-p',String(port),bootstrap]);
 sql('sql/bootstrap-prerequisites-20261016/000-roles.sql');
 sql('sql/baseline-20261016/schema.sql');
 sql('sql/bootstrap-prerequisites-20261016/010-permissions.sql');
 sql('sql/bootstrap-prerequisites-20261016/010-permissions.sql');
 sql('sql/bootstrap-prerequisites-20261016/verify-prerequisites.sql');
 sql('sql/bootstrap-prerequisites-20261016/verify-schema.sql');
 // Run the committed harness unchanged, with its relative provisioning import beside it.
 copyFileSync('tools/fresh-install/verify-and-demo.mjs',join(report,'verify-and-demo.mjs'));
 copyFileSync('tools/provisioning/provision.mjs',join(report,'provision.mjs'));
 env.GYMPRO_1F_PASSWORD=randomBytes(48).toString('base64url');
 env.GYMPRO_FRESH_NO_BROWSER='1';
 run(process.execPath,[join(report,'verify-and-demo.mjs'),project,String(port),bootstrap,'3151',report],{timeout:600000});
 delete env.GYMPRO_1F_PASSWORD;
 const read=name=>JSON.parse(readFileSync(join(report,name),'utf8'));
 const unit=read('full-suite-results.json'),e2e=read('root-e2e-results.json'),http=read('provisioning-results.json');
 assert.equal(unit.success,true);assert.ok(unit.numPassedTests>=1567);assert.equal(unit.numFailedTests,0);assert.equal(unit.numPendingTests,0);
 assert.equal(e2e.success,true);assert.equal(e2e.numFailedTests,0);assert.equal(e2e.numPendingTests,0);assert.ok(e2e.numPassedTests>=1);
 assert.equal(http.automaticChecksPassed,true);assert.equal(http.automaticCheckCount,46);assert.equal(http.fixtureCleanupPassed,true);assert.equal(http.ownApiStopped,true);
 passed=true;
}finally{
 delete env.GYMPRO_1F_PASSWORD;
 if(owned){const r=spawnSync('docker',['rm','-f','-v',container],{env,stdio:'inherit',timeout:30000});removed=r.status===0;}
 writeFileSync(join(report,'ci-summary.json'),JSON.stringify({fullDatabaseVerificationPassed:passed,disposableContainerRemoved:removed,workingDatabaseUsed:false,productionSecretsUsed:false,manualBrowserTestPerformed:false,kbzPayDeferred:true},null,2)+'\n');
 if(owned&&!removed)throw Error('Owned PostgreSQL container cleanup failed');
}
console.log('PASS: Hosted full suite, root e2e, 46 HTTP/database checks and container cleanup.');
