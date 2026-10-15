\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'gympro_saas' OR to_regprocedure('security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid)') IS NULL THEN RAISE EXCEPTION 'Verified C3 installation required'; END IF;
END $$;
CREATE ROLE gympro_card_owner NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
INSERT INTO app.permissions(module_code,resource_code,action_code,description)
VALUES('gym','cards','manage','Issue and revoke member cards'),('gym','cards','read','Read member card details') ON CONFLICT(permission_code) DO NOTHING;
CREATE TABLE app.member_cards(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL REFERENCES platform.tenants(id) ON DELETE RESTRICT,
 branch_id uuid NOT NULL,member_id uuid NOT NULL,status varchar(20) NOT NULL DEFAULT 'active' CHECK(status IN('active','revoked')),
 issued_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(issued_at)),revoked_at timestamptz,
 CHECK((status='active' AND revoked_at IS NULL) OR (status='revoked' AND revoked_at IS NOT NULL AND isfinite(revoked_at) AND revoked_at>=issued_at)),
 UNIQUE(tenant_id,id),UNIQUE(tenant_id,branch_id,member_id,id),
 FOREIGN KEY(tenant_id,branch_id) REFERENCES app.branches(tenant_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,member_id) REFERENCES app.members(tenant_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_member_cards_active ON app.member_cards(tenant_id,member_id) WHERE status='active';
CREATE INDEX idx_member_cards_branch_member ON app.member_cards(tenant_id,branch_id,member_id);
CREATE TABLE app.member_card_events(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,branch_id uuid NOT NULL,member_id uuid NOT NULL,card_id uuid NOT NULL,
 request_id uuid NOT NULL,event_type varchar(20) NOT NULL CHECK(event_type IN('issued','revoked')),
 reason text,event_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(event_at)),
 actor_membership_id uuid NOT NULL,actor_snapshot jsonb NOT NULL CHECK(jsonb_typeof(actor_snapshot)='object' AND actor_snapshot<>'{}'::jsonb),
 CHECK((event_type='issued' AND reason IS NULL) OR (event_type='revoked' AND reason IS NOT NULL AND reason=btrim(reason) AND length(reason) BETWEEN 2 AND 500 AND reason ~ '[^[:space:]]')),
 UNIQUE(tenant_id,id),UNIQUE(tenant_id,request_id),UNIQUE(tenant_id,card_id,event_type),
 FOREIGN KEY(tenant_id,branch_id,member_id,card_id) REFERENCES app.member_cards(tenant_id,branch_id,member_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(tenant_id,actor_membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_member_card_events_card ON app.member_card_events(tenant_id,card_id,event_at);
ALTER TABLE app.member_cards ENABLE ROW LEVEL SECURITY;ALTER TABLE app.member_cards FORCE ROW LEVEL SECURITY;
ALTER TABLE app.member_card_events ENABLE ROW LEVEL SECURITY;ALTER TABLE app.member_card_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON app.member_cards,app.member_card_events FROM PUBLIC,gympro_app;
GRANT USAGE ON SCHEMA app,security TO gympro_card_owner;
GRANT SELECT ON app.members,app.branches TO gympro_card_owner;
GRANT UPDATE(id) ON app.members,app.branches TO gympro_card_owner;
GRANT SELECT,INSERT ON app.member_cards,app.member_card_events TO gympro_card_owner;
GRANT UPDATE(status,revoked_at) ON app.member_cards TO gympro_card_owner;
CREATE POLICY c4_members_select ON app.members FOR SELECT TO gympro_card_owner USING(true);
CREATE POLICY c4_members_lock ON app.members FOR UPDATE TO gympro_card_owner USING(true) WITH CHECK(true);
CREATE POLICY c4_branches_select ON app.branches FOR SELECT TO gympro_card_owner USING(true);
CREATE POLICY c4_branches_lock ON app.branches FOR UPDATE TO gympro_card_owner USING(true) WITH CHECK(true);
CREATE POLICY c4_cards_select ON app.member_cards FOR SELECT TO gympro_card_owner USING(true);
CREATE POLICY c4_cards_insert ON app.member_cards FOR INSERT TO gympro_card_owner WITH CHECK(true);
CREATE POLICY c4_cards_update ON app.member_cards FOR UPDATE TO gympro_card_owner USING(true) WITH CHECK(true);
CREATE POLICY c4_events_select ON app.member_card_events FOR SELECT TO gympro_card_owner USING(true);
CREATE POLICY c4_events_insert ON app.member_card_events FOR INSERT TO gympro_card_owner WITH CHECK(true);
GRANT EXECUTE ON FUNCTION security.verify_tenant_session(bytea),security.has_tenant_permission(uuid,uuid,text,uuid) TO gympro_card_owner;
GRANT CREATE ON SCHEMA security TO gympro_card_owner;
CREATE FUNCTION security.change_member_card(p_hash bytea,p_tenant uuid,p_branch uuid,p_subject uuid,p_action text,p_request uuid,p_reason text)
RETURNS SETOF app.member_card_events LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on SET timezone='Asia/Yangon'
AS $$
DECLARE v_session record;v_member app.members%ROWTYPE;v_card app.member_cards%ROWTYPE;v_event app.member_card_events%ROWTYPE;v_member_id uuid;v_at timestamptz;v_reason text;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_branch IS NULL OR p_subject IS NULL OR p_request IS NULL OR p_action IS NULL OR p_action NOT IN('issue','revoke') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 IF security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.cards.manage',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_action='issue' AND p_reason IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 IF p_action='revoke' THEN
  v_reason:=btrim(p_reason);
  IF v_reason IS NULL OR length(v_reason) NOT BETWEEN 2 AND 500 OR v_reason !~ '[^[:space:]]' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('gympro.card:'||p_tenant::text||':'||p_request::text,0));
 IF p_action='issue' THEN v_member_id:=p_subject;
 ELSE SELECT c.member_id INTO v_member_id FROM app.member_cards c WHERE c.tenant_id=p_tenant AND c.id=p_subject AND c.branch_id=p_branch;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 END IF;
 SELECT * INTO v_member FROM app.members WHERE tenant_id=p_tenant AND id=v_member_id FOR UPDATE;
 IF NOT FOUND OR (p_action='issue' AND v_member.branch_id IS NOT NULL AND v_member.branch_id<>p_branch) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 SELECT * INTO v_event FROM app.member_card_events WHERE tenant_id=p_tenant AND request_id=p_request;
 IF FOUND THEN
  IF v_event.branch_id<>p_branch OR (p_action='issue' AND (v_event.event_type<>'issued' OR v_event.member_id<>p_subject)) OR
    (p_action='revoke' AND (v_event.event_type<>'revoked' OR v_event.card_id<>p_subject OR v_event.reason IS DISTINCT FROM v_reason)) THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  RETURN NEXT v_event;RETURN;
 END IF;
 PERFORM 1 FROM app.branches WHERE tenant_id=p_tenant AND id=p_branch AND status='active' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 IF p_action='issue' THEN
  IF v_member.status<>'active' OR EXISTS(SELECT 1 FROM app.member_cards WHERE tenant_id=p_tenant AND member_id=v_member_id AND status='active') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  INSERT INTO app.member_cards(tenant_id,branch_id,member_id) VALUES(p_tenant,p_branch,v_member_id) RETURNING * INTO v_card;
  v_at:=v_card.issued_at;
 ELSE
  SELECT * INTO v_card FROM app.member_cards WHERE tenant_id=p_tenant AND id=p_subject AND branch_id=p_branch AND member_id=v_member_id FOR UPDATE;
  IF NOT FOUND OR v_card.status<>'active' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid card request'; END IF;
  v_at:=greatest(clock_timestamp(),v_card.issued_at);
  UPDATE app.member_cards SET status='revoked',revoked_at=v_at WHERE tenant_id=p_tenant AND id=p_subject;
 END IF;
 INSERT INTO app.member_card_events(tenant_id,branch_id,member_id,card_id,request_id,event_type,reason,event_at,actor_membership_id,actor_snapshot)
 VALUES(p_tenant,p_branch,v_member_id,v_card.id,p_request,CASE WHEN p_action='issue' THEN 'issued' ELSE 'revoked' END,v_reason,v_at,v_session.membership_id,
 jsonb_build_object('membership_id',v_session.membership_id,'user_id',v_session.user_id,'session_id',v_session.session_id)) RETURNING * INTO v_event;
 RETURN NEXT v_event;
END $$;
ALTER FUNCTION security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text) OWNER TO gympro_card_owner;
CREATE FUNCTION security.read_member_card(p_hash bytea,p_tenant uuid,p_branch uuid,p_card uuid)
RETURNS TABLE(id uuid,tenant_id uuid,branch_id uuid,member_id uuid,member_number text,full_name text,status text,issued_at timestamptz,revoked_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $$
DECLARE v_session record;
BEGIN
 SELECT * INTO v_session FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_tenant IS DISTINCT FROM v_session.tenant_id OR p_branch IS NULL OR security.has_tenant_permission(p_tenant,v_session.membership_id,'gym.cards.read',p_branch) IS DISTINCT FROM true THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
 RETURN QUERY SELECT c.id,c.tenant_id,c.branch_id,c.member_id,m.member_number::text,m.full_name::text,c.status::text,c.issued_at,c.revoked_at FROM app.member_cards c JOIN app.members m ON m.tenant_id=c.tenant_id AND m.id=c.member_id WHERE c.tenant_id=p_tenant AND c.branch_id=p_branch AND c.id=p_card;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Card access denied'; END IF;
END $$;
ALTER FUNCTION security.read_member_card(bytea,uuid,uuid,uuid) OWNER TO gympro_card_owner;
REVOKE CREATE ON SCHEMA security FROM gympro_card_owner;
REVOKE ALL ON FUNCTION security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text),security.read_member_card(bytea,uuid,uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text),security.read_member_card(bytea,uuid,uuid,uuid) TO gympro_app;
DO $$ BEGIN
 IF (SELECT count(*) FROM app.permissions WHERE permission_code IN('gym.cards.manage','gym.cards.read') AND is_active)<>2 THEN RAISE EXCEPTION 'Required card permissions are not active'; END IF;
 IF has_table_privilege('gympro_app','app.member_cards','SELECT,INSERT,UPDATE,DELETE') OR has_table_privilege('gympro_app','app.member_card_events','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'Unsafe card table privileges'; END IF;
END $$;
SET LOCAL ROLE gympro_app;
DO $$ BEGIN
 BEGIN PERFORM * FROM security.change_member_card(NULL,NULL,NULL,NULL,'issue',NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Card write invalid-session boundary';END;
 BEGIN PERFORM * FROM security.read_member_card(NULL,NULL,NULL,NULL);RAISE EXCEPTION 'Invalid session accepted';EXCEPTION WHEN SQLSTATE '28000' THEN RAISE NOTICE 'PASS: Card read invalid-session boundary';END;
END $$;
RESET ROLE;
COMMIT;
