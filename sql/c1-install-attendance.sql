\set ON_ERROR_STOP on
BEGIN;
SELECT to_regclass('app.attendance_visits') IS NULL AS c1_install \gset
\if :c1_install
DO $$ BEGIN
 IF current_database()<>'gympro_saas' THEN RAISE EXCEPTION 'Wrong database'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_attendance_owner') THEN
  CREATE ROLE gympro_attendance_owner NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_attendance_owner' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolinherit))
 OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname='gympro_attendance_owner') OR roleid=(SELECT oid FROM pg_roles WHERE rolname='gympro_attendance_owner')) THEN
 RAISE EXCEPTION 'Unsafe attendance owner'; END IF;
END $$;
ALTER TABLE app.member_subscriptions ADD CONSTRAINT uq_subscriptions_tenant_member_id UNIQUE(tenant_id,member_id,id);
CREATE TABLE app.attendance_visits (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 branch_id uuid NOT NULL,
 member_id uuid NOT NULL,
 subscription_id uuid NOT NULL,
 request_id uuid NOT NULL,
 checked_in_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(checked_in_at)),
 business_date date NOT NULL CHECK(isfinite(business_date)) CHECK(business_date=(checked_in_at AT TIME ZONE 'Asia/Yangon')::date),
 checked_out_at timestamptz CHECK(checked_out_at IS NULL OR (isfinite(checked_out_at) AND checked_out_at>=checked_in_at)),
 actor_membership_id uuid NOT NULL,
 actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 UNIQUE(tenant_id,id), UNIQUE(tenant_id,request_id),
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,member_id) REFERENCES app.members(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,member_id,subscription_id) REFERENCES app.member_subscriptions(tenant_id,member_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_attendance_open_member ON app.attendance_visits(tenant_id,member_id) WHERE checked_out_at IS NULL;
CREATE INDEX idx_attendance_branch_date ON app.attendance_visits(tenant_id,branch_id,business_date DESC);
ALTER TABLE app.attendance_visits ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.attendance_visits FORCE ROW LEVEL SECURITY;
COMMENT ON TABLE app.attendance_visits IS 'GymPro C1 attendance v1';
REVOKE ALL ON app.attendance_visits FROM PUBLIC,gympro_app;
GRANT USAGE ON SCHEMA app,security TO gympro_attendance_owner;
GRANT SELECT ON app.members,app.member_subscriptions,app.branches TO gympro_attendance_owner;
-- PostgreSQL row locks require UPDATE on at least one column. This NOLOGIN
-- owner receives only id-column UPDATE, with policies, to serialize eligibility.
GRANT UPDATE(id) ON app.members,app.member_subscriptions,app.branches TO gympro_attendance_owner;
GRANT SELECT,INSERT ON app.attendance_visits TO gympro_attendance_owner;
CREATE POLICY c1_members_select ON app.members FOR SELECT TO gympro_attendance_owner USING(true);
CREATE POLICY c1_members_lock ON app.members FOR UPDATE TO gympro_attendance_owner USING(true) WITH CHECK(true);
CREATE POLICY c1_subscriptions_select ON app.member_subscriptions FOR SELECT TO gympro_attendance_owner USING(true);
CREATE POLICY c1_subscriptions_lock ON app.member_subscriptions FOR UPDATE TO gympro_attendance_owner USING(true) WITH CHECK(true);
CREATE POLICY c1_branches_select ON app.branches FOR SELECT TO gympro_attendance_owner USING(true);
CREATE POLICY c1_branches_lock ON app.branches FOR UPDATE TO gympro_attendance_owner USING(true) WITH CHECK(true);
CREATE POLICY c1_visits_select ON app.attendance_visits FOR SELECT TO gympro_attendance_owner USING(true);
CREATE POLICY c1_visits_insert ON app.attendance_visits FOR INSERT TO gympro_attendance_owner WITH CHECK(true);
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_attendance_owner;
GRANT CREATE ON SCHEMA security TO gympro_attendance_owner;
CREATE FUNCTION security.check_in_member(p_hash bytea,p_tenant uuid,p_branch uuid,p_member uuid,p_request uuid)
RETURNS SETOF app.attendance_visits LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE v_session record; v_member app.members%ROWTYPE; v_sub app.member_subscriptions%ROWTYPE;
 v_visit app.attendance_visits%ROWTYPE; v_today date; v_at timestamptz;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_member IS NULL OR p_request IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.record',p_branch) IS DISTINCT FROM true THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.attendance:'||p_tenant::text||':'||p_request::text,0));
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant AND id=p_member FOR UPDATE;
 IF NOT FOUND OR (v_member.branch_id IS NOT NULL AND v_member.branch_id<>p_branch) THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 SELECT * INTO v_visit FROM app.attendance_visits WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_visit.member_id<>p_member OR v_visit.branch_id<>p_branch THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
  RETURN NEXT v_visit; RETURN;
 END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 v_at:=clock_timestamp(); v_today:=(v_at AT TIME ZONE 'Asia/Yangon')::date;
 IF v_member.status<>'active' OR EXISTS(SELECT 1 FROM app.attendance_visits WHERE tenant_id=p_tenant AND member_id=p_member AND checked_out_at IS NULL) THEN
 RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 SELECT * INTO v_sub FROM app.member_subscriptions WHERE tenant_id=p_tenant AND member_id=p_member
 AND status='active' AND starts_on<=v_today AND ends_on>v_today
 AND (branch_id IS NULL OR branch_id=p_branch) ORDER BY id LIMIT 1 FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 v_at:=clock_timestamp(); v_today:=(v_at AT TIME ZONE 'Asia/Yangon')::date;
 IF v_sub.starts_on>v_today OR v_sub.ends_on<=v_today THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance request'; END IF;
 INSERT INTO app.attendance_visits(tenant_id,branch_id,member_id,subscription_id,request_id,checked_in_at,business_date,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,p_member,v_sub.id,p_request,v_at,v_today,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id,'membership_kind',v_sub.membership_kind))
 RETURNING * INTO v_visit;
 RETURN NEXT v_visit;
END $$;
ALTER FUNCTION security.check_in_member(bytea,uuid,uuid,uuid,uuid) OWNER TO gympro_attendance_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_attendance_owner;
REVOKE ALL ON FUNCTION security.check_in_member(bytea,uuid,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.check_in_member(bytea,uuid,uuid,uuid,uuid) TO gympro_app;
\endif
DO $$ BEGIN
 IF obj_description('app.attendance_visits'::regclass,'pg_class') IS DISTINCT FROM 'GymPro C1 attendance v1' THEN RAISE EXCEPTION 'Unexpected existing attendance schema'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='app.attendance_visits'::regclass AND relrowsecurity AND relforcerowsecurity) OR
 NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner WHERE p.oid=to_regprocedure('security.check_in_member(bytea,uuid,uuid,uuid,uuid)') AND p.prosecdef AND r.rolname='gympro_attendance_owner' AND NOT r.rolcanlogin AND NOT r.rolsuper AND NOT r.rolbypassrls) THEN RAISE EXCEPTION 'Unsafe attendance security boundary'; END IF;
 IF NOT has_function_privilege('gympro_app','security.check_in_member(bytea,uuid,uuid,uuid,uuid)','EXECUTE')
 OR has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Invalid attendance runtime privileges'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN
  PERFORM * FROM security.check_in_member(NULL,NULL,NULL,NULL,NULL);
  RAISE EXCEPTION 'Invalid session accepted';
 EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Runtime invalid-session boundary'; END;
END $$;
RESET ROLE;
COMMIT;
