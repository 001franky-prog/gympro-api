\set ON_ERROR_STOP on
\pset pager off
BEGIN;
DO $$
BEGIN
 IF current_database()<>'gympro_saas' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Expected local gympro_saas as postgres'; END IF;
 IF to_regclass('app.inventory_products') IS NOT NULL OR to_regclass('app.inventory_stock_movements') IS NOT NULL THEN RAISE EXCEPTION 'D1 tables already exist; stop rather than overwrite'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_app') THEN RAISE EXCEPTION 'Runtime role missing'; END IF;
 IF (SELECT count(*) FROM app.permissions WHERE is_active AND permission_code IN ('inventory.products.create','inventory.products.read','inventory.products.update','inventory.stock.adjust','pos.sales.create','pos.sales.read','pos.sales.refund','pos.sales.void'))<>8 THEN RAISE EXCEPTION 'Expected eight existing active inventory/POS permissions'; END IF;
END $$;
CREATE TABLE app.inventory_products (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 sku varchar(32) NOT NULL,
 product_name varchar(150) NOT NULL,
 description text,
 unit_code varchar(16) NOT NULL DEFAULT 'piece',
 sale_price numeric(14,2) NOT NULL,
 currency_code varchar(3) NOT NULL DEFAULT 'MMK',
 status varchar(20) NOT NULL DEFAULT 'draft',
 created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
 CONSTRAINT uq_inventory_products_tenant_id UNIQUE(tenant_id,id),
 CONSTRAINT uq_inventory_products_tenant_sku UNIQUE(tenant_id,sku),
 CONSTRAINT chk_inventory_products_sku CHECK(sku ~ '^[A-Z0-9][A-Z0-9_-]{0,31}$'),
 CONSTRAINT chk_inventory_products_name CHECK(product_name=btrim(product_name) AND length(product_name) BETWEEN 2 AND 150),
 CONSTRAINT chk_inventory_products_unit CHECK(unit_code ~ '^[a-z][a-z0-9_]{0,15}$'),
 CONSTRAINT chk_inventory_products_price CHECK(sale_price >= 0 AND sale_price <> 'NaN'::numeric),
 CONSTRAINT chk_inventory_products_currency CHECK(currency_code='MMK'),
 CONSTRAINT chk_inventory_products_status CHECK(status IN ('draft','active','inactive')),
 CONSTRAINT chk_inventory_products_times CHECK(isfinite(created_at) AND isfinite(updated_at) AND updated_at>=created_at)
);
CREATE INDEX idx_inventory_products_tenant_status ON app.inventory_products(tenant_id,status,id);
CREATE TABLE app.inventory_stock_movements (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 branch_id uuid NOT NULL,
 product_id uuid NOT NULL,
 request_id uuid NOT NULL,
 quantity_delta integer NOT NULL,
 reason text NOT NULL,
 actor_membership_id uuid NOT NULL,
 actor_snapshot jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT uq_inventory_stock_movements_tenant_id UNIQUE(tenant_id,id),
 CONSTRAINT uq_inventory_stock_movements_request UNIQUE(tenant_id,request_id),
 CONSTRAINT fk_inventory_movement_branch FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 CONSTRAINT fk_inventory_movement_product FOREIGN KEY(tenant_id,product_id) REFERENCES app.inventory_products(tenant_id,id) ON DELETE RESTRICT,
 CONSTRAINT fk_inventory_movement_actor FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT,
 CONSTRAINT chk_inventory_movement_quantity CHECK(quantity_delta<>0),
 CONSTRAINT chk_inventory_movement_reason CHECK(reason=btrim(reason) AND length(reason) BETWEEN 2 AND 500 AND reason ~ '[^[:space:]]'),
 CONSTRAINT chk_inventory_movement_snapshot CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 CONSTRAINT chk_inventory_movement_time CHECK(isfinite(created_at))
);
CREATE INDEX idx_inventory_movements_product_branch ON app.inventory_stock_movements(tenant_id,branch_id,product_id,created_at,id);
ALTER TABLE app.inventory_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.inventory_products FORCE ROW LEVEL SECURITY;
ALTER TABLE app.inventory_stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.inventory_stock_movements FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.inventory_products,app.inventory_stock_movements FROM PUBLIC,gympro_app;

