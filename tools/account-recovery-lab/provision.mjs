import {randomUUID,createHash} from 'node:crypto';
export const initialPermissions=Object.freeze(['gym.attendance.read','gym.attendance.record','gym.cards.manage','gym.cards.read','gym.members.create','gym.members.read','gym.members.update','gym.memberships.manage'].sort());
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function normalize(input){
 if(!input||typeof input!=='object'||Array.isArray(input)||![Object.prototype,null].includes(Object.getPrototypeOf(input)))throw Error('Invalid provisioning input');
 const keys=['requestId','tenantCode','tenantName','tenantType','branchCode','branchName','email','fullName','password'];
 if(Object.keys(input).length!==keys.length||keys.some(k=>typeof input[k]!=='string')||Object.keys(input).some(k=>!keys.includes(k)))throw Error('Invalid provisioning fields');
 const text=(value,min,max)=>{const v=value.trim();if(Array.from(v).length<min||Array.from(v).length>max)throw Error('Invalid provisioning text');return v;};
 const code=value=>{const v=value.trim().toUpperCase();if(!/^[A-Z][A-Z0-9_]{1,29}$/.test(v))throw Error('Invalid tenant or branch code');return v;};
 if(!uuid.test(input.requestId)||!['independent','multi_branch'].includes(input.tenantType))throw Error('Invalid request or tenant type');
 const email=input.email.trim().toLowerCase();if(email.length>255||! /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))throw Error('Invalid owner email');
 if(Array.from(input.password).length<12||input.password.length>256||!input.password.trim())throw Error('Use a separate password of 12 to 256 characters');
 return {requestId:input.requestId.toLowerCase(),tenantCode:code(input.tenantCode),tenantName:text(input.tenantName,2,200),tenantType:input.tenantType,branchCode:code(input.branchCode),branchName:text(input.branchName,2,200),email,fullName:text(input.fullName,2,200),password:input.password};
}
async function guard(client,context){
 const {rows:[r]}=await client.query("SELECT current_database() db,current_user role_name,inet_server_port() port,(pg_control_system()).system_identifier::text system_id");
 if(!context||!Number.isInteger(context.port)||context.port<55432||context.port>55462||r.port!==context.port||r.db!=='gympro_saas'||r.role_name!=='postgres'||r.system_id!==context.systemIdentifier)throw Error('Provisioning currently permits only the explicitly identified isolated cluster');
}
export async function provisionTenant(client,raw,argon2,context){
 const input=normalize(raw);await guard(client,context);const {password,...publicInput}=input;
 const digest=createHash('sha256').update(JSON.stringify(publicInput)).digest('hex');
 await client.query('BEGIN');
 try{
  await client.query('SELECT pg_advisory_xact_lock(81273,hashtext($1)),pg_advisory_xact_lock(81274,hashtext($2))',[input.requestId,input.tenantCode]);
  const existing=(await client.query('SELECT input_sha256,receipt FROM migration_control.provisioning_receipts WHERE request_id=$1',[input.requestId])).rows[0];
  if(existing){
   if(existing.input_sha256!==digest)throw Error('Provisioning request conflict');
   const account=(await client.query('SELECT password_hash FROM app.users WHERE id=$1',[existing.receipt.userId])).rows[0];
   if(!account||!await argon2.verify(account.password_hash,password))throw Error('Provisioning request conflict');
   await client.query('COMMIT');return existing.receipt;
  }
  const permitted=(await client.query('SELECT permission_code FROM app.permissions WHERE is_active AND permission_code=ANY($1::text[]) ORDER BY permission_code',[initialPermissions])).rows.map(x=>x.permission_code);
  if(JSON.stringify(permitted)!==JSON.stringify(initialPermissions))throw Error('Required permission seeds missing or inactive');
  const hash=await argon2.hash(password,{type:argon2.argon2id,memoryCost:19456,timeCost:2,parallelism:1,hashLength:32});
  const tenantId=randomUUID(),branchId=randomUUID(),userId=randomUUID(),membershipId=randomUUID(),roleId=randomUUID();
  await client.query("INSERT INTO platform.tenants(id,tenant_code,tenant_name,tenant_type,contact_email,status) VALUES($1,$2,$3,$4,$5,'active')",[tenantId,input.tenantCode,input.tenantName,input.tenantType,input.email]);
  await client.query("INSERT INTO app.branches(id,tenant_id,branch_code,branch_name,status) VALUES($1,$2,$3,$4,'active')",[branchId,tenantId,input.branchCode,input.branchName]);
  await client.query("INSERT INTO app.users(id,email,password_hash,full_name,status) VALUES($1,$2,$3,$4,'active')",[userId,input.email,hash,input.fullName]);
  await client.query("INSERT INTO app.tenant_memberships(id,tenant_id,user_id,status,joined_at) VALUES($1,$2,$3,'active',clock_timestamp())",[membershipId,tenantId,userId]);
  await client.query("INSERT INTO app.roles(id,tenant_id,role_code,role_name,is_system_role,status) VALUES($1,$2,'OWNER_BOOTSTRAP','Initial gym administrator',true,'active')",[roleId,tenantId]);
  await client.query('INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code=ANY($3::text[])',[tenantId,roleId,initialPermissions]);
  await client.query("INSERT INTO app.role_assignments(tenant_id,membership_id,role_id,scope_type,branch_id) VALUES($1,$2,$3,'tenant',NULL)",[tenantId,membershipId,roleId]);
  const receipt={requestId:input.requestId,tenantId,branchId,userId,membershipId,roleId,tenantCode:input.tenantCode,branchCode:input.branchCode,email:input.email,permissions:[...initialPermissions],createdAt:(await client.query('SELECT clock_timestamp() AS now')).rows[0].now.toISOString()};
  await client.query('INSERT INTO migration_control.provisioning_receipts(request_id,input_sha256,receipt) VALUES($1,$2,$3::jsonb)',[input.requestId,digest,JSON.stringify(receipt)]);
  await client.query('COMMIT');return receipt;
 }catch(error){await client.query('ROLLBACK');throw error;}
}
export async function removeFixture(client,receipt,context){
 await guard(client,context);await client.query('BEGIN');try{
  await client.query('DELETE FROM security.tenant_sessions WHERE tenant_id=$1',[receipt.tenantId]);
  for(const table of ['role_assignments','role_permissions','roles','tenant_memberships','branches'])await client.query(`DELETE FROM app.${table} WHERE tenant_id=$1`,[receipt.tenantId]);
  await client.query('DELETE FROM app.users WHERE id=$1',[receipt.userId]);
  await client.query('DELETE FROM platform.tenants WHERE id=$1',[receipt.tenantId]);
  await client.query('DELETE FROM migration_control.provisioning_receipts WHERE request_id=$1',[receipt.requestId]);
  await client.query('COMMIT');
 }catch(error){await client.query('ROLLBACK');throw error;}
}
