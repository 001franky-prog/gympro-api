import {Controller,Get,Header,Param,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PaymentReportingService} from './payment-reporting.service.js';
@Controller('tenants/:tenantId/branches/:branchId/payments')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PaymentReportingController {
 constructor(private readonly service:PaymentReportingService){}
 @Get('history') @Header('Cache-Control','no-store') @RequirePermission('finance.payments.read')
 history(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.history(r,t,b,q);}
 @Get('daily-summary') @Header('Cache-Control','no-store') @RequirePermission('finance.payments.read')
 summary(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.summary(r,t,b,q);}
}
