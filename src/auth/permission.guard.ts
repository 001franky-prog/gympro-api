import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import { Reflector } from '@nestjs/core';

import {
  RbacPermissionDatabaseService,
} from './rbac-permission-database.service.js';

import {
  REQUIRED_PERMISSION_KEY,
} from './require-permission.decorator.js';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

interface PermissionRequest
  extends GymProAuthenticatedRequest {
  params?: {
    tenantId?: unknown;
    branchId?: unknown;
  };
}

/**
 * Gym Pro SaaS
 * Database-backed permission authorization guard.
 *
 * Use after AuthenticatedSessionGuard and,
 * for tenant-scoped routes, TenantScopeGuard.
 *
 * Deny by default:
 * - Missing authentication -> 401
 * - Missing permission metadata -> 403
 * - Missing/invalid branch context -> 403
 * - Denied permission -> 403
 * - Database failure -> 503
 *
 * Never derive identity from HTTP request bodies.
 */
@Injectable()
export class PermissionGuard implements CanActivate {
  private readonly uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  private readonly permissionPattern =
    /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/;

  constructor(
    private readonly reflector: Reflector,
    private readonly rbacDatabase:
      RbacPermissionDatabaseService,
  ) {}

  async canActivate(
    context: ExecutionContext,
  ): Promise<boolean> {
    const request =
      context.switchToHttp()
        .getRequest<PermissionRequest>();

    const session = request?.gymproSession;

    if (!session) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    const permissionCode =
      this.reflector.getAllAndOverride<unknown>(
        REQUIRED_PERMISSION_KEY,
        [context.getHandler(), context.getClass()],
      );

    if (
      typeof permissionCode !== 'string' ||
      permissionCode.length > 128 ||
      !this.permissionPattern.test(permissionCode)
    ) {
      throw new ForbiddenException(
        'Permission denied',
      );
    }

    if (
      !this.uuidPattern.test(session.tenantId) ||
      !this.uuidPattern.test(session.membershipId)
    ) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    const routeTenantId =
      request.params?.tenantId;

    // If a route tenant ID is supplied, it must
    // match the server-verified session tenant.
    if (routeTenantId !== undefined) {
      if (
        typeof routeTenantId !== 'string' ||
        !this.uuidPattern.test(routeTenantId) ||
        routeTenantId.toLowerCase() !==
          session.tenantId.toLowerCase()
      ) {
        throw new ForbiddenException(
          'Tenant access denied',
        );
      }
    }

    let branchId: string | null = null;

    if (request.params?.branchId !== undefined) {
      const value = request.params.branchId;

      if (
        typeof value !== 'string' ||
        !this.uuidPattern.test(value)
      ) {
        throw new ForbiddenException(
          'Branch access denied',
        );
      }

      branchId = value;
    }

    let allowed: boolean;

    try {
      allowed =
        await this.rbacDatabase.hasTenantPermission({
          tenantId: session.tenantId,
          membershipId: session.membershipId,
          permissionCode,
          branchId,
        });
    } catch {
      throw new ServiceUnavailableException(
        'Permission verification unavailable',
      );
    }

    if (allowed !== true) {
      throw new ForbiddenException(
        'Permission denied',
      );
    }

    return true;
  }
}