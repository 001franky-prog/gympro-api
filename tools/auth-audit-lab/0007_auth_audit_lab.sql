-- Isolated rehearsal only. No live migration adoption or retention policy implied.
CREATE TABLE security.auth_audit_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK(isfinite(occurred_at)),
 event_type text NOT NULL CHECK(event_type IN ('login_succeeded','login_rejected','session_revoked','password_changed')),
 tenant_id uuid,user_id uuid,
 CHECK ((event_type='login_rejected' AND tenant_id IS NULL AND user_id IS NULL) OR (event_type<>'login_rejected' AND tenant_id IS NOT NULL AND user_id IS NOT NULL))
);
ALTER TABLE security.auth_audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.auth_audit_events FORCE ROW LEVEL SECURITY;
REVOKE ALL ON security.auth_audit_events FROM PUBLIC,gympro_app,gympro_auth,gympro_session;
GRANT SELECT,INSERT ON security.auth_audit_events TO gympro_session_owner;
CREATE POLICY audit_owner_select ON security.auth_audit_events FOR SELECT TO gympro_session_owner USING(true);
CREATE POLICY audit_owner_insert ON security.auth_audit_events FOR INSERT TO gympro_session_owner WITH CHECK(true);
CREATE INDEX auth_audit_self_history ON security.auth_audit_events(tenant_id,user_id,occurred_at DESC,id DESC);
CREATE FUNCTION security.capture_auth_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE uid uuid;
BEGIN
 IF TG_TABLE_NAME='tenant_sessions' THEN
  SELECT user_id INTO STRICT uid FROM app.tenant_memberships WHERE id=NEW.membership_id AND tenant_id=NEW.tenant_id;
  IF TG_OP='INSERT' THEN
   INSERT INTO security.auth_audit_events(event_type,tenant_id,user_id) VALUES('login_succeeded',NEW.tenant_id,uid);
  ELSIF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
   INSERT INTO security.auth_audit_events(event_type,tenant_id,user_id) VALUES('session_revoked',NEW.tenant_id,uid);
  END IF;
 ELSIF OLD.password_hash IS DISTINCT FROM NEW.password_hash THEN
  INSERT INTO security.auth_audit_events(event_type,tenant_id,user_id)
   SELECT 'password_changed',tenant_id,NEW.id FROM app.tenant_memberships WHERE user_id=NEW.id;
 END IF;
 RETURN NEW;
END $$;
ALTER FUNCTION security.capture_auth_audit() OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.capture_auth_audit() FROM PUBLIC,gympro_app,gympro_auth,gympro_session;
CREATE TRIGGER audit_session_insert AFTER INSERT ON security.tenant_sessions FOR EACH ROW EXECUTE FUNCTION security.capture_auth_audit();
CREATE TRIGGER audit_session_revoke AFTER UPDATE OF revoked_at ON security.tenant_sessions FOR EACH ROW EXECUTE FUNCTION security.capture_auth_audit();
CREATE TRIGGER audit_password_change AFTER UPDATE OF password_hash ON app.users FOR EACH ROW EXECUTE FUNCTION security.capture_auth_audit();
CREATE FUNCTION security.reject_audit_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF current_user<>'postgres' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Audit events are append only'; END IF;
 RETURN OLD;
END $$;
REVOKE ALL ON FUNCTION security.reject_audit_mutation() FROM PUBLIC,gympro_app,gympro_auth,gympro_session,gympro_session_owner;
CREATE TRIGGER audit_no_mutation BEFORE UPDATE OR DELETE ON security.auth_audit_events FOR EACH ROW EXECUTE FUNCTION security.reject_audit_mutation();
CREATE FUNCTION security.record_rejected_login() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 INSERT INTO security.auth_audit_events(event_type) VALUES('login_rejected');
$$;
ALTER FUNCTION security.record_rejected_login() OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.record_rejected_login() FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.record_rejected_login() TO gympro_auth;
CREATE FUNCTION security.read_own_auth_audit(p_hash bytea,p_limit integer DEFAULT 25,p_before uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE s record; boundary timestamptz; result jsonb;
BEGIN
 SELECT * INTO s FROM security.verify_tenant_session(p_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>50 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid history limit'; END IF;
 IF p_before IS NOT NULL THEN
  SELECT occurred_at INTO boundary FROM security.auth_audit_events WHERE id=p_before AND tenant_id=s.tenant_id AND user_id=s.user_id;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid history cursor'; END IF;
 END IF;
 SELECT jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object('id',q.id,'occurredAt',q.occurred_at,'eventType',q.event_type) ORDER BY q.occurred_at DESC,q.id DESC),'[]'::jsonb)) INTO result
 FROM (SELECT id,occurred_at,event_type FROM security.auth_audit_events WHERE tenant_id=s.tenant_id AND user_id=s.user_id AND (p_before IS NULL OR (occurred_at,id)<(boundary,p_before)) ORDER BY occurred_at DESC,id DESC LIMIT p_limit+1) q;
 RETURN result;
END $$;
ALTER FUNCTION security.read_own_auth_audit(bytea,integer,uuid) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.read_own_auth_audit(bytea,integer,uuid) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.read_own_auth_audit(bytea,integer,uuid) TO gympro_auth;
