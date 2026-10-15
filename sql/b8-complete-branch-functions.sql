\set ON_ERROR_STOP on
BEGIN;
GRANT CREATE ON SCHEMA security TO gympro_blacklist_owner;
CREATE OR REPLACE FUNCTION security.change_branch_member_blacklist(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_action text, p_reason text, p_request_id uuid)
RETURNS SETOF app.member_blacklist_events LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $fn$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.members.update',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.blacklist:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.change_member_blacklist(p_token_hash,p_tenant_id,p_member_id,p_action,p_reason,p_request_id);
END;
$fn$;
ALTER FUNCTION security.change_branch_member_blacklist(bytea,uuid,uuid,uuid,text,text,uuid) OWNER TO gympro_blacklist_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_blacklist_owner;
REVOKE ALL ON FUNCTION security.change_branch_member_blacklist(bytea,uuid,uuid,uuid,text,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.change_branch_member_blacklist(bytea,uuid,uuid,uuid,text,text,uuid) TO gympro_app;
GRANT CREATE ON SCHEMA security TO gympro_foc_owner;
CREATE OR REPLACE FUNCTION security.grant_branch_foc_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_reason text, p_request_id uuid)
RETURNS SETOF app.subscription_foc_grants LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $fn$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.grant_foc',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.foc:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.grant_foc_membership(p_token_hash,p_tenant_id,p_member_id,p_plan_id,p_plan_price_id,p_reason,p_request_id);
END;
$fn$;
ALTER FUNCTION security.grant_branch_foc_membership(bytea,uuid,uuid,uuid,uuid,uuid,text,uuid) OWNER TO gympro_foc_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_foc_owner;
REVOKE ALL ON FUNCTION security.grant_branch_foc_membership(bytea,uuid,uuid,uuid,uuid,uuid,text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.grant_branch_foc_membership(bytea,uuid,uuid,uuid,uuid,uuid,text,uuid) TO gympro_app;
GRANT CREATE ON SCHEMA security TO gympro_membership_owner;
CREATE OR REPLACE FUNCTION security.activate_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_member_id uuid, p_plan_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid)
RETURNS SETOF app.membership_discounts LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $fn$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.apply_discount',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.discount:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=p_member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 IF v_member.branch_id IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.activate_discounted_membership(p_token_hash,p_tenant_id,p_member_id,p_plan_id,p_plan_price_id,p_promotion_id,p_request_id);
END;
$fn$;
ALTER FUNCTION security.activate_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid,uuid) OWNER TO gympro_membership_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;
REVOKE ALL ON FUNCTION security.activate_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.activate_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid,uuid) TO gympro_app;
GRANT CREATE ON SCHEMA security TO gympro_membership_owner;
CREATE OR REPLACE FUNCTION security.renew_branch_discounted_membership(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_subscription_id uuid, p_plan_price_id uuid, p_promotion_id uuid, p_request_id uuid)
RETURNS SETOF app.membership_discounts LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $fn$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.memberships.apply_discount',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.discount:'||p_tenant_id::text||':'||p_request_id::text,0));
 IF p_request_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Request ID is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.renewal:'||p_tenant_id::text||':'||p_request_id::text,0));
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant_id AND id=p_subscription_id;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Subscription access denied'; END IF;
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant_id AND id=v_sub.member_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Member access denied'; END IF;
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant_id AND id=p_subscription_id FOR UPDATE;
 IF NOT FOUND OR v_sub.member_id IS DISTINCT FROM v_member.id OR v_sub.branch_id IS DISTINCT FROM p_branch_id OR v_member.branch_id IS DISTINCT FROM p_branch_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.renew_discounted_membership(p_token_hash,p_tenant_id,p_subscription_id,p_plan_price_id,p_promotion_id,p_request_id);
