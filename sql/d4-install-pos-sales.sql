\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected local gympro_saas as postgres'; END IF;
 IF to_regclass('app.inventory_product_events') IS NULL THEN RAISE EXCEPTION 'Verified D2 is required'; END IF;
 IF to_regclass('app.pos_sales') IS NOT NULL OR to_regclass('app.pos_sale_items') IS NOT NULL OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security' AND p.proname IN ('create_pos_sale','read_pos_sale')) THEN RAISE EXCEPTION 'D4 objects already exist; stop rather than overwrite'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_pos_owner') THEN CREATE ROLE gympro_pos_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_pos_owner' AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_pos_owner')) THEN RAISE EXCEPTION 'POS owner must be restricted and isolated'; END IF;
 IF (SELECT count(*) FROM app.permissions WHERE is_active AND permission_code IN ('pos.sales.create','pos.sales.read'))<>2 THEN RAISE EXCEPTION 'Active POS permissions missing'; END IF;
END $$;
CREATE TABLE app.pos_sales(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 branch_id uuid NOT NULL,request_id uuid NOT NULL,
 input_cart jsonb NOT NULL CHECK(jsonb_typeof(input_cart)='array' AND jsonb_array_length(input_cart) BETWEEN 1 AND 50),
 status varchar(20) NOT NULL DEFAULT 'completed' CHECK(status='completed'),
 total_amount numeric(26,2) NOT NULL CHECK(total_amount>=0 AND total_amount<>'NaN'::numeric),
 currency_code varchar(3) NOT NULL DEFAULT 'MMK' CHECK(currency_code='MMK'),
 actor_membership_id uuid NOT NULL,
 actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(created_at)),
 UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,branch_id,id),
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE TABLE app.pos_sale_items(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,branch_id uuid NOT NULL,sale_id uuid NOT NULL,product_id uuid NOT NULL,
 sku varchar(32) NOT NULL CHECK(sku ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'),
 product_name varchar(150) NOT NULL CHECK(product_name=btrim(product_name) AND length(product_name) BETWEEN 2 AND 150 AND product_name ~ '[^[:space:]]'),
 unit_code varchar(16) NOT NULL,
 quantity integer NOT NULL CHECK(quantity>0),
 unit_price numeric(14,2) NOT NULL CHECK(unit_price>=0 AND unit_price<>'NaN'::numeric),
 line_total numeric(24,2) NOT NULL CHECK(line_total=quantity::numeric*unit_price AND line_total<>'NaN'::numeric),
 UNIQUE(tenant_id,sale_id,product_id),UNIQUE(tenant_id,branch_id,sale_id,id,product_id),
 FOREIGN KEY(tenant_id,branch_id,sale_id) REFERENCES app.pos_sales(tenant_id,branch_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,product_id) REFERENCES app.inventory_products(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_pos_sales_branch_time ON app.pos_sales(tenant_id,branch_id,created_at,id);
ALTER TABLE app.inventory_stock_movements
 ADD COLUMN movement_kind varchar(16) NOT NULL DEFAULT 'adjustment',ADD COLUMN sale_id uuid,ADD COLUMN sale_item_id uuid,
 ADD CONSTRAINT chk_inventory_movement_kind CHECK((movement_kind='adjustment' AND sale_id IS NULL AND sale_item_id IS NULL) OR (movement_kind='sale' AND sale_id IS NOT NULL AND sale_item_id IS NOT NULL AND quantity_delta<0)),
 ADD CONSTRAINT fk_inventory_movement_sale_item FOREIGN KEY(tenant_id,branch_id,sale_id,sale_item_id,product_id) REFERENCES app.pos_sale_items(tenant_id,branch_id,sale_id,id,product_id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX uq_inventory_movement_sale_item ON app.inventory_stock_movements(tenant_id,sale_item_id) WHERE sale_item_id IS NOT NULL;
ALTER TABLE app.pos_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sales FORCE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.pos_sale_items FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.pos_sales,app.pos_sale_items FROM PUBLIC,gympro_app;
GRANT USAGE ON SCHEMA app,security TO gympro_pos_owner;
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_pos_owner;
GRANT SELECT ON app.inventory_products TO gympro_pos_owner;
GRANT UPDATE(id) ON app.inventory_products TO gympro_pos_owner;
GRANT SELECT,INSERT ON app.inventory_stock_movements,app.pos_sales,app.pos_sale_items TO gympro_pos_owner;
CREATE POLICY pos_products_select ON app.inventory_products FOR SELECT TO gympro_pos_owner USING(true);
CREATE POLICY pos_products_lock ON app.inventory_products FOR UPDATE TO gympro_pos_owner USING(true) WITH CHECK(true);
CREATE POLICY pos_movements_select ON app.inventory_stock_movements FOR SELECT TO gympro_pos_owner USING(true);
CREATE POLICY pos_movements_insert ON app.inventory_stock_movements FOR INSERT TO gympro_pos_owner WITH CHECK(true);
CREATE POLICY pos_sales_select ON app.pos_sales FOR SELECT TO gympro_pos_owner USING(true);
CREATE POLICY pos_sales_insert ON app.pos_sales FOR INSERT TO gympro_pos_owner WITH CHECK(true);
CREATE POLICY pos_items_select ON app.pos_sale_items FOR SELECT TO gympro_pos_owner USING(true);
CREATE POLICY pos_items_insert ON app.pos_sale_items FOR INSERT TO gympro_pos_owner WITH CHECK(true);
CREATE FUNCTION security.create_pos_sale(p_hash bytea,p_tenant uuid,p_branch uuid,p_items jsonb,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; v_existing app.pos_sales%ROWTYPE; p app.inventory_products%ROWTYPE; item jsonb; v_cart jsonb; v_count integer; v_balance bigint; v_total numeric; v_sale_id uuid; v_item_id uuid; v_quantity integer; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'pos.sales.create',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Sales require read committed isolation' USING ERRCODE='22023'; END IF;
 IF p_request IS NULL OR p_items IS NULL OR jsonb_typeof(p_items)<>'array' THEN RAISE EXCEPTION 'Invalid sale request' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'Invalid cart size' USING ERRCODE='22023'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
  IF jsonb_typeof(item)<>'object' THEN RAISE EXCEPTION 'Invalid cart item' USING ERRCODE='22023'; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(item))<>2 OR NOT(item ? 'productId' AND item ? 'quantity') OR jsonb_typeof(item->'productId')<>'string' OR (item->>'productId')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR jsonb_typeof(item->'quantity')<>'number' OR (item->>'quantity')!~'^[1-9][0-9]{0,9}$' THEN RAISE EXCEPTION 'Invalid cart fields' USING ERRCODE='22023'; END IF;
  IF (item->>'quantity')::numeric>2147483647 THEN RAISE EXCEPTION 'Excess quantity' USING ERRCODE='22023'; END IF;
 END LOOP;
 SELECT jsonb_agg(jsonb_build_object('productId',(value->>'productId')::uuid,'quantity',(value->>'quantity')::integer) ORDER BY (value->>'productId')::uuid),count(DISTINCT (value->>'productId')::uuid) INTO v_cart,v_count FROM jsonb_array_elements(p_items);
 IF v_count<>jsonb_array_length(p_items) THEN RAISE EXCEPTION 'Duplicate products' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,203));
 SELECT * INTO v_existing FROM app.pos_sales WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_existing.branch_id<>p_branch OR v_existing.input_cart<>v_cart THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  v_sale_id:=v_existing.id;
 ELSE
  PERFORM q.id FROM app.inventory_products q WHERE q.tenant_id=p_tenant AND q.id IN (SELECT (value->>'productId')::uuid FROM jsonb_array_elements(v_cart)) ORDER BY q.id FOR UPDATE;
  SELECT count(*),sum(q.sale_price*(x.value->>'quantity')::integer) INTO v_count,v_total FROM jsonb_array_elements(v_cart) x JOIN app.inventory_products q ON q.tenant_id=p_tenant AND q.id=(x.value->>'productId')::uuid AND q.status='active';
  IF v_count<>jsonb_array_length(v_cart) THEN RAISE EXCEPTION 'Invalid active product' USING ERRCODE='22023'; END IF;
  INSERT INTO app.pos_sales(tenant_id,branch_id,request_id,input_cart,total_amount,actor_membership_id,actor_snapshot) VALUES(p_tenant,p_branch,p_request,v_cart,v_total,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id)) RETURNING id INTO v_sale_id;
  FOR item IN SELECT value FROM jsonb_array_elements(v_cart) LOOP
   SELECT * INTO STRICT p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=(item->>'productId')::uuid;
   v_quantity:=(item->>'quantity')::integer;
   SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p.id;
   IF v_balance<v_quantity THEN RAISE EXCEPTION 'Insufficient stock' USING ERRCODE='22023'; END IF;
   INSERT INTO app.pos_sale_items(tenant_id,branch_id,sale_id,product_id,sku,product_name,unit_code,quantity,unit_price,line_total) VALUES(p_tenant,p_branch,v_sale_id,p.id,p.sku,p.product_name,p.unit_code,v_quantity,p.sale_price,v_quantity::numeric*p.sale_price) RETURNING id INTO v_item_id;
   INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot,movement_kind,sale_id,sale_item_id) VALUES(p_tenant,p_branch,p.id,v_item_id,-v_quantity,'POS sale',s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_balance-v_quantity,jsonb_build_object('sku',p.sku,'productName',p.product_name,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code),'sale',v_sale_id,v_item_id);
  END LOOP;
 END IF;
 SELECT jsonb_build_object('id',h.id,'tenantId',h.tenant_id,'branchId',h.branch_id,'requestId',h.request_id,'status',h.status,'currencyCode',h.currency_code,'totalAmount',h.total_amount::text,'createdAt',h.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'productId',i.product_id,'sku',i.sku,'productName',i.product_name,'unitCode',i.unit_code,'quantity',i.quantity,'unitPrice',i.unit_price::text,'lineTotal',i.line_total::text) ORDER BY i.product_id) FROM app.pos_sale_items i WHERE i.tenant_id=h.tenant_id AND i.sale_id=h.id)) INTO v_receipt FROM app.pos_sales h WHERE h.tenant_id=p_tenant AND h.branch_id=p_branch AND h.id=v_sale_id;
 RETURN v_receipt;
