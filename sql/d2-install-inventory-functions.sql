\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected gympro_saas as postgres'; END IF;
 IF to_regclass('app.inventory_products') IS NULL OR to_regclass('app.inventory_stock_movements') IS NULL THEN RAISE EXCEPTION 'D1 is required'; END IF;
 IF to_regclass('app.inventory_product_events') IS NOT NULL THEN RAISE EXCEPTION 'D2 already installed; do not overwrite'; END IF;
 IF EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security' AND p.proname IN ('create_inventory_product','update_inventory_product','read_inventory_products','adjust_inventory_stock','read_inventory_stock')) THEN RAISE EXCEPTION 'Inventory function name already exists; stop rather than modify it'; END IF;
 IF EXISTS(SELECT 1 FROM app.inventory_stock_movements) THEN RAISE EXCEPTION 'D2 expects the empty D1 movement ledger'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_inventory_owner') THEN CREATE ROLE gympro_inventory_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_inventory_owner' AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_inventory_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_inventory_owner')) THEN RAISE EXCEPTION 'Inventory owner must be isolated and restricted'; END IF;
END $$;
ALTER TABLE app.inventory_products ADD CONSTRAINT chk_inventory_product_name_nonblank CHECK(product_name ~ '[^[:space:]]');
ALTER TABLE app.inventory_stock_movements ADD COLUMN balance_after bigint NOT NULL,
 ADD COLUMN product_snapshot jsonb NOT NULL,
 ADD CONSTRAINT chk_inventory_movement_balance CHECK(balance_after>=0),
 ADD CONSTRAINT chk_inventory_movement_product_snapshot CHECK(jsonb_typeof(product_snapshot)='object' AND product_snapshot<>'{}'::jsonb);
CREATE TABLE app.inventory_product_events(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 product_id uuid NOT NULL,
 request_id uuid NOT NULL,
 action_code text NOT NULL CHECK(action_code IN ('create','update')),
 input_snapshot jsonb NOT NULL CHECK(jsonb_typeof(input_snapshot)='object' AND input_snapshot<>'{}'::jsonb),
 actor_membership_id uuid NOT NULL,
 actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 receipt jsonb NOT NULL CHECK(jsonb_typeof(receipt)='object' AND receipt<>'{}'::jsonb),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(created_at)),
 UNIQUE(tenant_id,request_id),
 FOREIGN KEY(tenant_id,product_id) REFERENCES app.inventory_products(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_inventory_product_events_product ON app.inventory_product_events(tenant_id,product_id,created_at,id);
ALTER TABLE app.inventory_product_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.inventory_product_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.inventory_product_events FROM PUBLIC,gympro_app;
GRANT USAGE ON SCHEMA app,security TO gympro_inventory_owner;
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_inventory_owner;
GRANT SELECT,INSERT ON app.inventory_products,app.inventory_stock_movements,app.inventory_product_events TO gympro_inventory_owner;
GRANT UPDATE(id,product_name,description,sale_price,status,updated_at) ON app.inventory_products TO gympro_inventory_owner;
CREATE POLICY inventory_products_owner_select ON app.inventory_products FOR SELECT TO gympro_inventory_owner USING(true);
CREATE POLICY inventory_products_owner_insert ON app.inventory_products FOR INSERT TO gympro_inventory_owner WITH CHECK(true);
CREATE POLICY inventory_products_owner_update ON app.inventory_products FOR UPDATE TO gympro_inventory_owner USING(true) WITH CHECK(true);
CREATE POLICY inventory_movements_owner_select ON app.inventory_stock_movements FOR SELECT TO gympro_inventory_owner USING(true);
CREATE POLICY inventory_movements_owner_insert ON app.inventory_stock_movements FOR INSERT TO gympro_inventory_owner WITH CHECK(true);
CREATE POLICY inventory_events_owner_select ON app.inventory_product_events FOR SELECT TO gympro_inventory_owner USING(true);
CREATE POLICY inventory_events_owner_insert ON app.inventory_product_events FOR INSERT TO gympro_inventory_owner WITH CHECK(true);

CREATE FUNCTION security.create_inventory_product(p_hash bytea,p_tenant uuid,p_sku text,p_name text,p_description text,p_price numeric,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; p app.inventory_products%ROWTYPE; e app.inventory_product_events%ROWTYPE; v_input jsonb; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.create',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 p_sku:=upper(btrim(p_sku));p_name:=btrim(p_name);p_description:=nullif(btrim(p_description),'');
 IF p_request IS NULL OR p_sku IS NULL OR p_sku!~'^[A-Z0-9][A-Z0-9_-]{0,31}$' OR p_name IS NULL OR length(p_name) NOT BETWEEN 2 AND 150 OR p_name!~'[^[:space:]]' OR coalesce(length(p_description),0)>2000 OR p_price IS NULL OR p_price<0 OR p_price>999999999999.99 OR p_price='NaN'::numeric OR p_price<>round(p_price,2) THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 v_input:=jsonb_build_object('sku',p_sku,'name',p_name,'description',p_description,'price',p_price);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,201));
 SELECT * INTO e FROM app.inventory_product_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF e.action_code<>'create' OR e.input_snapshot<>v_input THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  RETURN e.receipt;
 END IF;
 INSERT INTO app.inventory_products(tenant_id,sku,product_name,description,sale_price) VALUES(p_tenant,p_sku,p_name,p_description,p_price) RETURNING * INTO p;
 v_receipt:=jsonb_build_object('id',p.id,'tenantId',p.tenant_id,'sku',p.sku,'productName',p.product_name,'description',p.description,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code,'status',p.status,'createdAt',p.created_at,'updatedAt',p.updated_at,'requestId',p_request);
 INSERT INTO app.inventory_product_events(tenant_id,product_id,request_id,action_code,input_snapshot,actor_membership_id,actor_snapshot,receipt) VALUES(p_tenant,p.id,p_request,'create',v_input,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_receipt);
 RETURN v_receipt;