END;
$fn$;
ALTER FUNCTION security.renew_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid) OWNER TO gympro_membership_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_membership_owner;
REVOKE ALL ON FUNCTION security.renew_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.renew_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid) TO gympro_app;
GRANT CREATE ON SCHEMA security TO gympro_promotion_owner;
CREATE OR REPLACE FUNCTION security.set_branch_membership_promotion_status(p_token_hash bytea, p_tenant_id uuid, p_branch_id uuid, p_promotion_id uuid, p_status text)
RETURNS SETOF app.membership_promotions LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $fn$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE; v_branch uuid;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 SELECT * INTO v_session FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant_id IS NULL OR v_session.tenant_id IS DISTINCT FROM p_tenant_id THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant access denied'; END IF;
 IF p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 IF security.has_tenant_permission(p_tenant_id,v_session.membership_id,'gym.promotions.manage',p_branch_id) IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 SELECT branch_id INTO v_branch FROM app.membership_promotions WHERE tenant_id=p_tenant_id AND id=p_promotion_id FOR UPDATE;
 IF NOT FOUND OR v_branch IS DISTINCT FROM p_branch_id THEN RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Branch access denied'; END IF;
 RETURN QUERY SELECT * FROM security.set_membership_promotion_status(p_token_hash,p_tenant_id,p_promotion_id,p_status);
END;
$fn$;
ALTER FUNCTION security.set_branch_membership_promotion_status(bytea,uuid,uuid,uuid,text) OWNER TO gympro_promotion_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_promotion_owner;
REVOKE ALL ON FUNCTION security.set_branch_membership_promotion_status(bytea,uuid,uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.set_branch_membership_promotion_status(bytea,uuid,uuid,uuid,text) TO gympro_app;
DO $$
DECLARE v record;
BEGIN
 FOR v IN SELECT p.oid,p.proname,p.prosecdef,r.rolcanlogin,r.rolsuper,r.rolbypassrls
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner
 WHERE n.nspname='security' AND p.proname IN (
 'change_branch_member_blacklist','grant_branch_foc_membership',
 'activate_branch_discounted_membership','renew_branch_discounted_membership',
 'set_branch_membership_promotion_status','expire_branch_member_subscription') LOOP
 IF NOT v.prosecdef OR v.rolcanlogin OR v.rolsuper OR v.rolbypassrls OR NOT has_function_privilege('gympro_app',v.oid,'EXECUTE') THEN
 RAISE EXCEPTION 'Unsafe branch function boundary: %',v.proname; END IF;
 END LOOP;
 IF has_table_privilege('gympro_app','app.members','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('gympro_app','app.member_subscriptions','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('gympro_app','app.membership_discounts','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('gympro_app','app.member_blacklist_events','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('gympro_app','app.subscription_foc_grants','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('gympro_app','app.membership_promotions','SELECT,INSERT,UPDATE,DELETE') THEN
 RAISE EXCEPTION 'Runtime has direct table privileges'; END IF;
END;
$$;
SET LOCAL ROLE gympro_app;
DO $$
DECLARE v record; v_args text; v_state text; v_count integer:=0;
BEGIN
 FOR v IN SELECT p.oid,p.proname,p.proargtypes FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='security' AND p.proname IN (
 'change_branch_member_blacklist','grant_branch_foc_membership',
 'activate_branch_discounted_membership','renew_branch_discounted_membership',
 'set_branch_membership_promotion_status','expire_branch_member_subscription') LOOP
 SELECT string_agg('NULL::'||format_type(t,NULL),',' ORDER BY ord) INTO v_args
 FROM unnest(v.proargtypes::oid[]) WITH ORDINALITY AS a(t,ord);
 v_state:=NULL;
 BEGIN EXECUTE format('SELECT * FROM security.%I(%s)',v.proname,v_args);
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE; END;
 IF v_state IS DISTINCT FROM '28000' THEN RAISE EXCEPTION 'Invalid session test failed for %: %',v.proname,v_state; END IF;
 v_count:=v_count+1;
 END LOOP;
 IF v_count<>6 THEN RAISE EXCEPTION 'Expected six branch functions, found %',v_count; END IF;
 RAISE NOTICE 'PASS: All six remaining branch functions reject invalid sessions under gympro_app.';
END;
$$;
RESET ROLE;
COMMIT;
