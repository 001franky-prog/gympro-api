\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.find_member_card(bytea,uuid,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified C8 required';END IF;
END $$;
GRANT CREATE ON SCHEMA security TO gympro_attendance_reader;
CREATE FUNCTION security.summarize_branch_attendance(p_hash bytea,p_tenant uuid,p_branch uuid,p_day date)
RETURNS TABLE(tenant_id uuid,branch_id uuid,summary_day text,check_ins integer,distinct_members integer,check_outs integer,current_occupancy integer,generated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE s record;d date;at_time timestamptz;from_time timestamptz;to_time timestamptz;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.attendance.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Attendance access denied';END IF;
 at_time:=clock_timestamp();d:=coalesce(p_day,(at_time AT TIME ZONE 'Asia/Yangon')::date);
 IF NOT isfinite(d) OR d<DATE '0001-01-01' OR d>DATE '9999-12-31' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid attendance day';END IF;
 from_time:=d::timestamp AT TIME ZONE 'Asia/Yangon';to_time:=(d+1)::timestamp AT TIME ZONE 'Asia/Yangon';
 -- One aggregate statement, one MVCC snapshot. Occupancy includes all open visits,
 -- even when the selected summary day is historical or the visit began yesterday.
 RETURN QUERY SELECT p_tenant,p_branch,d::text,
 (count(*) FILTER(WHERE v.checked_in_at>=from_time AND v.checked_in_at<to_time))::integer,
 (count(DISTINCT v.member_id) FILTER(WHERE v.checked_in_at>=from_time AND v.checked_in_at<to_time))::integer,
 (count(*) FILTER(WHERE v.checked_out_at>=from_time AND v.checked_out_at<to_time))::integer,
 (count(*) FILTER(WHERE v.checked_out_at IS NULL))::integer,at_time
 FROM app.attendance_visits v WHERE v.tenant_id=p_tenant AND v.branch_id=p_branch
 AND ((v.checked_in_at>=from_time AND v.checked_in_at<to_time) OR (v.checked_out_at>=from_time AND v.checked_out_at<to_time) OR v.checked_out_at IS NULL);
END $$;
ALTER FUNCTION security.summarize_branch_attendance(bytea,uuid,uuid,date) OWNER TO gympro_attendance_reader;
REVOKE CREATE ON SCHEMA security FROM gympro_attendance_reader;
REVOKE ALL ON FUNCTION security.summarize_branch_attendance(bytea,uuid,uuid,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.summarize_branch_attendance(bytea,uuid,uuid,date) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_attendance_reader','app.attendance_visits','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unsafe attendance table access';END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.summarize_branch_attendance(NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Attendance summary rejects invalid sessions';END;
END $$;
RESET ROLE;
COMMIT;