END $$;

CREATE FUNCTION security.update_inventory_product(p_hash bytea,p_tenant uuid,p_product uuid,p_name text,p_description text,p_price numeric,p_status text,p_request uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; p app.inventory_products%ROWTYPE; e app.inventory_product_events%ROWTYPE; v_input jsonb; v_receipt jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.update',NULL) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 p_name:=btrim(p_name);p_description:=nullif(btrim(p_description),'');
 IF p_request IS NULL OR p_product IS NULL OR p_name IS NULL OR length(p_name) NOT BETWEEN 2 AND 150 OR p_name!~'[^[:space:]]' OR coalesce(length(p_description),0)>2000 OR p_price IS NULL OR p_price<0 OR p_price>999999999999.99 OR p_price='NaN'::numeric OR p_price<>round(p_price,2) OR p_status IS NULL OR p_status NOT IN ('draft','active','inactive') THEN RAISE EXCEPTION 'Invalid product update' USING ERRCODE='22023'; END IF;
 v_input:=jsonb_build_object('productId',p_product,'name',p_name,'description',p_description,'price',p_price,'status',p_status);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_request::text,201));
 SELECT * INTO e FROM app.inventory_product_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF e.action_code<>'update' OR e.input_snapshot<>v_input THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
  RETURN e.receipt;
 END IF;
 SELECT * INTO p FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 UPDATE app.inventory_products SET product_name=p_name,description=p_description,sale_price=p_price,status=p_status,updated_at=greatest(clock_timestamp(),created_at) WHERE tenant_id=p_tenant AND id=p_product RETURNING * INTO p;
 v_receipt:=jsonb_build_object('id',p.id,'tenantId',p.tenant_id,'sku',p.sku,'productName',p.product_name,'description',p.description,'unitCode',p.unit_code,'salePrice',p.sale_price::text,'currencyCode',p.currency_code,'status',p.status,'createdAt',p.created_at,'updatedAt',p.updated_at,'requestId',p_request);
 INSERT INTO app.inventory_product_events(tenant_id,product_id,request_id,action_code,input_snapshot,actor_membership_id,actor_snapshot,receipt) VALUES(p_tenant,p.id,p_request,'update',v_input,s.membership_id,jsonb_build_object('membershipId',s.membership_id,'userId',s.user_id,'sessionId',s.session_id),v_receipt);
 RETURN v_receipt;
