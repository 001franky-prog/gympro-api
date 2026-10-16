\set ON_ERROR_STOP on
\pset pager off
BEGIN;
SET LOCAL lock_timeout='10s';
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.payment_charges') IS NULL OR to_regclass('app.payment_receipts') IS NULL OR to_regclass('app.payment_reversals') IS NULL THEN RAISE EXCEPTION 'Verified E1 required'; END IF;
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='gympro_payment_owner') THEN RAISE EXCEPTION 'Payment owner already exists; use verification rather than reinstall'; END IF;
 IF (SELECT count(*) FROM app.permissions WHERE is_active AND permission_code IN ('finance.payments.record','finance.payments.read'))<>2 THEN RAISE EXCEPTION 'E1 permissions missing'; END IF;
END $$;
CREATE ROLE gympro_payment_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT USAGE ON SCHEMA app,security TO gympro_payment_owner;
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_payment_owner;
GRANT SELECT ON app.branches,app.member_subscriptions,app.subscription_renewals,app.pos_sales,app.pos_sale_returns,app.payment_charges,app.payment_receipts,app.payment_reversals TO gympro_payment_owner;
GRANT UPDATE(id) ON app.member_subscriptions,app.pos_sales,app.payment_charges TO gympro_payment_owner;
GRANT INSERT ON app.payment_charges,app.payment_receipts TO gympro_payment_owner;
CREATE POLICY e2_payment_select ON app.branches FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.member_subscriptions FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.subscription_renewals FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.pos_sales FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.pos_sale_returns FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.payment_charges FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.payment_receipts FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_select ON app.payment_reversals FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e2_payment_lock ON app.member_subscriptions FOR UPDATE TO gympro_payment_owner USING(true) WITH CHECK(true);
CREATE POLICY e2_payment_lock ON app.pos_sales FOR UPDATE TO gympro_payment_owner USING(true) WITH CHECK(true);
CREATE POLICY e2_payment_lock ON app.payment_charges FOR UPDATE TO gympro_payment_owner USING(true) WITH CHECK(true);
CREATE POLICY e2_payment_insert ON app.payment_charges FOR INSERT TO gympro_payment_owner WITH CHECK(true);
CREATE POLICY e2_payment_insert ON app.payment_receipts FOR INSERT TO gympro_payment_owner WITH CHECK(true);

