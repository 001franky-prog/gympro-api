param([string]$ProjectPath='C:\Projects\gympro-api',[string]$BackupRoot='C:\Projects\gympro-backups',[string]$PostgresBin='C:\Program Files\PostgreSQL\18\bin',[string]$GitPath='C:\Program Files\Git\cmd\git.exe')
$ErrorActionPreference='Stop';$exitCode=1;$credential=$null;$folder=$null;$transcribing=$false;$testCreated=$false;$testRemoved=$false;$testDb=$null
$priorPgPassword=[Environment]::GetEnvironmentVariable('PGPASSWORD','Process')
function Invoke-GymProE8([string]$Command,[string[]]$Arguments){& $Command @Arguments;if($LASTEXITCODE -ne 0){throw "Command failed ($LASTEXITCODE): $Command"}}
try{
 Set-Location -LiteralPath $ProjectPath
 $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,3000);try{$listener.Start()}catch{throw 'Stop the running API/operator with Ctrl+C before this recovery checkpoint.'}finally{$listener.Stop()}
 foreach($exe in @($GitPath,(Join-Path $PostgresBin 'pg_dump.exe'),(Join-Path $PostgresBin 'pg_dumpall.exe'),(Join-Path $PostgresBin 'pg_restore.exe'),(Join-Path $PostgresBin 'psql.exe'),(Join-Path $PostgresBin 'createdb.exe'),(Join-Path $PostgresBin 'dropdb.exe'))){if(-not(Test-Path -LiteralPath $exe)){throw "Required tool missing: $exe"}}
 $commit=(& $GitPath rev-parse HEAD|Out-String).Trim();if($LASTEXITCODE -ne 0){throw 'Git checkpoint lookup failed.'};$subject=(& $GitPath log -1 --format=%s|Out-String).Trim();if($LASTEXITCODE -ne 0){throw 'Git subject lookup failed.'}
 Invoke-GymProE8 $GitPath @('merge-base','--is-ancestor','825413d','HEAD')
 $tracked=@(& $GitPath status --porcelain --untracked-files=no);if($LASTEXITCODE -ne 0){throw 'Git state inspection failed.'};if($tracked.Count){$tracked|ForEach-Object{Write-Host $_};throw 'Tracked changes remain. Commit or inspect them before the recovery checkpoint.'}
 $required=@('src/inventory/inventory-history.service.ts','src/inventory/inventory-history.controller.ts','src/inventory/inventory.module.ts','src/pos/pos-return.service.ts','src/pos/pos-history.service.ts','src/pos/pos-ui.controller.ts','web/inventory/app.js','web/pos/app.js','sql/d9-install-stock-history.sql','sql/d5-install-pos-returns.sql','scripts/d9-verify-stock-history-api.mjs','src/payments/payment.service.ts','src/payments/payment-reversal.service.ts','src/payments/payment-reporting.service.ts','src/payments/payment-reconciliation.service.ts','src/payments/payment-ui.controller.ts','src/payments/payments.module.ts','web/payments/app.js','web/payments/index.html','web/payments/style.css','sql/e1-install-payment-foundation.sql','sql/e2-install-payment-functions.sql','sql/e4-install-payment-reversals.sql','sql/e5-install-payment-reporting.sql','sql/e6-install-payment-reconciliation.sql','scripts/e6-verify-payment-reconciliation-api.mjs','scripts/e7-verify-payment-ui.mjs')
 foreach($file in $required){Invoke-GymProE8 $GitPath @('ls-files','--error-unmatch','--',$file)}
 $folder=Join-Path $BackupRoot ('e8-recovery-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6));New-Item -ItemType Directory -Path $folder | Out-Null
 Start-Transcript -Path (Join-Path $folder 'recovery-report.txt') | Out-Null;$transcribing=$true
 Write-Progress -Activity 'Gym Pro E8 recovery checkpoint' -Status 'Backing up and restoring committed source history' -PercentComplete 10
 $bundle=Join-Path $folder 'gympro-source.bundle';Invoke-GymProE8 $GitPath @('bundle','create',$bundle,'--all');Invoke-GymProE8 $GitPath @('bundle','verify',$bundle)
 $clone=Join-Path $folder 'source-restore-check';Invoke-GymProE8 $GitPath @('clone','--no-checkout','--quiet',$bundle,$clone);Invoke-GymProE8 $GitPath @('-C',$clone,'fsck','--full');Invoke-GymProE8 $GitPath @('-C',$clone,'cat-file','-e',($commit+'^{commit}'))
 foreach($file in $required){Invoke-GymProE8 $GitPath @('-C',$clone,'cat-file','-e',($commit+':'+$file))}
 $untracked=@(& $GitPath ls-files --others --exclude-standard);if($LASTEXITCODE -ne 0){throw 'Untracked file listing failed.'};$untracked|Set-Content (Join-Path $folder 'untracked-not-in-source-bundle.txt') -Encoding UTF8
 $credential=[System.Management.Automation.PSCredential]::new('postgres',(Read-Host 'Local PostgreSQL postgres password' -AsSecureString));$env:PGPASSWORD=$credential.GetNetworkCredential().Password
 $fingerSql=@'
\pset pager off
SET TIME ZONE 'UTC';
SET DateStyle TO 'ISO, YMD';
SELECT 'payment_charges|'||count(*)||'|'||md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY id),'')) FROM app.payment_charges x
UNION ALL SELECT 'payment_receipts|'||count(*)||'|'||md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY id),'')) FROM app.payment_receipts x
UNION ALL SELECT 'payment_reversals|'||count(*)||'|'||md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY id),'')) FROM app.payment_reversals x
UNION ALL SELECT 'payment_reconciliations|'||count(*)||'|'||md5(coalesce(string_agg(to_jsonb(x)::text,E'\n' ORDER BY id),'')) FROM app.payment_reconciliations x
ORDER BY 1;
'@
 $fingerPath=Join-Path $folder 'payment-ledger-fingerprint.sql';[IO.File]::WriteAllText($fingerPath,$fingerSql,[Text.UTF8Encoding]::new($false))
 $originalFingerprint=@(& (Join-Path $PostgresBin 'psql.exe') -X -w -h 127.0.0.1 -p 5432 -U postgres -d gympro_saas -v ON_ERROR_STOP=1 -A -t -f $fingerPath);if($LASTEXITCODE -ne 0){throw 'Payment fingerprint failed.'}
 $originalFingerprint|Set-Content (Join-Path $folder 'payment-original-fingerprint.txt') -Encoding UTF8
 $dump=Join-Path $folder 'gympro_saas.dump';$roles=Join-Path $folder 'roles-without-passwords.sql'
 Write-Progress -Activity 'Gym Pro E8 recovery checkpoint' -Status 'Backing up database and password-free roles' -PercentComplete 30
 Invoke-GymProE8 (Join-Path $PostgresBin 'pg_dump.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','-d','gympro_saas','-Fc','-f',$dump)
 $listing=& (Join-Path $PostgresBin 'pg_restore.exe') --list $dump;if($LASTEXITCODE -ne 0){throw 'Archive listing failed.'};$listing|Set-Content (Join-Path $folder 'archive-list.txt') -Encoding UTF8
 Invoke-GymProE8 (Join-Path $PostgresBin 'pg_dumpall.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','-l','gympro_saas','--roles-only','--no-role-passwords','-f',$roles)
 if((Get-Content $roles -Raw)-match '(?im)^\s*(?:ALTER|CREATE)\s+ROLE\b[^;]*\bPASSWORD\b'){throw 'Unexpected role password clause detected.'}
 $testDb='gympro_restore_e8_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6)
 Write-Host "Temporary restore database: $testDb"
 Write-Progress -Activity 'Gym Pro E8 recovery checkpoint' -Status 'Restoring database into a separate test database' -PercentComplete 50
 Invoke-GymProE8 (Join-Path $PostgresBin 'createdb.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','--template=template0',$testDb);$testCreated=$true
 Invoke-GymProE8 (Join-Path $PostgresBin 'pg_restore.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres','--exit-on-error','--single-transaction','-d',$testDb,$dump)
 $sql=@'