END $$;
CREATE FUNCTION security.read_pos_sale(p_hash bytea,p_tenant uuid,p_branch uuid,p_sale uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; v_sale_id uuid:=p_sale; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'pos.sales.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 SELECT jsonb_build_object('id',h.id,'tenantId',h.tenant_id,'branchId',h.branch_id,'requestId',h.request_id,'status',h.status,'currencyCode',h.currency_code,'totalAmount',h.total_amount::text,'createdAt',h.created_at,'items',(SELECT jsonb_agg(jsonb_build_object('id',i.id,'productId',i.product_id,'sku',i.sku,'productName',i.product_name,'unitCode',i.unit_code,'quantity',i.quantity,'unitPrice',i.unit_price::text,'lineTotal',i.line_total::text) ORDER BY i.product_id) FROM app.pos_sale_items i WHERE i.tenant_id=h.tenant_id AND i.sale_id=h.id)) INTO v_receipt FROM app.pos_sales h WHERE h.tenant_id=p_tenant AND h.branch_id=p_branch AND h.id=v_sale_id;
 IF v_receipt IS NULL THEN RAISE EXCEPTION 'Invalid sale' USING ERRCODE='22023'; END IF;
 RETURN v_receipt;
END $$;
ALTER FUNCTION security.create_pos_sale(bytea,uuid,uuid,jsonb,uuid) OWNER TO gympro_pos_owner;
ALTER FUNCTION security.read_pos_sale(bytea,uuid,uuid,uuid) OWNER TO gympro_pos_owner;
REVOKE ALL ON FUNCTION security.create_pos_sale(bytea,uuid,uuid,jsonb,uuid),security.read_pos_sale(bytea,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.create_pos_sale(bytea,uuid,uuid,jsonb,uuid),security.read_pos_sale(bytea,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_pos_owner','app.pos_sales','UPDATE,DELETE') OR has_table_privilege('gympro_pos_owner','app.pos_sale_items','UPDATE,DELETE') OR has_table_privilege('gympro_pos_owner','app.inventory_stock_movements','UPDATE,DELETE') THEN RAISE EXCEPTION 'POS history must be append-only for owner'; END IF;
END $$;
CREATE OR REPLACE FUNCTION security.adjust_inventory_stock(p_hash bytea,p_tenant uuid,p_branch uuid,p_product uuid,p_delta integer,p_reason text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; p app.inventory_products%ROWTYPE; m app.inventory_stock_movements%ROWTYPE; v_balance bigint; v_new numeric;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.stock.adjust',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF current_setting('transaction_isolation')<>'read committed' THEN RAISE EXCEPTION 'Stock adjustment requires read committed isolation' USING ERRCODE='22023'; END IF;
 p_reason:=btrim(p_reason);
 IF p_product IS NULL OR p_request IS NULL OR p_delta IS NULL OR p_delta=0 OR p_reason IS NULL OR length(p_reason) NOT BETWEEN 2 AND 500 OR p_reason!~'[^[:space:]]' THEN RAISE EXCEPTION 'Invalid adjustment' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,202));
 SELECT * INTO m FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF m.movement_kind<>'adjustment' OR m.branch_id<>p_branch OR m.product_id<>p_product OR m.quantity_delta<>p_delta OR m.reason<>p_reason THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
 ELSE
  SELECT * INTO p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product FOR UPDATE;
  IF NOT FOUND OR p.status<>'active' THEN RAISE EXCEPTION 'Invalid active product' USING ERRCODE='22023'; END IF;
  SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p_product;
  v_new:=v_balance::numeric+p_delta::numeric;
  IF v_new<0 OR v_new>9223372036854775807::numeric THEN RAISE EXCEPTION 'Insufficient or excessive stock' USING ERRCODE='22023'; END IF;
  INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot,balance_after,product_snapshot)
  VALUES(p_tenant,p_branch,p_product,p_request,p_delta,p_reason,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_new::bigint,jsonb_build_object('sku',p.sku,'productName',p.product_name,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code)) RETURNING * INTO m;
 END IF;
 RETURN jsonb_build_object('id',m.id,'tenantId',m.tenant_id,'branchId',m.branch_id,'productId',m.product_id,'requestId',m.request_id,'quantityDelta',m.quantity_delta,'balanceAfter',m.balance_after::text,'reason',m.reason,'createdAt',m.created_at);
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM security.create_pos_sale(NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.read_pos_sale(NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 RAISE NOTICE 'PASS: POS functions reject invalid sessions as runtime.';
END $$;
RESET ROLE;
COMMIT;
