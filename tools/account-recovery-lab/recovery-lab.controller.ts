import {Body,CanActivate,Controller,ExecutionContext,Get,Header,Headers,HttpCode,HttpException,Injectable,Post,Req,UseGuards} from '@nestjs/common';
import {readFileSync} from 'node:fs';import {join} from 'node:path';import type {Request} from 'express';
import {AuthenticatedSessionGuard} from './authenticated-session.guard.js';import {SessionBearerTokenService} from './session-bearer-token.service.js';import {LoginAttemptLimiter} from './login-attempt-limiter.js';import {RecoveryLabService} from './recovery-lab.service.js';
@Injectable()export class RecoveryLabOnlyGuard implements CanActivate{constructor(private readonly service:RecoveryLabService){}canActivate(context:ExecutionContext){context.switchToHttp().getResponse<{setHeader(n:string,v:string):void}>().setHeader('Cache-Control','no-store');this.service.assertEnabled();const peer=context.switchToHttp().getRequest<Request>().socket.remoteAddress;if(!['127.0.0.1','::1','::ffff:127.0.0.1'].includes(peer??''))throw new HttpException('Local rehearsal only',403);return true;}}
@Injectable()export class RecoveryLabLimitGuard implements CanActivate{private readonly limiter=new LoginAttemptLimiter();canActivate(context:ExecutionContext){const http=context.switchToHttp(),r=http.getRequest<Request>();const retry=this.limiter.consume(r.socket.remoteAddress??'unknown',r.body);if(retry){http.getResponse<{setHeader(n:string,v:string):void}>().setHeader('Retry-After',String(retry));throw new HttpException('Too many recovery attempts. Try again later.',429);}return true;}}
@Controller('auth/recovery-lab')@UseGuards(RecoveryLabOnlyGuard)
export class RecoveryLabController{
 constructor(private readonly service:RecoveryLabService,private readonly tokens:SessionBearerTokenService){}
 @Post('email/request')@HttpCode(202)@UseGuards(AuthenticatedSessionGuard,RecoveryLabLimitGuard)
 requestVerification(@Req()r:Request,@Body()b:unknown){return this.service.issue('verify_email',b,this.tokens.hashAuthorization(r.headers.authorization));}
 @Post('email/confirm')@HttpCode(200)@UseGuards(RecoveryLabLimitGuard)verify(@Body()b:unknown){return this.service.verify(b);}
 @Post('password/request')@HttpCode(202)@UseGuards(RecoveryLabLimitGuard)async requestReset(@Body()b:unknown){const start=Date.now();try{return await this.service.issue('reset_password',b);}finally{const remaining=300-(Date.now()-start);if(remaining>0)await new Promise(r=>setTimeout(r,remaining));}}
 @Post('password/confirm')@HttpCode(200)@UseGuards(RecoveryLabLimitGuard)reset(@Body()b:unknown){return this.service.reset(b);}
 @Get('inbox')@UseGuards(RecoveryLabLimitGuard)inbox(@Headers('x-rehearsal-inbox-key')key:unknown){return this.service.inbox(key);}
}
@Controller('account/recovery-lab')@UseGuards(RecoveryLabOnlyGuard)
export class RecoveryLabUiController{
 @Get()@Header('Content-Type','text/html; charset=utf-8')@Header('Cache-Control','no-store')@Header('Referrer-Policy','no-referrer')
 @Header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")page(){return readFileSync(join(process.cwd(),'web/recovery-lab/index.html'),'utf8');}
 @Get('app.js')@Header('Content-Type','application/javascript; charset=utf-8')@Header('Cache-Control','no-store')script(){return readFileSync(join(process.cwd(),'web/recovery-lab/app.js'),'utf8');}
 @Get('style.css')@Header('Content-Type','text/css; charset=utf-8')style(){return readFileSync(join(process.cwd(),'web/recovery-lab/style.css'),'utf8');}
}