SAVEPOINT d1_fixtures;
CREATE TEMP TABLE d1_results(test_name text PRIMARY KEY,result text NOT NULL) ON COMMIT DROP;
CREATE FUNCTION pg_temp.d1_reject(p_name text,p_sql text,p_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN
 BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE; END;
 IF v_state IS DISTINCT FROM p_state THEN RAISE EXCEPTION 'Test % expected %, received %',p_name,p_state,coalesce(v_state,'success'); END IF;
 INSERT INTO pg_temp.d1_results VALUES(p_name,'PASS');
END $$;
DO $$
DECLARE
 t uuid:='d0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
 t2 uuid:='b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
 b uuid:='fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c';
 m uuid:='3b318e89-f3bc-4ac5-a04d-09fdb3d626de';
 p uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); req uuid:=gen_random_uuid();
 marker text:='D1_'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,20));
 q text; r record;
BEGIN
 INSERT INTO app.inventory_products(id,tenant_id,sku,product_name,sale_price) VALUES(p,t,marker,'D1 verification product',1500);
 SELECT * INTO STRICT r FROM app.inventory_products WHERE id=p;
 IF r.status<>'draft' OR r.unit_code<>'piece' OR r.currency_code<>'MMK' OR r.created_at<>r.updated_at THEN RAISE EXCEPTION 'Product defaults mismatch'; END IF;
 INSERT INTO pg_temp.d1_results VALUES('01_product_defaults','PASS');
 INSERT INTO app.inventory_products(id,tenant_id,sku,product_name,sale_price) VALUES(p2,t2,marker,'Other tenant product',0);
 INSERT INTO pg_temp.d1_results VALUES('02_same_sku_other_tenant_allowed','PASS');
 q:=format('INSERT INTO app.inventory_products(tenant_id,sku,product_name,sale_price) VALUES(%L,%L,%L,10)',t,marker,'Duplicate');
 PERFORM pg_temp.d1_reject('03_duplicate_tenant_sku',q,'23505');
 PERFORM pg_temp.d1_reject('04_negative_price',format('UPDATE app.inventory_products SET sale_price=-1 WHERE id=%L',p),'23514');
 PERFORM pg_temp.d1_reject('05_nan_price',format('UPDATE app.inventory_products SET sale_price=''NaN'' WHERE id=%L',p),'23514');
 PERFORM pg_temp.d1_reject('06_padded_sku',format('UPDATE app.inventory_products SET sku='' BAD '' WHERE id=%L',p),'23514');
 PERFORM pg_temp.d1_reject('07_blank_name',format('UPDATE app.inventory_products SET product_name='' '' WHERE id=%L',p),'23514');
 PERFORM pg_temp.d1_reject('08_invalid_currency',format('UPDATE app.inventory_products SET currency_code=''USD'' WHERE id=%L',p),'23514');
 PERFORM pg_temp.d1_reject('09_invalid_status',format('UPDATE app.inventory_products SET status=''deleted'' WHERE id=%L',p),'23514');
 INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot)
 VALUES(t,b,p,req,10,'Initial test stock',m,jsonb_build_object('membershipId',m));
 INSERT INTO pg_temp.d1_results VALUES('10_stock_movement_and_actor','PASS');
 PERFORM pg_temp.d1_reject('11_duplicate_movement_request',format('INSERT INTO app.inventory_stock_movements(tenant_id,branch_id,product_id,request_id,quantity_delta,reason,actor_membership_id,actor_snapshot) VALUES(%L,%L,%L,%L,1,''Duplicate request'',%L,''{"test":true}'')',t,b,p,req,m),'23505');
 PERFORM pg_temp.d1_reject('12_zero_quantity',format('UPDATE app.inventory_stock_movements SET quantity_delta=0 WHERE request_id=%L',req),'23514');
 PERFORM pg_temp.d1_reject('13_blank_reason',format('UPDATE app.inventory_stock_movements SET reason=E''\t\t'' WHERE request_id=%L',req),'23514');
 PERFORM pg_temp.d1_reject('14_empty_actor_snapshot',format('UPDATE app.inventory_stock_movements SET actor_snapshot=''{}'' WHERE request_id=%L',req),'23514');
 PERFORM pg_temp.d1_reject('15_array_actor_snapshot',format('UPDATE app.inventory_stock_movements SET actor_snapshot=''[]'' WHERE request_id=%L',req),'23514');
 PERFORM pg_temp.d1_reject('16_other_tenant_product',format('UPDATE app.inventory_stock_movements SET product_id=%L WHERE request_id=%L',p2,req),'23503');
 PERFORM pg_temp.d1_reject('17_unknown_branch',format('UPDATE app.inventory_stock_movements SET branch_id=%L WHERE request_id=%L',gen_random_uuid(),req),'23503');
 PERFORM pg_temp.d1_reject('18_unknown_actor',format('UPDATE app.inventory_stock_movements SET actor_membership_id=%L WHERE request_id=%L',gen_random_uuid(),req),'23503');
 PERFORM pg_temp.d1_reject('19_infinite_timestamp',format('UPDATE app.inventory_stock_movements SET created_at=''infinity'' WHERE request_id=%L',req),'23514');
 IF (SELECT count(*) FROM app.inventory_stock_movements WHERE product_id=p)<>1 THEN RAISE EXCEPTION 'Rejected writes changed movement count'; END IF;
 INSERT INTO pg_temp.d1_results VALUES('20_rejections_saved_no_extra_movements','PASS');
 IF EXISTS(SELECT 1 FROM pg_class WHERE oid IN ('app.inventory_products'::regclass,'app.inventory_stock_movements'::regclass) AND (NOT relrowsecurity OR NOT relforcerowsecurity)) THEN RAISE EXCEPTION 'Missing forced RLS'; END IF;
 IF has_table_privilege('gympro_app','app.inventory_products','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_app','app.inventory_stock_movements','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unexpected runtime direct access'; END IF;
 INSERT INTO pg_temp.d1_results VALUES('21_forced_rls_and_no_runtime_crud','PASS');
END $$;
SET LOCAL ROLE gympro_app;
DO $$
BEGIN
 BEGIN PERFORM 1 FROM app.inventory_products; RAISE EXCEPTION 'Runtime product SELECT unexpectedly allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN PERFORM 1 FROM app.inventory_stock_movements; RAISE EXCEPTION 'Runtime movement SELECT unexpectedly allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
INSERT INTO pg_temp.d1_results VALUES('22_runtime_select_denied','PASS');
SELECT * FROM pg_temp.d1_results ORDER BY test_name;
ROLLBACK TO SAVEPOINT d1_fixtures;
DO $$
BEGIN
 IF EXISTS(SELECT 1 FROM app.inventory_products) OR EXISTS(SELECT 1 FROM app.inventory_stock_movements) THEN RAISE EXCEPTION 'Fixture rollback failed'; END IF;
 RAISE NOTICE 'PASS: D1 fixtures rolled back; product and movement tables empty.';
END $$;
COMMIT;
SELECT n.nspname AS schema_name,c.relname AS table_name,c.relrowsecurity AS rls_enabled,c.relforcerowsecurity AS rls_forced,
 has_table_privilege('gympro_app',c.oid,'SELECT,INSERT,UPDATE,DELETE') AS runtime_has_direct_crud
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.oid IN ('app.inventory_products'::regclass,'app.inventory_stock_movements'::regclass) ORDER BY c.relname;