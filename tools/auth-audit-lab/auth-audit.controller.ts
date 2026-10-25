import {CallHandler,Controller,ExecutionContext,Get,Header,HttpException,Injectable,NestInterceptor,Query,Req,UseGuards} from '@nestjs/common';import {catchError,from,mergeMap,throwError} from 'rxjs';import {readFileSync} from 'node:fs';import {join} from 'node:path';import {AuthAuditService} from './auth-audit.service.js';import {AuthenticatedSessionGuard} from './authenticated-session.guard.js';import type {GymProAuthenticatedRequest} from './authenticated-session.guard.js';import {SessionBearerTokenService} from './session-bearer-token.service.js';
@Injectable()export class RejectedLoginAuditInterceptor implements NestInterceptor{
 constructor(private readonly audit:AuthAuditService){}
 intercept(context:ExecutionContext,next:CallHandler){const r=context.switchToHttp().getRequest<{method?:string;path?:string}>();return next.handle().pipe(catchError((error:unknown)=>{if(r.method==='POST'&&r.path==='/auth/login'&&error instanceof HttpException&&error.getStatus()===401)return from(this.audit.rejected()).pipe(mergeMap(()=>throwError(()=>error)));return throwError(()=>error);}));}
}
@Controller('auth/audit')export class AuthAuditController{constructor(private readonly audit:AuthAuditService,private readonly tokens:SessionBearerTokenService){}
 @Get('history')@Header('Cache-Control','no-store')@UseGuards(AuthenticatedSessionGuard)history(@Req()r:GymProAuthenticatedRequest,@Query()q:Record<string,unknown>){return this.audit.history(this.tokens.hashAuthorization(r.headers?.authorization),q);}
}
@Controller('account/security-history')export class AuthAuditUiController{
 @Get()@Header('Content-Type','text/html; charset=utf-8')@Header('Cache-Control','no-store')@Header('Referrer-Policy','no-referrer')@Header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")page(){return readFileSync(join(process.cwd(),'web/auth-audit/index.html'),'utf8');}
 @Get('app.js')@Header('Content-Type','application/javascript; charset=utf-8')script(){return readFileSync(join(process.cwd(),'web/auth-audit/app.js'),'utf8');}
 @Get('style.css')@Header('Content-Type','text/css; charset=utf-8')style(){return readFileSync(join(process.cwd(),'web/auth-audit/style.css'),'utf8');}
}
