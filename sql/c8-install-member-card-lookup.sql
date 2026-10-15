\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.search_branch_members(bytea,uuid,uuid,text,integer,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified C7 required';END IF;
END $$;
GRANT CREATE ON SCHEMA security TO gympro_card_owner;
CREATE FUNCTION security.find_member_card(p_hash bytea,p_tenant uuid,p_branch uuid,p_member uuid)
RETURNS TABLE(card_id uuid) LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on
AS $$
DECLARE s record;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session';END IF;
 IF p_tenant IS DISTINCT FROM s.tenant_id OR p_branch IS NULL OR p_member IS NULL OR security.has_tenant_permission(p_tenant,s.membership_id,'gym.cards.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied';END IF;
 PERFORM 1 FROM app.members m WHERE m.tenant_id=p_tenant AND m.id=p_member AND (m.branch_id=p_branch OR m.branch_id IS NULL);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied';END IF;
 RETURN QUERY SELECT c.id FROM app.member_cards c
 WHERE c.tenant_id=p_tenant AND c.branch_id=p_branch AND c.member_id=p_member
 ORDER BY (c.status='active') DESC,c.issued_at DESC,c.id DESC LIMIT 1;
END $$;
ALTER FUNCTION security.find_member_card(bytea,uuid,uuid,uuid) OWNER TO gympro_card_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_card_owner;
REVOKE ALL ON FUNCTION security.find_member_card(bytea,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.find_member_card(bytea,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF has_table_privilege('gympro_app','app.member_cards','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_app','app.members','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unsafe direct runtime access';END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.find_member_card(NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Member card lookup rejects invalid sessions';END;
END $$;
RESET ROLE;
COMMIT;
