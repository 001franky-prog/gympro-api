import { MfaLabService } from './mfa-lab.service.js';
import { MfaLabController,MfaLabUiController,MfaLabOnlyGuard,MfaLabLimitGuard } from './mfa-lab.controller.js';
import { RecoveryLabService } from './recovery-lab.service.js';
import { RecoveryLabController,RecoveryLabUiController,RecoveryLabOnlyGuard,RecoveryLabLimitGuard } from './recovery-lab.controller.js';
import { Module } from '@nestjs/common';
import { PasswordChangeService } from './password-change.service.js';
import { PasswordCredentialDatabaseService } from './password-credential-database.service.js';
import { PasswordChangeController } from './password-change.controller.js';
import { SelfSessionService } from './self-session.service.js';
import { SelfSessionController } from './self-session.controller.js';
import { SessionAccountUiController } from './session-account-ui.controller.js';
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
    MfaLabController, MfaLabUiController, RecoveryLabController, RecoveryLabUiController,
    PasswordChangeController,
    SelfSessionController, SessionAccountUiController,
    AuthController,
  ],

  providers: [
    MfaLabService, MfaLabOnlyGuard, MfaLabLimitGuard, RecoveryLabService, RecoveryLabOnlyGuard, RecoveryLabLimitGuard,
    PasswordChangeService, PasswordCredentialDatabaseService,
    SelfSessionService,
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