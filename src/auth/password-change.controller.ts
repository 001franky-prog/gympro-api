import {Body,Controller,HttpCode,Post,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from './authenticated-session.guard.js';import type {GymProAuthenticatedRequest} from './authenticated-session.guard.js';
import {LoginRateLimitGuard} from './login-rate-limit.guard.js';import {SessionBearerTokenService} from './session-bearer-token.service.js';import {PasswordChangeService} from './password-change.service.js';
@Controller('auth/password')
export class PasswordChangeController {
 constructor(private readonly service:PasswordChangeService,private readonly tokens:SessionBearerTokenService){}
 @Post('change') @HttpCode(200) @UseGuards(AuthenticatedSessionGuard,LoginRateLimitGuard)
 change(@Req() request:GymProAuthenticatedRequest,@Body() body:unknown){return this.service.change(this.tokens.hashAuthorization(request.headers?.authorization),body);}
}