CREATE FUNCTION security.payment_session(p_hash bytea,p_tenant uuid,p_branch uuid,p_permission text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; BEGIN
 IF p_hash IS NULL OR octet_length(p_hash)<>32 THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF s.session_id IS NULL THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR p_tenant<>s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,p_permission,p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Payment access denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active') THEN RAISE EXCEPTION 'Inactive payment branch' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('sessionId',s.session_id,'membershipId',s.membership_id,'userId',s.user_id);
END $$;
CREATE FUNCTION security.payment_charge_json(p_tenant uuid,p_charge uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
 SELECT jsonb_build_object('id',c.id,'tenantId',c.tenant_id,'branchId',c.branch_id,'requestId',c.request_id,'sourceKind',c.source_kind,'saleId',c.sale_id,'subscriptionId',c.subscription_id,'renewalId',c.renewal_id,'amountDue',c.amount_due::text,'currencyCode',c.currency_code,'createdAt',c.created_at)
 FROM app.payment_charges c WHERE c.tenant_id=p_tenant AND c.id=p_charge;
$$;
CREATE FUNCTION security.payment_receipt_json(p_tenant uuid,p_receipt uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
 SELECT jsonb_build_object('id',r.id,'tenantId',r.tenant_id,'chargeId',r.charge_id,'collectionBranchId',r.collection_branch_id,'requestId',r.request_id,'amount',r.amount::text,'currencyCode',r.currency_code,'methodCode',r.method_code,'externalReference',r.external_reference,'recordedAt',r.recorded_at)
 FROM app.payment_receipts r WHERE r.tenant_id=p_tenant AND r.id=p_receipt;
$$;
CREATE FUNCTION security.open_payment_charge(p_hash bytea,p_tenant uuid,p_branch uuid,p_kind text,p_source uuid,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE; sale app.pos_sales%ROWTYPE;sub app.member_subscriptions%ROWTYPE;ren app.subscription_renewals%ROWTYPE;
 amount numeric; snap jsonb; scope_branch uuid; sub_id uuid; ren_id uuid; sale_id uuid; old_snapshot jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.record');
 IF current_setting('transaction_isolation')<>'read committed' OR p_source IS NULL OR p_request IS NULL OR p_kind IS NULL OR p_kind NOT IN ('pos_sale','membership_activation','membership_renewal') THEN RAISE EXCEPTION 'Invalid charge request' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 IF p_kind='pos_sale' THEN
  SELECT * INTO sale FROM app.pos_sales WHERE tenant_id=p_tenant AND id=p_source FOR UPDATE;
  IF sale.id IS NULL THEN RAISE EXCEPTION 'Unknown sale' USING ERRCODE='22023'; END IF;
  amount:=sale.total_amount;snap:=jsonb_build_object('saleId',sale.id,'originalAmount',sale.total_amount::text,'currencyCode',sale.currency_code);scope_branch:=sale.branch_id;sale_id:=sale.id;
 ELSE
  IF p_kind='membership_renewal' THEN
   SELECT * INTO ren FROM app.subscription_renewals WHERE tenant_id=p_tenant AND id=p_source;
   IF ren.id IS NULL THEN RAISE EXCEPTION 'Unknown renewal' USING ERRCODE='22023'; END IF;
   sub_id:=ren.subscription_id;ren_id:=ren.id;
  ELSE sub_id:=p_source; END IF;
  SELECT * INTO sub FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=sub_id FOR UPDATE;
  IF sub.id IS NULL OR sub.activated_at IS NULL THEN RAISE EXCEPTION 'Unknown activated membership' USING ERRCODE='22023'; END IF;
  scope_branch:=sub.branch_id;
  IF p_kind='membership_renewal' THEN
   amount:=ren.agreed_price_amount;snap:=jsonb_build_object('renewalId',ren.id,'subscriptionId',sub.id,'originalAmount',amount::text,'startsOn',ren.renewal_starts_on,'endsOn',ren.renewal_ends_on);
  ELSE
   SELECT previous_subscription_snapshot INTO old_snapshot FROM app.subscription_renewals WHERE tenant_id=p_tenant AND subscription_id=sub.id ORDER BY renewal_starts_on,created_at,id LIMIT 1;
   IF old_snapshot IS NOT NULL THEN
    IF NOT(old_snapshot ? 'agreed_price_amount') OR jsonb_typeof(old_snapshot->'agreed_price_amount') NOT IN ('number','string') THEN RAISE EXCEPTION 'Original activation amount cannot be established' USING ERRCODE='22023'; END IF;
    amount:=(old_snapshot->>'agreed_price_amount')::numeric;
   ELSE amount:=sub.agreed_price_amount; END IF;
   snap:=jsonb_build_object('subscriptionId',sub.id,'originalAmount',amount::text,'membershipKind',sub.membership_kind);
  END IF;
 END IF;
 IF scope_branch IS NOT NULL AND scope_branch<>p_branch THEN RAISE EXCEPTION 'Purchase branch mismatch' USING ERRCODE='42501'; END IF;
 IF scope_branch IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.record',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant membership payment access denied' USING ERRCODE='42501'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND request_id=p_request;
 IF c.id IS NOT NULL THEN
  IF c.source_kind<>p_kind OR c.sale_id IS DISTINCT FROM sale_id OR c.subscription_id IS DISTINCT FROM sub_id OR c.renewal_id IS DISTINCT FROM ren_id THEN RAISE EXCEPTION 'Charge request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_charge_json(p_tenant,c.id);
 END IF;
 IF EXISTS(SELECT FROM app.payment_charges x WHERE x.tenant_id=p_tenant AND ((p_kind='pos_sale' AND x.sale_id=p_source) OR(p_kind='membership_activation' AND x.source_kind=p_kind AND x.subscription_id=p_source) OR(p_kind='membership_renewal' AND x.renewal_id=p_source))) THEN RAISE EXCEPTION 'Purchase already has a charge' USING ERRCODE='22023'; END IF;
 IF amount IS NULL OR NOT(amount>=0 AND amount<1e24) OR amount<>round(amount,2) THEN RAISE EXCEPTION 'Invalid source amount' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_charges(tenant_id,request_id,source_kind,branch_id,sale_id,subscription_id,renewal_id,amount_due,source_snapshot,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_request,p_kind,scope_branch,sale_id,sub_id,ren_id,amount,snap,(actor->>'membershipId')::uuid,actor) RETURNING * INTO c;
 RETURN security.payment_charge_json(p_tenant,c.id);
END $$;
CREATE FUNCTION security.record_payment_receipt(p_hash bytea,p_tenant uuid,p_branch uuid,p_charge uuid,p_amount numeric,p_method text,p_reference text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE;r app.payment_receipts%ROWTYPE; paid numeric;rev numeric;credits numeric;ref text;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.record');
 IF current_setting('transaction_isolation')<>'read committed' OR p_charge IS NULL OR p_request IS NULL OR p_amount IS NULL OR NOT(p_amount>0 AND p_amount<1e24) OR p_amount<>round(p_amount,2) OR p_method IS NULL OR p_method NOT IN ('cash','bank_transfer','mobile_wallet','card') THEN RAISE EXCEPTION 'Invalid payment request' USING ERRCODE='22023'; END IF;
 ref:=nullif(btrim(p_reference),'');
 IF (ref IS NOT NULL AND (length(ref)>150 OR ref !~ '[^[:space:]]')) OR (p_method<>'cash' AND ref IS NULL) THEN RAISE EXCEPTION 'Payment reference required' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Unknown charge' USING ERRCODE='22023'; END IF;
 IF c.branch_id IS NOT NULL AND c.branch_id<>p_branch THEN RAISE EXCEPTION 'Charge branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.record',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 -- Same purchase lock used by existing sales-return and membership functions.
 IF c.sale_id IS NOT NULL THEN PERFORM id FROM app.pos_sales WHERE tenant_id=p_tenant AND id=c.sale_id FOR UPDATE;
 ELSE PERFORM id FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=c.subscription_id FOR UPDATE; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge FOR UPDATE;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF r.id IS NOT NULL THEN
  IF r.charge_id<>p_charge OR r.collection_branch_id<>p_branch OR r.amount<>p_amount OR r.method_code<>p_method OR r.external_reference IS DISTINCT FROM ref THEN RAISE EXCEPTION 'Payment request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_receipt_json(p_tenant,r.id);
 END IF;
 SELECT coalesce(sum(amount),0) INTO paid FROM app.payment_receipts WHERE tenant_id=p_tenant AND charge_id=p_charge;
 SELECT coalesce(sum(v.amount),0) INTO rev FROM app.payment_reversals v JOIN app.payment_receipts x ON x.tenant_id=v.tenant_id AND x.id=v.receipt_id WHERE x.tenant_id=p_tenant AND x.charge_id=p_charge;
 SELECT coalesce(sum(total_amount),0) INTO credits FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=c.sale_id;
 IF p_amount>greatest(0,c.amount_due-credits)-(paid-rev) THEN RAISE EXCEPTION 'Payment exceeds outstanding balance' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_receipts(tenant_id,charge_id,collection_branch_id,request_id,amount,method_code,external_reference,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_charge,p_branch,p_request,p_amount,p_method,ref,(actor->>'membershipId')::uuid,actor) RETURNING * INTO r;
 RETURN security.payment_receipt_json(p_tenant,r.id);
END $$;
CREATE FUNCTION security.read_payment_charge(p_hash bytea,p_tenant uuid,p_branch uuid,p_charge uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;c app.payment_charges%ROWTYPE;v jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=p_charge;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Unknown charge' USING ERRCODE='22023'; END IF;
 IF c.branch_id IS NOT NULL AND c.branch_id<>p_branch THEN RAISE EXCEPTION 'Charge branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 SELECT security.payment_charge_json(p_tenant,c.id)||jsonb_build_object('creditedAmount',credits::text,'payableAmount',greatest(0,c.amount_due-credits)::text,'receivedAmount',paid::text,'reversedAmount',rev::text,'netReceivedAmount',(paid-rev)::text,'outstandingAmount',greatest(0,c.amount_due-credits-paid+rev)::text,'refundDueAmount',greatest(0,paid-rev-greatest(0,c.amount_due-credits))::text)
 INTO v FROM
 (SELECT coalesce(sum(total_amount),0) AS credits FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=c.sale_id) cr,
 (SELECT coalesce(sum(amount),0) AS paid FROM app.payment_receipts WHERE tenant_id=p_tenant AND charge_id=c.id) pa,
 (SELECT coalesce(sum(x.amount),0) AS rev FROM app.payment_reversals x JOIN app.payment_receipts r ON r.tenant_id=x.tenant_id AND r.id=x.receipt_id WHERE r.tenant_id=p_tenant AND r.charge_id=c.id) re;
 RETURN v;
END $$;
CREATE FUNCTION security.read_payment_receipt(p_hash bytea,p_tenant uuid,p_branch uuid,p_receipt uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Unknown receipt' USING ERRCODE='22023'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 RETURN security.payment_receipt_json(p_tenant,r.id);
END $$;
ALTER FUNCTION security.payment_session(bytea,uuid,uuid,text) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.payment_session(bytea,uuid,uuid,text) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.payment_charge_json(uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.payment_charge_json(uuid,uuid) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.payment_receipt_json(uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.payment_receipt_json(uuid,uuid) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.open_payment_charge(bytea,uuid,uuid,text,uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.open_payment_charge(bytea,uuid,uuid,text,uuid,uuid) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.read_payment_charge(bytea,uuid,uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.read_payment_charge(bytea,uuid,uuid,uuid) FROM PUBLIC,gympro_app;
ALTER FUNCTION security.read_payment_receipt(bytea,uuid,uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.read_payment_receipt(bytea,uuid,uuid,uuid) FROM PUBLIC,gympro_app;
GRANT EXECUTE ON FUNCTION security.open_payment_charge(bytea,uuid,uuid,text,uuid,uuid) TO gympro_app;
GRANT EXECUTE ON FUNCTION security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid) TO gympro_app;
GRANT EXECUTE ON FUNCTION security.read_payment_charge(bytea,uuid,uuid,uuid) TO gympro_app;
GRANT EXECUTE ON FUNCTION security.read_payment_receipt(bytea,uuid,uuid,uuid) TO gympro_app;

DO $$ DECLARE x text; BEGIN
 FOREACH x IN ARRAY ARRAY['app.payment_charges','app.payment_receipts','app.payment_reversals'] LOOP
 IF has_table_privilege('gympro_app',x,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN RAISE EXCEPTION 'Runtime table access detected'; END IF;
 END LOOP;
 IF has_function_privilege('gympro_app','security.payment_session(bytea,uuid,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'Private helper executable'; END IF;
END $$;
COMMIT;
