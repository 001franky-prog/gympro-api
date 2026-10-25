-- ISOLATED REHEARSAL ONLY. Production email delivery/rollout is not enabled by this file.
CREATE TABLE security.account_recovery_tokens (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
 purpose text NOT NULL CHECK(purpose IN ('verify_email','reset_password')),
 token_hash bytea NOT NULL UNIQUE CHECK(octet_length(token_hash)=32),
 email_snapshot text NOT NULL,
 credential_snapshot text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz,
 CHECK(isfinite(created_at) AND isfinite(expires_at) AND expires_at>created_at),
 CHECK(used_at IS NULL OR isfinite(used_at))
);
CREATE INDEX account_recovery_user_time ON security.account_recovery_tokens(user_id,purpose,created_at);
ALTER TABLE security.account_recovery_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.account_recovery_tokens FORCE ROW LEVEL SECURITY;
REVOKE ALL ON security.account_recovery_tokens FROM PUBLIC,gympro_auth,gympro_app,gympro_session;
GRANT SELECT,INSERT,UPDATE ON security.account_recovery_tokens TO gympro_session_owner;
CREATE POLICY recovery_owner ON security.account_recovery_tokens TO gympro_session_owner USING(true) WITH CHECK(true);
GRANT SELECT(email,email_verified_at),UPDATE(email_verified_at) ON app.users TO gympro_session_owner;

CREATE FUNCTION security.account_recovery_issue(p_purpose text,p_digest bytea,p_session bytea DEFAULT NULL,p_email text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; u record; expiry timestamptz;
BEGIN
 IF p_purpose IS NULL OR p_purpose NOT IN ('verify_email','reset_password') OR p_digest IS NULL OR octet_length(p_digest)<>32 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid recovery request'; END IF;
 IF p_purpose='verify_email' THEN
  IF p_email IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid recovery request'; END IF;
  SELECT * INTO v FROM security.verify_tenant_session(p_session);
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
  SELECT id,email,password_hash,email_verified_at INTO u FROM app.users WHERE id=v.user_id AND status='active' FOR UPDATE;
 ELSE
  IF p_session IS NOT NULL OR p_email IS NULL OR length(p_email)>255 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid recovery request'; END IF;
  SELECT id,email,password_hash,email_verified_at INTO u FROM app.users WHERE lower(email)=lower(trim(p_email)) AND status='active' FOR UPDATE;
 END IF;
 IF NOT FOUND OR u.password_hash IS NULL THEN RETURN NULL; END IF;
 IF NOT EXISTS(SELECT 1 FROM app.tenant_memberships m JOIN platform.tenants t ON t.id=m.tenant_id WHERE m.user_id=u.id AND m.status='active' AND t.status='active') THEN RETURN NULL; END IF;
 IF (p_purpose='reset_password' AND u.email_verified_at IS NULL) OR (p_purpose='verify_email' AND u.email_verified_at IS NOT NULL) THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM security.account_recovery_tokens WHERE user_id=u.id AND purpose=p_purpose AND created_at>clock_timestamp()-interval '60 seconds') THEN RETURN NULL; END IF;
 UPDATE security.account_recovery_tokens SET used_at=clock_timestamp() WHERE user_id=u.id AND purpose=p_purpose AND used_at IS NULL;
 expiry=clock_timestamp()+interval '15 minutes';
 INSERT INTO security.account_recovery_tokens(user_id,purpose,token_hash,email_snapshot,credential_snapshot,expires_at)
 VALUES(u.id,p_purpose,p_digest,u.email,u.password_hash,expiry);
 RETURN jsonb_build_object('recipient',u.email,'purpose',p_purpose,'expiresAt',expiry);
END $$;
ALTER FUNCTION security.account_recovery_issue(text,bytea,bytea,text) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.account_recovery_issue(text,bytea,bytea,text) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.account_recovery_issue(text,bytea,bytea,text) TO gympro_auth;

