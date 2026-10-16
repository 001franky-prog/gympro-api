\set ON_ERROR_STOP on
\pset pager off
BEGIN;
SET LOCAL lock_timeout='10s';
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regprocedure('security.summarize_payment_collection(bytea,uuid,uuid,date)') IS NULL THEN RAISE EXCEPTION 'Verified E5 required'; END IF;
 IF to_regclass('app.payment_reconciliations') IS NOT NULL THEN RAISE EXCEPTION 'E6 exists; use verification only'; END IF;
 IF NOT EXISTS(SELECT FROM app.permissions WHERE permission_code='finance.reconciliation.manage' AND is_active) THEN RAISE EXCEPTION 'Reconciliation permission missing'; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='gympro_payment_owner' AND NOT(rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication)) OR EXISTS(SELECT FROM pg_auth_members WHERE member='gympro_payment_owner'::regrole OR roleid='gympro_payment_owner'::regrole) THEN RAISE EXCEPTION 'Restricted payment owner required'; END IF;
END $$;
CREATE TABLE app.payment_reconciliations(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 branch_id uuid NOT NULL,reconciliation_date date NOT NULL CHECK(isfinite(reconciliation_date)),request_id uuid NOT NULL,
 declared_totals jsonb NOT NULL CHECK(jsonb_typeof(declared_totals)='object' AND declared_totals ?& ARRAY['cash','bank_transfer','mobile_wallet','card'] AND (declared_totals-ARRAY['cash','bank_transfer','mobile_wallet','card'])='{}'::jsonb AND jsonb_typeof(declared_totals->'cash')='string' AND (declared_totals->>'cash') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(declared_totals->'bank_transfer')='string' AND (declared_totals->>'bank_transfer') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(declared_totals->'mobile_wallet')='string' AND (declared_totals->>'mobile_wallet') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(declared_totals->'card')='string' AND (declared_totals->>'card') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'),expected_totals jsonb NOT NULL CHECK(jsonb_typeof(expected_totals)='object' AND expected_totals ?& ARRAY['cash','bank_transfer','mobile_wallet','card'] AND (expected_totals-ARRAY['cash','bank_transfer','mobile_wallet','card'])='{}'::jsonb AND jsonb_typeof(expected_totals->'cash')='string' AND (expected_totals->>'cash') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(expected_totals->'bank_transfer')='string' AND (expected_totals->>'bank_transfer') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(expected_totals->'mobile_wallet')='string' AND (expected_totals->>'mobile_wallet') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$' AND jsonb_typeof(expected_totals->'card')='string' AND (expected_totals->>'card') ~ '^-?(0|[1-9][0-9]{0,42})[.][0-9]{2}$'),difference_totals jsonb NOT NULL CHECK(jsonb_typeof(difference_totals)='object' AND difference_totals ?& ARRAY['cash','bank_transfer','mobile_wallet','card'] AND (difference_totals-ARRAY['cash','bank_transfer','mobile_wallet','card'])='{}'::jsonb AND jsonb_typeof(difference_totals->'cash')='string' AND (difference_totals->>'cash') ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$' AND jsonb_typeof(difference_totals->'bank_transfer')='string' AND (difference_totals->>'bank_transfer') ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$' AND jsonb_typeof(difference_totals->'mobile_wallet')='string' AND (difference_totals->>'mobile_wallet') ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$' AND jsonb_typeof(difference_totals->'card')='string' AND (difference_totals->>'card') ~ '^-?(0|[1-9][0-9]{0,43})[.][0-9]{2}$'),
 declared_net_amount numeric(47,2) NOT NULL,expected_net_amount numeric(47,2) NOT NULL,difference_amount numeric(48,2) NOT NULL,
 currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 status varchar(16) NOT NULL CHECK(status IN ('matched','variance')),
 note varchar(500) NOT NULL CHECK(note=btrim(note) AND length(note) BETWEEN 2 AND 500 AND note ~ '[^[:space:]]'),
 collection_snapshot jsonb NOT NULL CHECK(jsonb_typeof(collection_snapshot)='object' AND collection_snapshot ?& ARRAY['tenantId','collectionBranchId','date','netAmount','includesTenantMemberships','byMethod'] AND collection_snapshot->>'tenantId' IS NOT NULL AND collection_snapshot->>'collectionBranchId' IS NOT NULL AND collection_snapshot->>'date' IS NOT NULL AND collection_snapshot->>'netAmount' IS NOT NULL AND collection_snapshot->>'includesTenantMemberships'='true' AND collection_snapshot->>'tenantId'=tenant_id::text AND collection_snapshot->>'collectionBranchId'=branch_id::text AND collection_snapshot->>'date'=to_char(reconciliation_date,'YYYY-MM-DD') AND jsonb_typeof(collection_snapshot->'byMethod')='array' AND jsonb_array_length(collection_snapshot->'byMethod')=4),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 reconciled_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(reconciled_at)),
 UNIQUE(tenant_id,id),UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,branch_id,reconciliation_date),
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT,
 CHECK(reconciliation_date<(reconciled_at AT TIME ZONE 'Asia/Yangon')::date),
 CHECK(declared_net_amount=((declared_totals->>'cash')::numeric+(declared_totals->>'bank_transfer')::numeric+(declared_totals->>'mobile_wallet')::numeric+(declared_totals->>'card')::numeric) AND expected_net_amount=((expected_totals->>'cash')::numeric+(expected_totals->>'bank_transfer')::numeric+(expected_totals->>'mobile_wallet')::numeric+(expected_totals->>'card')::numeric) AND difference_amount=declared_net_amount-expected_net_amount AND expected_net_amount=(collection_snapshot->>'netAmount')::numeric),
 CHECK((difference_totals->>'cash')::numeric=(declared_totals->>'cash')::numeric-(expected_totals->>'cash')::numeric AND (difference_totals->>'bank_transfer')::numeric=(declared_totals->>'bank_transfer')::numeric-(expected_totals->>'bank_transfer')::numeric AND (difference_totals->>'mobile_wallet')::numeric=(declared_totals->>'mobile_wallet')::numeric-(expected_totals->>'mobile_wallet')::numeric AND (difference_totals->>'card')::numeric=(declared_totals->>'card')::numeric-(expected_totals->>'card')::numeric),CHECK((status='matched')=((difference_totals->>'cash')::numeric=0 AND (difference_totals->>'bank_transfer')::numeric=0 AND (difference_totals->>'mobile_wallet')::numeric=0 AND (difference_totals->>'card')::numeric=0))
);
CREATE INDEX idx_payment_reconciliations_branch ON app.payment_reconciliations(tenant_id,branch_id,reconciliation_date,id);
ALTER TABLE app.payment_reconciliations ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.payment_reconciliations FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.payment_reconciliations FROM PUBLIC,gympro_app;
GRANT SELECT,INSERT ON app.payment_reconciliations TO gympro_payment_owner;
CREATE POLICY e6_reconciliation_select ON app.payment_reconciliations FOR SELECT TO gympro_payment_owner USING(true);
CREATE POLICY e6_reconciliation_insert ON app.payment_reconciliations FOR INSERT TO gympro_payment_owner WITH CHECK(true);
CREATE FUNCTION security.payment_reconciliation_json(p_tenant uuid,p_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
 SELECT jsonb_build_object('id',x.id,'tenantId',x.tenant_id,'branchId',x.branch_id,'date',to_char(x.reconciliation_date,'YYYY-MM-DD'),'requestId',x.request_id,'declaredTotals',x.declared_totals,'expectedTotals',x.expected_totals,'differenceTotals',x.difference_totals,'declaredNetAmount',x.declared_net_amount::text,'expectedNetAmount',x.expected_net_amount::text,'differenceAmount',x.difference_amount::text,'currencyCode',x.currency_code,'status',x.status,'note',x.note,'collectionSnapshot',x.collection_snapshot,'reconciledAt',x.reconciled_at)
 FROM app.payment_reconciliations x WHERE x.tenant_id=p_tenant AND x.id=p_id;
$$;
CREATE FUNCTION security.reconcile_payment_collection(p_hash bytea,p_tenant uuid,p_branch uuid,p_date date,p_declared jsonb,p_note text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;existing app.payment_reconciliations%ROWTYPE;snapshot jsonb;declared jsonb:='{}';expected jsonb:='{}';difference jsonb:='{}';m text;v numeric;exp numeric;declared_sum numeric:=0;expected_sum numeric:=0;matched boolean:=true;why text;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.reconciliation.manage');
 IF security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Complete collection read access required' USING ERRCODE='42501'; END IF;
 why:=regexp_replace(p_note,'^[[:space:]]+|[[:space:]]+$','','g');
 IF current_setting('transaction_isolation')<>'read committed' OR p_date IS NULL OR NOT isfinite(p_date) OR p_date>=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date OR p_request IS NULL OR why IS NULL OR length(why) NOT BETWEEN 2 AND 500 OR why !~ '[^[:space:]]' OR p_declared IS NULL OR jsonb_typeof(p_declared)<>'object' THEN RAISE EXCEPTION 'Invalid reconciliation request' USING ERRCODE='22023'; END IF;
 IF NOT(p_declared ?& ARRAY['cash','bank_transfer','mobile_wallet','card']) OR(p_declared-ARRAY['cash','bank_transfer','mobile_wallet','card'])<>'{}'::jsonb THEN RAISE EXCEPTION 'Four declared method totals required' USING ERRCODE='22023'; END IF;
 FOREACH m IN ARRAY ARRAY['cash','bank_transfer','mobile_wallet','card'] LOOP
  IF jsonb_typeof(p_declared->m)<>'string' OR(p_declared->>m)!~'^-?(0|[1-9][0-9]{0,42})([.][0-9]{1,2})?$' THEN RAISE EXCEPTION 'Invalid declared amount' USING ERRCODE='22023'; END IF;
  v:=(p_declared->>m)::numeric(45,2);declared:=declared||jsonb_build_object(m,v::text);declared_sum:=declared_sum+v;
 END LOOP;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,506));
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_branch::text||':'||to_char(p_date,'YYYY-MM-DD'),507));
 SELECT * INTO existing FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND request_id=p_request;
 IF existing.id IS NOT NULL THEN
  IF existing.branch_id<>p_branch OR existing.reconciliation_date<>p_date OR existing.declared_totals<>declared OR existing.note<>why THEN RAISE EXCEPTION 'Reconciliation request conflict' USING ERRCODE='22023'; END IF;
  RETURN security.payment_reconciliation_json(p_tenant,existing.id);
 END IF;
 IF EXISTS(SELECT FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND branch_id=p_branch AND reconciliation_date=p_date) THEN RAISE EXCEPTION 'Collection day already reconciled' USING ERRCODE='22023'; END IF;
 snapshot:=security.summarize_payment_collection(p_hash,p_tenant,p_branch,p_date);
 IF (snapshot->>'includesTenantMemberships')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Incomplete collection snapshot' USING ERRCODE='22023'; END IF;
 FOREACH m IN ARRAY ARRAY['cash','bank_transfer','mobile_wallet','card'] LOOP
  SELECT (x->>'netAmount')::numeric INTO exp FROM jsonb_array_elements(snapshot->'byMethod') x WHERE x->>'methodCode'=m;
  IF exp IS NULL THEN RAISE EXCEPTION 'Incomplete method snapshot' USING ERRCODE='22023'; END IF;
  v:=(declared->>m)::numeric;expected:=expected||jsonb_build_object(m,exp::numeric(45,2)::text);difference:=difference||jsonb_build_object(m,(v-exp)::numeric(46,2)::text);expected_sum:=expected_sum+exp;matched:=matched AND v=exp;
 END LOOP;
 INSERT INTO app.payment_reconciliations(tenant_id,branch_id,reconciliation_date,request_id,declared_totals,expected_totals,difference_totals,declared_net_amount,expected_net_amount,difference_amount,status,note,collection_snapshot,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,p_date,p_request,declared,expected,difference,declared_sum,expected_sum,declared_sum-expected_sum,CASE WHEN matched THEN 'matched' ELSE 'variance' END,why,snapshot,(actor->>'membershipId')::uuid,actor) RETURNING * INTO existing;
 RETURN security.payment_reconciliation_json(p_tenant,existing.id);
