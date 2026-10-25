import { LoginRateLimitGuard } from './login-rate-limit.guard.js';

import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  Req,
  ServiceUnavailableException,
  UnauthorizedException,
  UseGuards,
} from '@nestjs/common';

import {
  SessionIssuanceService,
} from './session-issuance.service.js';

import type {
  TenantLoginResponse,
} from './session-issuance.service.js';

import {
  AuthenticatedSessionGuard,
} from './authenticated-session.guard.js';

import {
  TenantScopeGuard,
} from './tenant-scope.guard.js';

import {
  PermissionGuard,
} from './permission.guard.js';

import {
  RequirePermission,
} from './require-permission.decorator.js';

import {
  SessionBearerTokenService,
} from './session-bearer-token.service.js';

import {
  SessionRevocationDatabaseService,
} from './session-revocation-database.service.js';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

import type {
  VerifiedTenantSession,
} from './auth-database.service.js';

/**
 * Gym Pro SaaS
 * Phase A - Authentication Controller
 *
 * Routes:
 *
 * POST /auth/login
 * GET  /auth/me
 * POST /auth/logout
 * GET  /auth/tenants/:tenantId/check
 * GET  /auth/tenants/:tenantId/permissions/members-read
 *
 * Login persistence follows the explicit runtime session policy.
 */

@Controller('auth')
export class AuthController {
  constructor(
    private readonly sessionIssuance:
      SessionIssuanceService,

    private readonly bearerTokenService:
      SessionBearerTokenService,

    private readonly sessionRevocation:
      SessionRevocationDatabaseService,
  ) {}

  /**
   * POST /auth/login
   *
   * Login issuance remains fail-closed until
   * trusted activation is approved and tested.
   */
  @Post('login')
  @UseGuards(LoginRateLimitGuard)
  @HttpCode(HttpStatus.OK)
  async login(
    @Body() body: unknown,
  ): Promise<TenantLoginResponse> {
    const invalidRequest = () =>
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      );

    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw invalidRequest();
    }

    const input = body as Record<string, unknown>;

    if (
      typeof input.email !== 'string' ||
      typeof input.password !== 'string' ||
      typeof input.tenantId !== 'string'
    ) {
      throw invalidRequest();
    }

    const email = input.email.trim().toLowerCase();
    const password = input.password;
    const tenantId = input.tenantId;

    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (
      email.length === 0 ||
      email.length > 255 ||
      password.length === 0 ||
      password.length > 1024 ||
      !uuidPattern.test(tenantId)
    ) {
      throw invalidRequest();
    }

    return this.sessionIssuance.issueSession({
      email,
      password,
      tenantId,
    });
  }

  /**
   * GET /auth/me
   *
   * Return only the server-verified identity.
   */
  @Get('me')
  @UseGuards(AuthenticatedSessionGuard)
  @HttpCode(HttpStatus.OK)
  getCurrentSession(
    @Req() request: GymProAuthenticatedRequest,
  ): VerifiedTenantSession {
    const session = request.gymproSession;

    if (!session) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    return {
      sessionId: session.sessionId,
      userId: session.userId,
      tenantId: session.tenantId,
      membershipId: session.membershipId,
    };
  }

  /**
   * POST /auth/logout
   *
   * Requirements:
   * - Bearer token already authenticated by guard.
   * - Session ID comes from verified DB identity.
   * - Token hash comes from Authorization header.
   * - No client-supplied session ID is accepted.
   *
   * Successful revocation returns HTTP 204.
   */
  @Post('logout')
  @UseGuards(AuthenticatedSessionGuard)
  @HttpCode(HttpStatus.NO_CONTENT)
  async logout(
    @Req() request: GymProAuthenticatedRequest,
  ): Promise<void> {
    const session = request.gymproSession;

    if (!session) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    // The same bearer token has already been
    // validated by AuthenticatedSessionGuard.
    // Compute its hash for exact-match revocation.
    const tokenHash =
      this.bearerTokenService.hashAuthorization(
        request.headers?.authorization,
      );

    let revoked: boolean;

    try {
      revoked =
        await this.sessionRevocation.revokeSession(
          session.sessionId,
          tokenHash,
        );
    } catch {
      // Never claim success when the database
      // operation failed or its result is invalid.
      throw new ServiceUnavailableException(
        'Session revocation unavailable',
      );
    }

    if (revoked !== true) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    // HTTP 204: no response body.
  }

  /**
   * Tenant isolation diagnostic endpoint.
   */
  @Get('tenants/:tenantId/check')
  @UseGuards(
    AuthenticatedSessionGuard,
    TenantScopeGuard,
  )
  @HttpCode(HttpStatus.OK)
  checkTenantAccess(
    @Req() request: GymProAuthenticatedRequest,
  ): {
    authorized: true;
    tenantId: string;
    userId: string;
  } {
    const session = request.gymproSession;

    if (!session) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    return {
      authorized: true,
      tenantId: session.tenantId,
      userId: session.userId,
    };
  }

  /**
   * RBAC diagnostic endpoint.
   */
  @Get('tenants/:tenantId/permissions/members-read')
  @RequirePermission('gym.members.read')
  @UseGuards(
    AuthenticatedSessionGuard,
    TenantScopeGuard,
    PermissionGuard,
  )
  @HttpCode(HttpStatus.OK)
  checkMembersReadPermission(
    @Req() request: GymProAuthenticatedRequest,
  ): {
    authorized: true;
    permission: string;
    tenantId: string;
  } {
    const session = request.gymproSession;

    if (!session) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    return {
      authorized: true,
      permission: 'gym.members.read',
      tenantId: session.tenantId,
    };
  }
}