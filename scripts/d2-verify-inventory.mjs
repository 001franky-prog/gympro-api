import {createRequire} from 'node:module';
import {join} from 'node:path';
import {randomUUID,randomBytes} from 'node:crypto';
const require=createRequire(join(process.env.GYMPRO_D2_PROJECT,'package.json'));
const {Client,Pool}=require('pg');
const config={host:'127.0.0.1',port:5432,database:'gympro_saas',user:'postgres',password:process.env.PGPASSWORD,connectionTimeoutMillis:5000,statement_timeout:15000};
const db=new Client(config), pool=new Pool({...config,max:4});
const t='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b', t2='b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const u=randomUUID(),m=randomUUID(),b=randomUUID(),b2=randomUUID(),r=randomUUID(),r2=randomUUID(),session=randomUUID(),hash=randomBytes(32),tag='D2_'+randomUUID().replaceAll('-','').toUpperCase().slice(0,24);
const results=[];let failed=false,connected=false,setup=false,product,created,baseline;
function assert(ok,msg){if(!ok)throw Error(msg);}
async function test(name,fn){try{await fn();results.push({test:name,result:'PASS',detail:''});}catch(e){results.push({test:name,result:'FAIL',detail:e.message});throw e;}}
async function denied(fn,expected){let code;try{await fn();}catch(e){code=e.code;}assert(code===expected,`Expected SQLSTATE ${expected}, received ${code??'success'}`);}
async function runtime(sql,args=[]){const c=await pool.connect();try{await c.query('BEGIN');await c.query('SET LOCAL ROLE gympro_app');const q=await c.query(sql,args);await c.query('COMMIT');return q;}catch(e){await c.query('ROLLBACK');throw e;}finally{c.release();}}
const create=(req,price='1500.00',h=hash,tenant=t)=>runtime('SELECT security.create_inventory_product($1,$2,$3,$4,$5,$6,$7) AS receipt',[h,tenant,tag,'  D2 Test Product  ','  Test description  ',price,req]).then(q=>q.rows[0].receipt);
const update=(req,status='active',price='2000.00')=>runtime('SELECT security.update_inventory_product($1,$2,$3,$4,$5,$6,$7,$8) AS receipt',[hash,t,product,'D2 Updated Product','Updated description',price,status,req]).then(q=>q.rows[0].receipt);
const adjust=(delta,req,reason='D2 stock verification',branch=b,h=hash)=>runtime('SELECT security.adjust_inventory_stock($1,$2,$3,$4,$5,$6,$7) AS receipt',[h,t,branch,product,delta,reason,req]).then(q=>q.rows[0].receipt);
const stock=(branch=b)=>runtime('SELECT security.read_inventory_stock($1,$2,$3,$4) AS receipt',[hash,t,branch,product]).then(q=>q.rows[0].receipt);
async function demo(){return JSON.stringify((await db.query("SELECT jsonb_build_object('members',(SELECT jsonb_agg(to_jsonb(x) ORDER BY id) FROM app.members x WHERE id=ANY($1::uuid[])),'subscription',(SELECT to_jsonb(x) FROM app.member_subscriptions x WHERE id=$2)) AS v",[['3113ab9f-8edd-41f4-afe6-c8f03e291f89','41f45bd6-114c-4241-9be0-0a949dc5f2b6'],'8a28fa97-e41f-4053-be61-8162ff3d387d'])).rows[0].v);}
try{
 await db.connect();connected=true;baseline=await demo();
 await test('01_isolated_fixture_setup',async()=>{
  await db.query('BEGIN');try{
   await db.query("INSERT INTO app.users(id,email,full_name,status) VALUES($1,$2,'D2 inventory fixture','active')",[u,`${u}@example.invalid`]);
   await db.query("INSERT INTO app.tenant_memberships(id,tenant_id,user_id,status,joined_at) VALUES($1,$2,$3,'active',CURRENT_TIMESTAMP)",[m,t,u]);
   for(const [id,suffix]of[[b,'A'],[b2,'B']])await db.query("INSERT INTO app.branches(id,tenant_id,branch_code,branch_name,status) VALUES($1,$2,$3,'D2 fixture branch','active')",[id,t,tag+suffix]);
   for(const [id,suffix]of[[r,'T'],[r2,'B']])await db.query("INSERT INTO app.roles(id,tenant_id,role_code,role_name,is_system_role,status) VALUES($1,$2,$3,'D2 isolated role',false,'active')",[id,t,tag+suffix]);
   await db.query("INSERT INTO app.role_assignments(tenant_id,membership_id,role_id,scope_type,branch_id) VALUES($1,$2,$3,'tenant',NULL),($1,$2,$4,'branch',$5)",[t,m,r,r2,b]);
   await db.query("INSERT INTO security.tenant_sessions(id,tenant_id,membership_id,session_token_hash,created_at,expires_at) VALUES($1,$2,$3,$4,clock_timestamp(),clock_timestamp()+interval '30 minutes')",[session,t,m,hash]);
   await db.query('COMMIT');setup=true;
  }catch(e){await db.query('ROLLBACK');throw e;}
 });
 await test('02_catalog_permission_required',()=>denied(()=>create(randomUUID()),'42501'));
 await test('03_assign_only_required_fixture_permissions',async()=>{
  const q=await db.query("INSERT INTO app.role_permissions(tenant_id,role_id,permission_id) SELECT $1,CASE WHEN permission_code IN ('inventory.products.create','inventory.products.update') THEN $2::uuid ELSE $3::uuid END,id FROM app.permissions WHERE is_active AND permission_code IN ('inventory.products.create','inventory.products.update','inventory.products.read','inventory.stock.adjust')",[t,r,r2]);assert(q.rowCount===4,'Four fixture permissions required');
 });
 await test('04_unknown_session',()=>denied(()=>create(randomUUID(),'1500',randomBytes(32)),'28000'));
 await test('05_wrong_tenant',()=>denied(()=>create(randomUUID(),'1500',hash,t2),'42501'));
 const createReq=randomUUID();
 await test('06_product_creation_normalization',async()=>{created=await create(createReq);product=created.id;assert(created.productName==='D2 Test Product'&&created.description==='Test description'&&created.status==='draft'&&created.salePrice==='1500.00'&&created.currencyCode==='MMK','Invalid created product');});
 await test('07_product_creation_retry',async()=>assert(JSON.stringify(await create(createReq))===JSON.stringify(created),'Create retry changed receipt'));
 await test('08_product_request_conflict',()=>denied(()=>create(createReq,'1501'),'22023'));
 await test('09_excess_price_precision',()=>denied(()=>create(randomUUID(),'1.001'),'22023'));
 await test('10_draft_stock_adjustment_denied',()=>denied(()=>adjust(10,randomUUID()),'22023'));
 const updateReq=randomUUID();let updated;
 await test('11_activate_product_and_retry',async()=>{updated=await update(updateReq);assert(updated.status==='active'&&updated.salePrice==='2000.00','Product update failed');assert(JSON.stringify(updated)===JSON.stringify(await update(updateReq)),'Update retry changed receipt');});
 await test('12_create_retry_preserves_original_draft_receipt',async()=>assert(JSON.stringify(created)===JSON.stringify(await create(createReq)),'Old create retry returned current product'));
 await test('13_update_request_conflict',()=>denied(()=>update(updateReq,'inactive'),'22023'));
 await test('14_branch_product_read_and_no_tenant_scope',async()=>{
  const q=await runtime('SELECT * FROM security.read_inventory_products($1,$2,$3,$4,$5)',[hash,t,b,null,100]);assert(q.rows.some(x=>x.id===product&&x.sale_price==='2000.00'),'Branch catalog missing product');
  await denied(()=>runtime('SELECT * FROM security.read_inventory_products($1,$2,NULL,NULL,25)',[hash,t]),'42501');
 });
 await test('15_unassigned_branch_denied',async()=>{await denied(()=>stock(b2),'42501');await denied(()=>adjust(10,randomUUID(),'D2 stock verification',b2),'42501');});
 await test('16_initial_stock_zero',async()=>assert((await stock()).quantity==='0','Initial stock nonzero'));
 const stockReq=randomUUID();let first;
 await test('17_stock_receipt_and_retry',async()=>{first=await adjust(10,stockReq,'  D2 stock verification  ');assert(first.balanceAfter==='10'&&first.reason==='D2 stock verification','Adjustment normalization failed');assert(JSON.stringify(first)===JSON.stringify(await adjust(10,stockReq)),'Adjustment retry changed receipt');});
 await test('18_request_reuse_conflict',()=>denied(()=>adjust(11,stockReq),'22023'));
 await test('19_negative_stock_prevented',async()=>{await denied(()=>adjust(-11,randomUUID()),'22023');assert((await stock()).quantity==='10','Rejected withdrawal changed stock');});
 await test('20_concurrent_withdrawals_cannot_oversell',async()=>{
  const q=await Promise.allSettled([adjust(-7,randomUUID()),adjust(-7,randomUUID())]);assert(q.filter(x=>x.status==='fulfilled').length===1&&q.filter(x=>x.status==='rejected'&&x.reason.code==='22023').length===1,'Concurrent withdrawals were not serialized');assert((await stock()).quantity==='3','Wrong concurrent withdrawal balance');
 });
 await test('21_concurrent_same_request_saved_once',async()=>{const req=randomUUID();const [a,c]=await Promise.all([adjust(5,req),adjust(5,req)]);assert(JSON.stringify(a)===JSON.stringify(c)&&(await stock()).quantity==='8','Concurrent retry duplicated adjustment');});
 await test('22_old_stock_retry_is_immutable',async()=>assert(JSON.stringify(first)===JSON.stringify(await adjust(10,stockReq))&&(await stock()).quantity==='8','Old receipt changed or reapplied stock'));
 await test('23_zero_and_blank_adjustments_denied',async()=>{await denied(()=>adjust(0,randomUUID()),'22023');await denied(()=>adjust(1,randomUUID(),'\t\t'),'22023');});
 await test('24_inactive_branch_denied',async()=>{await db.query("UPDATE app.branches SET status='inactive' WHERE id=$1",[b]);try{await denied(()=>stock(),'42501');await denied(()=>adjust(10,stockReq),'42501');}finally{await db.query("UPDATE app.branches SET status='active' WHERE id=$1",[b]);}});
 await test('25_expired_session_denied',async()=>{
  const old=(await db.query('SELECT created_at,expires_at FROM security.tenant_sessions WHERE id=$1',[session])).rows[0];
  await db.query("UPDATE security.tenant_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE id=$1",[session]);
  try{await denied(()=>stock(),'28000');await denied(()=>adjust(10,stockReq),'28000');}finally{await db.query('UPDATE security.tenant_sessions SET created_at=$2,expires_at=$3 WHERE id=$1',[session,old.created_at,old.expires_at]);}
 });
 await test('26_revoked_session_denied',async()=>{await db.query('UPDATE security.tenant_sessions SET revoked_at=clock_timestamp() WHERE id=$1',[session]);try{await denied(()=>stock(),'28000');await denied(()=>adjust(10,stockReq),'28000');}finally{await db.query('UPDATE security.tenant_sessions SET revoked_at=NULL WHERE id=$1',[session]);}});
 await test('27_no_direct_runtime_table_access',async()=>{for(const table of ['inventory_products','inventory_stock_movements','inventory_product_events'])await denied(()=>runtime(`SELECT 1 FROM app.${table}`),'42501');});
 await test('28_audit_and_exact_movement_counts',async()=>{
  const q=(await db.query('SELECT quantity_delta,balance_after::text,actor_membership_id,actor_snapshot,product_snapshot FROM app.inventory_stock_movements WHERE tenant_id=$1 AND product_id=$2 ORDER BY created_at,id',[t,product])).rows;
  assert(q.length===3&&q.reduce((a,x)=>a+x.quantity_delta,0)===8&&q.every(x=>x.actor_membership_id===m&&x.actor_snapshot.userId===u&&x.product_snapshot.salePrice==='2000.00'),'Stock audit/count mismatch');
  assert((await db.query('SELECT count(*)::int AS n FROM app.inventory_product_events WHERE tenant_id=$1 AND product_id=$2',[t,product])).rows[0].n===2,'Duplicate product events');
 });
 await test('29_inactive_product_denies_new_adjustment_preserves_retry',async()=>{await update(randomUUID(),'inactive');await denied(()=>adjust(1,randomUUID()),'22023');assert(JSON.stringify(first)===JSON.stringify(await adjust(10,stockReq)),'Inactive product invalidated original receipt');});
 await test('30_existing_demo_unchanged',async()=>assert(await demo()===baseline,'Existing demo records changed'));
}catch(e){failed=true;if(!results.some(x=>x.result==='FAIL'))results.push({test:'setup_or_execution',result:'FAIL',detail:e.message});}
finally{
 if(connected){try{
  await db.query('BEGIN');
  const ids=(await db.query('SELECT id FROM app.inventory_products WHERE tenant_id=$1 AND sku LIKE $2',[t,tag+'%'])).rows.map(x=>x.id);
  await db.query('DELETE FROM app.inventory_stock_movements WHERE tenant_id=$1 AND product_id=ANY($2::uuid[])',[t,ids]);
  await db.query('DELETE FROM app.inventory_product_events WHERE tenant_id=$1 AND product_id=ANY($2::uuid[])',[t,ids]);
  await db.query('DELETE FROM app.inventory_products WHERE tenant_id=$1 AND id=ANY($2::uuid[])',[t,ids]);
  await db.query('DELETE FROM security.tenant_sessions WHERE id=$1',[session]);
  await db.query('DELETE FROM app.role_assignments WHERE tenant_id=$1 AND membership_id=$2 AND role_id=ANY($3::uuid[])',[t,m,[r,r2]]);
  await db.query('DELETE FROM app.role_permissions WHERE tenant_id=$1 AND role_id=ANY($2::uuid[])',[t,[r,r2]]);
  await db.query('DELETE FROM app.roles WHERE tenant_id=$1 AND id=ANY($2::uuid[])',[t,[r,r2]]);
  await db.query('DELETE FROM app.tenant_memberships WHERE tenant_id=$1 AND id=$2',[t,m]);
  await db.query('DELETE FROM app.users WHERE id=$1',[u]);
  await db.query('DELETE FROM app.branches WHERE tenant_id=$1 AND id=ANY($2::uuid[])',[t,[b,b2]]);
  const left=(await db.query('SELECT (SELECT count(*) FROM app.inventory_products WHERE tenant_id=$1 AND sku LIKE $2)+(SELECT count(*) FROM app.users WHERE id=$3)+(SELECT count(*) FROM app.branches WHERE id=ANY($4::uuid[]))+(SELECT count(*) FROM security.tenant_sessions WHERE id=$5) AS n',[t,tag+'%',u,[b,b2],session])).rows[0].n;
  assert(Number(left)===0,'Fixture records remain');await db.query('COMMIT');results.push({test:'31_fixture_cleanup',result:'PASS',detail:''});
 }catch(e){await db.query('ROLLBACK');failed=true;results.push({test:'31_fixture_cleanup',result:'FAIL',detail:e.message});console.log('Retain fixture IDs for cleanup:',JSON.stringify({u,m,b,b2,r,r2,session,tag}));}
 await db.end();}
 await pool.end();
 console.table(results);
 if(failed){console.error('FAIL: D2 verification failed. Retain reports; functions may already be installed.');process.exitCode=1;}else{console.log('PASS: D2 product operations, branch stock authorization, concurrency and audit verification completed.');console.log('PASS: Fixture records removed; existing demo records unchanged.');}
}