END $$;
CREATE FUNCTION security.read_payment_reconciliation(p_hash bytea,p_tenant uuid,p_branch uuid,p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;x app.payment_reconciliations%ROWTYPE;current_snapshot jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.reconciliation.manage');
 IF security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Complete collection read access required' USING ERRCODE='42501'; END IF;
 SELECT * INTO x FROM app.payment_reconciliations WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_id;
 IF x.id IS NULL THEN RAISE EXCEPTION 'Unknown payment reconciliation' USING ERRCODE='22023'; END IF;
 current_snapshot:=security.summarize_payment_collection(p_hash,p_tenant,p_branch,x.reconciliation_date);
 RETURN security.payment_reconciliation_json(p_tenant,x.id)||jsonb_build_object('currentCollection',current_snapshot,'ledgerChanged',current_snapshot<>x.collection_snapshot);
END $$;
ALTER FUNCTION security.payment_reconciliation_json(uuid,uuid) OWNER TO gympro_payment_owner;
ALTER FUNCTION security.reconcile_payment_collection(bytea,uuid,uuid,date,jsonb,text,uuid) OWNER TO gympro_payment_owner;
ALTER FUNCTION security.read_payment_reconciliation(bytea,uuid,uuid,uuid) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.payment_reconciliation_json(uuid,uuid),security.reconcile_payment_collection(bytea,uuid,uuid,date,jsonb,text,uuid),security.read_payment_reconciliation(bytea,uuid,uuid,uuid) FROM PUBLIC,gympro_app;
GRANT EXECUTE ON FUNCTION security.reconcile_payment_collection(bytea,uuid,uuid,date,jsonb,text,uuid),security.read_payment_reconciliation(bytea,uuid,uuid,uuid) TO gympro_app;
COMMIT;
