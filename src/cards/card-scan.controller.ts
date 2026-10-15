import {Body,Controller,Get,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {CardScanService} from './card-scan.service.js';
@Controller('tenants/:tenantId/branches/:branchId')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class CardScanController {
 constructor(private readonly service:CardScanService){}
 @Get('cards/:cardId/qr') @RequirePermission('gym.cards.read')
 qr(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('cardId')c:string,@Query()q:unknown){return this.service.qr(r,t,b,c,q);}
 @Post('attendance/scan-card') @HttpCode(200) @RequirePermission('gym.attendance.record')
 scan(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Body()body:unknown){return this.service.scan(r,t,b,body);}
}
