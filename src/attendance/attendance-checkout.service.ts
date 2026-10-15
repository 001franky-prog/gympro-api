import { BadRequestException, ForbiddenException, Injectable, ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import type { OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import pg from 'pg';
import { SessionBearerTokenService } from '../auth/session-bearer-token.service.js';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const same = (a: unknown,b: string) => uuid(a) && a.toLowerCase()===b.toLowerCase();
interface Visit extends pg.QueryResultRow {id:string;visit_id:string;tenant_id:string;branch_id:string;member_id:string;request_id:string;checked_in_at:Date;checked_out_at:Date;}
@Injectable()
export class AttendanceCheckoutService implements OnModuleInit,OnModuleDestroy {
 private readonly pool: pg.Pool;
 private ready=false;
 constructor(config: ConfigService,private readonly bearer: SessionBearerTokenService){
  const url=config.get<string>('DATABASE_URL'); if(!url)throw new Error('DATABASE_URL is required');
  this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});
  this.pool.on('error',()=>console.error('Attendance database pool error'));
 }
 async onModuleInit(){
  this.ready=false;
  const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app'
   AND NOT rolsuper AND NOT rolbypassrls
   AND has_function_privilege(current_user,to_regprocedure('security.check_out_member(bytea,uuid,uuid,uuid,uuid)'),'EXECUTE')
   AND NOT has_table_privilege(current_user,'app.attendance_visits','SELECT,INSERT,UPDATE,DELETE') AND NOT has_table_privilege(current_user,'app.attendance_checkouts','SELECT,INSERT,UPDATE,DELETE') AS safe
   FROM pg_roles WHERE rolname=current_user`);
  if(r.rows.length!==1 || r.rows[0].safe!==true)throw new Error('Attendance requires restricted function-only database access');
  this.ready=true;
 }
 async checkOut(req:GymProAuthenticatedRequest,tenant:string,branch:string,visit:string,body:unknown){
  const s=req.gymproSession;
  if(!s || ![s.sessionId,s.tenantId,s.membershipId,s.userId].every(uuid))throw new UnauthorizedException('Invalid or expired session');
  if(![tenant,branch,visit].every(uuid))throw new BadRequestException('Invalid attendance identifier');
  if(!same(s.tenantId,tenant))throw new ForbiddenException('Tenant access denied');
  if(!this.ready)throw new ServiceUnavailableException('Attendance unavailable');
  if(!body || typeof body!=='object' || Array.isArray(body) || Object.keys(body).length!==1 || !('requestId' in body) || !uuid(body.requestId))throw new BadRequestException('Attendance requires requestId only');
  const requestId=body.requestId;
  const hash=this.bearer.hashAuthorization(req.headers?.authorization);
  if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  let row:Visit|undefined;
  try {
   const r=await this.pool.query<Visit>(`SELECT id,tenant_id,branch_id,member_id,visit_id,request_id,checked_in_at,checked_out_at FROM security.check_out_member($1::bytea,$2::uuid,$3::uuid,$4::uuid,$5::uuid)`,[hash,tenant,branch,visit,requestId]);
   if(r.rows.length===1)row=r.rows[0];
  }catch(e:unknown){
   const x=(typeof e==='object' && e!==null ? e : {}) as {code?:string;message?:string};
   if(x.code==='28000' && x.message==='Invalid or expired session')throw new UnauthorizedException('Invalid or expired session');
   if(x.code==='42501' && x.message==='Attendance access denied')throw new ForbiddenException('Attendance access denied');
   if(x.code==='22023' || x.code==='23505')throw new BadRequestException('Invalid attendance request');
   throw new ServiceUnavailableException('Attendance unavailable');
  }
  if(!row || !uuid(row.id)||!uuid(row.member_id)||!same(row.tenant_id,tenant)||!same(row.branch_id,branch)||!same(row.visit_id,visit)||!same(row.request_id,requestId)|| !(row.checked_in_at instanceof Date)|| !Number.isFinite(row.checked_in_at.getTime()) || !(row.checked_out_at instanceof Date)||!Number.isFinite(row.checked_out_at.getTime())||row.checked_out_at<row.checked_in_at)throw new ServiceUnavailableException('Attendance unavailable');
  return {id:row.id,tenantId:row.tenant_id,branchId:row.branch_id,memberId:row.member_id,visitId:row.visit_id,requestId:row.request_id,checkedInAt:row.checked_in_at,checkedOutAt:row.checked_out_at};
 }
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
