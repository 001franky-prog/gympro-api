\set ON_ERROR_STOP on
\pset pager off
BEGIN;
SET LOCAL lock_timeout='10s';
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.payment_charges') IS NOT NULL OR to_regclass('app.payment_receipts') IS NOT NULL OR to_regclass('app.payment_reversals') IS NOT NULL THEN RAISE EXCEPTION 'E1 tables already exist; do not install twice'; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='gympro_app') THEN RAISE EXCEPTION 'Runtime role missing'; END IF;
END $$;
CREATE TABLE app.payment_charges(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 request_id uuid NOT NULL, source_kind varchar(24) NOT NULL,
 branch_id uuid, sale_id uuid, subscription_id uuid, renewal_id uuid,
 amount_due numeric(26,2) NOT NULL CHECK(amount_due>=0 AND amount_due<1e24),
 currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 source_snapshot jsonb NOT NULL CHECK(jsonb_typeof(source_snapshot)='object' AND source_snapshot<>'{}'::jsonb),
 actor_membership_id uuid NOT NULL, actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(created_at)),
 UNIQUE(tenant_id,id), UNIQUE(tenant_id,id,currency_code), UNIQUE(tenant_id,request_id),
 CHECK((source_kind='pos_sale' AND sale_id IS NOT NULL AND branch_id IS NOT NULL AND subscription_id IS NULL AND renewal_id IS NULL)
 OR (source_kind='membership_activation' AND sale_id IS NULL AND subscription_id IS NOT NULL AND renewal_id IS NULL)
 OR (source_kind='membership_renewal' AND sale_id IS NULL AND subscription_id IS NOT NULL AND renewal_id IS NOT NULL)),
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,branch_id,sale_id) REFERENCES app.pos_sales(tenant_id,branch_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,subscription_id) REFERENCES app.member_subscriptions(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,subscription_id,renewal_id) REFERENCES app.subscription_renewals(tenant_id,subscription_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_payment_charge_sale ON app.payment_charges(tenant_id,sale_id) WHERE source_kind='pos_sale';
CREATE UNIQUE INDEX uq_payment_charge_activation ON app.payment_charges(tenant_id,subscription_id) WHERE source_kind='membership_activation';
CREATE UNIQUE INDEX uq_payment_charge_renewal ON app.payment_charges(tenant_id,renewal_id) WHERE source_kind='membership_renewal';
CREATE INDEX idx_payment_charge_branch_time ON app.payment_charges(tenant_id,branch_id,created_at,id);
CREATE TABLE app.payment_receipts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, charge_id uuid NOT NULL,
 collection_branch_id uuid NOT NULL, request_id uuid NOT NULL,
 amount numeric(26,2) NOT NULL CHECK(amount>0 AND amount<1e24),
 currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 method_code varchar(24) NOT NULL CHECK(method_code IN ('cash','bank_transfer','mobile_wallet','card')),
 external_reference varchar(150),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(recorded_at)),
 UNIQUE(tenant_id,id), UNIQUE(tenant_id,id,currency_code), UNIQUE(tenant_id,request_id),
 CHECK(external_reference IS NULL OR (external_reference=btrim(external_reference) AND length(external_reference)>0 AND external_reference ~ '[^[:space:]]')),
 CHECK(method_code='cash' OR external_reference IS NOT NULL),
 FOREIGN KEY(tenant_id,charge_id,currency_code) REFERENCES app.payment_charges(tenant_id,id,currency_code) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,collection_branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_payment_receipt_charge ON app.payment_receipts(tenant_id,charge_id,recorded_at,id);
CREATE INDEX idx_payment_receipt_branch ON app.payment_receipts(tenant_id,collection_branch_id,recorded_at,id);
CREATE TABLE app.payment_reversals(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,receipt_id uuid NOT NULL,
 request_id uuid NOT NULL,reversal_kind varchar(16) NOT NULL CHECK(reversal_kind IN ('refund','void')),
 amount numeric(26,2) NOT NULL CHECK(amount>0 AND amount<1e24),
 currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 reason varchar(500) NOT NULL CHECK(reason=btrim(reason) AND length(reason) BETWEEN 2 AND 500 AND reason ~ '[^[:space:]]'),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(recorded_at)),
 UNIQUE(tenant_id,id),UNIQUE(tenant_id,request_id),
 FOREIGN KEY(tenant_id,receipt_id,currency_code) REFERENCES app.payment_receipts(tenant_id,id,currency_code) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_payment_reversal_receipt ON app.payment_reversals(tenant_id,receipt_id,recorded_at,id);
ALTER TABLE app.payment_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.payment_charges FORCE ROW LEVEL SECURITY;
ALTER TABLE app.payment_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.payment_receipts FORCE ROW LEVEL SECURITY;
ALTER TABLE app.payment_reversals ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.payment_reversals FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.payment_charges,app.payment_receipts,app.payment_reversals FROM PUBLIC,gympro_app;
INSERT INTO app.permissions(module_code,resource_code,action_code,description) VALUES
 ('finance','payments','record','Record an authorized payment receipt'),
 ('finance','payments','read','Read authorized payment records'),
 ('finance','payments','reverse','Record authorized payment reversals'),
 ('finance','reconciliation','manage','Manage payment reconciliation')
 ON CONFLICT(permission_code) DO NOTHING;
