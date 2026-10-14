
import type {
  AuthenticatedSessionRequest,
} from './authenticated-session-request.js';

/**
 * Gym Pro SaaS
 * Session Persistence Contract
 *
 * Only internal authenticated session requests
 * should be submitted for persistence.
 *
 * TypeScript contracts and runtime brands
 * are not independent authentication proof.
 */

/**
 * Persistence operation result.
 *
 * The raw bearer token must never be included
 * in this result or stored in PostgreSQL.
 */
export interface SessionPersistenceResult {
  readonly sessionId: string;
}

/**
 * Internal persistence interface.
 *
 * The implementation must:
 *
 * 1. Receive a request from the trusted
 *    session issuance workflow.
 *
 * 2. Validate the request at runtime.
 *
 * 3. Confirm database authorization
 *    requirements before writing.
 *
 * 4. Persist only the token hash.
 *
 * 5. Return a session ID only after
 *    successful database persistence.
 *
 * 6. Fail closed on any error.
 *
 * Current implementation remains disabled.
 */
export interface SessionPersistencePort {
  createSession(
    request: AuthenticatedSessionRequest,
  ): Promise<SessionPersistenceResult>;
}
