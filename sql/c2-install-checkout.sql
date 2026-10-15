\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR obj_description('app.attendance_visits'::regclass,'pg_class') IS DISTINCT FROM 'GymPro C1 attendance v1' THEN RAISE EXCEPTION 'Expected verified C1 database'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_attendance_owner' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolinherit)) OR
 EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_attendance_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_attendance_owner')) THEN RAISE EXCEPTION 'Unsafe attendance owner'; END IF;
END $$;
ALTER TABLE app.attendance_visits ADD CONSTRAINT uq_visits_tenant_branch_member_id UNIQUE(tenant_id,branch_id,member_id,id);
CREATE TABLE app.attendance_checkouts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL,
 visit_id uuid NOT NULL,
 branch_id uuid NOT NULL,
 member_id uuid NOT NULL,
 request_id uuid NOT NULL,
 checked_in_at timestamptz NOT NULL CHECK(isfinite(checked_in_at)),
 checked_out_at timestamptz NOT NULL CHECK(isfinite(checked_out_at) AND checked_out_at>=checked_in_at),
 actor_membership_id uuid NOT NULL,
 actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 UNIQUE(tenant_id,id),UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,visit_id),
 FOREIGN KEY(tenant_id,branch_id,member_id,visit_id) REFERENCES app.attendance_visits(tenant_id,branch_id,member_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,member_id) REFERENCES app.members(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_attendance_checkouts_branch ON app.attendance_checkouts(tenant_id,branch_id,checked_out_at DESC);
ALTER TABLE app.attendance_checkouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.attendance_checkouts FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.attendance_checkouts FROM PUBLIC,gympro_app;
GRANT SELECT,INSERT ON app.attendance_checkouts TO gympro_attendance_owner;
GRANT UPDATE(checked_out_at) ON app.attendance_visits TO gympro_attendance_owner;
CREATE POLICY c2_checkouts_select ON app.attendance_checkouts FOR SELECT TO gympro_attendance_owner USING(true);
CREATE POLICY c2_checkouts_insert ON app.attendance_checkouts FOR INSERT TO gympro_attendance_owner WITH CHECK(true);
CREATE POLICY c2_visits_update ON app.attendance_visits FOR UPDATE TO gympro_attendance_owner USING(true) WITH CHECK(true);
GRANT CREATE ON SCHEMA security TO gympro_attendance_owner;
CREATE FUNCTION security.check_out_member(p_hash bytea,p_tenant uuid,p_branch uuid,p_visit uuid,p_request uuid)
RETURNS SETOF app.attendance_checkouts LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE v_session record; v_visit app.attendance_visits%ROWTYPE; v_member uuid;
 v_receipt app.attendance_checkouts%ROWTYPE; v_at timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_visit IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance.checkout:'||p_tenant::text||':'||p_request::text,0));
 SELECT member_id INTO v_member FROM app.attendance_visits WHERE tenant_id=p_tenant AND id=p_visit AND branch_id=p_branch;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 -- Same member-before-visit lock order as check-in and membership operations.
 PERFORM 1 FROM app.members WHERE tenant_id=p_tenant AND id=v_member FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_visit FROM app.attendance_visits WHERE tenant_id=p_tenant AND id=p_visit AND member_id=v_member AND branch_id=p_branch FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_receipt FROM app.attendance_checkouts WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_receipt.visit_id<>p_visit OR v_receipt.branch_id<>p_branch THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
  RETURN NEXT v_receipt; RETURN;
 END IF;
 IF v_visit.checked_out_at IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 v_at:=greatest(clock_timestamp(),v_visit.checked_in_at);
 INSERT INTO app.attendance_checkouts(tenant_id,visit_id,branch_id,member_id,request_id,checked_in_at,checked_out_at,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_visit,p_branch,v_member,p_request,v_visit.checked_in_at,v_at,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id)) RETURNING * INTO v_receipt;
 UPDATE app.attendance_visits SET checked_out_at=v_at WHERE tenant_id=p_tenant AND id=p_visit;
 RETURN NEXT v_receipt;
END $$;
ALTER FUNCTION security.check_out_member(bytea,uuid,uuid,uuid,uuid) OWNER TO gympro_attendance_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_attendance_owner;
REVOKE ALL ON FUNCTION security.check_out_member(bytea,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.check_out_member(bytea,uuid,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_app','app.attendance_checkouts','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unsafe runtime table privileges'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.check_out_member(NULL,NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';
 EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Runtime checkout invalid-session boundary'; END;
END $$;
RESET ROLE;
COMMIT;
