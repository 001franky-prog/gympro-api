import {Body,Controller,Get,Header,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PaymentService} from './payment.service.js';
@Controller('tenants/:tenantId/branches/:branchId/payments')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PaymentController {
 constructor(private readonly service:PaymentService){}
 @Post('charges') @HttpCode(201) @Header('Cache-Control','no-store') @RequirePermission('finance.payments.record')
 open(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Body()body:unknown){return this.service.open(r,t,b,body);}
 @Post('charges/:chargeId/receipts') @HttpCode(201) @Header('Cache-Control','no-store') @RequirePermission('finance.payments.record')
 record(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('chargeId')c:string,@Body()body:unknown){return this.service.record(r,t,b,c,body);}
 @Get('charges/:chargeId') @Header('Cache-Control','no-store') @RequirePermission('finance.payments.read')
 charge(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('chargeId')c:string,@Query()q:unknown){return this.service.readCharge(r,t,b,c,q);}
 @Get('receipts/:receiptId') @Header('Cache-Control','no-store') @RequirePermission('finance.payments.read')
 receipt(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('receiptId')c:string,@Query()q:unknown){return this.service.readReceipt(r,t,b,c,q);}
}
