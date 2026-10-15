\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.pos_sale_returns') IS NULL OR to_regprocedure('security.read_pos_sale_return_status(bytea,uuid,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified D5 is required'; END IF;
 IF to_regprocedure('security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer)') IS NOT NULL THEN RAISE EXCEPTION 'D6 already exists; do not reapply'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_pos_return_owner' AND NOT rolcanlogin AND NOT rolinherit AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_return_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_return_owner')) THEN RAISE EXCEPTION 'Restricted D5 owner required'; END IF;
END $$;
CREATE FUNCTION security.read_pos_sale_history(p_hash bytea,p_tenant uuid,p_branch uuid,p_from date,p_through date,p_cursor uuid,p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;v_cursor_created timestamptz;v_result jsonb;v_from date;v_through date;v_lower timestamptz;v_upper timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_from IS NULL)<>(p_through IS NULL)) THEN RAISE EXCEPTION 'Invalid history query' USING ERRCODE='22023'; END IF;
 v_from:=coalesce(p_from,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);v_through:=coalesce(p_through,v_from);
 IF NOT isfinite(v_from) OR NOT isfinite(v_through) THEN RAISE EXCEPTION 'Invalid history date range' USING ERRCODE='22023'; END IF;
 IF v_from<DATE '0001-01-01' OR v_through>DATE '9999-12-30' OR v_through<v_from OR v_through-v_from>365 THEN RAISE EXCEPTION 'Invalid history date range' USING ERRCODE='22023'; END IF;
 v_lower:=v_from::timestamp AT TIME ZONE 'Asia/Yangon';v_upper:=(v_through+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 IF p_cursor IS NOT NULL THEN
  SELECT sh.created_at INTO v_cursor_created FROM app.pos_sales sh WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.id=p_cursor AND sh.created_at>=v_lower AND sh.created_at<v_upper;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid history cursor' USING ERRCODE='22023'; END IF;
 END IF;
 WITH candidates AS MATERIALIZED(
  SELECT sh.* FROM app.pos_sales sh WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.created_at>=v_lower AND sh.created_at<v_upper AND (p_cursor IS NULL OR (sh.created_at,sh.id)<(v_cursor_created,p_cursor)) ORDER BY sh.created_at DESC,sh.id DESC LIMIT p_limit+1
 ),page AS MATERIALIZED(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit), public_rows AS(
  SELECT sh.id,sh.created_at,jsonb_build_object('id',sh.id,'tenantId',sh.tenant_id,'branchId',sh.branch_id,'requestId',sh.request_id,'createdAt',sh.created_at,'currencyCode',sh.currency_code,'totalAmount',sh.total_amount::text,
  'reversedAmount',rev.amount::text,'status',CASE WHEN rev.voided THEN 'voided' WHEN units.returned=units.sold THEN 'refunded' WHEN units.returned>0 THEN 'partially_refunded' ELSE 'completed' END,
  'quantitySold',units.sold::text,'quantityReturned',units.returned::text) AS item
  FROM page sh CROSS JOIN LATERAL(SELECT coalesce(sum(sr.total_amount),0)::numeric(26,2) AS amount,coalesce(bool_or(sr.action_code='void'),false) AS voided FROM app.pos_sale_returns sr WHERE sr.tenant_id=sh.tenant_id AND sr.sale_id=sh.id)rev
  CROSS JOIN LATERAL(SELECT (SELECT coalesce(sum(li.quantity),0) FROM app.pos_sale_items li WHERE li.tenant_id=sh.tenant_id AND li.sale_id=sh.id) AS sold,(SELECT coalesce(sum(ri.quantity),0) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sh.tenant_id AND ri.sale_id=sh.id) AS returned)units
 )
 SELECT jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'from',v_from::text,'through',v_through::text,'items',coalesce((SELECT jsonb_agg(item ORDER BY created_at DESC,id DESC) FROM public_rows),'[]'::jsonb),'nextCursor',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT id FROM page ORDER BY created_at ASC,id ASC LIMIT 1) ELSE NULL END) INTO v_result;
 RETURN v_result;
END $$;
ALTER FUNCTION security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer) OWNER TO gympro_pos_return_owner;
REVOKE ALL ON FUNCTION security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer) TO gympro_app;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM security.read_pos_sale_history(NULL,NULL,NULL,NULL,NULL,NULL,25);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN NULL;END;
 RAISE NOTICE 'PASS: D6 runtime history rejects invalid sessions.';
END $$;
RESET ROLE;
COMMIT;
