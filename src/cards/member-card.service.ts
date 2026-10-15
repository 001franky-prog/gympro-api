import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const uuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const same=(a:unknown,b:string)=>uuid(a)&&a.toLowerCase()===b.toLowerCase();
const date=(v:unknown):v is Date=>v instanceof Date&&Number.isFinite(v.getTime());
interface CardEvent extends pg.QueryResultRow {id:string;tenant_id:string;branch_id:string;member_id:string;card_id:string;request_id:string;event_type:string;reason:string|null;event_at:Date;}
interface Card extends pg.QueryResultRow {id:string;tenant_id:string;branch_id:string;member_id:string;member_number:string;full_name:string;status:string;issued_at:Date;revoked_at:Date|null;}
@Injectable()
export class MemberCardService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService){const url=config.get<string>('DATABASE_URL');if(!url)throw new Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Member card database pool error'));}
 async onModuleInit(){this.ready=false;const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls AND has_function_privilege(current_user,to_regprocedure('security.change_member_card(bytea,uuid,uuid,uuid,text,uuid,text)'),'EXECUTE') AND has_function_privilege(current_user,to_regprocedure('security.read_member_card(bytea,uuid,uuid,uuid)'),'EXECUTE') AND NOT has_table_privilege(current_user,'app.member_cards','SELECT,INSERT,UPDATE,DELETE') AND NOT has_table_privilege(current_user,'app.member_card_events','SELECT,INSERT,UPDATE,DELETE') AS safe FROM pg_roles WHERE rolname=current_user`);if(r.rows.length!==1||r.rows[0].safe!==true)throw new Error('Member cards require restricted function-only database access');this.ready=true;}
 private authorize(req:GymProAuthenticatedRequest,tenant:string,branch:string,subject:string){const s=req.gymproSession;if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(uuid))throw new UnauthorizedException('Invalid or expired session');if(![tenant,branch,subject].every(uuid))throw new BadRequestException('Invalid card identifier');if(!same(s.tenantId,tenant))throw new ForbiddenException('Tenant access denied');if(!this.ready)throw new ServiceUnavailableException('Member cards unavailable');const hash=this.bearer.hashAuthorization(req.headers?.authorization);if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');return hash;}
 issue(req:GymProAuthenticatedRequest,t:string,b:string,m:string,body:unknown){return this.change(req,t,b,m,'issue',body);}
 revoke(req:GymProAuthenticatedRequest,t:string,b:string,c:string,body:unknown){return this.change(req,t,b,c,'revoke',body);}
 private async change(req:GymProAuthenticatedRequest,t:string,b:string,subject:string,action:'issue'|'revoke',body:unknown){
  const hash=this.authorize(req,t,b,subject);
  if(!body||typeof body!=='object'||Array.isArray(body)||!('requestId'in body)||!uuid(body.requestId)||Object.keys(body).some(k=>!['requestId',...(action==='revoke'?['reason']:[])].includes(k)))throw new BadRequestException('Invalid card request');
  const requestId=body.requestId;let reason:string|null=null;
  if(action==='revoke'){if(!('reason'in body)||typeof body.reason!=='string')throw new BadRequestException('Revocation reason required');reason=body.reason.trim();if(Array.from(reason).length<2||Array.from(reason).length>500)throw new BadRequestException('Revocation reason must contain 2 to 500 characters');}
  let rows:CardEvent[];
  try{rows=(await this.pool.query<CardEvent>('SELECT id,tenant_id,branch_id,member_id,card_id,request_id,event_type,reason,event_at FROM security.change_member_card($1::bytea,$2::uuid,$3::uuid,$4::uuid,$5::text,$6::uuid,$7::text)',[hash,t,b,subject,action,requestId,reason])).rows;}catch(e){this.databaseError(e);}
  const r=rows[0];if(rows.length!==1||!r||!uuid(r.id)||!same(r.tenant_id,t)||!same(r.branch_id,b)||!uuid(r.card_id)||!uuid(r.member_id)||!same(r.request_id,requestId)||r.event_type!==(action==='issue'?'issued':'revoked')||r.reason!==reason||!date(r.event_at)||(action==='issue'?!same(r.member_id,subject):!same(r.card_id,subject)))throw new ServiceUnavailableException('Member cards unavailable');
  return {id:r.id,tenantId:r.tenant_id,branchId:r.branch_id,memberId:r.member_id,cardId:r.card_id,requestId:r.request_id,eventType:r.event_type,reason:r.reason,eventAt:r.event_at};
 }
 async read(req:GymProAuthenticatedRequest,t:string,b:string,card:string,query:unknown){
  const hash=this.authorize(req,t,b,card);if(!query||typeof query!=='object'||Array.isArray(query)||Object.keys(query).length!==0)throw new BadRequestException('Card details do not accept query parameters');
  let rows:Card[];try{rows=(await this.pool.query<Card>('SELECT * FROM security.read_member_card($1::bytea,$2::uuid,$3::uuid,$4::uuid)',[hash,t,b,card])).rows;}catch(e){this.databaseError(e);}
  const r=rows[0];if(rows.length!==1||!r||!same(r.id,card)||!same(r.tenant_id,t)||!same(r.branch_id,b)||!uuid(r.member_id)||typeof r.member_number!=='string'||r.member_number.length<1||typeof r.full_name!=='string'||r.full_name.trim().length<2||!date(r.issued_at)||!['active','revoked'].includes(r.status)||(r.status==='active'?r.revoked_at!==null:!date(r.revoked_at)||r.revoked_at<r.issued_at))throw new ServiceUnavailableException('Member cards unavailable');
  return {id:r.id,tenantId:r.tenant_id,branchId:r.branch_id,memberId:r.member_id,memberNumber:r.member_number,fullName:r.full_name,status:r.status,issuedAt:r.issued_at,revokedAt:r.revoked_at};
 }
 private databaseError(e:unknown):never{const x=(typeof e==='object'&&e!==null?e:{})as{code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid or expired session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&x.message==='Card access denied')throw new ForbiddenException('Card access denied');if(x.code==='22023'||x.code==='23505')throw new BadRequestException('Invalid card request');throw new ServiceUnavailableException('Member cards unavailable');}
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
