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
  MemberBlacklistService,
} from './member-blacklist.service.js';

import type {
  MemberBlacklistEvent,
} from './member-blacklist.js';

@Controller('tenants/:tenantId/members/:memberId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.members.update')
export class MemberBlacklistController {
  constructor(
    private readonly blacklistService: MemberBlacklistService,
  ) {}

  @Post('blacklist')
  @HttpCode(HttpStatus.OK)
  async blacklist(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('memberId') memberId: string,
    @Body() body: unknown,
  ): Promise<MemberBlacklistEvent> {
    return this.blacklistService.change(
      request,
      tenantId,
      memberId,
      'blacklist',
      body,
    );
  }

  @Post('unblacklist')
  @HttpCode(HttpStatus.OK)
  async unblacklist(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('memberId') memberId: string,
    @Body() body: unknown,
  ): Promise<MemberBlacklistEvent> {
    return this.blacklistService.change(
      request,
      tenantId,
      memberId,
      'unblacklist',
      body,
    );
  }
}