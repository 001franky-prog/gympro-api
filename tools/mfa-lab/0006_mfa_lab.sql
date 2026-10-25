-- ISOLATED REHEARSAL ONLY. Do not deploy without persistent key custody and rollout review.
CREATE TABLE security.mfa_lab_factors(
 user_id uuid PRIMARY KEY REFERENCES app.users(id) ON DELETE CASCADE,
 version uuid NOT NULL UNIQUE,status text NOT NULL CHECK(status IN ('pending','active')),
 encrypted_secret jsonb NOT NULL CHECK(jsonb_typeof(encrypted_secret)='object'),
 credential_snapshot text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '10 minutes',
 enabled_at timestamptz,last_step bigint NOT NULL DEFAULT -1,
 failures integer NOT NULL DEFAULT 0 CHECK(failures BETWEEN 0 AND 5),locked_until timestamptz,
 CHECK(isfinite(expires_at)),UNIQUE(user_id,version)
);
CREATE TABLE security.mfa_lab_backup_codes(
 user_id uuid NOT NULL,version uuid NOT NULL,code_hash bytea NOT NULL CHECK(octet_length(code_hash)=32),used_at timestamptz,
 PRIMARY KEY(user_id,code_hash),FOREIGN KEY(user_id,version) REFERENCES security.mfa_lab_factors(user_id,version) ON DELETE CASCADE
);
CREATE TABLE security.mfa_lab_challenges(
 digest bytea PRIMARY KEY CHECK(octet_length(digest)=32),user_id uuid NOT NULL,version uuid NOT NULL,
 tenant_id uuid NOT NULL,membership_id uuid NOT NULL,credential_snapshot text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT clock_timestamp()+interval '2 minutes',used_at timestamptz,
 attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 FOREIGN KEY(user_id,version) REFERENCES security.mfa_lab_factors(user_id,version) ON DELETE CASCADE,
 FOREIGN KEY(tenant_id,membership_id) REFERENCES app.tenant_memberships(tenant_id,id) ON DELETE CASCADE,
 CHECK(isfinite(expires_at))
);
ALTER TABLE security.mfa_lab_factors ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.mfa_lab_factors FORCE ROW LEVEL SECURITY;
ALTER TABLE security.mfa_lab_backup_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.mfa_lab_backup_codes FORCE ROW LEVEL SECURITY;
ALTER TABLE security.mfa_lab_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.mfa_lab_challenges FORCE ROW LEVEL SECURITY;
REVOKE ALL ON security.mfa_lab_factors,security.mfa_lab_backup_codes,security.mfa_lab_challenges FROM PUBLIC,gympro_app,gympro_auth,gympro_session;
GRANT SELECT,INSERT,UPDATE,DELETE ON security.mfa_lab_factors,security.mfa_lab_backup_codes,security.mfa_lab_challenges TO gympro_session_owner;
CREATE POLICY mfa_factor_owner ON security.mfa_lab_factors TO gympro_session_owner USING(true) WITH CHECK(true);
CREATE POLICY mfa_backup_owner ON security.mfa_lab_backup_codes TO gympro_session_owner USING(true) WITH CHECK(true);
CREATE POLICY mfa_challenge_owner ON security.mfa_lab_challenges TO gympro_session_owner USING(true) WITH CHECK(true);

