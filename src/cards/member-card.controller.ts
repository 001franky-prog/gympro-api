import {Body,Controller,Get,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {MemberCardService} from './member-card.service.js';
@Controller('tenants/:tenantId/branches/:branchId')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class MemberCardController {
 constructor(private readonly service:MemberCardService){}
 @Post('members/:memberId/cards/issue') @HttpCode(200) @RequirePermission('gym.cards.manage')
 issue(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('memberId')m:string,@Body()body:unknown){return this.service.issue(r,t,b,m,body);}
 @Post('cards/:cardId/revoke') @HttpCode(200) @RequirePermission('gym.cards.manage')
 revoke(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('cardId')c:string,@Body()body:unknown){return this.service.revoke(r,t,b,c,body);}
 @Get('cards/:cardId') @RequirePermission('gym.cards.read')
 read(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('cardId')c:string,@Query()q:unknown){return this.service.read(r,t,b,c,q);}
}
