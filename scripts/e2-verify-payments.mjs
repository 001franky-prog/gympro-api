import {createRequire} from 'node:module';
import {join} from 'node:path';
import {writeFileSync} from 'node:fs';
import {randomUUID,randomBytes} from 'node:crypto';
const require=createRequire(join(process.env.GYMPRO_E2_PROJECT,'package.json'));
const {Client}=require('pg');
const config={host:'127.0.0.1',port:5432,database:'gympro_saas',user:'postgres',password:process.env.PGPASSWORD,connectionTimeoutMillis:6000,statement_timeout:20000};
const db=new Client(config),ids=Object.fromEntries(['user','membership','branch','otherBranch','role','tenantRole','session','sale','raceSale','otherSale','member','subscription','generalMember','generalSub','focMember','focSub','renewal'].map(k=>[k,randomUUID()]));
const t='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b',t2='b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc',hash=randomBytes(32),tag='E2_'+randomUUID().replaceAll('-','').slice(0,20).toUpperCase();
const results=[];let failed=false,connected=false,baseline;let charge,raceCharge,receipt,memberCharge,renewalCharge,generalCharge,request=randomUUID(),raceReceipt;
const check=(ok,msg)=>{if(!ok)throw Error(msg)};
async function test(name,fn){try{await fn();results.push({test:name,result:'PASS',detail:''})}catch(e){results.push({test:name,result:'FAIL',detail:e.message});throw e}}
async function invoke(name,args,h=hash){const c=new Client(config);await c.connect();try{await c.query('BEGIN');await c.query('SET LOCAL ROLE gympro_app');const v=await c.query(`SELECT security.${name}(${[h,...args].map((_,i)=>'$'+(i+1)).join(',')}) AS v`,[h,...args]);await c.query('COMMIT');return v.rows[0].v}catch(e){await c.query('ROLLBACK');throw e}finally{await c.end()}}
async function deny(fn,code){try{await fn()}catch(e){check(e.code===code,`Expected ${code}, received ${e.code}: ${e.message}`);return}throw Error('Rejected request unexpectedly accepted')}
const open=(source=ids.sale,kind='pos_sale',req=randomUUID(),branch=ids.branch,tenant=t,h=hash)=>invoke('open_payment_charge',[tenant,branch,kind,source,req],h);
const pay=(amount,req=randomUUID(),ch=charge,method='cash',ref=null,branch=ids.branch,h=hash)=>invoke('record_payment_receipt',[t,branch,ch.id,amount,method,ref,req],h);
const read=(ch=charge,branch=ids.branch,h=hash)=>invoke('read_payment_charge',[t,branch,ch.id],h);
async function demo(){return JSON.stringify((await db.query("SELECT jsonb_build_object('members',(SELECT jsonb_agg(to_jsonb(m) ORDER BY id) FROM app.members m WHERE id=ANY($1::uuid[])),'subscription',(SELECT to_jsonb(s) FROM app.member_subscriptions s WHERE id=$2)) AS v",[['3113ab9f-8edd-41f4-afe6-c8f03e291f89','41f45bd6-114c-4241-9be0-0a949dc5f2b6'],'8a28fa97-e41f-4053-be61-8162ff3d387d'])).rows[0].v)}
try{
 await db.connect();connected=true;baseline=await demo();
 await test('01_isolated_fixture_setup',async()=>{
  await db.query('BEGIN');try{
   const argon2=require('argon2'),pw=await argon2.hash(randomBytes(32).toString('hex'));
   await db.query("INSERT INTO app.users(id,email,full_name,password_hash,status) VALUES($1,$2,'E2 payment fixture',$3,'active')",[ids.user,tag+'@example.invalid',pw]);
   await db.query("INSERT INTO app.tenant_memberships(id,tenant_id,user_id,status,joined_at) VALUES($1,$2,$3,'active',clock_timestamp())",[ids.membership,t,ids.user]);
   for(const [id,suffix]of[[ids.branch,'A'],[ids.otherBranch,'B']])await db.query("INSERT INTO app.branches(id,tenant_id,branch_code,branch_name,status) VALUES($1,$2,$3,'E2 payment fixture','active')",[id,t,tag+suffix]);
   for(const [id,suffix]of[[ids.role,'B'],[ids.tenantRole,'T']])await db.query("INSERT INTO app.roles(id,tenant_id,role_code,role_name,is_system_role,status) VALUES($1,$2,$3,'E2 payment fixture',false,'active')",[id,t,tag+suffix]);
   await db.query("INSERT INTO app.role_assignments(tenant_id,membership_id,role_id,scope_type,branch_id) VALUES($1,$2,$3,'branch',$4)",[t,ids.membership,ids.role,ids.branch]);
   await db.query("INSERT INTO security.tenant_sessions(id,tenant_id,membership_id,session_token_hash,created_at,expires_at) VALUES($1,$2,$3,$4,clock_timestamp(),clock_timestamp()+interval '30 minutes')",[ids.session,t,ids.membership,hash]);
   for(const [id,branch]of[[ids.sale,ids.branch],[ids.raceSale,ids.branch],[ids.otherSale,ids.otherBranch]])await db.query("INSERT INTO app.pos_sales(id,tenant_id,branch_id,request_id,input_cart,total_amount,actor_membership_id,actor_snapshot) VALUES($1,$2,$3,$4,'[{\"fixture\":true}]',1000,$5,'{\"fixture\":\"E2\"}')",[id,t,branch,randomUUID(),ids.membership]);
   const plan=(await db.query('SELECT plan_id,plan_price_id FROM app.member_subscriptions WHERE tenant_id=$1 LIMIT 1',[t])).rows[0];check(plan,'Verified membership fixture source is required');
   for(const [mem,sub,branch,kind,price]of[[ids.member,ids.subscription,ids.branch,'standard',1000],[ids.generalMember,ids.generalSub,null,'standard',1000],[ids.focMember,ids.focSub,ids.branch,'foc',0]]){
    await db.query("INSERT INTO app.members(id,tenant_id,branch_id,full_name,phone,status) VALUES($1,$2,$3,'E2 member fixture','09900000000','active')",[mem,t,branch]);
    await db.query("INSERT INTO app.member_subscriptions(id,tenant_id,member_id,branch_id,plan_id,plan_price_id,duration_value,duration_unit,agreed_price_amount,status,starts_on,ends_on,activated_at,membership_kind) VALUES($1,$2,$3,$4,$5,$6,1,'months',$7,'active',CURRENT_DATE,CURRENT_DATE+30,clock_timestamp(),$8)",[sub,t,mem,branch,plan.plan_id,plan.plan_price_id,price,kind]);
   }
   await db.query("INSERT INTO app.subscription_renewals(id,tenant_id,subscription_id,request_id,plan_id,plan_price_id,previous_ends_on,renewal_starts_on,renewal_ends_on,duration_value,duration_unit,agreed_price_amount,previous_subscription_snapshot) SELECT $1,tenant_id,id,$2,plan_id,plan_price_id,ends_on,ends_on,ends_on+30,1,'months',2000,to_jsonb(s) FROM app.member_subscriptions s WHERE id=$3",[ids.renewal,randomUUID(),ids.subscription]);
   await db.query('UPDATE app.member_subscriptions SET agreed_price_amount=2500,ends_on=ends_on+30 WHERE id=$1',[ids.subscription]);
   await db.query('COMMIT');
  }catch(e){await db.query('ROLLBACK');throw e}
 });
 await test('02_missing_payment_permission',()=>deny(()=>open(),'42501'));
 await test('03_assign_only_fixture_payment_permissions',async()=>{await db.query("INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE is_active AND permission_code IN ('finance.payments.record','finance.payments.read')",[t,ids.role])});
 await test('04_unknown_session',()=>deny(()=>open(ids.sale,'pos_sale',randomUUID(),ids.branch,t,randomBytes(32)),'28000'));
 await test('05_wrong_tenant',()=>deny(()=>open(ids.sale,'pos_sale',randomUUID(),ids.branch,t2),'42501'));
 await test('06_unassigned_branch',()=>deny(()=>open(ids.otherSale,'pos_sale',randomUUID(),ids.otherBranch),'42501'));
 await test('07_source_route_branch_mismatch',()=>deny(()=>open(ids.otherSale),'42501'));
 await test('08_unknown_source',()=>deny(()=>open(randomUUID()),'22023'));
 await test('09_server_sale_charge',async()=>{charge=await open(ids.sale,'pos_sale',request);check(charge.amountDue==='1000.00'&&charge.saleId===ids.sale&&charge.branchId===ids.branch,'Original sale price mismatch');check(!('sourceSnapshot'in charge)&&!('actorSnapshot'in charge),'Private fields exposed')});
 await test('10_charge_retry_immutable',async()=>check(JSON.stringify(await open(ids.sale,'pos_sale',request))===JSON.stringify(charge),'Charge retry changed'));
 await test('11_charge_request_reuse_conflict',()=>deny(()=>open(ids.raceSale,'pos_sale',request),'22023'));
 await test('12_second_charge_for_same_sale_rejected',()=>deny(()=>open(),'22023'));
 await test('13_initial_outstanding_balance',async()=>{const b=await read();check(Number(b.outstandingAmount)===1000&&Number(b.netReceivedAmount)===0,'Initial balance incorrect')});
 let firstReq=randomUUID();
 await test('14_partial_cash_payment',async()=>{receipt=await pay('400.00',firstReq);check(receipt.amount==='400.00'&&receipt.chargeId===charge.id,'Cash receipt mismatch')});
 await test('15_receipt_retry_immutable',async()=>check(JSON.stringify(await pay('400.00',firstReq))===JSON.stringify(receipt),'Receipt retry changed'));
 await test('16_receipt_request_conflict',()=>deny(()=>pay('401.00',firstReq),'22023'));
 await test('17_overpayment_rejected',()=>deny(()=>pay('600.01'),'22023'));
 await test('18_nonpositive_and_nonfinite_amounts',async()=>{for(const v of ['0','-1','NaN','Infinity'])await deny(()=>pay(v),'22023')});
 await test('19_excess_precision_rejected',()=>deny(()=>pay('0.001'),'22023'));
 await test('20_transfer_reference_required',()=>deny(()=>pay('100',randomUUID(),charge,'bank_transfer',null),'22023'));
 await test('21_normalized_transfer_and_retry',async()=>{const req=randomUUID(),a=await pay('100',req,charge,'bank_transfer','  E2-reference  '),b=await pay('100',req,charge,'bank_transfer','E2-reference');check(a.externalReference==='E2-reference'&&JSON.stringify(a)===JSON.stringify(b),'Transfer normalization/retry mismatch')});
 await test('22_exact_partial_balance',async()=>{const b=await read();check(Number(b.receivedAmount)===500&&Number(b.outstandingAmount)===500,'Partial balance mismatch')});
 await test('23_receipt_read_public_fields',async()=>{const v=await invoke('read_payment_receipt',[t,ids.branch,receipt.id]);check(JSON.stringify(v)===JSON.stringify(receipt)&&!('actorSnapshot'in v),'Receipt read mismatch')});
 await test('24_dedicated_read_permission_required',async()=>{await db.query("DELETE FROM app.role_permissions WHERE role_id=$1 AND permission_id IN (SELECT id FROM app.permissions WHERE permission_code='finance.payments.read')",[ids.role]);try{await deny(()=>read(),'42501')}finally{await db.query("INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code='finance.payments.read'",[t,ids.role])}});
 await test('25_concurrent_payments_cannot_overpay',async()=>{raceCharge=await open(ids.raceSale);const r=await Promise.allSettled([pay('600',randomUUID(),raceCharge),pay('600',randomUUID(),raceCharge)]);check(r.filter(x=>x.status==='fulfilled').length===1&&r.filter(x=>x.status==='rejected'&&x.reason.code==='22023').length===1,'Concurrent overpayment protection failed');check(Number((await read(raceCharge)).receivedAmount)===600,'Concurrent amount mismatch')});
 await test('26_concurrent_identical_retry_saved_once',async()=>{const req=randomUUID();const r=await Promise.all([pay('150',req,raceCharge),pay('150',req,raceCharge)]);raceReceipt=r[0];check(JSON.stringify(r[0])===JSON.stringify(r[1]),'Concurrent retry returned different receipts');check(Number((await read(raceCharge)).receivedAmount)===750,'Duplicate concurrent receipt')});
 await test('27_final_balance_and_settled_rejection',async()=>{await pay('250',randomUUID(),raceCharge);check(Number((await read(raceCharge)).outstandingAmount)===0,'Final balance wrong');await deny(()=>pay('1',randomUUID(),raceCharge),'22023')});
 await test('28_return_reduces_payable_and_blocks_collection',async()=>{await db.query("INSERT INTO app.pos_sale_returns(tenant_id,branch_id,sale_id,request_id,action_code,reason,input_items,total_amount,actor_membership_id,actor_snapshot) VALUES($1,$2,$3,$4,'refund','E2 rollback fixture','[{\"fixture\":true}]',200,$5,'{\"fixture\":\"E2\"}')",[t,ids.branch,ids.raceSale,randomUUID(),ids.membership]);const v=await read(raceCharge);check(Number(v.payableAmount)===800&&Number(v.refundDueAmount)===200,'POS return balance mismatch');await deny(()=>pay('1',randomUUID(),raceCharge),'22023')});
 await test('29_old_receipt_retry_survives_pos_return',async()=>check(JSON.stringify(await pay('150',raceReceipt.requestId,raceCharge))===JSON.stringify(raceReceipt),'Old retry changed after return'));
 await test('30_activation_uses_original_pre_renewal_price',async()=>{memberCharge=await open(ids.subscription,'membership_activation');check(memberCharge.amountDue==='1000.00','Activation incorrectly used current renewal price')});
 await test('31_renewal_uses_original_agreed_price',async()=>{renewalCharge=await open(ids.renewal,'membership_renewal');check(renewalCharge.amountDue==='2000.00'&&renewalCharge.renewalId===ids.renewal,'Renewal original price mismatch')});
 await test('32_foc_zero_charge_cannot_collect',async()=>{const c=await open(ids.focSub,'membership_activation');check(c.amountDue==='0.00','FOC charge not zero');await deny(()=>pay('1',randomUUID(),c),'22023')});
 await test('33_branch_staff_cannot_collect_tenant_membership',()=>deny(()=>open(ids.generalSub,'membership_activation'),'42501'));
 await test('34_tenant_permission_allows_general_membership',async()=>{await db.query("INSERT INTO app.role_assignments(tenant_id,membership_id,role_id,scope_type,branch_id) VALUES($1,$2,$3,'tenant',NULL)",[t,ids.membership,ids.tenantRole]);await db.query("INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,$2,id FROM app.permissions WHERE permission_code IN ('finance.payments.record','finance.payments.read')",[t,ids.tenantRole]);generalCharge=await open(ids.generalSub,'membership_activation');await pay('100',randomUUID(),generalCharge);check(Number((await read(generalCharge)).outstandingAmount)===900,'Tenant membership collection failed');await db.query('DELETE FROM app.role_assignments WHERE role_id=$1',[ids.tenantRole])});
 await test('35_inactive_branch_denies_retries',async()=>{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[ids.branch]);try{await deny(()=>read(),'42501');await deny(()=>pay('400',firstReq),'42501')}finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[ids.branch])}});
 await test('36_expired_session_denied',async()=>{const old=(await db.query('SELECT created_at,expires_at FROM security.tenant_sessions WHERE id=$1',[ids.session])).rows[0];await db.query("UPDATE security.tenant_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1",[ids.session]);try{await deny(()=>read(),'28000')}finally{await db.query('UPDATE security.tenant_sessions SET created_at=$2,expires_at=$3 WHERE id=$1',[ids.session,old.created_at,old.expires_at])}});
 await test('37_revoked_session_retry_denied',async()=>{await db.query('UPDATE security.tenant_sessions SET revoked_at=clock_timestamp() WHERE id=$1',[ids.session]);try{await deny(()=>pay('400',firstReq),'28000')}finally{await db.query('UPDATE security.tenant_sessions SET revoked_at=NULL WHERE id=$1',[ids.session])}});
 await test('38_runtime_function_only_and_restricted_owner',async()=>{for(const table of ['payment_charges','payment_receipts','payment_reversals']){check(!(await db.query("SELECT has_table_privilege('gympro_app',$1,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') AS v",['app.'+table])).rows[0].v,'Direct runtime table privilege')}for(const sig of ['payment_session(bytea,uuid,uuid,text)','payment_charge_json(uuid,uuid)','payment_receipt_json(uuid,uuid)'])check(!(await db.query("SELECT has_function_privilege('gympro_app',$1,'EXECUTE') AS v",['security.'+sig])).rows[0].v,'Private helper executable');const r=(await db.query("SELECT rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication AS bad FROM pg_roles WHERE rolname='gympro_payment_owner'")).rows[0];check(r&&!r.bad,'Unsafe payment owner');check((await db.query("SELECT count(*)::int AS n FROM pg_auth_members WHERE roleid='gympro_payment_owner'::regrole OR member='gympro_payment_owner'::regrole")).rows[0].n===0,'Unexpected owner membership')});
 await test('39_saved_audit_and_exact_receipts',async()=>{const r=(await db.query("SELECT count(*)::int n,bool_and(actor_membership_id=$1 AND actor_snapshot->>'membershipId'=$1::text AND actor_snapshot->>'sessionId'=$2::text) AS audited FROM app.payment_receipts WHERE tenant_id=$3 AND charge_id=$4",[ids.membership,ids.session,t,raceCharge.id])).rows[0];check(r.n===3&&r.audited,'Receipt counts/actor audit mismatch')});
 await test('40_existing_demo_unchanged',async()=>check(await demo()===baseline,'Existing demo changed'));
}catch(e){failed=true;if(!results.some(r=>r.result==='FAIL'))results.push({test:'setup_or_execution',result:'FAIL',detail:e.message})}
finally{
 if(connected){try{
  await db.query('BEGIN');
  const subs=[ids.subscription,ids.generalSub,ids.focSub],sales=[ids.sale,ids.raceSale,ids.otherSale];
  await db.query('DELETE FROM app.payment_reversals WHERE tenant_id=$1 AND receipt_id IN(SELECT r.id FROM app.payment_receipts r JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id WHERE c.tenant_id=$1 AND(c.sale_id=ANY($2::uuid[]) OR c.subscription_id=ANY($3::uuid[])))',[t,sales,subs]);
  await db.query('DELETE FROM app.payment_receipts WHERE tenant_id=$1 AND charge_id IN(SELECT id FROM app.payment_charges WHERE tenant_id=$1 AND(sale_id=ANY($2::uuid[]) OR subscription_id=ANY($3::uuid[])))',[t,sales,subs]);
  await db.query('DELETE FROM app.payment_charges WHERE tenant_id=$1 AND(sale_id=ANY($2::uuid[]) OR subscription_id=ANY($3::uuid[]))',[t,sales,subs]);
  await db.query('DELETE FROM app.pos_sale_returns WHERE tenant_id=$1 AND sale_id=ANY($2::uuid[])',[t,sales]);
  await db.query('DELETE FROM app.pos_sales WHERE tenant_id=$1 AND id=ANY($2::uuid[])',[t,sales]);
  await db.query('DELETE FROM app.subscription_renewals WHERE id=$1',[ids.renewal]);
  await db.query('DELETE FROM app.member_subscriptions WHERE id=ANY($1::uuid[])',[subs]);
  await db.query('DELETE FROM app.members WHERE id=ANY($1::uuid[])',[[ids.member,ids.generalMember,ids.focMember]]);
  await db.query('DELETE FROM security.tenant_sessions WHERE id=$1',[ids.session]);
  await db.query('DELETE FROM app.role_assignments WHERE role_id=ANY($1::uuid[])',[[ids.role,ids.tenantRole]]);
  await db.query('DELETE FROM app.role_permissions WHERE role_id=ANY($1::uuid[])',[[ids.role,ids.tenantRole]]);
  await db.query('DELETE FROM app.roles WHERE id=ANY($1::uuid[])',[[ids.role,ids.tenantRole]]);
  await db.query('DELETE FROM app.tenant_memberships WHERE id=$1',[ids.membership]);await db.query('DELETE FROM app.users WHERE id=$1',[ids.user]);
  await db.query('DELETE FROM app.branches WHERE id=ANY($1::uuid[])',[[ids.branch,ids.otherBranch]]);
  await db.query('COMMIT');
  check((await db.query('SELECT count(*)::int n FROM app.branches WHERE id=ANY($1::uuid[])',[[ids.branch,ids.otherBranch]])).rows[0].n===0,'Cleanup incomplete');
  if(baseline!==undefined)check(await demo()===baseline,'Demo changed after cleanup');
  results.push({test:'41_fixture_cleanup_and_demo_preserved',result:'PASS',detail:''});
 }catch(e){failed=true;try{await db.query('ROLLBACK')}catch{}results.push({test:'41_fixture_cleanup_and_demo_preserved',result:'FAIL',detail:e.message});console.error('Retain fixture IDs:',JSON.stringify(ids))}await db.end()}
 console.table(results);
 const summary={phase:'E',step:'E2',passed:!failed&&results.length===41,checks:results,verifiedAt:new Date().toISOString(),databaseFunctionsOnly:true,paymentReversalFunctionInstalled:false,nestApiInstalled:false};
 writeFileSync(join(process.env.GYMPRO_E2_REPORT,'e2-summary.json'),JSON.stringify(summary,null,2));
 if(!summary.passed){console.error('FAIL: E2 verification incomplete; retain reports and review the first failure.');process.exitCode=1}else console.log('PASS: E2 authorized charges, partial payments, exact balances, concurrency, immutable retries and fixture cleanup verified (41 checks).');
}
