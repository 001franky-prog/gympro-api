\set ON_ERROR_STOP on
\pset pager off
BEGIN;
SET LOCAL lock_timeout='10s';
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regprocedure('security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified E4 required'; END IF;
 IF EXISTS(SELECT FROM pg_proc WHERE pronamespace='security'::regnamespace AND proname IN ('read_payment_history','summarize_payment_collection')) THEN RAISE EXCEPTION 'E5 reporting functions exist; use verification only'; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='gympro_payment_owner' AND NOT(rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication)) OR EXISTS(SELECT FROM pg_auth_members WHERE member='gympro_payment_owner'::regrole OR roleid='gympro_payment_owner'::regrole) THEN RAISE EXCEPTION 'Restricted and isolated payment owner required'; END IF;
END $$;
CREATE INDEX idx_e5_payment_reversal_time ON app.payment_reversals(tenant_id,recorded_at,id);
CREATE FUNCTION security.read_payment_history(p_hash bytea,p_tenant uuid,p_branch uuid,p_from date,p_to date,p_cursor_kind text,p_cursor uuid,p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;from_day date;to_day date;include_general boolean;period_start timestamptz;period_end timestamptz;result jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 to_day:=coalesce(p_to,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);from_day:=coalesce(p_from,to_day-29);
 IF NOT isfinite(from_day) OR NOT isfinite(to_day) OR to_day<from_day OR to_day-from_day>365 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_cursor IS NULL)<>(p_cursor_kind IS NULL) OR(p_cursor_kind IS NOT NULL AND p_cursor_kind NOT IN ('receipt','refund','void')) THEN RAISE EXCEPTION 'Invalid payment history query' USING ERRCODE='22023'; END IF;
 include_general:=security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS TRUE;
 period_start:=from_day::timestamp AT TIME ZONE 'Asia/Yangon';period_end:=(to_day+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 WITH events AS (SELECT 'receipt'::text AS event_kind,r.id,r.tenant_id,r.charge_id,r.id AS receipt_id,r.collection_branch_id,r.request_id,r.amount,r.currency_code,r.method_code,r.external_reference,NULL::text AS reason,r.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END AS source_id
 FROM app.payment_receipts r JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE r.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND r.recorded_at>=period_start AND r.recorded_at<period_end
 UNION ALL
 SELECT v.reversal_kind::text,v.id,v.tenant_id,r.charge_id,r.id,r.collection_branch_id,v.request_id,v.amount,v.currency_code,r.method_code,r.external_reference,v.reason,v.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE v.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND v.recorded_at>=period_start AND v.recorded_at<period_end),
 cursor_event AS(SELECT * FROM events WHERE id=p_cursor AND event_kind=p_cursor_kind),
 selected AS(SELECT e.* FROM events e WHERE p_cursor IS NULL OR (e.recorded_at,e.id,e.event_kind COLLATE "C")<(SELECT x.recorded_at,x.id,x.event_kind COLLATE "C" FROM cursor_event x) ORDER BY e.recorded_at DESC,e.id DESC,e.event_kind COLLATE "C" DESC LIMIT p_limit+1),
 page AS(SELECT * FROM selected ORDER BY recorded_at DESC,id DESC,event_kind COLLATE "C" DESC LIMIT p_limit)
 SELECT jsonb_build_object('tenantId',p_tenant,'collectionBranchId',p_branch,'fromDate',to_char(from_day,'YYYY-MM-DD'),'toDate',to_char(to_day,'YYYY-MM-DD'),'includesTenantMemberships',include_general,'limit',p_limit,'cursorFound',p_cursor IS NULL OR EXISTS(SELECT FROM cursor_event),
 'items',coalesce((SELECT jsonb_agg(jsonb_build_object('eventKind',event_kind,'id',id,'tenantId',tenant_id,'collectionBranchId',collection_branch_id,'receiptId',receipt_id,'chargeId',charge_id,'requestId',request_id,'sourceKind',source_kind,'sourceId',source_id,'amount',amount::text,'signedAmount',(CASE WHEN event_kind='receipt' THEN amount ELSE -amount END)::text,'currencyCode',currency_code,'methodCode',method_code,'externalReference',external_reference,'reason',reason,'recordedAt',recorded_at) ORDER BY recorded_at DESC,id DESC,event_kind COLLATE "C" DESC) FROM page),'[]'::jsonb),
 'nextCursor',CASE WHEN(SELECT count(*) FROM selected)>p_limit THEN(SELECT event_kind||':'||id::text FROM page ORDER BY recorded_at,id,event_kind COLLATE "C" LIMIT 1) ELSE NULL END) INTO result;
 IF (result->>'cursorFound')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'Invalid payment history cursor' USING ERRCODE='22023'; END IF;
 RETURN result-'cursorFound';
END $$;
CREATE FUNCTION security.summarize_payment_collection(p_hash bytea,p_tenant uuid,p_branch uuid,p_date date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE actor jsonb;day date;include_general boolean;period_start timestamptz;period_end timestamptz;result jsonb;
BEGIN
 actor:=security.payment_session(p_hash,p_tenant,p_branch,'finance.payments.read');
 day:=coalesce(p_date,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);
 IF NOT isfinite(day) THEN RAISE EXCEPTION 'Invalid collection date' USING ERRCODE='22023'; END IF;
 include_general:=security.has_tenant_permission(p_tenant,(actor->>'membershipId')::uuid,'finance.payments.read',NULL) IS TRUE;
 period_start:=day::timestamp AT TIME ZONE 'Asia/Yangon';period_end:=(day+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 WITH events AS (SELECT 'receipt'::text AS event_kind,r.id,r.tenant_id,r.charge_id,r.id AS receipt_id,r.collection_branch_id,r.request_id,r.amount,r.currency_code,r.method_code,r.external_reference,NULL::text AS reason,r.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END AS source_id
 FROM app.payment_receipts r JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE r.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND r.recorded_at>=period_start AND r.recorded_at<period_end
 UNION ALL
 SELECT v.reversal_kind::text,v.id,v.tenant_id,r.charge_id,r.id,r.collection_branch_id,v.request_id,v.amount,v.currency_code,r.method_code,r.external_reference,v.reason,v.recorded_at,c.source_kind,
 CASE c.source_kind WHEN 'pos_sale' THEN c.sale_id WHEN 'membership_renewal' THEN c.renewal_id ELSE c.subscription_id END
 FROM app.payment_reversals v JOIN app.payment_receipts r ON r.tenant_id=v.tenant_id AND r.id=v.receipt_id JOIN app.payment_charges c ON c.tenant_id=r.tenant_id AND c.id=r.charge_id
 WHERE v.tenant_id=p_tenant AND r.collection_branch_id=p_branch AND(c.branch_id=p_branch OR(c.branch_id IS NULL AND include_general)) AND v.recorded_at>=period_start AND v.recorded_at<period_end),
 methods(ord,code) AS(VALUES(1,'cash'),(2,'bank_transfer'),(3,'mobile_wallet'),(4,'card')),
 aggregates AS(SELECT m.ord,m.code,count(e.id) FILTER(WHERE e.event_kind='receipt') receipt_count,count(e.id) FILTER(WHERE e.event_kind='refund') refund_count,count(e.id) FILTER(WHERE e.event_kind='void') void_count,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='receipt'),0) received,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='refund'),0) refunded,
 coalesce(sum(e.amount) FILTER(WHERE e.event_kind='void'),0) voided FROM methods m LEFT JOIN events e ON e.method_code=m.code GROUP BY m.ord,m.code)
 SELECT jsonb_build_object('tenantId',p_tenant,'collectionBranchId',p_branch,'date',to_char(day,'YYYY-MM-DD'),'timezone','Asia/Yangon','currencyCode','MMK','includesTenantMemberships',include_general,
 'receiptCount',(SELECT sum(receipt_count)::text FROM aggregates),'refundCount',(SELECT sum(refund_count)::text FROM aggregates),'voidCount',(SELECT sum(void_count)::text FROM aggregates),
 'receivedAmount',(SELECT sum(received)::text FROM aggregates),'refundedAmount',(SELECT sum(refunded)::text FROM aggregates),'voidedAmount',(SELECT sum(voided)::text FROM aggregates),'netAmount',(SELECT sum(received-refunded-voided)::text FROM aggregates),
 'byMethod',(SELECT jsonb_agg(jsonb_build_object('methodCode',code,'receiptCount',receipt_count::text,'refundCount',refund_count::text,'voidCount',void_count::text,'receivedAmount',received::text,'refundedAmount',refunded::text,'voidedAmount',voided::text,'netAmount',(received-refunded-voided)::text) ORDER BY ord) FROM aggregates)) INTO result;
 RETURN result;
END $$;
ALTER FUNCTION security.read_payment_history(bytea,uuid,uuid,date,date,text,uuid,integer) OWNER TO gympro_payment_owner;
ALTER FUNCTION security.summarize_payment_collection(bytea,uuid,uuid,date) OWNER TO gympro_payment_owner;
REVOKE ALL ON FUNCTION security.read_payment_history(bytea,uuid,uuid,date,date,text,uuid,integer),security.summarize_payment_collection(bytea,uuid,uuid,date) FROM PUBLIC,gympro_app;
GRANT EXECUTE ON FUNCTION security.read_payment_history(bytea,uuid,uuid,date,date,text,uuid,integer),security.summarize_payment_collection(bytea,uuid,uuid,date) TO gympro_app;
COMMIT;
