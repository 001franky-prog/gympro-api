import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';

import {
  AuthenticatedSessionGuard,
} from '../auth/authenticated-session.guard.js';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import {
  TenantScopeGuard,
} from '../auth/tenant-scope.guard.js';

import {
  PermissionGuard,
} from '../auth/permission.guard.js';

import {
  RequirePermission,
} from '../auth/require-permission.decorator.js';

import {
  SubscriptionActivationService,
} from './subscription-activation.service.js';

import type {
  MemberSubscription,
} from './member-subscription.js';

@Controller('tenants/:tenantId/members/:memberId/subscriptions')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.manage')
export class SubscriptionActivationController {
  constructor(
    private readonly activationService:
      SubscriptionActivationService,
  ) {}

  @Post('activate')
  @HttpCode(HttpStatus.CREATED)
  async activate(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('memberId') memberId: string,
    @Body() body: unknown,
  ): Promise<MemberSubscription> {
    return this.activationService.activate(
      request,
      tenantId,
      memberId,
      body,
    );
  }
}