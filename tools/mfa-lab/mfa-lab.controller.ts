import {Body,CanActivate,Controller,ExecutionContext,Get,Header,HttpCode,HttpException,Injectable,Post,Req,UseGuards} from '@nestjs/common';import type {Request} from 'express';import {readFileSync} from 'node:fs';import {join} from 'node:path';import {MfaLabService} from './mfa-lab.service.js';import {AuthenticatedSessionGuard} from './authenticated-session.guard.js';import type {GymProAuthenticatedRequest} from './authenticated-session.guard.js';import {SessionBearerTokenService} from './session-bearer-token.service.js';import {LoginAttemptLimiter} from './login-attempt-limiter.js';
@Injectable()export class MfaLabOnlyGuard implements CanActivate{constructor(private readonly service:MfaLabService){}canActivate(context:ExecutionContext){this.service.assertEnabled();const http=context.switchToHttp();http.getResponse<{setHeader(n:string,v:string):void}>().setHeader('Cache-Control','no-store');if(!['127.0.0.1','::1','::ffff:127.0.0.1'].includes(http.getRequest<Request>().socket.remoteAddress??''))throw new HttpException('Local rehearsal only',403);return true;}}
@Injectable()export class MfaLabLimitGuard implements CanActivate{private readonly limiter=new LoginAttemptLimiter();canActivate(context:ExecutionContext){const http=context.switchToHttp(),r=http.getRequest<Request>(),retry=this.limiter.consume(r.socket.remoteAddress??'unknown',r.body);if(retry){http.getResponse<{setHeader(n:string,v:string):void}>().setHeader('Retry-After',String(retry));throw new HttpException('Too many MFA attempts. Try again later.',429);}return true;}}
@Controller('auth/mfa-lab')@UseGuards(MfaLabOnlyGuard,MfaLabLimitGuard)
export class MfaLabController{constructor(private readonly service:MfaLabService,private readonly tokens:SessionBearerTokenService){}
 private hash(r:GymProAuthenticatedRequest){return this.tokens.hashAuthorization(r.headers?.authorization);}
 @Post('login')@HttpCode(200)login(@Body()b:unknown){return this.service.login(b);}
 @Post('complete')@HttpCode(200)complete(@Body()b:unknown){return this.service.complete(b);}
 @Get('status')@UseGuards(AuthenticatedSessionGuard)status(@Req()r:GymProAuthenticatedRequest){return this.service.status(this.hash(r));}
 @Post('enroll')@HttpCode(200)@UseGuards(AuthenticatedSessionGuard)enroll(@Req()r:GymProAuthenticatedRequest,@Body()b:unknown){return this.service.prepare(this.hash(r),r.gymproSession!.userId,b);}
 @Post('confirm')@HttpCode(200)@UseGuards(AuthenticatedSessionGuard)confirm(@Req()r:GymProAuthenticatedRequest,@Body()b:unknown){return this.service.confirm(this.hash(r),b);}
 @Post('disable')@HttpCode(200)@UseGuards(AuthenticatedSessionGuard)disable(@Req()r:GymProAuthenticatedRequest,@Body()b:unknown){return this.service.disable(this.hash(r),b);}
}
@Controller('account/mfa-lab')@UseGuards(MfaLabOnlyGuard)
export class MfaLabUiController{
 @Get()@Header('Content-Type','text/html; charset=utf-8')@Header('Referrer-Policy','no-referrer')@Header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")page(){return readFileSync(join(process.cwd(),'web/mfa-lab/index.html'),'utf8');}
 @Get('app.js')@Header('Content-Type','application/javascript; charset=utf-8')script(){return readFileSync(join(process.cwd(),'web/mfa-lab/app.js'),'utf8');}
 @Get('style.css')@Header('Content-Type','text/css; charset=utf-8')style(){return readFileSync(join(process.cwd(),'web/mfa-lab/style.css'),'utf8');}
}
