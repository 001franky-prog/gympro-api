\set ON_ERROR_STOP on
\pset pager off
BEGIN;
SET LOCAL lock_timeout='10s';
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regprocedure('security.record_payment_receipt(bytea,uuid,uuid,uuid,numeric,text,text,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified E2 required'; END IF;
 IF to_regprocedure('security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'E4 already installed; use verification only'; END IF;
 IF NOT EXISTS(SELECT FROM app.permissions WHERE permission_code='finance.payments.reverse' AND is_active) THEN RAISE EXCEPTION 'Active reversal permission required'; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='gympro_payment_owner' AND NOT(rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication)) OR EXISTS(SELECT FROM pg_auth_members WHERE member='gympro_payment_owner'::regrole OR roleid='gympro_payment_owner'::regrole) THEN RAISE EXCEPTION 'Restricted and isolated E2 owner required'; END IF;
END $$;
GRANT INSERT ON app.payment_reversals TO gympro_payment_owner;
GRANT UPDATE(id) ON app.payment_receipts TO gympro_payment_owner;
CREATE POLICY e4_payment_reversal_insert ON app.payment_reversals FOR INSERT TO gympro_payment_owner WITH CHECK(true);
CREATE POLICY e4_payment_receipt_lock ON app.payment_receipts FOR UPDATE TO gympro_payment_owner USING(true) WITH CHECK(true);
CREATE FUNCTION security.payment_reversal_json(p_tenant uuid,p_reversal uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
 SELECT jsonb_build_object('id',v.id,'tenantId',v.tenant_id,'receiptId',v.receipt_id,'chargeId',r.charge_id,'collectionBranchId',r.collection_branch_id,'requestId',v.request_id,'reversalKind',v.reversal_kind,'amount',v.amount::text,'currencyCode',v.currency_code,'reason',v.reason,'recordedAt',v.recorded_at)
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id WHERE v.tenant_id=p_tenant AND v.id=p_reversal;
$$;
CREATE FUNCTION security.reverse_payment_receipt(p_hash bytea,p_tenant uuid,p_branch uuid,p_receipt uuid,p_kind text,p_amount numeric,p_reason text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;v app.payment_reversals%ROWTYPE;why text;already numeric;amount numeric;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.reverse');
 why:=regexp_replace(p_reason,'^[[:space:]]+|[[:space:]]+$','','g');
 IF current_setting('transaction_isolation')<>'read committed' OR p_receipt IS NULL OR p_request IS NULL OR p_kind IS NULL OR p_kind NOT IN ('refund','void') OR why IS NULL OR length(why) NOT BETWEEN 2 AND 500 OR why !~ '[^[:space:]]' THEN RAISE EXCEPTION 'Invalid payment reversal request' USING ERRCODE='22023'; END IF;
 IF (p_kind='void' AND p_amount IS NOT NULL) OR (p_kind='refund' AND (p_amount IS NULL OR NOT(p_amount>0 AND p_amount<1e24) OR p_amount<>round(p_amount,2))) THEN RAISE EXCEPTION 'Invalid reversal amount' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,502));
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt;
 IF r.id IS NULL THEN RAISE EXCEPTION 'Unknown payment receipt' USING ERRCODE='22023'; END IF;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.reverse',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant reversal access denied' USING ERRCODE='42501'; END IF;
 -- Preserve the purchase -> charge -> receipt lock order used by payment recording.
 IF c.sale_id IS NOT NULL THEN PERFORM id FROM app.pos_sales WHERE tenant_id=p_tenant AND id=c.sale_id FOR UPDATE;
 ELSE PERFORM id FROM app.member_subscriptions WHERE tenant_id=p_tenant AND id=c.subscription_id FOR UPDATE; END IF;
 PERFORM id FROM app.payment_charges WHERE tenant_id=p_tenant AND id=c.id FOR UPDATE;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=p_receipt FOR UPDATE;
 SELECT * INTO v FROM app.payment_reversals WHERE tenant_id=p_tenant AND request_id=p_request;
 IF v.id IS NOT NULL THEN
  IF v.receipt_id<>p_receipt OR v.reversal_kind<>p_kind OR v.reason<>why OR(p_kind='refund' AND v.amount<>p_amount) THEN RAISE EXCEPTION 'Reversal request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_reversal_json(p_tenant,v.id);
 END IF;
 SELECT coalesce(sum(x.amount),0) INTO already FROM app.payment_reversals x WHERE x.tenant_id=p_tenant AND x.receipt_id=p_receipt;
 IF p_kind='void' THEN
  IF EXISTS(SELECT FROM app.payment_reversals WHERE tenant_id=p_tenant AND receipt_id=p_receipt) THEN RAISE EXCEPTION 'A reversed receipt cannot be voided' USING ERRCODE='22023'; END IF;
  amount:=r.amount;
 ELSE amount:=p_amount; END IF;
 IF amount>r.amount-already THEN RAISE EXCEPTION 'Reversal exceeds remaining receipt amount' USING ERRCODE='22023'; END IF;
 INSERT INTO app.payment_reversals(tenant_id,receipt_id,request_id,reversal_kind,amount,reason,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_receipt,p_request,p_kind,amount,why,(actor->>'membershipId')::uuid,actor) RETURNING * INTO v;
 RETURN security.payment_reversal_json(p_tenant,v.id);
END $$;
CREATE FUNCTION security.read_payment_reversal(p_hash bytea,p_tenant uuid,p_branch uuid,p_reversal uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;v app.payment_reversals%ROWTYPE;r app.payment_receipts%ROWTYPE;c app.payment_charges%ROWTYPE;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 SELECT * INTO v FROM app.payment_reversals WHERE tenant_id=p_tenant AND id=p_reversal;
 IF v.id IS NULL THEN RAISE EXCEPTION 'Unknown payment reversal' USING ERRCODE='22023'; END IF;
 SELECT * INTO r FROM app.payment_receipts WHERE tenant_id=p_tenant AND id=v.receipt_id;
 SELECT * INTO c FROM app.payment_charges WHERE tenant_id=p_tenant AND id=r.charge_id;
 IF r.collection_branch_id<>p_branch OR(c.branch_id IS NOT NULL AND c.branch_id<>p_branch) THEN RAISE EXCEPTION 'Receipt branch mismatch' USING ERRCODE='42501'; END IF;
 IF c.branch_id IS NULL AND security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Tenant payment access denied' USING ERRCODE='42501'; END IF;
 RETURN security.payment_reversal_json(p_tenant,v.id);
END $$;
ALTER FUNCTION security.payment_reversal_json(uuid,uuid) OWNER TO gympro_payment_owner;
ALTER FUNCTION security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid) OWNER TO gympro_payment_owner;
ALTER FUNCTION security.read_payment_reversal(bytea,uuid,uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.payment_reversal_json(uuid,uuid),security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid),security.read_payment_reversal(bytea,uuid,uuid,uuid) FROM PUBLIC,gympro_app;
GRANT EXECUTE ON FUNCTION security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid),security.read_payment_reversal(bytea,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.payment_reversals','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') OR has_function_privilege('gympro_app','security.payment_reversal_json(uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Runtime payment boundary violated'; END IF;
END $$;
COMMIT;
