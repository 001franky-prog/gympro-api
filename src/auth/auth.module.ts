import { Module } from '@nestjs/common';
import { LoginRateLimitGuard } from './login-rate-limit.guard.js';
import { ProductionAuthPolicyService } from './production-auth-policy.service.js';

import { AuthController } from './auth.controller.js';
import { TenantAuthorizationService } from './tenant-authorization.service.js';
import { PasswordService } from './password.service.js';
import { AuthDatabaseService } from './auth-database.service.js';
import { AuthenticationService } from './authentication.service.js';
import { SessionTokenService } from './session-token.service.js';
import { LoginOrchestratorService } from './login-orchestrator.service.js';
import { AuthenticatedEligibilityService } from './authenticated-eligibility.service.js';
import { SessionIssuanceService } from './session-issuance.service.js';
import { SessionPersistenceService } from './session-persistence.service.js';
import { SessionDatabaseService } from './session-database.service.js';
import { SessionPersistenceAuthorizationService } from './session-persistence-authorization.service.js';
import { SessionBearerTokenService } from './session-bearer-token.service.js';
import { AuthenticatedSessionGuard } from './authenticated-session.guard.js';
import { TenantScopeGuard } from './tenant-scope.guard.js';
import { RbacPermissionDatabaseService } from './rbac-permission-database.service.js';
import { PermissionGuard } from './permission.guard.js';
import { SessionRevocationDatabaseService } from './session-revocation-database.service.js';

/**
 * Gym Pro SaaS
 * Phase A authentication foundation.
 * Phase B support for protected member routes.
 */
@Module({
  controllers: [
    AuthController,
  ],

  providers: [
    LoginRateLimitGuard,
    ProductionAuthPolicyService,
    TenantAuthorizationService,
    PasswordService,
    AuthDatabaseService,
    AuthenticationService,
    SessionTokenService,
    LoginOrchestratorService,
    AuthenticatedEligibilityService,
    SessionIssuanceService,
    SessionPersistenceService,
    SessionDatabaseService,
    SessionPersistenceAuthorizationService,
    SessionBearerTokenService,
    AuthenticatedSessionGuard,
    TenantScopeGuard,
    RbacPermissionDatabaseService,
    PermissionGuard,
    SessionRevocationDatabaseService,
  ],

  exports: [
    TenantAuthorizationService,

    // Existing guards for protected member routes.
    AuthenticatedSessionGuard,
    TenantScopeGuard,
    PermissionGuard,

    // Dependencies required by those guards.
    AuthDatabaseService,
    SessionBearerTokenService,
    RbacPermissionDatabaseService,
  ],
})
export class AuthModule {}