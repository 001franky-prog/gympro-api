import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import QRCode from 'qrcode';
import {MemberCardService} from './member-card.service.js';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const pattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid=(v:unknown):v is string=>typeof v==='string'&&pattern.test(v);
const same=(v:unknown,x:string)=>uuid(v)&&v.toLowerCase()===x.toLowerCase();
const date=(v:unknown):v is Date=>v instanceof Date&&Number.isFinite(v.getTime());
const calendar=(v:unknown):v is string=>{if(typeof v!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(v))return false;const d=new Date(v+'T00:00:00Z');return date(d)&&d.toISOString().slice(0,10)===v;};
interface Visit extends pg.QueryResultRow{id:string;tenant_id:string;branch_id:string;member_id:string;subscription_id:string;request_id:string;checked_in_at:Date;checked_out_at:Date|null;business_date:string;}
@Injectable()
export class CardScanService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService,private readonly cards:MemberCardService){const url=config.get<string>('DATABASE_URL');if(!url)throw new Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Card scan database pool error'));}
 async onModuleInit(){this.ready=false;const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls AND has_function_privilege(current_user,to_regprocedure('security.scan_member_card(bytea,uuid,uuid,uuid,uuid)'),'EXECUTE') AND NOT has_table_privilege(current_user,'app.member_cards','SELECT,INSERT,UPDATE,DELETE') AND NOT has_table_privilege(current_user,'app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') AS safe FROM pg_roles WHERE rolname=current_user`);if(r.rows.length!==1||r.rows[0].safe!==true)throw new Error('Card scanning requires restricted function-only access');this.ready=true;}
 async qr(req:GymProAuthenticatedRequest,t:string,b:string,c:string,q:unknown){
  if(!this.ready)throw new ServiceUnavailableException('Card QR unavailable');
  const card=await this.cards.read(req,t,b,c,q);if(card.status!=='active')throw new BadRequestException('Card is not active');
  const payload=`GP1:${t.toLowerCase()}:${b.toLowerCase()}:${c.toLowerCase()}`;
  try{const svg=await QRCode.toString(payload,{type:'svg',errorCorrectionLevel:'M',margin:4,width:320});if(typeof svg!=='string'||!svg.includes('<svg'))throw new Error();return{cardId:card.id,payload,svg};}catch{throw new ServiceUnavailableException('Card QR unavailable');}
 }
 async scan(req:GymProAuthenticatedRequest,t:string,b:string,body:unknown){
  const s=req.gymproSession;if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(uuid))throw new UnauthorizedException('Invalid or expired session');if(![t,b].every(uuid))throw new BadRequestException('Invalid card scan identifier');if(!same(s.tenantId,t))throw new ForbiddenException('Tenant access denied');if(!this.ready)throw new ServiceUnavailableException('Card scan unavailable');
  if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).length!==2||!('requestId'in body)||!uuid(body.requestId)||!('payload'in body)||typeof body.payload!=='string'||body.payload.length!==114)throw new BadRequestException('Card scan requires payload and requestId');
  const parts=body.payload.split(':');if(parts.length!==4||parts[0]!=='GP1'||!parts.slice(1).every(uuid))throw new BadRequestException('Invalid card QR payload');
  if(!same(parts[1],t)||!same(parts[2],b))throw new ForbiddenException('Card scan access denied');
  const hash=this.bearer.hashAuthorization(req.headers?.authorization);if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  let rows:Visit[];try{rows=(await this.pool.query<Visit>('SELECT id,tenant_id,branch_id,member_id,subscription_id,request_id,checked_in_at,checked_out_at,business_date::text FROM security.scan_member_card($1::bytea,$2::uuid,$3::uuid,$4::uuid,$5::uuid)',[hash,t,b,parts[3],body.requestId])).rows;}
  catch(e){const x=(typeof e==='object'&&e!==null?e:{})as{code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid or expired session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&['Card scan access denied','Attendance access denied'].includes(x.message??''))throw new ForbiddenException('Card scan access denied');if(x.code==='22023'||x.code==='23505')throw new BadRequestException('Invalid card scan');throw new ServiceUnavailableException('Card scan unavailable');}
  const r=rows[0];if(rows.length!==1||!r||!uuid(r.id)||!same(r.tenant_id,t)||!same(r.branch_id,b)||!uuid(r.member_id)||!uuid(r.subscription_id)||!same(r.request_id,body.requestId)||!date(r.checked_in_at)||!calendar(r.business_date)||(r.checked_out_at!==null&&(!date(r.checked_out_at)||r.checked_out_at<r.checked_in_at)))throw new ServiceUnavailableException('Card scan unavailable');
  return{id:r.id,tenantId:r.tenant_id,branchId:r.branch_id,memberId:r.member_id,subscriptionId:r.subscription_id,requestId:r.request_id,checkedInAt:r.checked_in_at,checkedOutAt:r.checked_out_at,businessDate:r.business_date};
 }
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
