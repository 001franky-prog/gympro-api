import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

/**
 * Gym Pro SaaS
 * Phase A â€” Tenant Scope Guard
 *
 * Use AFTER AuthenticatedSessionGuard.
 *
 * Example route:
 * GET /tenants/:tenantId/members
 *
 * This guard checks whether the route tenant ID
 * matches the tenant ID verified by PostgreSQL.
 *
 * It must NOT use a client-supplied user identity.
 *
 * Note:
 * This is a tenant-boundary check, not a complete
 * role, branch, or object-level authorization check.
 */

interface TenantScopedRequest
  extends GymProAuthenticatedRequest {
  params?: {
    tenantId?: unknown;
  };
}

@Injectable()
export class TenantScopeGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const request =
      context.switchToHttp()
        .getRequest<TenantScopedRequest>();

    // Require the authenticated session guard to
    // have established the verified identity.
    if (
      !request ||
      typeof request !== 'object' ||
      !request.gymproSession
    ) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    const sessionTenantId =
      request.gymproSession.tenantId;

    const requestedTenantId =
      request.params?.tenantId;

    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    // Reject missing or malformed tenant references.
    if (
      typeof requestedTenantId !== 'string' ||
      !uuidPattern.test(requestedTenantId) ||
      typeof sessionTenantId !== 'string' ||
      !uuidPattern.test(sessionTenantId)
    ) {
      throw new ForbiddenException(
        'Tenant access denied',
      );
    }

    // UUID comparison is case-insensitive.
    if (
      requestedTenantId.toLowerCase() !==
      sessionTenantId.toLowerCase()
    ) {
      throw new ForbiddenException(
        'Tenant access denied',
      );
    }

    return true;
  }
}