\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.pos_sale_returns') IS NULL OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='app' AND table_name='inventory_stock_movements' AND column_name='return_id') THEN RAISE EXCEPTION 'D5 stock reversal schema required'; END IF;
 IF to_regprocedure('security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer)') IS NOT NULL THEN RAISE EXCEPTION 'D9 already exists; do not reapply'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_inventory_read_owner') THEN CREATE ROLE gympro_inventory_read_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_inventory_read_owner' AND (rolcanlogin OR rolinherit OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolreplication)) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_inventory_read_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_inventory_read_owner')) THEN RAISE EXCEPTION 'Isolated restricted history owner required'; END IF;
END $$;
GRANT USAGE ON SCHEMA app,security TO gympro_inventory_read_owner;
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_inventory_read_owner;
GRANT SELECT(id,tenant_id) ON app.inventory_products TO gympro_inventory_read_owner;
GRANT SELECT(id,tenant_id,branch_id,product_id,quantity_delta,reason,actor_membership_id,balance_after,product_snapshot,movement_kind,sale_id,return_id,created_at) ON app.inventory_stock_movements TO gympro_inventory_read_owner;
GRANT SELECT(id,tenant_id,user_id) ON app.tenant_memberships TO gympro_inventory_read_owner;
GRANT SELECT(id,full_name) ON app.users TO gympro_inventory_read_owner;
CREATE POLICY inventory_history_products_read ON app.inventory_products FOR SELECT TO gympro_inventory_read_owner USING(true);
CREATE POLICY inventory_history_movements_read ON app.inventory_stock_movements FOR SELECT TO gympro_inventory_read_owner USING(true);
CREATE POLICY inventory_history_memberships_read ON app.tenant_memberships FOR SELECT TO gympro_inventory_read_owner USING(true);
CREATE POLICY inventory_history_staff_names_read ON app.users FOR SELECT TO gympro_inventory_read_owner USING(true);
CREATE FUNCTION security.read_inventory_stock_history(p_hash bytea,p_tenant uuid,p_branch uuid,p_product uuid,p_from date,p_through date,p_cursor uuid,p_limit integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;v_from date;v_through date;v_lower timestamptz;v_upper timestamptz;v_cursor_created timestamptz;v_result jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_product IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR ((p_from IS NULL)<>(p_through IS NULL)) THEN RAISE EXCEPTION 'Invalid stock history query' USING ERRCODE='22023'; END IF;
 PERFORM ip.id FROM app.inventory_products ip WHERE ip.tenant_id=p_tenant AND ip.id=p_product;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 v_through:=coalesce(p_through,(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date);v_from:=coalesce(p_from,v_through-29);
 IF NOT isfinite(v_from) OR NOT isfinite(v_through) THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 IF v_from<DATE '0001-01-01' OR v_through>DATE '9999-12-30' THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 IF v_through<v_from OR v_through-v_from>365 THEN RAISE EXCEPTION 'Invalid stock history range' USING ERRCODE='22023'; END IF;
 v_lower:=v_from::timestamp AT TIME ZONE 'Asia/Yangon';v_upper:=(v_through+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 IF p_cursor IS NOT NULL THEN
  SELECT mv.created_at INTO v_cursor_created FROM app.inventory_stock_movements mv WHERE mv.tenant_id=p_tenant AND mv.branch_id=p_branch AND mv.product_id=p_product AND mv.id=p_cursor AND mv.created_at>=v_lower AND mv.created_at<v_upper;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid stock history cursor' USING ERRCODE='22023'; END IF;
 END IF;
 WITH candidates AS MATERIALIZED(
  SELECT mv.id,mv.tenant_id,mv.branch_id,mv.product_id,mv.quantity_delta,mv.reason,mv.actor_membership_id,mv.balance_after,mv.product_snapshot,mv.movement_kind,mv.sale_id,mv.return_id,mv.created_at FROM app.inventory_stock_movements mv
  WHERE mv.tenant_id=p_tenant AND mv.branch_id=p_branch AND mv.product_id=p_product AND mv.created_at>=v_lower AND mv.created_at<v_upper AND (p_cursor IS NULL OR (mv.created_at,mv.id)<(v_cursor_created,p_cursor)) ORDER BY mv.created_at DESC,mv.id DESC LIMIT p_limit+1
 ),page AS MATERIALIZED(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT p_limit),public_rows AS(
  SELECT mv.id,mv.created_at,jsonb_build_object('id',mv.id,'tenantId',mv.tenant_id,'branchId',mv.branch_id,'productId',mv.product_id,'createdAt',mv.created_at,'kind',mv.movement_kind,'quantityDelta',mv.quantity_delta,'balanceAfter',mv.balance_after::text,'reason',mv.reason,'actorMembershipId',mv.actor_membership_id,'actorName',coalesce(nullif(left(btrim(staff.full_name),150),''),'Staff'),'sku',mv.product_snapshot->>'sku','productName',mv.product_snapshot->>'productName','saleId',mv.sale_id,'returnId',mv.return_id) AS item
  FROM page mv LEFT JOIN app.tenant_memberships membership ON membership.tenant_id=mv.tenant_id AND membership.id=mv.actor_membership_id LEFT JOIN app.users staff ON staff.id=membership.user_id
 ) SELECT jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'productId',p_product,'from',v_from::text,'through',v_through::text,'items',coalesce((SELECT jsonb_agg(item ORDER BY created_at DESC,id DESC) FROM public_rows),'[]'::jsonb),'nextCursor',CASE WHEN (SELECT count(*) FROM candidates)>p_limit THEN (SELECT id FROM page ORDER BY created_at ASC,id ASC LIMIT 1) ELSE NULL END) INTO v_result;
 RETURN v_result;
END $$;
ALTER FUNCTION security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer) OWNER TO gympro_inventory_read_owner;
REVOKE ALL ON FUNCTION security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.read_inventory_stock_history(bytea,uuid,uuid,uuid,date,date,uuid,integer) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_inventory_read_owner','app.inventory_stock_movements','INSERT,UPDATE,DELETE') OR has_column_privilege('gympro_inventory_read_owner','app.users','password_hash','SELECT') OR has_table_privilege('gympro_app','app.inventory_stock_movements','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'D9 privilege boundary unsafe'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM security.read_inventory_stock_history(NULL,NULL,NULL,NULL,NULL,NULL,NULL,25);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN NULL;END;
 RAISE NOTICE 'PASS: Runtime stock history rejects invalid sessions.';
END $$;
RESET ROLE;
COMMIT;
