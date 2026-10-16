import {Body,Controller,Get,Header,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PaymentReconciliationService} from './payment-reconciliation.service.js';
@Controller('tenants/:tenantId/branches/:branchId/payments/reconciliations')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PaymentReconciliationController {
 constructor(private readonly service:PaymentReconciliationService){}
 @Post() @HttpCode(201) @Header('Cache-Control','no-store') @RequirePermission('finance.reconciliation.manage')
 reconcile(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Body()body:unknown){return this.service.reconcile(r,t,b,body);}
 @Get(':reconciliationId') @Header('Cache-Control','no-store') @RequirePermission('finance.reconciliation.manage')
 read(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('reconciliationId')id:string,@Query()q:unknown){return this.service.read(r,t,b,id,q);}
}
