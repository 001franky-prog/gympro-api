\set ON_ERROR_STOP on
\pset pager off
BEGIN READ ONLY;
SELECT pg_catalog.set_config('gympro.rehearsal_database', :'target', true);
DO $guard$
BEGIN
 IF current_database() <> current_setting('gympro.rehearsal_database') OR current_database() !~ '^gympro_bootstrap_[0-9]{14}_[a-f0-9]{6}$' THEN RAISE EXCEPTION 'Unsafe rehearsal target'; END IF;
END $guard$;
DO $verify$
DECLARE v record; v_observed record; v_row_count bigint;
BEGIN
 IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('app','platform','security') AND c.relkind='r') <> 36 THEN RAISE EXCEPTION 'Table count mismatch'; END IF;
 FOR v IN SELECT * FROM (VALUES
('app.membership_discounts','postgres',true,true),
('app.member_subscriptions','postgres',true,true),
('app.member_blacklist_events','postgres',true,true),
('app.member_card_events','postgres',true,true),
('app.attendance_visits','postgres',true,true),
('app.attendance_checkouts','postgres',true,true),
('app.membership_promotions','postgres',true,true),
('app.subscription_expirations','postgres',true,true),
('app.subscription_foc_grants','postgres',true,true),
('app.members','postgres',true,true),
('app.subscription_renewals','postgres',true,true),
('app.subscription_suspensions','postgres',true,true),
('app.branches','postgres',true,true),
('app.card_scan_receipts','postgres',true,true),
('app.inventory_product_events','postgres',true,true),
('app.inventory_products','postgres',true,true),
('app.inventory_stock_movements','postgres',true,true),
('app.member_cards','postgres',true,true),
('app.membership_plans','postgres',true,true),
('app.payment_charges','postgres',true,true),
('app.payment_receipts','postgres',true,true),
('app.payment_reconciliations','postgres',true,true),
('app.payment_reversals','postgres',true,true),
('app.permissions','postgres',false,false),
('app.plan_prices','postgres',true,true),
('app.pos_sale_items','postgres',true,true),
('app.pos_sale_return_items','postgres',true,true),
('app.pos_sale_returns','postgres',true,true),
('app.pos_sales','postgres',true,true),
('app.role_assignments','postgres',false,false),
('app.role_permissions','postgres',false,false),
('app.roles','postgres',false,false),
('app.tenant_memberships','postgres',false,false),
('app.users','postgres',false,false),
('platform.tenants','postgres',false,false),
('security.tenant_sessions','postgres',false,false)
 ) AS expected(name,owner_name,rls,forced) LOOP
  SELECT pg_get_userbyid(relowner) owner_name,relrowsecurity rls,relforcerowsecurity forced INTO STRICT v_observed FROM pg_class WHERE oid=to_regclass(v.name);
  IF v_observed.owner_name<>v.owner_name OR v_observed.rls<>v.rls OR v_observed.forced<>v.forced THEN RAISE EXCEPTION 'Table properties mismatch: %',v.name; END IF;
  EXECUTE format('SELECT count(*) FROM %s',to_regclass(v.name)) INTO v_row_count;
  IF v_row_count<>0 THEN RAISE EXCEPTION 'Baseline unexpectedly contains rows: %',v.name; END IF;
  IF has_table_privilege('gympro_app',v.name,'SELECT') <> (v.name='app.branches') OR has_table_privilege('gympro_app',v.name,'INSERT') OR has_table_privilege('gympro_app',v.name,'UPDATE') OR has_table_privilege('gympro_app',v.name,'DELETE') THEN RAISE EXCEPTION 'Runtime table privilege mismatch: %',v.name; END IF;
 END LOOP;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security')<>64 THEN RAISE EXCEPTION 'Security function count mismatch'; END IF;
 FOR v IN SELECT * FROM (VALUES
('security.activate_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.activate_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.activate_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.activate_member_subscription(bytea,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.adjust_inventory_stock(bytea,uuid,uuid,uuid,integer,text,uuid)','gympro_inventory_owner',true),
('security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)','gympro_promotion_owner',true),
('security.change_branch_member_blacklist(bytea,uuid,uuid,uuid,text,text,uuid)','gympro_blacklist_owner',true),
('security.change_member_blacklist(bytea,uuid,uuid,text,text,uuid)','gympro_blacklist_owner',true),
('security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text)','gympro_card_owner',true),
('security.change_pos_sale(bytea,uuid,uuid,uuid,text,jsonb,text,uuid)','gympro_pos_return_owner',true),
('security.check_in_member(bytea,uuid,uuid,uuid,uuid)','gympro_attendance_owner',true),
('security.check_out_member(bytea,uuid,uuid,uuid,uuid)','gympro_attendance_owner',true),
('security.create_inventory_product(bytea,uuid,text,text,text,numeric,uuid)','gympro_inventory_owner',true),
('security.create_membership_promotion(bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date)','gympro_promotion_owner',true),
('security.create_pos_sale(bytea,uuid,uuid,jsonb,uuid)','gympro_pos_owner',true),
('security.create_tenant_session(uuid,bytea)','gympro_session_owner',true),
('security.expire_branch_member_subscription(bytea,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.expire_member_subscription(bytea,uuid,uuid)','gympro_membership_owner',true),
('security.find_member_card(bytea,uuid,uuid,uuid)','gympro_card_owner',true),
('security.get_active_tenant_membership(uuid,uuid)','postgres',true),
('security.get_user_credentials(text)','postgres',true),
('security.grant_branch_foc_membership(bytea,uuid,uuid,uuid,uuid,uuid,text,uuid)','gympro_foc_owner',true),
('security.grant_foc_membership(bytea,uuid,uuid,uuid,uuid,text,uuid)','gympro_foc_owner',true),
('security.has_tenant_permission(uuid,uuid,text,uuid)','gympro_rbac_owner',true),
('security.is_tenant_session_valid(uuid)','postgres',true),
('security.open_payment_charge(bytea,uuid,uuid,text,uuid,uuid)','gympro_payment_owner',true),
('security.payment_charge_json(uuid,uuid)','gympro_payment_owner',true),
('security.payment_receipt_json(uuid,uuid)','gympro_payment_owner',true),
('security.payment_reconciliation_json(uuid,uuid)','gympro_payment_owner',true),
('security.payment_reversal_json(uuid,uuid)','gympro_payment_owner',true),
('security.payment_session(bytea,uuid,uuid,text)','gympro_payment_owner',true),
('security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamp with time zone,uuid)','gympro_attendance_reader',true),
('security.read_inventory_products(bytea,uuid,uuid,uuid,integer)','gympro_inventory_owner',true),
('security.read_inventory_stock(bytea,uuid,uuid,uuid)','gympro_inventory_owner',true),
('security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer)','gympro_inventory_read_owner',true),
('security.read_member_card(bytea,uuid,uuid,uuid)','gympro_card_owner',true),
('security.read_payment_charge(bytea,uuid,uuid,uuid)','gympro_payment_owner',true),
('security.read_payment_history(bytea,uuid,uuid,date,date,text,uuid,integer)','gympro_payment_owner',true),
('security.read_payment_receipt(bytea,uuid,uuid,uuid)','gympro_payment_owner',true),
('security.read_payment_reconciliation(bytea,uuid,uuid,uuid)','gympro_payment_owner',true),
('security.read_payment_reversal(bytea,uuid,uuid,uuid)','gympro_payment_owner',true),
('security.read_pos_sale(bytea,uuid,uuid,uuid)','gympro_pos_owner',true),
('security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer)','gympro_pos_return_owner',true),
('security.read_pos_sale_return(bytea,uuid,uuid,uuid,uuid)','gympro_pos_return_owner',true),
('security.read_pos_sale_return_status(bytea,uuid,uuid,uuid)','gympro_pos_return_owner',true),
('security.reconcile_payment_collection(bytea,uuid,uuid,date,jsonb,text,uuid)','gympro_payment_owner',true),
('security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid)','gympro_payment_owner',true),
('security.register_member(bytea,uuid,uuid,text,text,text)','gympro_member_owner',true),
('security.renew_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.renew_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.renew_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)','gympro_membership_owner',true),
('security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid)','gympro_payment_owner',true),
('security.revoke_tenant_session(uuid,bytea)','gympro_session_owner',true),
('security.scan_member_card(bytea,uuid,uuid,uuid,uuid)','gympro_card_owner',true),
('security.search_branch_members(bytea,uuid,uuid,text,integer,uuid)','gympro_member_reader',true),
('security.set_branch_membership_promotion_status(bytea,uuid,uuid,uuid,text)','gympro_promotion_owner',true),
('security.set_membership_promotion_status(bytea,uuid,uuid,text)','gympro_promotion_owner',true),
('security.summarize_branch_attendance(bytea,uuid,uuid,date)','gympro_attendance_reader',true),
('security.summarize_payment_collection(bytea,uuid,uuid,date)','gympro_payment_owner',true),
('security.suspend_branch_member_subscription(bytea,uuid,uuid,uuid,text,uuid)','gympro_membership_owner',true),
('security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)','gympro_membership_owner',true),
('security.update_inventory_product(bytea,uuid,uuid,text,text,numeric,text,uuid)','gympro_inventory_owner',true),
('security.verify_tenant_session(bytea)','gympro_session_owner',true)
 ) AS expected(signature,owner_name,security_definer) LOOP
  SELECT pg_get_userbyid(proowner) owner_name,prosecdef INTO STRICT v_observed FROM pg_proc WHERE oid=to_regprocedure(v.signature);
  IF v_observed.owner_name<>v.owner_name OR v_observed.prosecdef<>v.security_definer THEN RAISE EXCEPTION 'Function ownership or security mismatch: %',v.signature; END IF;
 END LOOP;
 RAISE NOTICE 'PASS: 36 empty tables, table owners/RLS/runtime CRUD and 64 function owners/security modes match the recovered baseline.';