\set ON_ERROR_STOP on
\pset pager off
BEGIN READ ONLY;
SELECT set_config('gympro.restore_target', :'expected_database', true) AS target \gset private_
DO $$
DECLARE v_table text;v_function text;v_owner record;v_role text;
BEGIN
 IF current_database() IS DISTINCT FROM current_setting('gympro.restore_target') OR current_database()='gympro_saas' OR left(current_database(),length('gympro_restore_e8_'))<>'gympro_restore_e8_' THEN RAISE EXCEPTION 'Only the exact temporary restore database may be verified'; END IF;
 FOREACH v_table IN ARRAY ARRAY['app.members',
 'app.membership_plans',
 'app.plan_prices',
 'app.member_subscriptions',
 'app.subscription_renewals',
 'app.subscription_suspensions',
 'app.subscription_expirations',
 'app.member_blacklist_events',
 'app.subscription_foc_grants',
 'app.membership_promotions',
 'app.membership_discounts',
 'app.attendance_visits',
 'app.attendance_checkouts',
 'app.member_cards',
 'app.member_card_events',
 'app.card_scan_receipts',
 'app.inventory_products',
 'app.inventory_stock_movements',
 'app.inventory_product_events',
 'app.pos_sales',
 'app.pos_sale_items',
 'app.pos_sale_returns',
 'app.pos_sale_return_items','app.payment_charges','app.payment_receipts','app.payment_reversals','app.payment_reconciliations'] LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=to_regclass(v_table) AND relrowsecurity AND relforcerowsecurity) THEN RAISE EXCEPTION 'Missing restored forced RLS: %',v_table; END IF;
  IF has_table_privilege('gympro_app',v_table,'SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unexpected runtime direct access: %',v_table; END IF;
 END LOOP;
 RAISE NOTICE 'PASS: All 27 membership, attendance, card, inventory and POS tables retain forced RLS and no runtime CRUD.';
 FOREACH v_function IN ARRAY ARRAY['security.register_member(bytea,uuid,uuid,text,text,text)',
 'security.check_in_member(bytea,uuid,uuid,uuid,uuid)',
 'security.check_out_member(bytea,uuid,uuid,uuid,uuid)',
 'security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid)',
 'security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text)',
 'security.read_member_card(bytea,uuid,uuid,uuid)',
 'security.scan_member_card(bytea,uuid,uuid,uuid,uuid)',
 'security.search_branch_members(bytea,uuid,uuid,text,integer,uuid)',
 'security.find_member_card(bytea,uuid,uuid,uuid)',
 'security.summarize_branch_attendance(bytea,uuid,uuid,date)',
 'security.create_inventory_product(bytea,uuid,text,text,text,numeric,uuid)',
 'security.update_inventory_product(bytea,uuid,uuid,text,text,numeric,text,uuid)',
 'security.read_inventory_products(bytea,uuid,uuid,uuid,integer)',
 'security.adjust_inventory_stock(bytea,uuid,uuid,uuid,integer,text,uuid)',
 'security.read_inventory_stock(bytea,uuid,uuid,uuid)',
 'security.create_pos_sale(bytea,uuid,uuid,jsonb,uuid)',
 'security.read_pos_sale(bytea,uuid,uuid,uuid)',
 'security.change_pos_sale(bytea,uuid,uuid,uuid,text,jsonb,text,uuid)',
 'security.read_pos_sale_return(bytea,uuid,uuid,uuid,uuid)',
 'security.read_pos_sale_return_status(bytea,uuid,uuid,uuid)',
 'security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer)',
 'security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer)','security.open_payment_charge(bytea,uuid,uuid,text,uuid,uuid)','security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid)','security.read_payment_charge(bytea,uuid,uuid,uuid)','security.read_payment_receipt(bytea,uuid,uuid,uuid)','security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid)','security.read_payment_reversal(bytea,uuid,uuid,uuid)','security.read_payment_history(bytea,uuid,uuid,date,date,text,uuid,integer)','security.summarize_payment_collection(bytea,uuid,uuid,date)','security.reconcile_payment_collection(bytea,uuid,uuid,date,jsonb,text,uuid)','security.read_payment_reconciliation(bytea,uuid,uuid,uuid)'] LOOP
  SELECT r.* INTO v_owner FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=to_regprocedure(v_function) AND p.prosecdef;
  IF NOT FOUND THEN RAISE EXCEPTION 'Restored restricted function missing: %',v_function; END IF;
  IF v_owner.rolcanlogin OR v_owner.rolinherit OR v_owner.rolsuper OR v_owner.rolbypassrls OR v_owner.rolcreatedb OR v_owner.rolcreaterole OR v_owner.rolreplication THEN RAISE EXCEPTION 'Unsafe function owner: %',v_function; END IF;
  IF NOT has_function_privilege('gympro_app',v_function,'EXECUTE') THEN RAISE EXCEPTION 'Runtime execute missing: %',v_function; END IF;
  IF EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid=to_regprocedure(v_function) AND a.grantee=0 AND a.privilege_type='EXECUTE') THEN RAISE EXCEPTION 'Public execution restored unexpectedly: %',v_function; END IF;
 END LOOP;
 FOREACH v_role IN ARRAY ARRAY['gympro_inventory_owner','gympro_pos_owner','gympro_pos_return_owner','gympro_inventory_read_owner','gympro_payment_owner'] LOOP
  IF EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=v_role) OR roleid=(SELECT oid FROM pg_roles WHERE rolname=v_role)) THEN RAISE EXCEPTION 'Restricted owner has role membership: %',v_role; END IF;
 END LOOP;
 IF (SELECT rolname FROM pg_roles WHERE oid=(SELECT proowner FROM pg_proc WHERE oid=to_regprocedure('security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer)')))<>'gympro_inventory_read_owner' THEN RAISE EXCEPTION 'D9 history owner changed'; END IF;
 IF has_table_privilege('gympro_inventory_read_owner','app.inventory_stock_movements','INSERT,UPDATE,DELETE') OR has_column_privilege('gympro_inventory_read_owner','app.users','password_hash','SELECT') THEN RAISE EXCEPTION 'History owner privilege boundary changed'; END IF;
 RAISE NOTICE 'PASS: All 32 core, inventory, POS and payment functions retain restricted owners, runtime execute and no public execute.';
 IF (SELECT count(*) FROM app.members WHERE tenant_id='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b' AND id IN('3113ab9f-8edd-41f4-afe6-c8f03e291f89','41f45bd6-114c-4241-9be0-0a949dc5f2b6'))<>2 OR NOT EXISTS(SELECT 1 FROM app.member_subscriptions WHERE tenant_id='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b' AND id='8a28fa97-e41f-4053-be61-8162ff3d387d' AND status='suspended' AND starts_on=DATE '2026-10-14' AND ends_on=DATE '2026-12-14') THEN RAISE EXCEPTION 'Demo membership checkpoint differs'; END IF;
 IF EXISTS(SELECT 1 FROM app.members WHERE id='6c600001-1111-4444-8888-000000000001') OR EXISTS(SELECT 1 FROM app.branches WHERE branch_code ~ '^(D7_UI_|D8_UI_)') OR EXISTS(SELECT 1 FROM app.roles WHERE role_code ~ '^(D7_UI_|D8_UI_)') OR EXISTS(SELECT 1 FROM app.users WHERE email ~ '^(pos-ui-|inventory-ui-)') OR EXISTS(SELECT 1 FROM app.inventory_products WHERE sku ~ '^(D7_UI_|D8_UI_)') THEN RAISE EXCEPTION 'Temporary browser test fixtures remain'; END IF;
 RAISE NOTICE 'PASS: Demo members and suspended subscription preserved; temporary browser accounts, roles, branches and products absent.';
 IF EXISTS(SELECT 1 FROM app.inventory_stock_movements GROUP BY tenant_id,branch_id,product_id HAVING sum(quantity_delta)<0) THEN RAISE EXCEPTION 'Negative stock balance restored'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sales sh WHERE sh.total_amount IS DISTINCT FROM (SELECT sum(li.line_total) FROM app.pos_sale_items li WHERE li.tenant_id=sh.tenant_id AND li.sale_id=sh.id)) THEN RAISE EXCEPTION 'Sale total mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sale_items li WHERE (SELECT count(*) FROM app.inventory_stock_movements mv WHERE mv.tenant_id=li.tenant_id AND mv.sale_item_id=li.id AND mv.movement_kind='sale' AND mv.sale_id=li.sale_id AND mv.branch_id=li.branch_id AND mv.product_id=li.product_id AND mv.quantity_delta=-li.quantity)<>1) THEN RAISE EXCEPTION 'Sale stock audit mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sale_returns rh WHERE rh.total_amount IS DISTINCT FROM (SELECT sum(ri.line_total) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=rh.tenant_id AND ri.return_id=rh.id)) THEN RAISE EXCEPTION 'Return total mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sale_return_items ri JOIN app.pos_sale_returns rh ON rh.tenant_id=ri.tenant_id AND rh.id=ri.return_id JOIN app.pos_sale_items li ON li.tenant_id=ri.tenant_id AND li.id=ri.sale_item_id WHERE ri.unit_price<>li.unit_price OR ri.sku<>li.sku OR ri.product_name<>li.product_name OR (SELECT count(*) FROM app.inventory_stock_movements mv WHERE mv.tenant_id=ri.tenant_id AND mv.return_item_id=ri.id AND mv.return_id=rh.id AND mv.sale_id=ri.sale_id AND mv.product_id=ri.product_id AND mv.branch_id=ri.branch_id AND mv.quantity_delta=ri.quantity AND mv.movement_kind=rh.action_code)<>1) THEN RAISE EXCEPTION 'Return snapshot or ledger mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sale_items li WHERE li.quantity<(SELECT sum(ri.quantity) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=li.tenant_id AND ri.sale_item_id=li.id)) THEN RAISE EXCEPTION 'Returned units exceed original sale'; END IF;
 IF EXISTS(SELECT 1 FROM app.pos_sale_returns rh WHERE rh.action_code='void' AND EXISTS(SELECT 1 FROM app.pos_sale_returns other WHERE other.tenant_id=rh.tenant_id AND other.sale_id=rh.sale_id AND other.id<>rh.id)) THEN RAISE EXCEPTION 'Voided sale has an additional reversal'; END IF;
 RAISE NOTICE 'PASS: Restored nonnegative stock, original sale totals, return snapshots and exact movement links verified.';
