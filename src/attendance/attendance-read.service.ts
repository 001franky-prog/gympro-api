import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const uuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const same=(v:unknown,x:string)=>uuid(v)&&v.toLowerCase()===x.toLowerCase();
const calendar=(v:unknown):v is string=>{if(typeof v!=='string'||!/^(?!0000)\d{4}-\d{2}-\d{2}$/.test(v))return false;const d=new Date(v+'T00:00:00Z');return Number.isFinite(d.getTime())&&d.toISOString().slice(0,10)===v;};
const stamp=(v:unknown):v is string=>typeof v==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(v)&&Number.isFinite(Date.parse(v))&&new Date(v).toISOString().slice(0,23)===v.slice(0,23);
const validDate=(v:unknown):v is Date=>v instanceof Date&&Number.isFinite(v.getTime());
interface Visit extends pg.QueryResultRow {id:string;tenant_id:string;branch_id:string;member_id:string;member_number:string;full_name:string;subscription_id:string;checked_in_at:Date;checked_out_at:Date|null;business_date:string;cursor_at:string;}
@Injectable()
export class AttendanceReadService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService){const url=config.get<string>('DATABASE_URL');if(!url)throw new Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Attendance read database pool error'));}
 async onModuleInit(){this.ready=false;const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls AND has_function_privilege(current_user,to_regprocedure('security.read_branch_attendance(bytea,uuid,uuid,boolean,date,date,integer,timestamptz,uuid)'),'EXECUTE') AND NOT has_table_privilege(current_user,'app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') AS safe FROM pg_roles WHERE rolname=current_user`);if(r.rows.length!==1||r.rows[0].safe!==true)throw new Error('Attendance reading requires restricted function-only access');this.ready=true;}
 async list(req:GymProAuthenticatedRequest,tenant:string,branch:string,query:unknown,current=false){
  const s=req.gymproSession;if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(uuid))throw new UnauthorizedException('Invalid or expired session');
  if(![tenant,branch].every(uuid))throw new BadRequestException('Invalid attendance identifier');if(!same(s.tenantId,tenant))throw new ForbiddenException('Tenant access denied');if(!this.ready)throw new ServiceUnavailableException('Attendance reading unavailable');
  if(!query||typeof query!=='object'||Array.isArray(query)||Object.keys(query).some(k=>!['from','to','limit','cursor'].includes(k)))throw new BadRequestException('Invalid attendance query');
  const q=query as Record<string,unknown>;let limit=50;let beforeAt:string|null=null,beforeId:string|null=null;
  if(q.limit!==undefined){if(typeof q.limit!=='string'||!/^([1-9][0-9]?|100)$/.test(q.limit))throw new BadRequestException('Invalid attendance limit');limit=Number(q.limit);}
  if(current&&(q.from!==undefined||q.to!==undefined))throw new BadRequestException('Occupancy does not accept date filters');
  let from:string|null=null,to:string|null=null;
  if(q.from!==undefined||q.to!==undefined){if(!calendar(q.from)||!calendar(q.to)||q.to<=q.from||Date.parse(q.to)-Date.parse(q.from)>93*86400000)throw new BadRequestException('Invalid attendance date range');from=q.from;to=q.to;}
  if(q.cursor!==undefined){try{
   if(typeof q.cursor!=='string'||q.cursor.length>256||!/^[A-Za-z0-9_-]+$/.test(q.cursor))throw new Error();
   const bytes=Buffer.from(q.cursor,'base64url');if(bytes.toString('base64url')!==q.cursor)throw new Error();const c:unknown=JSON.parse(bytes.toString('utf8'));
   if(!c||typeof c!=='object'||Array.isArray(c)||Object.keys(c).length!==2||!('at'in c)||!('id'in c)||!stamp(c.at)||!uuid(c.id))throw new Error();beforeAt=c.at;beforeId=c.id;
  }catch{throw new BadRequestException('Invalid attendance cursor');}}
  const hash=this.bearer.hashAuthorization(req.headers?.authorization);if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  let rows:Visit[];
  try{const r=await this.pool.query<Visit>('SELECT * FROM security.read_branch_attendance($1::bytea,$2::uuid,$3::uuid,$4::boolean,$5::date,$6::date,$7::integer,$8::timestamptz,$9::uuid)',[hash,tenant,branch,current,from,to,limit,beforeAt,beforeId]);rows=r.rows;}
  catch(e:unknown){const x=(typeof e==='object'&&e!==null?e:{})as{code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid or expired session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&x.message==='Attendance access denied')throw new ForbiddenException('Attendance access denied');if(x.code==='22023')throw new BadRequestException('Invalid attendance query');throw new ServiceUnavailableException('Attendance reading unavailable');}
  if(rows.length>limit+1)throw new ServiceUnavailableException('Attendance reading unavailable');
  const seen=new Set<string>();let previousAt=beforeAt,previousId=beforeId;
  for(const r of rows){
   if(!uuid(r.id)||!same(r.tenant_id,tenant)||!same(r.branch_id,branch)||!uuid(r.member_id)||!uuid(r.subscription_id)||typeof r.member_number!=='string'||r.member_number.length<1||typeof r.full_name!=='string'||r.full_name.trim().length<2||!validDate(r.checked_in_at)||!calendar(r.business_date)||!stamp(r.cursor_at)||Date.parse(r.cursor_at)!==r.checked_in_at.getTime()||(r.checked_out_at!==null&&(!validDate(r.checked_out_at)||r.checked_out_at<r.checked_in_at))||(current&&r.checked_out_at!==null)||(from!==null&&(r.business_date<from||r.business_date>=to!))||seen.has(r.id.toLowerCase())||(previousAt!==null&&(r.cursor_at>previousAt||(r.cursor_at===previousAt&&r.id.toLowerCase()>=previousId!.toLowerCase()))))throw new ServiceUnavailableException('Attendance reading unavailable');
   seen.add(r.id.toLowerCase());previousAt=r.cursor_at;previousId=r.id;
  }
  const page=rows.slice(0,limit);const last=page.at(-1);
  const nextCursor=rows.length>limit&&last?Buffer.from(JSON.stringify({at:last.cursor_at,id:last.id})).toString('base64url'):null;
  return {items:page.map(r=>({id:r.id,tenantId:r.tenant_id,branchId:r.branch_id,memberId:r.member_id,memberNumber:r.member_number,fullName:r.full_name,subscriptionId:r.subscription_id,checkedInAt:r.checked_in_at,checkedOutAt:r.checked_out_at,businessDate:r.business_date})),nextCursor};
 }
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
