import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {resolve,join} from 'node:path';
import {readFileSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
const [sourceArg,rootArg]=process.argv.slice(2),source=resolve(sourceArg),root=resolve(rootArg);
const meta=JSON.parse(readFileSync(join(root,'installation.json'),'utf8'));
assert.equal(meta.databasePort,55440);assert.equal(meta.apiPort,3200);
const {Client}=createRequire(join(source,'package.json'))('pg'),argon2=createRequire(join(source,'package.json'))('argon2');
const {provisionTenant}=await import(pathToFileURL(join(source,'tools/provisioning/provision.mjs')).href);
const c=new Client({host:'127.0.0.1',port:55440,user:'postgres',database:'gympro_saas',ssl:false,connectionTimeoutMillis:5000});
try{
 await c.connect();
 const {rows:[server]}=await c.query('SELECT (pg_control_system()).system_identifier::text id,inet_server_port() port,current_database() db');
 assert.equal(server.id,meta.systemIdentifier);assert.equal(server.port,55440);assert.equal(server.db,'gympro_saas');
 assert.equal((await c.query('SELECT count(*)::int n FROM platform.tenants')).rows[0].n,0);
 const ownerPassword=process.env.GYMPRO_STAGE_OWNER_PASSWORD;
 assert.ok(ownerPassword?.length>=12&&ownerPassword.length<=200);
 const receipt=await provisionTenant(c,{requestId:randomUUID(),tenantCode:'LOCAL_STAGE',tenantName:'Gym Pro Local Staging',tenantType:'independent',branchCode:'STAGE_MAIN',branchName:'Staging Main Branch',email:'staging.owner@example.invalid',fullName:'Local Staging Owner',password:ownerPassword},argon2,{port:55440,systemIdentifier:meta.systemIdentifier});
 delete process.env.GYMPRO_STAGE_OWNER_PASSWORD;
 writeFileSync(join(root,'owner.json'),JSON.stringify({tenantId:receipt.tenantId,branchId:receipt.branchId,email:receipt.email,permissions:receipt.permissions},null,2)+'\n');
 await c.query("SET password_encryption='scram-sha-256'");
 for(const [role,key] of [['gympro_app','GYMPRO_STAGE_APP_PASSWORD'],['gympro_auth','GYMPRO_STAGE_AUTH_PASSWORD'],['gympro_session','GYMPRO_STAGE_SESSION_PASSWORD'],['postgres','GYMPRO_STAGE_ADMIN_PASSWORD']]){
  const password=process.env[key];assert.match(password||'',/^[a-f0-9]{64}$/);
  await c.query(`ALTER ROLE ${role} PASSWORD ${c.escapeLiteral(password)}`);delete process.env[key];
 }
 console.log('PASS: Isolated staging owner provisioned; separate database credentials configured.');
}catch(error){console.error('FAIL: Staging provisioning/security setup:',error.code||error.name);process.exitCode=1;}finally{await c.end();}