END $$;
DO $$
DECLARE f text;
BEGIN
 FOREACH f IN ARRAY ARRAY['payment_session(bytea,uuid,uuid,text)','payment_charge_json(uuid,uuid)','payment_receipt_json(uuid,uuid)','payment_reversal_json(uuid,uuid)','payment_reconciliation_json(uuid,uuid)'] LOOP
  IF to_regprocedure('security.'||f) IS NULL OR has_function_privilege('gympro_app','security.'||f,'EXECUTE') THEN RAISE EXCEPTION 'Private payment helper boundary changed: %',f; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM app.payment_receipts r JOIN LATERAL(SELECT coalesce(sum(amount),0) amount FROM app.payment_reversals x WHERE x.tenant_id=r.tenant_id AND x.receipt_id=r.id) x ON true WHERE x.amount>r.amount) THEN RAISE EXCEPTION 'Reversals exceed original receipt'; END IF;
 IF EXISTS(SELECT 1 FROM app.users WHERE email LIKE 'e7ui\_%@example.invalid' ESCAPE '\') THEN RAISE EXCEPTION 'Temporary payment browser users remain'; END IF;
 FOREACH f IN ARRAY ARRAY['finance.payments.record','finance.payments.read','finance.payments.reverse','finance.reconciliation.manage'] LOOP
  IF NOT EXISTS(SELECT 1 FROM app.permissions WHERE permission_code=f AND is_active) THEN RAISE EXCEPTION 'Missing finance permission: %',f; END IF;
 END LOOP;
 RAISE NOTICE 'PASS: Private payment helpers, reversal limits, finance permissions and browser-fixture cleanup verified.';
END $$;

SET LOCAL ROLE gympro_app;
DO $$ DECLARE v_call text; BEGIN
 FOREACH v_call IN ARRAY ARRAY['SELECT * FROM security.register_member(NULL::bytea,NULL::uuid,NULL::uuid,NULL::text,NULL::text,NULL::text)',
 'SELECT * FROM security.check_in_member(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.check_out_member(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.read_branch_attendance(NULL::bytea,NULL::uuid,NULL::uuid,NULL::boolean,NULL::date,NULL::date,NULL::integer,NULL::timestamptz,NULL::uuid)',
 'SELECT * FROM security.change_member_card(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,NULL::uuid,NULL::text)',
 'SELECT * FROM security.read_member_card(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.scan_member_card(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.search_branch_members(NULL::bytea,NULL::uuid,NULL::uuid,NULL::text,NULL::integer,NULL::uuid)',
 'SELECT * FROM security.find_member_card(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.summarize_branch_attendance(NULL::bytea,NULL::uuid,NULL::uuid,NULL::date)',
 'SELECT * FROM security.create_inventory_product(NULL::bytea,NULL::uuid,NULL::text,NULL::text,NULL::text,NULL::numeric,NULL::uuid)',
 'SELECT * FROM security.update_inventory_product(NULL::bytea,NULL::uuid,NULL::uuid,NULL::text,NULL::text,NULL::numeric,NULL::text,NULL::uuid)',
 'SELECT * FROM security.read_inventory_products(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::integer)',
 'SELECT * FROM security.adjust_inventory_stock(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::integer,NULL::text,NULL::uuid)',
 'SELECT * FROM security.read_inventory_stock(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.create_pos_sale(NULL::bytea,NULL::uuid,NULL::uuid,NULL::jsonb,NULL::uuid)',
 'SELECT * FROM security.read_pos_sale(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.change_pos_sale(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,NULL::jsonb,NULL::text,NULL::uuid)',
 'SELECT * FROM security.read_pos_sale_return(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.read_pos_sale_return_status(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)',
 'SELECT * FROM security.read_pos_sale_history(NULL::bytea,NULL::uuid,NULL::uuid,NULL::date,NULL::date,NULL::uuid,NULL::integer)',
 'SELECT * FROM security.read_inventory_stock_history(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,NULL::date,NULL::date,NULL::uuid,NULL::integer)'] LOOP
  BEGIN EXECUTE v_call;RAISE EXCEPTION 'Restored function accepted invalid session: %',v_call;EXCEPTION WHEN SQLSTATE '28000' THEN NULL;END;
 END LOOP;
 RAISE NOTICE 'PASS: All 22 restored functions reject invalid sessions under gympro_app.';
END $$;
DO $$ DECLARE c text; BEGIN FOREACH c IN ARRAY ARRAY['SELECT security.open_payment_charge(NULL::bytea,NULL::uuid,NULL::uuid,''pos_sale'',NULL::uuid,NULL::uuid)','SELECT security.record_payment_receipt(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,1::numeric,''cash'',NULL::text,NULL::uuid)','SELECT security.read_payment_charge(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)','SELECT security.read_payment_receipt(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)','SELECT security.reverse_payment_receipt(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid,''refund'',1::numeric,''test'',NULL::uuid)','SELECT security.read_payment_reversal(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)','SELECT security.read_payment_history(NULL::bytea,NULL::uuid,NULL::uuid,NULL::date,NULL::date,NULL::text,NULL::uuid,25)','SELECT security.summarize_payment_collection(NULL::bytea,NULL::uuid,NULL::uuid,NULL::date)','SELECT security.reconcile_payment_collection(NULL::bytea,NULL::uuid,NULL::uuid,NULL::date,''{}''::jsonb,''test'',NULL::uuid)','SELECT security.read_payment_reconciliation(NULL::bytea,NULL::uuid,NULL::uuid,NULL::uuid)'] LOOP BEGIN EXECUTE c; RAISE EXCEPTION 'Payment function accepted invalid session: %',c; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END; END LOOP; RAISE NOTICE 'PASS: All 10 restored payment functions reject invalid sessions under gympro_app.'; END $$;
RESET ROLE;
SELECT 'app.inventory_products' AS table_name,count(*) AS rows_restored FROM app.inventory_products
UNION ALL SELECT 'app.inventory_stock_movements',count(*) FROM app.inventory_stock_movements
UNION ALL SELECT 'app.pos_sales',count(*) FROM app.pos_sales
UNION ALL SELECT 'app.pos_sale_returns',count(*) FROM app.pos_sale_returns;
ROLLBACK;

'@
 $check=Join-Path $folder 'verify-restored-checkpoint.sql';[IO.File]::WriteAllText($check,$sql,[Text.UTF8Encoding]::new($false))
 Write-Progress -Activity 'Gym Pro E8 recovery checkpoint' -Status 'Verifying restored security, inventory, POS and audit data' -PercentComplete 75
 Invoke-GymProE8 (Join-Path $PostgresBin 'psql.exe') @('-X','-w','-h','127.0.0.1','-p','5432','-U','postgres','-d',$testDb,'-v','ON_ERROR_STOP=1','-v',('expected_database='+$testDb),'-f',$check)
 $restoredFingerprint=@(& (Join-Path $PostgresBin 'psql.exe') -X -w -h 127.0.0.1 -p 5432 -U postgres -d $testDb -v ON_ERROR_STOP=1 -A -t -f $fingerPath);if($LASTEXITCODE -ne 0){throw 'Restored payment fingerprint failed.'};$restoredFingerprint|Set-Content (Join-Path $folder 'payment-restored-fingerprint.txt') -Encoding UTF8;if(($originalFingerprint -join "`n") -cne ($restoredFingerprint -join "`n")){throw 'Restored payment ledger differs from original fingerprint.'};Write-Host 'PASS: All four payment tables match their original row counts and content fingerprints.' -ForegroundColor Green
 if($testDb -notmatch '^gympro_restore_e8_[0-9]{8}_[0-9]{6}_[0-9a-f]{6}$' -or $testDb -eq 'gympro_saas'){throw 'Unexpected cleanup target; refused.'}
 Invoke-GymProE8 (Join-Path $PostgresBin 'dropdb.exe') @('-w','-h','127.0.0.1','-p','5432','-U','postgres',$testDb);$testRemoved=$true
 $readme=@'
GYM PRO E8 RECOVERY CHECKPOINT

Source: gympro-source.bundle contains committed Git history. Clone it into a new folder with Git, then select the commit in checkpoint.json. The source-restore-check folder is a verification clone without a working-tree checkout. Untracked files are listed separately and are not included. Ignored local configuration such as .env is not included.

Database: gympro_saas.dump is a custom PostgreSQL archive including data, owners, privileges and row-security policies. It was restored and verified in a separate temporary database on this existing PostgreSQL cluster, then that database was removed. The working gympro_saas database was only read by backup tools.

Roles: roles-without-passwords.sql does not contain login passwords. This run used the cluster's existing roles; it did not test role creation on a fresh PostgreSQL server. A fresh-server recovery must review/apply the role file using a PostgreSQL administrator, restore the archive into a separate database, and set required login passwords separately. Do not restore over a working database.

Configuration: recreate the local .env from your secure configuration, using the restricted gympro_app and gympro_auth roles for the application. Keep administrative credentials out of the application. Install the locked dependencies with npm ci, build, and run the regression verification appropriate to the restored environment before use.

Checks: file hashes, Git clone/integrity, forced row security, restricted function owners, runtime function-only access, invalid-session rejection, stock and sale/return audit consistency, payment tables and immutable financial audit, known demo members/subscription and absence of temporary browser fixtures. Authenticated business flows were already verified through E7 and were not rerun in the restored clone.

Keep this recovery folder private: the database contains application data and password hashes, even though the separate roles file excludes login passwords.
'@
 [IO.File]::WriteAllText((Join-Path $folder 'RECOVERY-NOTES.txt'),$readme,[Text.UTF8Encoding]::new($false))
 $hashes=@($bundle,$dump,$roles,$check,(Join-Path $folder 'RECOVERY-NOTES.txt'))|ForEach-Object{[ordered]@{file=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash;bytes=(Get-Item -LiteralPath $_).Length}}
 $hashes|ConvertTo-Json|Set-Content (Join-Path $folder 'sha256-manifest.json') -Encoding UTF8
 [ordered]@{checkpoint='E8 payments recovery through verified E7';createdAt=(Get-Date).ToString('o');gitCommit=$commit;gitSubject=$subject;sourceBundleVerified=$true;sourceCloneVerified=$true;databaseRestoreVerified=$true;forcedRlsTablesVerified=27;restrictedRuntimeFunctionsVerified=32;invalidSessionRejectionsVerified=32;paymentLedgerFingerprintMatched=$true;stockAndPosAuditChecksPassed=$true;browserFixturesAbsent=$true;temporaryDatabaseRemoved=$true;testedUsingExistingClusterRoles=$true;roleRestoreOnFreshClusterTested=$false;rolesIncludePasswords=$false;authenticatedBusinessFlowsReexecuted=$false;liveDatabase='gympro_saas';applicationSourceChanged=$false;gitCommitPerformed=$false}|ConvertTo-Json|Set-Content (Join-Path $folder 'checkpoint.json') -Encoding UTF8
 $exitCode=0
 Write-Host 'PASS: Committed E1-E7 source bundle cloned and verified; database archive and password-free role backup created.' -ForegroundColor Green
 Write-Host 'PASS: Database restored; forced RLS, restricted functions, stock/POS/payment audit and demo records verified.' -ForegroundColor Green
 Write-Host 'PASS: Temporary restore database removed. Working database and application source unchanged by this runner.' -ForegroundColor Green
 Write-Host "Recovery folder: $folder"
 Write-Host 'No application migration, Git commit or external publication performed.'
}catch{Write-Host ('FAIL: '+$_.Exception.Message) -ForegroundColor Red;if($folder){Write-Host "Keep recovery reports: $folder"};if($testCreated -and -not $testRemoved){Write-Host "Temporary restore database retained for diagnosis: $testDb"}}
finally{[Environment]::SetEnvironmentVariable('PGPASSWORD',$priorPgPassword,'Process');$credential=$null;Write-Progress -Activity 'Gym Pro E8 recovery checkpoint' -Completed;if($transcribing){Stop-Transcript|Out-Null}}
exit $exitCode
