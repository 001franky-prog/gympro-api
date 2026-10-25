import { BadRequestException, Body, Controller, Get, HttpCode, Param, Post, Req, UseGuards } from '@nestjs/common';
import { AuthenticatedSessionGuard } from './authenticated-session.guard.js';
import type { GymProAuthenticatedRequest } from './authenticated-session.guard.js';
import { SessionBearerTokenService } from './session-bearer-token.service.js';
import { SelfSessionService } from './self-session.service.js';
@Controller('auth/sessions')
@UseGuards(AuthenticatedSessionGuard)
export class SelfSessionController {
 constructor(private readonly service:SelfSessionService,private readonly tokens:SessionBearerTokenService){}
 private empty(body:unknown):void{if(body!==undefined&&(body===null||typeof body!=='object'||Array.isArray(body)||Object.keys(body).length))throw new BadRequestException('Invalid session management request');}
 @Get() list(@Req() request:GymProAuthenticatedRequest){return this.service.manage(this.tokens.hashAuthorization(request.headers?.authorization),'list');}
 @Post('revoke-others') @HttpCode(200)
 others(@Req() request:GymProAuthenticatedRequest,@Body() body:unknown){this.empty(body);return this.service.manage(this.tokens.hashAuthorization(request.headers?.authorization),'revoke_others');}
 @Post(':sessionId/revoke') @HttpCode(200)
 revoke(@Req() request:GymProAuthenticatedRequest,@Param('sessionId') id:string,@Body() body:unknown){this.empty(body);if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))throw new BadRequestException('Invalid session identifier');return this.service.manage(this.tokens.hashAuthorization(request.headers?.authorization),'revoke',id);}
}
