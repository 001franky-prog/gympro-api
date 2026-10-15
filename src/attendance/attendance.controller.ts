import { Body, Controller, HttpCode, Param, Post, Req, UseGuards } from '@nestjs/common';
import { AuthenticatedSessionGuard } from '../auth/authenticated-session.guard.js';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import { TenantScopeGuard } from '../auth/tenant-scope.guard.js';
import { PermissionGuard } from '../auth/permission.guard.js';
import { RequirePermission } from '../auth/require-permission.decorator.js';
import { AttendanceService } from './attendance.service.js';
@Controller('tenants/:tenantId/branches/:branchId/members/:memberId/attendance')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class AttendanceController {
 constructor(private readonly service:AttendanceService){}
 @Post('check-in') @HttpCode(200) @RequirePermission('gym.attendance.record')
 checkIn(@Req()req:GymProAuthenticatedRequest,@Param('tenantId')tenant:string,@Param('branchId')branch:string,@Param('memberId')member:string,@Body()body:unknown){return this.service.checkIn(req,tenant,branch,member,body);}
}
