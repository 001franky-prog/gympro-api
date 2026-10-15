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
  type GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';
import { TenantScopeGuard } from '../auth/tenant-scope.guard.js';
import { PermissionGuard } from '../auth/permission.guard.js';
import { RequirePermission } from '../auth/require-permission.decorator.js';
import { SubscriptionRenewalService } from './subscription-renewal.service.js';
import type { SubscriptionRenewal } from './subscription-renewal.js';

@Controller('tenants/:tenantId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.manage')
export class SubscriptionRenewalController {
  constructor(
    private readonly renewalService: SubscriptionRenewalService,
  ) {}

  @Post('subscriptions/:subscriptionId/renew')
  @HttpCode(HttpStatus.OK)
  async renew(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<SubscriptionRenewal> {
    return this.renewalService.renew(
      request,
      tenantId,
      subscriptionId,
      body,
    );
  }

  @Post('branches/:branchId/subscriptions/:subscriptionId/renew')
  @HttpCode(HttpStatus.OK)
  async renewBranch(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('branchId') branchId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<SubscriptionRenewal> {
    return this.renewalService.renewBranch(
      request,
      tenantId,
      branchId,
      subscriptionId,
      body,
    );
  }
}