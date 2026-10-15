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
import { SubscriptionSuspensionService } from './subscription-suspension.service.js';
import type { SubscriptionSuspension } from './subscription-suspension.js';

@Controller('tenants/:tenantId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.manage')
export class SubscriptionSuspensionController {
  constructor(
    private readonly suspensionService: SubscriptionSuspensionService,
  ) {}

  @Post('subscriptions/:subscriptionId/suspend')
  @HttpCode(HttpStatus.OK)
  async suspend(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<SubscriptionSuspension> {
    return this.suspensionService.suspend(
      request, tenantId, subscriptionId, body,
    );
  }

  @Post('branches/:branchId/subscriptions/:subscriptionId/suspend')
  @HttpCode(HttpStatus.OK)
  async suspendBranch(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('branchId') branchId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<SubscriptionSuspension> {
    return this.suspensionService.suspendBranch(
      request, tenantId, branchId, subscriptionId, body,
    );
  }
}