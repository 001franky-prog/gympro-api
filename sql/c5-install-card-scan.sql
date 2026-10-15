\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text)') IS NULL THEN RAISE EXCEPTION 'Verified C4 required'; END IF;
END $$;
CREATE TABLE app.card_scan_receipts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,branch_id uuid NOT NULL,member_id uuid NOT NULL,
 card_id uuid NOT NULL,visit_id uuid NOT NULL,request_id uuid NOT NULL,
 scanned_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(scanned_at)),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,visit_id),
 FOREIGN KEY(tenant_id,branch_id,member_id,card_id) REFERENCES app.member_cards(tenant_id,branch_id,member_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,branch_id,member_id,visit_id) REFERENCES app.attendance_visits(tenant_id,branch_id,member_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
ALTER TABLE app.card_scan_receipts ENABLE ROW LEVEL SECURITY;ALTER TABLE app.card_scan_receipts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.card_scan_receipts FROM PUBLIC,gympro_app;
GRANT SELECT,INSERT ON app.card_scan_receipts TO gympro_card_owner;
CREATE POLICY c5_scans_select ON app.card_scan_receipts FOR SELECT TO gympro_card_owner USING(true);
CREATE POLICY c5_scans_insert ON app.card_scan_receipts FOR INSERT TO gympro_card_owner WITH CHECK(true);
GRANT SELECT(tenant_id,request_id) ON app.attendance_visits TO gympro_card_owner;
CREATE POLICY c5_visits_request_read ON app.attendance_visits FOR SELECT TO gympro_card_owner USING(true);
GRANT EXECUTE ON FUNCTION security.check_in_member(bytea,uuid,uuid,uuid,uuid) TO gympro_card_owner;
GRANT CREATE ON SCHEMA security TO gympro_card_owner;
CREATE FUNCTION security.scan_member_card(p_hash bytea,p_tenant uuid,p_branch uuid,p_card uuid,p_request uuid)
RETURNS SETOF app.attendance_visits LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE v_session record;v_card app.member_cards%ROWTYPE;v_member uuid;v_receipt app.card_scan_receipts%ROWTYPE;v_visit app.attendance_visits%ROWTYPE;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 IF p_branch IS NULL OR p_card IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 -- Acquire the delegated check-in request lock BEFORE the member lock.
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance:'||p_tenant::text||':'||p_request::text,0));
 SELECT member_id INTO v_member FROM app.member_cards WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_card;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 PERFORM 1 FROM app.members WHERE tenant_id=p_tenant AND id=v_member FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 -- Card revocation also locks member first, then card: same ordering.
 SELECT * INTO v_card FROM app.member_cards WHERE tenant_id=p_tenant AND branch_id=p_branch AND id=p_card AND member_id=v_member FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card scan access denied'; END IF;
 IF v_card.status<>'active' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan'; END IF;
 SELECT * INTO v_receipt FROM app.card_scan_receipts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_receipt.card_id<>p_card OR v_receipt.branch_id<>p_branch OR v_receipt.member_id<>v_member THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan';END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM app.attendance_visits WHERE tenant_id=p_tenant AND request_id=p_request) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card scan';END IF;
 END IF;
 SELECT * INTO v_visit FROM security.check_in_member(p_hash,p_tenant,p_branch,v_member,p_request);
 IF v_receipt.id IS NULL THEN
  INSERT INTO app.card_scan_receipts(tenant_id,branch_id,member_id,card_id,visit_id,request_id,actor_membership_id,actor_snapshot)
  VALUES(p_tenant,p_branch,v_member,p_card,v_visit.id,p_request,v_session.membership_id,
   jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id));
 END IF;
 RETURN NEXT v_visit;
END $$;
ALTER FUNCTION security.scan_member_card(bytea,uuid,uuid,uuid,uuid) OWNER TO gympro_card_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_card_owner;
REVOKE ALL ON FUNCTION security.scan_member_card(bytea,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.scan_member_card(bytea,uuid,uuid,uuid,uuid) TO gympro_app;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.scan_member_card(NULL,NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Card scan invalid-session boundary';END;
END $$;
RESET ROLE;
COMMIT;
