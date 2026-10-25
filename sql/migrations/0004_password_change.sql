-- Trusted application credential verification; database serializes credential changes and issuance.
GRANT SELECT(password_hash), UPDATE(password_hash,updated_at) ON app.users TO gympro_session_owner;
CREATE OR REPLACE FUNCTION security.create_credential_bound_session(p_membership uuid,p_digest bytea,p_verified_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; v_id uuid;
BEGIN
 IF p_digest IS NULL OR octet_length(p_digest)<>32 OR p_verified_hash IS NULL OR length(p_verified_hash)>512 THEN
  RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials or tenant access'; END IF;
 SELECT u.id,u.password_hash,m.tenant_id INTO v FROM app.users u
 JOIN app.tenant_memberships m ON m.user_id=u.id JOIN platform.tenants t ON t.id=m.tenant_id
 WHERE m.id=p_membership AND u.status='active' AND m.status='active' AND t.status='active' FOR SHARE OF u;
 IF NOT FOUND OR v.password_hash IS DISTINCT FROM p_verified_hash THEN
  RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials or tenant access'; END IF;
 INSERT INTO security.tenant_sessions(tenant_id,membership_id,session_token_hash,expires_at)
 VALUES(v.tenant_id,p_membership,p_digest,clock_timestamp()+interval '8 hours') RETURNING id INTO v_id;
 RETURN v_id;
END $$;
ALTER FUNCTION security.create_credential_bound_session(uuid,bytea,text) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.create_credential_bound_session(uuid,bytea,text) FROM PUBLIC,gympro_app,gympro_auth;
GRANT EXECUTE ON FUNCTION security.create_credential_bound_session(uuid,bytea,text) TO gympro_session;

CREATE OR REPLACE FUNCTION security.read_own_credential(p_digest bytea) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; v_hash text;
BEGIN
 SELECT * INTO v FROM security.verify_tenant_session(p_digest);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 SELECT password_hash INTO v_hash FROM app.users WHERE id=v.user_id AND status='active';
 IF v_hash IS NULL THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 RETURN v_hash;
END $$;
ALTER FUNCTION security.read_own_credential(bytea) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.read_own_credential(bytea) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.read_own_credential(bytea) TO gympro_auth;

CREATE OR REPLACE FUNCTION security.change_own_password(p_digest bytea,p_old_hash text,p_new_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; v_current text; v_count integer;
BEGIN
 IF p_new_hash IS NULL OR length(p_new_hash)>512 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Password change validation: hash length'; END IF;
 IF p_new_hash !~ '^[$]argon2id[$]v=19[$]m=19456,(t=2,p=1|p=1,t=2)[$][A-Za-z0-9+/]+[$][A-Za-z0-9+/]+$' THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Password change validation: hash format'; END IF;
 IF p_new_hash=p_old_hash THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Password change validation: unchanged hash'; END IF;
 SELECT * INTO v FROM security.verify_tenant_session(p_digest);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 SELECT password_hash INTO v_current FROM app.users WHERE id=v.user_id AND status='active' FOR UPDATE;
 IF NOT FOUND OR v_current IS DISTINCT FROM p_old_hash THEN
  RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Credentials changed; sign in again'; END IF;
 -- Revalidate after acquiring the same user-row lock used by credential-bound issuance.
 PERFORM 1 FROM security.verify_tenant_session(p_digest);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 UPDATE app.users SET password_hash=p_new_hash,updated_at=clock_timestamp() WHERE id=v.user_id;
 UPDATE security.tenant_sessions s SET revoked_at=clock_timestamp()
 FROM app.tenant_memberships m WHERE s.membership_id=m.id AND s.tenant_id=m.tenant_id
 AND m.user_id=v.user_id AND s.revoked_at IS NULL;
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('changed',true,'revokedCount',v_count,'signedOut',true);
END $$;
ALTER FUNCTION security.change_own_password(bytea,text,text) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.change_own_password(bytea,text,text) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.change_own_password(bytea,text,text) TO gympro_auth;

-- Disable the unbound legacy entry point for runtime session writers.
REVOKE EXECUTE ON FUNCTION security.create_tenant_session(uuid,bytea) FROM gympro_session;