END $verify$;
SET LOCAL ROLE gympro_app;
DO $boundary$
BEGIN
 BEGIN
  PERFORM security.verify_tenant_session(decode(repeat('00',32),'hex'));
  RAISE EXCEPTION 'Runtime app unexpectedly has direct session verifier access';
 EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS: gympro_app cannot execute the private session verifier.';
 END;
 BEGIN
  PERFORM security.read_payment_charge(decode(repeat('00',32),'hex'),'00000000-0000-4000-8000-000000000001'::uuid,'00000000-0000-4000-8000-000000000002'::uuid,'00000000-0000-4000-8000-000000000003'::uuid);
  RAISE EXCEPTION 'Unknown session accepted by payment endpoint';
 EXCEPTION WHEN SQLSTATE '28000' THEN
  RAISE NOTICE 'PASS: Runtime payment entry point rejects an unknown session.';
 END;
END $boundary$;
RESET ROLE;
SET LOCAL ROLE gympro_auth;
DO $runtime$
BEGIN
 IF EXISTS (SELECT 1 FROM security.verify_tenant_session(decode(repeat('00',32),'hex'))) THEN RAISE EXCEPTION 'Unknown session returned an identity'; END IF;
 RAISE NOTICE 'PASS: Restored session verifier returns no identity for an unknown session under gympro_auth.';
END $runtime$;
ROLLBACK;