CREATE FUNCTION security.account_recovery_validate_reset(p_digest bytea) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT p_digest IS NOT NULL AND octet_length(p_digest)=32 AND EXISTS(
 SELECT 1 FROM security.account_recovery_tokens k JOIN app.users u ON u.id=k.user_id
 WHERE k.token_hash=p_digest AND k.purpose='reset_password' AND k.used_at IS NULL AND k.expires_at>clock_timestamp()
 AND u.status='active' AND u.email_verified_at IS NOT NULL AND u.email=k.email_snapshot AND u.password_hash=k.credential_snapshot
 AND EXISTS(SELECT 1 FROM app.tenant_memberships m JOIN platform.tenants t ON t.id=m.tenant_id WHERE m.user_id=u.id AND m.status='active' AND t.status='active'));
$$;
ALTER FUNCTION security.account_recovery_validate_reset(bytea) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.account_recovery_validate_reset(bytea) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.account_recovery_validate_reset(bytea) TO gympro_auth;

CREATE FUNCTION security.account_recovery_consume(p_purpose text,p_digest bytea,p_new_hash text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE k record; u record; n integer;
BEGIN
 IF p_purpose IS NULL OR p_purpose NOT IN ('verify_email','reset_password') OR p_digest IS NULL OR octet_length(p_digest)<>32 THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired recovery link'; END IF;
 IF p_purpose='reset_password' THEN
  IF p_new_hash IS NULL OR length(p_new_hash)>512 OR p_new_hash !~ '^[$]argon2id[$]v=19[$]m=19456,(t=2,p=1|p=1,t=2)[$][A-Za-z0-9+/]+[$][A-Za-z0-9+/]+$' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid recovery request'; END IF;
 ELSIF p_new_hash IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid recovery request'; END IF;
 SELECT * INTO k FROM security.account_recovery_tokens WHERE token_hash=p_digest AND purpose=p_purpose;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired recovery link'; END IF;
 -- Lock the user before the token, matching issuance/password-change lock order.
 SELECT id,email,password_hash,email_verified_at INTO u FROM app.users WHERE id=k.user_id AND status='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired recovery link'; END IF;
 SELECT * INTO k FROM security.account_recovery_tokens WHERE token_hash=p_digest AND purpose=p_purpose FOR UPDATE;
 IF k.used_at IS NOT NULL OR k.expires_at<=clock_timestamp() OR u.email IS DISTINCT FROM k.email_snapshot OR u.password_hash IS DISTINCT FROM k.credential_snapshot
 OR (p_purpose='reset_password' AND u.email_verified_at IS NULL)
 OR NOT EXISTS(SELECT 1 FROM app.tenant_memberships m JOIN platform.tenants t ON t.id=m.tenant_id WHERE m.user_id=u.id AND m.status='active' AND t.status='active') THEN
  RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired recovery link'; END IF;
 IF p_purpose='verify_email' THEN
  UPDATE app.users SET email_verified_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=u.id;
  UPDATE security.account_recovery_tokens SET used_at=clock_timestamp() WHERE user_id=u.id AND purpose='verify_email' AND used_at IS NULL;
  RETURN jsonb_build_object('verified',true);
 END IF;
 UPDATE app.users SET password_hash=p_new_hash,updated_at=clock_timestamp() WHERE id=u.id;
 UPDATE security.tenant_sessions s SET revoked_at=clock_timestamp() FROM app.tenant_memberships m
 WHERE s.membership_id=m.id AND s.tenant_id=m.tenant_id AND m.user_id=u.id AND s.revoked_at IS NULL;
 GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE security.account_recovery_tokens SET used_at=clock_timestamp() WHERE user_id=u.id AND used_at IS NULL;
 RETURN jsonb_build_object('changed',true,'signedOut',true,'revokedCount',n);
END $$;
ALTER FUNCTION security.account_recovery_consume(text,bytea,text) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.account_recovery_consume(text,bytea,text) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.account_recovery_consume(text,bytea,text) TO gympro_auth;