SAVEPOINT e1_fixtures;
CREATE TEMP TABLE e1_results(test_name text PRIMARY KEY,result text NOT NULL) ON COMMIT DROP;
CREATE FUNCTION pg_temp.e1_reject(p_name text,p_sql text,p_state text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN
 IF SQLSTATE=p_state THEN INSERT INTO e1_results VALUES(p_name,'PASS');RETURN; END IF;
 RAISE EXCEPTION 'Test % expected %, received %: %',p_name,p_state,SQLSTATE,SQLERRM;
 END;
 RAISE EXCEPTION 'Test % unexpectedly accepted invalid input',p_name;
END $$;
DO $$ DECLARE t uuid; s uuid; a uuid; b uuid; c uuid; r uuid; q uuid:=gen_random_uuid(); snap jsonb:='{"fixture":"E1"}'; template text; BEGIN
 SELECT ms.tenant_id,ms.id,tm.id,br.id INTO t,s,a,b FROM app.member_subscriptions ms
 JOIN app.tenant_memberships tm ON tm.tenant_id=ms.tenant_id
 JOIN app.branches br ON br.tenant_id=ms.tenant_id LIMIT 1;
 IF t IS NULL THEN RAISE EXCEPTION 'A subscription, tenant membership and branch are needed for rollback fixtures'; END IF;
 INSERT INTO app.payment_charges(tenant_id,request_id,source_kind,subscription_id,amount_due,source_snapshot,actor_membership_id,actor_snapshot)
 VALUES(t,q,'membership_activation',s,1000,snap,a,snap) RETURNING id INTO c;
 INSERT INTO e1_results VALUES('01_charge_defaults_and_source','PASS');
 INSERT INTO app.payment_receipts(tenant_id,charge_id,collection_branch_id,request_id,amount,method_code,actor_membership_id,actor_snapshot)
 VALUES(t,c,b,gen_random_uuid(),600,'cash',a,snap) RETURNING id INTO r;
 IF NOT EXISTS(SELECT FROM app.payment_receipts WHERE id=r AND currency_code='MMK' AND isfinite(recorded_at)) THEN RAISE EXCEPTION 'Receipt defaults failed'; END IF;
 INSERT INTO e1_results VALUES('02_partial_cash_receipt_defaults','PASS');
 INSERT INTO app.payment_reversals(tenant_id,receipt_id,request_id,reversal_kind,amount,reason,actor_membership_id,actor_snapshot)
 VALUES(t,r,gen_random_uuid(),'refund',100,'Fixture partial reversal',a,snap);
 INSERT INTO e1_results VALUES('03_reversal_relationship','PASS');
 template:=format('INSERT INTO app.payment_charges(tenant_id,request_id,source_kind,subscription_id,amount_due,source_snapshot,actor_membership_id,actor_snapshot) VALUES(%L,%%s,''membership_activation'',%L,1000,%L,%L,%L)',t,s,snap,a,snap);
 PERFORM pg_temp.e1_reject('04_duplicate_charge_request',format(template,quote_literal(q)),'23505');
 PERFORM pg_temp.e1_reject('05_duplicate_activation_charge',format(template,'gen_random_uuid()'),'23505');
 template:=format('INSERT INTO app.payment_receipts(tenant_id,charge_id,collection_branch_id,request_id,amount,method_code,external_reference,actor_membership_id,actor_snapshot) VALUES(%L,%L,%L,gen_random_uuid(),%%s,%%s,%%s,%L,%%s)',t,c,b,a);
 PERFORM pg_temp.e1_reject('06_zero_payment',format(template,'0',quote_literal('cash'),'NULL',quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('07_negative_payment',format(template,'-1',quote_literal('cash'),'NULL',quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('08_nan_payment',format(template,quote_literal('NaN'),quote_literal('cash'),'NULL',quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('09_infinite_payment',format(template,quote_literal('Infinity'),quote_literal('cash'),'NULL',quote_literal(snap)),'22003');
 PERFORM pg_temp.e1_reject('10_unknown_method',format(template,'1',quote_literal('crypto'),'NULL',quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('11_transfer_reference_required',format(template,'1',quote_literal('bank_transfer'),'NULL',quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('12_padded_reference',format(template,'1',quote_literal('card'),quote_literal(' x '),quote_literal(snap)),'23514');
 PERFORM pg_temp.e1_reject('13_empty_actor_snapshot',format(template,'1',quote_literal('cash'),'NULL',quote_literal('{}')),'23514');
 PERFORM pg_temp.e1_reject('14_array_actor_snapshot',format(template,'1',quote_literal('cash'),'NULL',quote_literal('[]')),'23514');
 EXECUTE format(template,'100',quote_literal('bank_transfer'),quote_literal('E1-TRANSFER'),quote_literal(snap));
 INSERT INTO e1_results VALUES('15_transfer_with_reference','PASS');
 PERFORM pg_temp.e1_reject('16_unknown_receipt_charge',format('UPDATE app.payment_receipts SET charge_id=%L WHERE id=%L',gen_random_uuid(),r),'23503');
 PERFORM pg_temp.e1_reject('17_other_tenant_receipt',format('UPDATE app.payment_receipts SET tenant_id=%L WHERE id=%L',gen_random_uuid(),r),'23503');
 PERFORM pg_temp.e1_reject('18_blank_reversal_reason',format('UPDATE app.payment_reversals SET reason='''' WHERE receipt_id=%L',r),'23514');
 PERFORM pg_temp.e1_reject('19_zero_reversal',format('UPDATE app.payment_reversals SET amount=0 WHERE receipt_id=%L',r),'23514');
 PERFORM pg_temp.e1_reject('20_unknown_reversal_receipt',format('UPDATE app.payment_reversals SET receipt_id=%L WHERE receipt_id=%L',gen_random_uuid(),r),'23503');
 PERFORM pg_temp.e1_reject('21_infinite_receipt_timestamp',format('UPDATE app.payment_receipts SET recorded_at=''infinity'' WHERE id=%L',r),'23514');
 PERFORM pg_temp.e1_reject('22_unknown_charge_source',format('UPDATE app.payment_charges SET source_kind=''other'' WHERE id=%L',c),'23514');
 PERFORM pg_temp.e1_reject('23_missing_renewal_source',format('UPDATE app.payment_charges SET source_kind=''membership_renewal'' WHERE id=%L',c),'23514');
 PERFORM pg_temp.e1_reject('24_negative_charge',format('UPDATE app.payment_charges SET amount_due=-1 WHERE id=%L',c),'23514');
 PERFORM pg_temp.e1_reject('25_currency_rejected',format('UPDATE app.payment_receipts SET currency_code=''USD'' WHERE id=%L',r),'23514');
 PERFORM pg_temp.e1_reject('26_unknown_actor',format('UPDATE app.payment_receipts SET actor_membership_id=%L WHERE id=%L',gen_random_uuid(),r),'23503');
 IF (SELECT count(*) FROM app.payment_charges)<>1 OR (SELECT count(*) FROM app.payment_receipts)<>2 OR (SELECT count(*) FROM app.payment_reversals)<>1 THEN RAISE EXCEPTION 'Rejected statements changed fixture counts'; END IF;
 INSERT INTO e1_results VALUES('27_exact_fixture_counts','PASS');
END $$;
DO $$ DECLARE x text; BEGIN
 FOREACH x IN ARRAY ARRAY['app.payment_charges','app.payment_receipts','app.payment_reversals'] LOOP
 IF NOT EXISTS(SELECT FROM pg_class WHERE oid=x::regclass AND relrowsecurity AND relforcerowsecurity) THEN RAISE EXCEPTION 'Forced RLS missing: %',x; END IF;
 IF has_table_privilege('gympro_app',x,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN RAISE EXCEPTION 'Runtime direct privilege found: %',x; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM app.role_permissions rp JOIN app.permissions p ON p.id=rp.permission_id WHERE p.permission_code IN ('finance.payments.record','finance.payments.read','finance.payments.reverse','finance.reconciliation.manage')) THEN RAISE EXCEPTION 'Finance permissions unexpectedly assigned'; END IF;
 INSERT INTO e1_results VALUES('28_forced_rls_and_runtime_denial','PASS'),('29_permissions_unassigned','PASS');
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM 1 FROM app.payment_receipts; RAISE EXCEPTION 'Runtime read unexpectedly accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN DELETE FROM app.payment_reversals WHERE false; RAISE EXCEPTION 'Runtime delete unexpectedly accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
INSERT INTO e1_results VALUES('30_actual_runtime_access_denied','PASS');
SELECT * FROM e1_results ORDER BY test_name;
DO $$ BEGIN IF (SELECT count(*) FROM e1_results WHERE result='PASS')<>30 THEN RAISE EXCEPTION 'Incomplete E1 verification'; END IF; END $$;
ROLLBACK TO SAVEPOINT e1_fixtures;
RELEASE SAVEPOINT e1_fixtures;
DO $$ BEGIN
 IF EXISTS(SELECT FROM app.payment_charges) OR EXISTS(SELECT FROM app.payment_receipts) OR EXISTS(SELECT FROM app.payment_reversals) THEN RAISE EXCEPTION 'Fixture rollback failed'; END IF;
 IF (SELECT count(*) FROM app.permissions WHERE is_active AND permission_code IN ('finance.payments.record','finance.payments.read','finance.payments.reverse','finance.reconciliation.manage'))<>4 THEN RAISE EXCEPTION 'Finance permission baseline incomplete'; END IF;
END $$;
COMMIT;
SELECT 'PASS' AS fixture_rollback_and_schema_install;
