\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.scan_member_card(bytea,uuid,uuid,uuid,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified C6 database required'; END IF;
END $$;
CREATE ROLE gympro_member_reader NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
GRANT USAGE ON SCHEMA app,security TO gympro_member_reader;
GRANT SELECT ON app.members TO gympro_member_reader;
CREATE POLICY c7_members_read ON app.members FOR SELECT TO gympro_member_reader USING(true);
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_member_reader;
GRANT CREATE ON SCHEMA security TO gympro_member_reader;
CREATE FUNCTION security.search_branch_members(p_hash bytea,p_tenant uuid,p_branch uuid,p_query text,p_limit integer,p_after uuid)
RETURNS TABLE(id uuid,tenant_id uuid,branch_id uuid,member_number text,full_name text,status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on
AS $$
DECLARE s record;q text;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.members.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Member lookup access denied';END IF;
 q:=btrim(p_query);
 IF q IS NULL OR length(q) NOT BETWEEN 2 AND 100 OR q !~ '[^[:space:]]' OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid member lookup';END IF;
 -- Branch-assigned members only. Unassigned tenant-wide members are not exposed on this branch route.
 RETURN QUERY SELECT m.id,m.tenant_id,m.branch_id,m.member_number::text,m.full_name::text,m.status::text
 FROM app.members m WHERE m.tenant_id=p_tenant AND m.branch_id=p_branch
 AND (p_after IS NULL OR m.id>p_after)
 AND (strpos(lower(m.full_name),lower(q))>0 OR strpos(lower(m.member_number),lower(q))>0)
 ORDER BY m.id LIMIT p_limit+1;
END $$;
ALTER FUNCTION security.search_branch_members(bytea,uuid,uuid,text,integer,uuid) OWNER TO gympro_member_reader;
REVOKE CREATE ON SCHEMA security FROM gympro_member_reader;
REVOKE ALL ON FUNCTION security.search_branch_members(bytea,uuid,uuid,text,integer,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.search_branch_members(bytea,uuid,uuid,text,integer,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.members','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unexpected runtime member access';END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='gympro_member_reader' AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreatedb OR rolcreaterole OR rolinherit)) OR EXISTS(SELECT 1 FROM pg_auth_members WHERE member='gympro_member_reader'::regrole OR roleid='gympro_member_reader'::regrole) THEN RAISE EXCEPTION 'Unsafe reader role';END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.search_branch_members(NULL,NULL,NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Member lookup invalid-session boundary verified';END;
END $$;
RESET ROLE;
COMMIT;
