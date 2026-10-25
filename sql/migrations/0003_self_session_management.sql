-- Self-service, tenant-scoped sessions. No direct runtime session-table access.
GRANT SELECT (created_at) ON security.tenant_sessions TO gympro_session_owner;
CREATE OR REPLACE FUNCTION security.manage_own_sessions(p_token_hash bytea, p_action text, p_target uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE v record; v_items jsonb; v_count integer;
BEGIN
 IF p_token_hash IS NULL OR octet_length(p_token_hash) <> 32 THEN
  RAISE EXCEPTION USING ERRCODE='28000', MESSAGE='Invalid or expired session';
 END IF;
 IF p_action IS NULL OR p_action NOT IN ('list','revoke','revoke_others') OR
    (p_action='revoke' AND p_target IS NULL) OR (p_action<>'revoke' AND p_target IS NOT NULL) THEN
  RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid session management request';
 END IF;
 SELECT * INTO v FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 -- Serialize operations for this exact tenant membership, then revalidate authority.
 PERFORM pg_advisory_xact_lock(81275,hashtext(v.tenant_id::text||':'||v.membership_id::text));
 SELECT * INTO v FROM security.verify_tenant_session(p_token_hash);
 IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Invalid or expired session'; END IF;
 IF p_action='list' THEN
  SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC,x.id DESC),'[]'::jsonb) INTO v_items
  FROM (SELECT s.id,s.created_at,jsonb_build_object('sessionId',s.id,'createdAt',s.created_at,'expiresAt',s.expires_at,'current',s.id=v.session_id) item
   FROM security.tenant_sessions s WHERE s.tenant_id=v.tenant_id AND s.membership_id=v.membership_id
   AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp() ORDER BY s.created_at DESC,s.id DESC LIMIT 100) x;
  RETURN jsonb_build_object('items',v_items,'limit',100,'scope','current_tenant_membership');
 END IF;
 UPDATE security.tenant_sessions s SET revoked_at=clock_timestamp()
 WHERE s.tenant_id=v.tenant_id AND s.membership_id=v.membership_id AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp()
 AND ((p_action='revoke' AND s.id=p_target) OR (p_action='revoke_others' AND s.id<>v.session_id));
 GET DIAGNOSTICS v_count=ROW_COUNT;
 RETURN jsonb_build_object('revokedCount',v_count,'currentRevoked',p_action='revoke' AND p_target=v.session_id AND v_count=1);
END $$;
ALTER FUNCTION security.manage_own_sessions(bytea,text,uuid) OWNER TO gympro_session_owner;
REVOKE ALL ON FUNCTION security.manage_own_sessions(bytea,text,uuid) FROM PUBLIC,gympro_app,gympro_session;
GRANT EXECUTE ON FUNCTION security.manage_own_sessions(bytea,text,uuid) TO gympro_auth;