END $$;

CREATE FUNCTION security.read_inventory_products(p_hash bytea,p_tenant uuid,p_branch uuid,p_after uuid DEFAULT NULL,p_limit integer DEFAULT 25)
RETURNS TABLE(id uuid,tenant_id uuid,sku text,product_name text,description text,unit_code text,sale_price text,currency_code text,status text,updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Invalid limit' USING ERRCODE='22023'; END IF;
 RETURN QUERY SELECT p.id,p.tenant_id,p.sku::text,p.product_name::text,p.description,p.unit_code::text,p.sale_price::text,p.currency_code::text,p.status::text,p.updated_at FROM app.inventory_products p WHERE p.tenant_id=p_tenant AND (p_after IS NULL OR p.id>p_after) ORDER BY p.id LIMIT p_limit+1;
END $$;

CREATE FUNCTION security.adjust_inventory_stock(p_hash bytea,p_tenant uuid,p_branch uuid,p_product uuid,p_delta integer,p_reason text,p_request uuid)
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
  IF m.branch_id<>p_branch OR m.product_id<>p_product OR m.quantity_delta<>p_delta OR m.reason<>p_reason THEN RAISE EXCEPTION 'Request conflict' USING ERRCODE='22023'; END IF;
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

CREATE FUNCTION security.read_inventory_stock(p_hash bytea,p_tenant uuid,p_branch uuid,p_product uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE s record; v_balance bigint;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid session' USING ERRCODE='28000'; END IF;
 IF p_tenant IS NULL OR s.tenant_id<>p_tenant OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'inventory.products.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Permission denied' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.inventory_products WHERE tenant_id=p_tenant AND id=p_product) THEN RAISE EXCEPTION 'Invalid product' USING ERRCODE='22023'; END IF;
 SELECT coalesce(sum(quantity_delta),0) INTO v_balance FROM app.inventory_stock_movements WHERE tenant_id=p_tenant AND branch_id=p_branch AND product_id=p_product;
 RETURN jsonb_build_object('tenantId',p_tenant,'branchId',p_branch,'productId',p_product,'quantity',v_balance::text);
END $$;
DO $$ DECLARE f record;
BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='security' AND p.proname IN ('create_inventory_product','update_inventory_product','read_inventory_products','adjust_inventory_stock','read_inventory_stock') LOOP
  EXECUTE format('ALTER FUNCTION %s OWNER TO gympro_inventory_owner',f.signature);
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',f.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO gympro_app',f.signature);
 END LOOP;
 IF has_table_privilege('gympro_inventory_owner','app.inventory_stock_movements','UPDATE,DELETE') OR has_table_privilege('gympro_inventory_owner','app.inventory_product_events','UPDATE,DELETE') THEN RAISE EXCEPTION 'History owner has mutation access'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM security.create_inventory_product(NULL,NULL,NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.update_inventory_product(NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.read_inventory_products(NULL,NULL,NULL,NULL,25); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.adjust_inventory_stock(NULL,NULL,NULL,NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 BEGIN PERFORM security.read_inventory_stock(NULL,NULL,NULL,NULL); RAISE EXCEPTION 'Invalid session accepted'; EXCEPTION WHEN SQLSTATE '28000' THEN NULL; END;
 RAISE NOTICE 'PASS: All five D2 functions reject invalid sessions as runtime.';
END $$;
RESET ROLE;
COMMIT;