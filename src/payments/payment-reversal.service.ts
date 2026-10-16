import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import * as v from './payment-validation.js';
import * as reversal from './payment-reversal-validation.js';
@Injectable()
export class PaymentReversalService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService){const url=config.get<string>('DATABASE_URL');if(!url)throw Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Payment database pool unavailable'));}
 async onModuleInit(){this.ready=false;const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls
 AND (SELECT count(*)=2 AND bool_and(p.prosecdef AND p.proowner='gympro_payment_owner'::regrole AND has_function_privilege(current_user,p.oid,'EXECUTE') AND NOT EXISTS(SELECT FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE')) FROM pg_proc p WHERE p.oid=ANY(ARRAY[to_regprocedure('security.reverse_payment_receipt(bytea,uuid,uuid,uuid,text,numeric,text,uuid)'),to_regprocedure('security.read_payment_reversal(bytea,uuid,uuid,uuid)')]::oid[]))
 AND (SELECT count(*)=1 AND bool_and(NOT(rolcanlogin OR rolsuper OR rolbypassrls OR rolinherit OR rolcreatedb OR rolcreaterole OR rolreplication)) FROM pg_roles WHERE rolname='gympro_payment_owner')
 AND NOT EXISTS(SELECT FROM pg_auth_members WHERE member='gympro_payment_owner'::regrole OR roleid='gympro_payment_owner'::regrole)
 AND NOT has_table_privilege(current_user,'app.payment_charges','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 AND NOT has_table_privilege(current_user,'app.payment_receipts','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 AND NOT has_table_privilege(current_user,'app.payment_reversals','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 AND NOT has_function_privilege(current_user,'security.payment_reversal_json(uuid,uuid)','EXECUTE')
 AND (SELECT count(*)=3 AND bool_and(relrowsecurity AND relforcerowsecurity) FROM pg_class WHERE oid IN ('app.payment_charges'::regclass,'app.payment_receipts'::regclass,'app.payment_reversals'::regclass)) AS safe FROM pg_roles WHERE rolname=current_user`);if(r.rows.length!==1||r.rows[0]?.safe!==true)throw Error('Payment reversals require restricted function-only database access');this.ready=true;}
 private authorize(req:GymProAuthenticatedRequest,tenant:string,branch:string,target?:string){const s=req?.gymproSession;if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(v.uuid))throw new UnauthorizedException('Invalid or expired session');if(!v.uuid(tenant)||!v.uuid(branch)||(target!==undefined&&!v.uuid(target)))throw new BadRequestException('Invalid payment identifier');if(!v.same(s.tenantId,tenant))throw new ForbiddenException('Tenant access denied');if(!this.ready)throw new ServiceUnavailableException('Payments unavailable');const h=this.bearer.hashAuthorization(req.headers?.authorization);if(!Buffer.isBuffer(h)||h.length!==32)throw new UnauthorizedException('Invalid or expired session');return h;}
 private input<T>(fn:()=>T):T{try{return fn()}catch{throw new BadRequestException('Invalid payment request')}}
 private async query(sql:string,args:unknown[]){try{const r=await this.pool.query(sql,args);if(r.rows.length!==1)throw Error('Invalid payment result');return r.rows[0]?.receipt as unknown}catch(e){const x=(e&&typeof e==='object'?e:{}) as {code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&['Payment access denied','Inactive payment branch','Purchase branch mismatch','Tenant membership payment access denied','Charge branch mismatch','Tenant payment access denied','Receipt branch mismatch','Tenant reversal access denied'].includes(x.message??''))throw new ForbiddenException('Payment access denied');if(x.code==='22023'||x.code==='23505')throw new BadRequestException('Invalid payment request');throw new ServiceUnavailableException('Payments unavailable');}}
 private output<T>(fn:()=>T):T{try{return fn()}catch{throw new ServiceUnavailableException('Payments unavailable')}}
 async reverse(req:GymProAuthenticatedRequest,tenant:string,branch:string,receipt:string,body:unknown){const h=this.authorize(req,tenant,branch,receipt);const x=this.input(()=>reversal.input(body));const r=await this.query('SELECT security.reverse_payment_receipt($1::bytea,$2::uuid,$3::uuid,$4::uuid,$5::text,$6::numeric,$7::text,$8::uuid) AS receipt',[h,tenant,branch,receipt,x.reversalKind,x.amount,x.reason,x.requestId]);return this.output(()=>reversal.receipt(r,tenant,branch,{...x,receiptId:receipt}));}
 async read(req:GymProAuthenticatedRequest,tenant:string,branch:string,id:string,query:unknown){const h=this.authorize(req,tenant,branch,id);this.input(()=>v.object(query,[]));const r=await this.query('SELECT security.read_payment_reversal($1::bytea,$2::uuid,$3::uuid,$4::uuid) AS receipt',[h,tenant,branch,id]);return this.output(()=>reversal.receipt(r,tenant,branch,{id}));}
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
