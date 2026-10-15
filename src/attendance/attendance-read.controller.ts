import {Controller,Get,Header,Param,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {AttendanceReadService} from './attendance-read.service.js';
@Controller('tenants/:tenantId/branches/:branchId/attendance')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
@RequirePermission('gym.attendance.read')
export class AttendanceReadController {
 constructor(private readonly service:AttendanceReadService){}
 @Get() history(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.list(r,t,b,q);}
 @Get('summary') @Header('Cache-Control','no-store') summary(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.summary(r,t,b,q);}
 @Get('current') current(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.list(r,t,b,q,true);}
}
