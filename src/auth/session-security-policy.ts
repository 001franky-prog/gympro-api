
/**
 * GYM PRO SAAS
 * PHASE A - STEP A-F6.29
 *
 * SESSION SECURITY POLICY
 *
 * Default:
 * - Session persistence disabled.
 *
 * Development-only activation:
 * - Requires NODE_ENV=development.
 * - Requires two explicit opt-in flags.
 *
 * Production:
 * - Explicit GYMPRO_SESSION_MODE=persistent required.
 * - Development overrides are rejected at startup.
 *
 * SECURITY:
 * This feature flag is not authentication proof.
 * Session creation also requires the trusted
 * application authentication workflow and
 * restricted PostgreSQL credentials.
 */

export const SESSION_SECURITY_POLICY = Object.freeze({
  tokenBytes: 32,
  tokenHashBytes: 32,
  tokenHashAlgorithm: 'sha256',
  sessionLifetimeSeconds: 8 * 60 * 60,
  databaseRole: 'gympro_session',

  // Baseline security policy: disabled.
  persistenceEnabled: false,
} as const);

/**
 * Enable production persistence explicitly, or retain the existing
 * separately authorized local development opt-in.
 *
 * Both flags must match exactly.
 *
 * Never allow the development override in
 * production or other runtime environments.
 */
export function isSessionPersistenceEnabled(): boolean {
  if (process.env.NODE_ENV === 'production') {
    return process.env.GYMPRO_SESSION_MODE === 'persistent' &&
      !process.env.GYMPRO_DEV_SESSION_WRITES &&
      !process.env.GYMPRO_DEV_SESSION_CONFIRM;
  }
  if (process.env.NODE_ENV !== 'development') return false;
  return process.env.GYMPRO_DEV_SESSION_WRITES === 'enabled' &&
    process.env.GYMPRO_DEV_SESSION_CONFIRM === 'I_UNDERSTAND_THE_RISK';
}

/**
 * Legacy structural validation.
 *
 * This does not authenticate credentials or
 * authorize arbitrary session creation.
 */
export function isValidSessionPersistenceInput(
  value: unknown,
): boolean {
  if (
    typeof value !== 'object' ||
    value === null
  ) {
    return false;
  }

  const input =
    value as Record<string, unknown>;

  if (
    typeof input.identity !== 'object' ||
    input.identity === null
  ) {
    return false;
  }

  const identity =
    input.identity as Record<string, unknown>;

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const validIdentity =
    typeof identity.userId === 'string' &&
    uuidPattern.test(identity.userId) &&
    typeof identity.tenantId === 'string' &&
    uuidPattern.test(identity.tenantId) &&
    typeof identity.membershipId === 'string' &&
    uuidPattern.test(identity.membershipId);

  const validTokenHash =
    Buffer.isBuffer(input.tokenHash) &&
    input.tokenHash.length ===
      SESSION_SECURITY_POLICY.tokenHashBytes;

  return validIdentity && validTokenHash;
}
