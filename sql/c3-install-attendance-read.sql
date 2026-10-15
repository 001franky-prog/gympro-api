\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.check_out_member(bytea,uuid,uuid,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified C2 installation required'; END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_attendance_reader') THEN RAISE EXCEPTION 'Attendance reader already exists; inspect before retry'; END IF;
END $$;
CREATE ROLE gympro_attendance_reader NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
GRANT USAGE ON SCHEMA app,security TO gympro_attendance_reader;
GRANT SELECT ON app.attendance_visits,app.members TO gympro_attendance_reader;
CREATE POLICY c3_visits_read ON app.attendance_visits FOR SELECT TO gympro_attendance_reader USING(true);
CREATE POLICY c3_members_read ON app.members FOR SELECT TO gympro_attendance_reader USING(true);
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_attendance_reader;
CREATE INDEX idx_attendance_branch_history_page ON app.attendance_visits(tenant_id,branch_id,checked_in_at DESC,id DESC);
CREATE INDEX idx_attendance_branch_open_page ON app.attendance_visits(tenant_id,branch_id,checked_in_at DESC,id DESC) WHERE checked_out_at IS NULL;
GRANT CREATE ON SCHEMA security TO gympro_attendance_reader;
CREATE FUNCTION security.read_branch_attendance(p_hash bytea,p_tenant uuid,p_branch uuid,p_current boolean,p_from date,p_to date,p_limit integer,p_before_at timestamptz,p_before_id uuid)
RETURNS TABLE(id uuid,tenant_id uuid,branch_id uuid,member_id uuid,member_number text,full_name text,subscription_id uuid,checked_in_at timestamptz,checked_out_at timestamptz,business_date text,cursor_at text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE v_session record;v_today date;v_from date;v_to date;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_branch IS NULL OR p_current IS NULL OR p_limit IS NULL OR p_limit<1 OR p_limit>100
 OR (p_before_at IS NULL)<>(p_before_id IS NULL) OR (p_before_at IS NOT NULL AND NOT isfinite(p_before_at)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.attendance.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied'; END IF;
 IF p_current THEN
  IF p_from IS NOT NULL OR p_to IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 ELSE
  v_today:=(clock_timestamp() AT TIME ZONE 'Asia/Yangon')::date;
  IF (p_from IS NULL)<>(p_to IS NULL) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
  v_from:=coalesce(p_from,v_today-29);v_to:=coalesce(p_to,v_today+1);
  IF NOT isfinite(v_from) OR NOT isfinite(v_to) OR v_to<=v_from OR v_to-v_from>93 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance query'; END IF;
 END IF;
 RETURN QUERY
 SELECT v.id,v.tenant_id,v.branch_id,v.member_id,m.member_number::text,m.full_name::text,v.subscription_id,v.checked_in_at,v.checked_out_at,v.business_date::text,
 to_char(v.checked_in_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
 FROM app.attendance_visits v JOIN app.members m ON m.tenant_id=v.tenant_id AND m.id=v.member_id
 WHERE v.tenant_id=p_tenant AND v.branch_id=p_branch
 AND ((p_current AND v.checked_out_at IS NULL) OR (NOT p_current AND v.business_date>=v_from AND v.business_date<v_to))
 AND (p_before_at IS NULL OR (v.checked_in_at,v.id)<(p_before_at,p_before_id))
 ORDER BY v.checked_in_at DESC,v.id DESC LIMIT p_limit+1;
END $$;
ALTER FUNCTION security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid) OWNER TO gympro_attendance_reader;
REVOKE CREATE ON SCHEMA security FROM gympro_attendance_reader;
REVOKE ALL ON FUNCTION security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_attendance_reader','app.attendance_visits','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unsafe attendance read privileges'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.read_branch_attendance(NULL,NULL,NULL,false,NULL,NULL,50,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';
 EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Runtime attendance read invalid-session boundary'; END;
END $$;
RESET ROLE;
COMMIT;
