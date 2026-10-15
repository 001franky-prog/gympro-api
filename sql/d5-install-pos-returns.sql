\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.pos_sales') IS NULL THEN RAISE EXCEPTION 'D4 is required'; END IF;
 IF to_regclass('app.pos_sale_returns') IS NOT NULL OR to_regclass('app.pos_sale_return_items') IS NOT NULL OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security' AND p.proname IN ('change_pos_sale','read_pos_sale_return','read_pos_sale_return_status')) THEN RAISE EXCEPTION 'D5 objects already exist; stop rather than overwrite'; END IF;
 IF (SELECT count(*) FROM app.permissions WHERE is_active AND permission_code IN ('pos.sales.refund','pos.sales.void','pos.sales.read'))<>3 THEN RAISE EXCEPTION 'Active POS permissions missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_pos_return_owner') THEN CREATE ROLE gympro_pos_return_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_pos_return_owner' AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_return_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_return_owner')) THEN RAISE EXCEPTION 'Return owner must be restricted and isolated'; END IF;
END $$;
CREATE TABLE app.pos_sale_returns(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,branch_id uuid NOT NULL,sale_id uuid NOT NULL,request_id uuid NOT NULL,
 action_code varchar(10) NOT NULL CHECK(action_code IN ('refund','void')),
 reason text NOT NULL CHECK(reason=btrim(reason) AND length(reason) BETWEEN 2 AND 500 AND reason ~ '[^[:space:]]'),
 input_items jsonb NOT NULL CHECK(jsonb_typeof(input_items)='array' AND jsonb_array_length(input_items) BETWEEN 1 AND 50),
 total_amount numeric(26,2) NOT NULL CHECK(total_amount>=0 AND total_amount<>'NaN'::numeric),currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(created_at)),
 UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,branch_id,sale_id,id),
 FOREIGN KEY(tenant_id,branch_id,sale_id) REFERENCES app.pos_sales(tenant_id,branch_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_pos_sale_single_void ON app.pos_sale_returns(tenant_id,sale_id) WHERE action_code='void';
CREATE INDEX idx_pos_sale_returns_sale ON app.pos_sale_returns(tenant_id,sale_id,created_at,id);
CREATE TABLE app.pos_sale_return_items(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,branch_id uuid NOT NULL,sale_id uuid NOT NULL,return_id uuid NOT NULL,sale_item_id uuid NOT NULL,product_id uuid NOT NULL,
 sku varchar(32) NOT NULL CHECK(sku ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'),
 product_name varchar(150) NOT NULL CHECK(product_name=btrim(product_name) AND length(product_name) BETWEEN 2 AND 150 AND product_name ~ '[^[:space:]]'),unit_code varchar(16) NOT NULL,
 quantity integer NOT NULL CHECK(quantity>0),unit_price numeric(14,2) NOT NULL CHECK(unit_price>=0 AND unit_price<>'NaN'::numeric),
 line_total numeric(24,2) NOT NULL CHECK(line_total=quantity::numeric*unit_price AND line_total<>'NaN'::numeric),
 UNIQUE(tenant_id,return_id,sale_item_id),UNIQUE(tenant_id,branch_id,sale_id,return_id,id,sale_item_id,product_id),
 FOREIGN KEY(tenant_id,branch_id,sale_id,return_id) REFERENCES app.pos_sale_returns(tenant_id,branch_id,sale_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,branch_id,sale_id,sale_item_id,product_id) REFERENCES app.pos_sale_items(tenant_id,branch_id,sale_id,id,product_id) ON DELETE RESTRICT
);
CREATE INDEX idx_pos_return_items_original ON app.pos_sale_return_items(tenant_id,sale_id,sale_item_id);
DROP INDEX app.uq_inventory_movement_sale_item;
CREATE UNIQUE INDEX uq_inventory_movement_sale_item ON app.inventory_stock_movements(tenant_id,sale_item_id) WHERE movement_kind='sale';
ALTER TABLE app.inventory_stock_movements DROP CONSTRAINT chk_inventory_movement_kind;
ALTER TABLE app.inventory_stock_movements ADD COLUMN return_id uuid,ADD COLUMN return_item_id uuid,
 ADD CONSTRAINT chk_inventory_movement_kind CHECK(
 (movement_kind='adjustment' AND sale_id IS NULL AND sale_item_id IS NULL AND return_id IS NULL AND return_item_id IS NULL) OR
 (movement_kind='sale' AND sale_id IS NOT NULL AND sale_item_id IS NOT NULL AND quantity_delta<0 AND return_id IS NULL AND return_item_id IS NULL) OR
 (movement_kind IN ('refund','void') AND sale_id IS NOT NULL AND sale_item_id IS NOT NULL AND quantity_delta>0 AND return_id IS NOT NULL AND return_item_id IS NOT NULL)),
 ADD CONSTRAINT fk_inventory_movement_return_item FOREIGN KEY(tenant_id,branch_id,sale_id,return_id,return_item_id,sale_item_id,product_id) REFERENCES app.pos_sale_return_items(tenant_id,branch_id,sale_id,return_id,id,sale_item_id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX uq_inventory_movement_return_item ON app.inventory_stock_movements(tenant_id,return_item_id) WHERE return_item_id IS NOT NULL;
ALTER TABLE app.pos_sale_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sale_returns FORCE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sale_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sale_return_items FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.pos_sale_returns,app.pos_sale_return_items FROM PUBLIC,gympro_app;
GRANT USAGE ON SCHEMA app,security TO gympro_pos_return_owner;
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_pos_return_owner;
GRANT SELECT ON app.pos_sales,app.pos_sale_items,app.inventory_products TO gympro_pos_return_owner;
GRANT UPDATE(id) ON app.pos_sales,app.inventory_products TO gympro_pos_return_owner;
GRANT SELECT,INSERT ON app.pos_sale_returns,app.pos_sale_return_items,app.inventory_stock_movements TO gympro_pos_return_owner;
CREATE POLICY pos_return_sales_read ON app.pos_sales FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_sales_lock ON app.pos_sales FOR UPDATE TO gympro_pos_return_owner USING(true) WITH CHECK(true);
CREATE POLICY pos_return_sale_items_read ON app.pos_sale_items FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_products_read ON app.inventory_products FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_products_lock ON app.inventory_products FOR UPDATE TO gympro_pos_return_owner USING(true) WITH CHECK(true);
CREATE POLICY pos_return_movements_read ON app.inventory_stock_movements FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_movements_insert ON app.inventory_stock_movements FOR INSERT TO gympro_pos_return_owner WITH CHECK(true);
CREATE POLICY pos_return_history_read ON app.pos_sale_returns FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_history_insert ON app.pos_sale_returns FOR INSERT TO gympro_pos_return_owner WITH CHECK(true);
CREATE POLICY pos_return_items_read ON app.pos_sale_return_items FOR SELECT TO gympro_pos_return_owner USING(true);
CREATE POLICY pos_return_items_insert ON app.pos_sale_return_items FOR INSERT TO gympro_pos_return_owner WITH CHECK(true);

CREATE FUNCTION security.change_pos_sale(p_hash bytea,p_tenant uuid,p_branch uuid,p_sale uuid,p_action text,p_items jsonb,p_reason text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;v_sale app.pos_sales%ROWTYPE;v_existing app.pos_sale_returns%ROWTYPE;v_line app.pos_sale_items%ROWTYPE;v_item jsonb;v_cart jsonb;v_count integer;v_total numeric;v_returned bigint;v_balance bigint;v_new_balance numeric;v_return_id uuid;v_return_item_id uuid;v_quantity integer;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('refund','void') THEN RAISE EXCEPTION 'Invalid action' USING ERRCODE='22023'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,CASE p_action WHEN 'refund' THEN 'pos.sales.refund' ELSE 'pos.sales.void' END,p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Returns require read committed isolation' USING ERRCODE='22023'; END IF;
 p_reason:=btrim(p_reason);
 IF p_sale IS NULL OR p_request IS NULL OR p_reason IS NULL OR length(p_reason) NOT BETWEEN 2 AND 500 OR p_reason!~'[^[:space:]]' THEN RAISE EXCEPTION 'Invalid return request' USING ERRCODE='22023'; END IF;
 IF p_action='refund' THEN
  IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'Invalid return cart' USING ERRCODE='22023'; END IF;
  IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'Invalid return cart size' USING ERRCODE='22023'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
   IF jsonb_typeof(v_item)<>'object' THEN RAISE EXCEPTION 'Invalid return item' USING ERRCODE='22023'; END IF;
   IF (SELECT count(*) FROM jsonb_object_keys(v_item))<>2 OR NOT(v_item ? 'saleItemId' AND v_item ? 'quantity') OR jsonb_typeof(v_item->'saleItemId') IS DISTINCT FROM 'string' OR (v_item->>'saleItemId')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR jsonb_typeof(v_item->'quantity') IS DISTINCT FROM 'number' OR (v_item->>'quantity')!~'^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'Invalid return fields' USING ERRCODE='22023'; END IF;
   IF (v_item->>'quantity')::numeric>2147483647 THEN RAISE EXCEPTION 'Excess return quantity' USING ERRCODE='22023'; END IF;
  END LOOP;
  SELECT jsonb_agg(jsonb_build_object('saleItemId',(value->>'saleItemId')::uuid,'quantity',(value->>'quantity')::integer) ORDER BY (value->>'saleItemId')::uuid),count(DISTINCT (value->>'saleItemId')::uuid) INTO v_cart,v_count FROM jsonb_array_elements(p_items);
  IF v_count<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'Duplicate return items' USING ERRCODE='22023'; END IF;
 ELSE
  IF p_items IS NOT NULL THEN RAISE EXCEPTION 'Void does not accept items' USING ERRCODE='22023'; END IF;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,204));
 SELECT * INTO v_existing FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_existing.branch_id<>p_branch OR v_existing.sale_id<>p_sale OR v_existing.action_code<>p_action OR v_existing.reason<>p_reason OR (p_action='refund' AND v_existing.input_items<>v_cart) THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  v_return_id:=v_existing.id;
 ELSE
  SELECT * INTO v_sale FROM app.pos_sales WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_sale FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM app.pos_sale_returns WHERE tenant_id=p_tenant AND sale_id=p_sale AND (action_code='void' OR p_action='void')) THEN RAISE EXCEPTION 'Sale already reversed or refunded' USING ERRCODE='22023'; END IF;
  IF p_action='void' THEN SELECT jsonb_agg(jsonb_build_object('saleItemId',li.id,'quantity',li.quantity) ORDER BY li.id) INTO v_cart FROM app.pos_sale_items li WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale; END IF;
  IF v_cart IS NULL THEN RAISE EXCEPTION 'Invalid empty sale' USING ERRCODE='22023'; END IF;
  SELECT count(*),sum(li.unit_price*(ci.value->>'quantity')::integer) INTO v_count,v_total FROM jsonb_array_elements(v_cart) ci JOIN app.pos_sale_items li ON li.tenant_id=p_tenant AND li.sale_id=p_sale AND li.id=(ci.value->>'saleItemId')::uuid;
  IF v_count<>jsonb_array_length(v_cart) THEN RAISE EXCEPTION 'Unknown sale item' USING ERRCODE='22023'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT v_line FROM app.pos_sale_items WHERE tenant_id=p_tenant AND sale_id=p_sale AND id=(v_item->>'saleItemId')::uuid;
   SELECT coalesce(sum(quantity),0) INTO v_returned FROM app.pos_sale_return_items WHERE tenant_id=p_tenant AND sale_item_id=v_line.id;
   IF v_returned+(v_item->>'quantity')::bigint>v_line.quantity THEN RAISE EXCEPTION 'Return exceeds sold quantity' USING ERRCODE='22023'; END IF;
  END LOOP;
  PERFORM ip.id FROM app.inventory_products ip WHERE ip.tenant_id=p_tenant AND ip.id IN (SELECT li.product_id FROM app.pos_sale_items li JOIN jsonb_array_elements(v_cart) ci ON li.id=(ci.value->>'saleItemId')::uuid WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale) ORDER BY ip.id FOR UPDATE;
  INSERT INTO app.pos_sale_returns(tenant_id,branch_id,sale_id,request_id,action_code,reason,input_items,total_amount,actor_membership_id,actor_snapshot) VALUES(p_tenant,p_branch,p_sale,p_request,p_action,p_reason,v_cart,v_total,v_session.membership_id,jsonb_build_object('membershipId',v_session.membership_id,'userId',v_session.user_id,'sessionId',v_session.session_id)) RETURNING id INTO v_return_id;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT v_line FROM app.pos_sale_items WHERE tenant_id=p_tenant AND sale_id=p_sale AND id=(v_item->>'saleItemId')::uuid;
   v_quantity:=(v_item->>'quantity')::integer;
   SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=v_line.product_id;
   v_new_balance:=v_balance::numeric+v_quantity::numeric;
   IF v_new_balance<0 OR v_new_balance>9223372036854775807::numeric THEN RAISE EXCEPTION 'Invalid resulting stock' USING ERRCODE='22023'; END IF;
   INSERT INTO app.pos_sale_return_items(tenant_id,branch_id,sale_id,return_id,sale_item_id,product_id,sku,product_name,unit_code,quantity,unit_price,line_total) VALUES(p_tenant,p_branch,p_sale,v_return_id,v_line.id,v_line.product_id,v_line.sku,v_line.product_name,v_line.unit_code,v_quantity,v_line.unit_price,v_quantity::numeric*v_line.unit_price) RETURNING id INTO v_return_item_id;
   INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot,movement_kind,sale_id,sale_item_id,return_id,return_item_id) VALUES(p_tenant,p_branch,v_line.product_id,v_return_item_id,v_quantity,p_reason,v_session.membership_id,jsonb_build_object('membershipId',v_session.membership_id,'userId',v_session.user_id,'sessionId',v_session.session_id),v_new_balance::bigint,jsonb_build_object('sku',v_line.sku,'productName',v_line.product_name,'unitCode',v_line.unit_code,'salePrice',v_line.unit_price::text,'currencyCode','MMK'),p_action,p_sale,v_line.id,v_return_id,v_return_item_id);
  END LOOP;
 END IF;
 SELECT jsonb_build_object('id',sr.id,'tenantId',sr.tenant_id,'branchId',sr.branch_id,'saleId',sr.sale_id,'requestId',sr.request_id,'action',sr.action_code,'reason',sr.reason,'currencyCode',sr.currency_code,'totalAmount',sr.total_amount::text,'createdAt',sr.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',ri.id,'saleItemId',ri.sale_item_id,'productId',ri.product_id,'sku',ri.sku,'productName',ri.product_name,'unitCode',ri.unit_code,'quantity',ri.quantity,'unitPrice',ri.unit_price::text,'lineTotal',ri.line_total::text) ORDER BY ri.sale_item_id) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sr.tenant_id AND ri.return_id=sr.id)) INTO v_receipt FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.branch_id=p_branch AND sr.sale_id=p_sale AND sr.id=v_return_id;
 RETURN v_receipt;
END $$;
CREATE FUNCTION security.read_pos_sale_return(p_hash bytea,p_tenant uuid,p_branch uuid,p_sale uuid,p_return uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;v_return_id uuid:=p_return;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',sr.id,'tenantId',sr.tenant_id,'branchId',sr.branch_id,'saleId',sr.sale_id,'requestId',sr.request_id,'action',sr.action_code,'reason',sr.reason,'currencyCode',sr.currency_code,'totalAmount',sr.total_amount::text,'createdAt',sr.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',ri.id,'saleItemId',ri.sale_item_id,'productId',ri.product_id,'sku',ri.sku,'productName',ri.product_name,'unitCode',ri.unit_code,'quantity',ri.quantity,'unitPrice',ri.unit_price::text,'lineTotal',ri.line_total::text) ORDER BY ri.sale_item_id) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=sr.tenant_id AND ri.return_id=sr.id)) INTO v_receipt FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.branch_id=p_branch AND sr.sale_id=p_sale AND sr.id=v_return_id;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale return' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;
CREATE FUNCTION security.read_pos_sale_return_status(p_hash bytea,p_tenant uuid,p_branch uuid,p_sale uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;v_receipt jsonb;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR v_session.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 WITH original AS (SELECT li.id,li.product_id,li.quantity,coalesce((SELECT sum(ri.quantity) FROM app.pos_sale_return_items ri WHERE ri.tenant_id=li.tenant_id AND ri.sale_item_id=li.id),0)::integer AS returned FROM app.pos_sale_items li WHERE li.tenant_id=p_tenant AND li.sale_id=p_sale),
 totals AS (SELECT count(*)>0 AS any_return,coalesce(bool_or(sr.action_code='void'),false) AS voided,coalesce(sum(sr.total_amount),0)::numeric(26,2) AS amount FROM app.pos_sale_returns sr WHERE sr.tenant_id=p_tenant AND sr.sale_id=p_sale)
 SELECT jsonb_build_object('tenantId',sh.tenant_id,'branchId',sh.branch_id,'saleId',sh.id,'status',CASE WHEN totals.voided THEN 'voided' WHEN NOT EXISTS(SELECT 1 FROM original WHERE returned<quantity) THEN 'refunded' WHEN totals.any_return THEN 'partially_refunded' ELSE 'completed' END,'voided',totals.voided,'currencyCode',sh.currency_code,'saleTotalAmount',sh.total_amount::text,'reversedAmount',totals.amount::text,'items',(SELECT jsonb_agg(jsonb_build_object('saleItemId',original.id,'productId',original.product_id,'quantitySold',original.quantity,'quantityReturned',original.returned,'quantityRemaining',original.quantity-original.returned) ORDER BY original.id) FROM original)) INTO v_receipt FROM app.pos_sales sh CROSS JOIN totals WHERE sh.tenant_id=p_tenant AND sh.branch_id=p_branch AND sh.id=p_sale;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;
ALTER FUNCTION security.change_pos_sale(bytea,uuid,uuid,uuid,text,jsonb,text,uuid) OWNER TO gympro_pos_return_owner;
ALTER FUNCTION security.read_pos_sale_return(bytea,uuid,uuid,uuid,uuid) OWNER TO gympro_pos_return_owner;
ALTER FUNCTION security.read_pos_sale_return_status(bytea,uuid,uuid,uuid) OWNER TO gympro_pos_return_owner;
REVOKE ALL ON FUNCTION security.change_pos_sale(bytea,uuid,uuid,uuid,text,jsonb,text,uuid),security.read_pos_sale_return(bytea,uuid,uuid,uuid,uuid),security.read_pos_sale_return_status(bytea,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.change_pos_sale(bytea,uuid,uuid,uuid,text,jsonb,text,uuid),security.read_pos_sale_return(bytea,uuid,uuid,uuid,uuid),security.read_pos_sale_return_status(bytea,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_pos_return_owner','app.pos_sale_returns','UPDATE,DELETE') OR has_table_privilege('gympro_pos_return_owner','app.pos_sale_return_items','UPDATE,DELETE') OR has_table_privilege('gympro_pos_return_owner','app.inventory_stock_movements','UPDATE,DELETE') THEN RAISE EXCEPTION 'Return audit owner must not mutate history'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM security.change_pos_sale(NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.read_pos_sale_return(NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.read_pos_sale_return_status(NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 RAISE NOTICE 'PASS: All D5 functions reject invalid sessions as runtime.';
END $$;
RESET ROLE;
COMMIT;
