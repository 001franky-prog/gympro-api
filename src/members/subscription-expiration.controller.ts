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
  SubscriptionExpirationService,
} from './subscription-expiration.service.js';

import type {
  SubscriptionExpiration,
} from './subscription-expiration.js';

@Controller('tenants/:tenantId/subscriptions/:subscriptionId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.manage')
export class SubscriptionExpirationController {
  constructor(
    private readonly expirationService:
      SubscriptionExpirationService,
  ) {}

  @Post('expire')
  @HttpCode(HttpStatus.OK)
  async expire(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<SubscriptionExpiration> {
    return this.expirationService.expire(
      request,
      tenantId,
      subscriptionId,
      body,
    );
  }
}