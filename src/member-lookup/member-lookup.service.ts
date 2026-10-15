import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const uuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const same=(a:unknown,b:string)=>uuid(a)&&a.toLowerCase()===b.toLowerCase();
interface Member extends pg.QueryResultRow {id:string;tenant_id:string;branch_id:string;member_number:string;full_name:string;status:string;}
@Injectable()
export class MemberLookupService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService){const url=config.get<string>('DATABASE_URL');if(!url)throw new Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Member lookup database pool error'));}
 async onModuleInit(){this.ready=false;const r=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls AND has_function_privilege(current_user,to_regprocedure('security.search_branch_members(bytea,uuid,uuid,text,integer,uuid)'),'EXECUTE') AND NOT has_table_privilege(current_user,'app.members','SELECT,INSERT,UPDATE,DELETE') AS safe FROM pg_roles WHERE rolname=current_user`);if(r.rows.length!==1||r.rows[0].safe!==true)throw new Error('Member lookup requires restricted function-only access');this.ready=true;}
 async search(req:GymProAuthenticatedRequest,t:string,b:string,query:unknown){
  const s=req.gymproSession;
  if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(uuid))throw new UnauthorizedException('Invalid or expired session');
  if(!uuid(t)||!uuid(b))throw new BadRequestException('Invalid lookup identifier');
  if(!same(s.tenantId,t))throw new ForbiddenException('Tenant access denied');
  if(!this.ready)throw new ServiceUnavailableException('Member lookup unavailable');
  const hash=this.bearer.hashAuthorization(req.headers?.authorization);
  if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  if(!query||typeof query!=='object'||Array.isArray(query)||Object.keys(query).some(k=>!['q','limit','cursor'].includes(k)))throw new BadRequestException('Invalid member lookup');
  const q=query as Record<string,unknown>;
  if(typeof q.q!=='string')throw new BadRequestException('Enter a name or member number');
  const term=q.q.trim();if([...term].length<2||[...term].length>100||term.includes('\0'))throw new BadRequestException('Search must contain 2 to 100 characters');
  const limit=q.limit===undefined?25:typeof q.limit==='string'&&/^(?:[1-9]|[1-4][0-9]|50)$/.test(q.limit)?Number(q.limit):NaN;
  if(!Number.isInteger(limit))throw new BadRequestException('Invalid lookup limit');
  const cursor=q.cursor===undefined?null:q.cursor;
  if(cursor!==null&&!uuid(cursor))throw new BadRequestException('Invalid lookup cursor');
  let rows:Member[];
  try{rows=(await this.pool.query<Member>('SELECT * FROM security.search_branch_members($1::bytea,$2::uuid,$3::uuid,$4::text,$5::integer,$6::uuid)',[hash,t,b,term,limit,cursor])).rows;}
  catch(e){const x=(e&&typeof e==='object'?e:{})as{code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid or expired session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&x.message==='Member lookup access denied')throw new ForbiddenException('Member lookup access denied');if(x.code==='22023')throw new BadRequestException('Invalid member lookup');throw new ServiceUnavailableException('Member lookup unavailable');}
  let previous=typeof cursor==='string'?cursor.toLowerCase():null;
  if(rows.length>limit+1)throw new ServiceUnavailableException('Member lookup unavailable');
  for(const r of rows){if(!uuid(r.id)||!same(r.tenant_id,t)||!same(r.branch_id,b)||typeof r.member_number!=='string'||r.member_number.trim().length<1||r.member_number.length>32||typeof r.full_name!=='string'||r.full_name.trim().length<2||[...r.full_name].length>150||!['pending','active','inactive','blacklisted'].includes(r.status)||(previous!==null&&r.id.toLowerCase()<=previous))throw new ServiceUnavailableException('Member lookup unavailable');previous=r.id.toLowerCase();}
  const items=rows.slice(0,limit).map(r=>({id:r.id,memberNumber:r.member_number,fullName:r.full_name,status:r.status}));
  return {items,nextCursor:rows.length>limit?items[items.length-1]!.id:null};
 }
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
