import {Body,Controller,Get,Header,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PaymentReversalService} from './payment-reversal.service.js';
@Controller('tenants/:tenantId/branches/:branchId/payments')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PaymentReversalController {
 constructor(private readonly service:PaymentReversalService){}
 @Post('receipts/:receiptId/reversals') @HttpCode(201) @Header('Cache-Control','no-store') @RequirePermission('finance.payments.reverse')
 reverse(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('receiptId')id:string,@Body()body:unknown){return this.service.reverse(r,t,b,id,body);}
 @Get('reversals/:reversalId') @Header('Cache-Control','no-store') @RequirePermission('finance.payments.read')
 read(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('reversalId')id:string,@Query()q:unknown){return this.service.read(r,t,b,id,q);}
}