CREATE FUNCTION security.mfa_lab_prepare(p_session bytea,p_credential text,p_version uuid,p_cipher jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; u record;
BEGIN
 SELECT * INTO v FROM security.verify_tenant_session(p_session);
 IF NOT FOUND OR p_version IS NULL OR p_cipher IS NULL OR jsonb_typeof(p_cipher)<>'object' OR length(p_cipher::text)>1000 THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid MFA request'; END IF;
 SELECT id,password_hash INTO u FROM app.users WHERE id=v.user_id AND status='active' FOR UPDATE;
 IF NOT FOUND OR u.password_hash IS DISTINCT FROM p_credential THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials'; END IF;
 PERFORM 1 FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid session'; END IF;
 IF EXISTS(SELECT 1 FROM security.mfa_lab_factors WHERE user_id=u.id AND status='active') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='MFA is already enabled'; END IF;
 DELETE FROM security.mfa_lab_factors WHERE user_id=u.id;
 INSERT INTO security.mfa_lab_factors(user_id,version,status,encrypted_secret,credential_snapshot) VALUES(u.id,p_version,'pending',p_cipher,u.password_hash);
 RETURN jsonb_build_object('version',p_version,'pending',true);
END $$;
CREATE FUNCTION security.mfa_lab_read_factor(p_session bytea) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; f record; remaining integer;
BEGIN
 SELECT * INTO v FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid session'; END IF;
 SELECT * INTO f FROM security.mfa_lab_factors WHERE user_id=v.user_id;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT count(*) INTO remaining FROM security.mfa_lab_backup_codes WHERE user_id=v.user_id AND used_at IS NULL;
 RETURN jsonb_build_object('userId',v.user_id,'version',f.version,'status',f.status,'cipher',f.encrypted_secret,'expiresAt',f.expires_at,'lastStep',f.last_step,'backupRemaining',remaining);
END $$;
CREATE FUNCTION security.mfa_lab_confirm(p_session bytea,p_version uuid,p_step bigint,p_backups bytea[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; u record; f record; now_step bigint;
BEGIN
 SELECT * INTO v FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid session'; END IF;
 SELECT id,password_hash INTO u FROM app.users WHERE id=v.user_id AND status='active' FOR UPDATE;
 PERFORM 1 FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid session'; END IF;
 SELECT * INTO f FROM security.mfa_lab_factors WHERE user_id=u.id FOR UPDATE;
 now_step=floor(extract(epoch FROM clock_timestamp())/30)::bigint;
 IF NOT FOUND OR f.status<>'pending' OR f.version IS DISTINCT FROM p_version OR f.expires_at<=clock_timestamp() OR f.credential_snapshot IS DISTINCT FROM u.password_hash
 OR p_step IS NULL OR abs(p_step-now_step)>1 OR cardinality(p_backups) IS DISTINCT FROM 10 THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired MFA enrollment'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(p_backups) x WHERE x IS NULL OR octet_length(x)<>32) OR (SELECT count(DISTINCT x) FROM unnest(p_backups) x)<>10 THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid backup codes'; END IF;
 INSERT INTO security.mfa_lab_backup_codes(user_id,version,code_hash) SELECT u.id,f.version,x FROM unnest(p_backups) x;
 UPDATE security.mfa_lab_factors SET status='active',enabled_at=clock_timestamp(),last_step=p_step WHERE user_id=u.id;
 UPDATE security.tenant_sessions s SET revoked_at=clock_timestamp() FROM app.tenant_memberships m WHERE m.id=s.membership_id AND m.tenant_id=s.tenant_id AND m.user_id=u.id AND s.revoked_at IS NULL;
 RETURN jsonb_build_object('enabled',true,'signedOut',true);
END $$;

CREATE FUNCTION security.mfa_lab_begin_login(p_membership uuid,p_credential text,p_challenge bytea) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE u record; f record;
BEGIN
 IF p_challenge IS NULL OR octet_length(p_challenge)<>32 THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials'; END IF;
 SELECT a.id,a.password_hash,m.tenant_id INTO u FROM app.users a JOIN app.tenant_memberships m ON m.user_id=a.id JOIN platform.tenants t ON t.id=m.tenant_id
 WHERE m.id=p_membership AND a.status='active' AND m.status='active' AND t.status='active' FOR UPDATE OF a;
 IF NOT FOUND OR u.password_hash IS DISTINCT FROM p_credential THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials'; END IF;
 SELECT * INTO f FROM security.mfa_lab_factors WHERE user_id=u.id FOR UPDATE;
 IF NOT FOUND OR f.status<>'active' THEN RETURN jsonb_build_object('required',false); END IF;
 IF f.locked_until>clock_timestamp() THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid credentials'; END IF;
 IF f.locked_until IS NOT NULL THEN UPDATE security.mfa_lab_factors SET failures=0,locked_until=NULL WHERE user_id=u.id; END IF;
 UPDATE security.mfa_lab_challenges SET used_at=clock_timestamp() WHERE user_id=u.id AND used_at IS NULL;
 INSERT INTO security.mfa_lab_challenges(digest,user_id,version,tenant_id,membership_id,credential_snapshot) VALUES(p_challenge,u.id,f.version,u.tenant_id,p_membership,u.password_hash);
 RETURN jsonb_build_object('required',true);
END $$;
CREATE FUNCTION security.mfa_lab_read_challenge(p_challenge bytea) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
 SELECT jsonb_build_object('userId',u.id,'version',f.version,'cipher',f.encrypted_secret,'lastStep',f.last_step)
 FROM security.mfa_lab_challenges c JOIN security.mfa_lab_factors f ON f.user_id=c.user_id AND f.version=c.version JOIN app.users u ON u.id=c.user_id
 WHERE c.digest=p_challenge AND c.used_at IS NULL AND c.attempts<5 AND c.expires_at>clock_timestamp() AND f.status='active'
 AND (f.locked_until IS NULL OR f.locked_until<=clock_timestamp()) AND u.status='active' AND u.password_hash=c.credential_snapshot;
$$;
CREATE FUNCTION security.mfa_lab_complete_login(p_challenge bytea,p_session_digest bytea,p_step bigint DEFAULT NULL,p_backup bytea DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c record; f record; u record; good boolean:=false; sid uuid; now_step bigint; changed integer;
BEGIN
 IF p_session_digest IS NULL OR octet_length(p_session_digest)<>32 THEN RETURN jsonb_build_object('accepted',false); END IF;
 SELECT * INTO c FROM security.mfa_lab_challenges WHERE digest=p_challenge;
 IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false); END IF;
 SELECT id,password_hash INTO u FROM app.users WHERE id=c.user_id AND status='active' FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('accepted',false); END IF;
 SELECT * INTO c FROM security.mfa_lab_challenges WHERE digest=p_challenge FOR UPDATE;
 SELECT * INTO f FROM security.mfa_lab_factors WHERE user_id=u.id FOR UPDATE;
 IF NOT FOUND OR f.status<>'active' OR c.version IS DISTINCT FROM f.version OR c.used_at IS NOT NULL OR c.attempts>=5 OR c.expires_at<=clock_timestamp() OR c.credential_snapshot IS DISTINCT FROM u.password_hash OR f.locked_until>clock_timestamp()
 OR NOT EXISTS(SELECT 1 FROM app.tenant_memberships m JOIN platform.tenants t ON t.id=m.tenant_id WHERE m.id=c.membership_id AND m.tenant_id=c.tenant_id AND m.user_id=u.id AND m.status='active' AND t.status='active') THEN RETURN jsonb_build_object('accepted',false); END IF;
 now_step=floor(extract(epoch FROM clock_timestamp())/30)::bigint;
 IF p_step IS NOT NULL AND p_backup IS NULL AND abs(p_step-now_step)<=1 AND p_step>f.last_step THEN good=true; END IF;
 IF p_step IS NULL AND p_backup IS NOT NULL AND octet_length(p_backup)=32 THEN
  UPDATE security.mfa_lab_backup_codes SET used_at=clock_timestamp() WHERE user_id=u.id AND version=f.version AND code_hash=p_backup AND used_at IS NULL;
  GET DIAGNOSTICS changed=ROW_COUNT;good=(changed=1);
 END IF;
 IF NOT good THEN
  UPDATE security.mfa_lab_challenges SET attempts=attempts+1 WHERE digest=p_challenge;
  UPDATE security.mfa_lab_factors SET failures=least(failures+1,5),locked_until=CASE WHEN failures+1>=5 THEN clock_timestamp()+interval '5 minutes' ELSE NULL END WHERE user_id=u.id;
  RETURN jsonb_build_object('accepted',false);
 END IF;
 UPDATE security.mfa_lab_factors SET last_step=CASE WHEN p_step IS NULL THEN last_step ELSE p_step END,failures=0,locked_until=NULL WHERE user_id=u.id;
 UPDATE security.mfa_lab_challenges SET used_at=clock_timestamp() WHERE digest=p_challenge;
 INSERT INTO security.tenant_sessions(tenant_id,membership_id,session_token_hash,expires_at) VALUES(c.tenant_id,c.membership_id,p_session_digest,clock_timestamp()+interval '8 hours') RETURNING id INTO sid;
 RETURN jsonb_build_object('accepted',true,'sessionId',sid,'userId',u.id,'tenantId',c.tenant_id,'membershipId',c.membership_id);
END $$;
CREATE FUNCTION security.mfa_lab_disable(p_session bytea,p_credential text,p_version uuid,p_step bigint DEFAULT NULL,p_backup bytea DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE v record; u record; f record; good boolean:=false; changed integer; now_step bigint;
BEGIN
 SELECT * INTO v FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RETURN jsonb_build_object('disabled',false); END IF;
 SELECT id,password_hash INTO u FROM app.users WHERE id=v.user_id AND status='active' FOR UPDATE;
 IF NOT FOUND OR u.password_hash IS DISTINCT FROM p_credential THEN RETURN jsonb_build_object('disabled',false); END IF;
 PERFORM 1 FROM security.verify_tenant_session(p_session);
 IF NOT FOUND THEN RETURN jsonb_build_object('disabled',false); END IF;
 SELECT * INTO f FROM security.mfa_lab_factors WHERE user_id=u.id FOR UPDATE;
 IF NOT FOUND OR f.status<>'active' OR f.version IS DISTINCT FROM p_version OR f.locked_until>clock_timestamp() THEN RETURN jsonb_build_object('disabled',false); END IF;
 now_step=floor(extract(epoch FROM clock_timestamp())/30)::bigint;
 IF p_step IS NOT NULL AND p_backup IS NULL AND abs(p_step-now_step)<=1 AND p_step>f.last_step THEN good=true; END IF;
 IF p_step IS NULL AND p_backup IS NOT NULL AND octet_length(p_backup)=32 THEN
  UPDATE security.mfa_lab_backup_codes SET used_at=clock_timestamp() WHERE user_id=u.id AND version=f.version AND code_hash=p_backup AND used_at IS NULL;
  GET DIAGNOSTICS changed=ROW_COUNT;good=(changed=1);
 END IF;
 IF NOT good THEN
  UPDATE security.mfa_lab_factors SET failures=least(failures+1,5),locked_until=CASE WHEN failures+1>=5 THEN clock_timestamp()+interval '5 minutes' ELSE NULL END WHERE user_id=u.id;
  RETURN jsonb_build_object('disabled',false);
 END IF;
 DELETE FROM security.mfa_lab_factors WHERE user_id=u.id;
 UPDATE security.tenant_sessions s SET revoked_at=clock_timestamp() FROM app.tenant_memberships m WHERE m.id=s.membership_id AND m.tenant_id=s.tenant_id AND m.user_id=u.id AND s.revoked_at IS NULL;
 RETURN jsonb_build_object('disabled',true,'signedOut',true);
END $$;
DO $$DECLARE p record;BEGIN
 FOR p IN SELECT oid::regprocedure signature FROM pg_proc WHERE pronamespace='security'::regnamespace AND proname IN ('mfa_lab_prepare','mfa_lab_read_factor','mfa_lab_confirm','mfa_lab_begin_login','mfa_lab_read_challenge','mfa_lab_complete_login','mfa_lab_disable') LOOP
  EXECUTE format('ALTER FUNCTION %s OWNER TO gympro_session_owner',p.signature);
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,gympro_app,gympro_session',p.signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO gympro_auth',p.signature);
 END LOOP;
END $$;

-- Close the ordinary password-only persistence path for every MFA-enabled account.
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
 IF EXISTS(SELECT 1 FROM security.mfa_lab_factors WHERE user_id=v.id AND status='active') THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='MFA verification is required'; END IF;
 INSERT INTO security.tenant_sessions(tenant_id,membership_id,session_token_hash,expires_at)
 VALUES(v.tenant_id,p_membership,p_digest,clock_timestamp()+interval '8 hours') RETURNING id INTO v_id;
 RETURN v_id;
END $$;
ALTER FUNCTION security.create_credential_bound_session(uuid,bytea,text) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.create_credential_bound_session(uuid,bytea,text) FROM PUBLIC,gympro_app,gympro_auth;
GRANT EXECUTE ON FUNCTION security.create_credential_bound_session(uuid,bytea,text) TO gympro_session;
