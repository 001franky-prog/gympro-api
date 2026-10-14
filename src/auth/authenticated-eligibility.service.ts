
import { Injectable } from '@nestjs/common';

import { LoginOrchestratorService } from './login-orchestrator.service.js';

import {
  createVerifiedLoginEligibility,
  isVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import type {
  VerifiedLoginEligibility,
} from './verified-login-eligibility.js';

/**
 * Gym Pro SaaS — Authenticated Eligibility Service
 *
 * Coordinates password authentication and
 * active tenant membership verification.
 *
 * This service:
 * - Does not accept a client-supplied userId.
 * - Does not accept a client-supplied membershipId.
 * - Does not create database sessions.
 * - Does not generate bearer tokens.
 *
 * The result is an internal application object,
 * not cryptographic proof of authentication.
 */
@Injectable()
export class AuthenticatedEligibilityService {
  constructor(
    private readonly loginOrchestrator:
      LoginOrchestratorService,
  ) {}

  async authenticateTenant(
    email: string,
    password: string,
    tenantId: string,
  ): Promise<VerifiedLoginEligibility> {
    const eligibility =
      await this.loginOrchestrator.verifyLoginEligibility(
        email,
        password,
        tenantId,
      );

    const verified =
      createVerifiedLoginEligibility(eligibility);

    if (!isVerifiedLoginEligibility(verified)) {
      throw new Error(
        'Internal eligibility verification failed',
      );
    }

    return verified;
  }
}
