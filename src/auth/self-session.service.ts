import { Injectable, OnModuleDestroy, OnModuleInit, ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import pg from 'pg';
@Injectable()
export class SelfSessionService implements OnModuleInit, OnModuleDestroy {
 private readonly pool:pg.Pool;
 constructor(config:ConfigService){
  const url=config.get<string>('AUTH_DATABASE_URL');if(!url)throw Error('AUTH_DATABASE_URL is not configured');
  this.pool=new pg.Pool({connectionString:url,max:3,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});
  this.pool.on('error',()=>console.error('Session management database pool error'));
 }
 async onModuleInit():Promise<void>{
  const r=await this.pool.query('SELECT current_database() db,current_user role');
  if(r.rows.length!==1||r.rows[0].db!=='gympro_saas'||r.rows[0].role!=='gympro_auth')throw Error('Session management database identity verification failed');
 }
 async manage(hash:Buffer,action:'list'|'revoke'|'revoke_others',target:string|null=null):Promise<Record<string,unknown>>{
  if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  try{
   const r=await this.pool.query('SELECT security.manage_own_sessions($1::bytea,$2::text,$3::uuid) result',[hash,action,target]);
   const value=r.rows[0]?.result;
   if(r.rows.length!==1||!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid session response');
   // Reconstruct public fields; tokens/hashes/identity internals never pass through.
   if(action==='list'){
    if(!Array.isArray(value.items)||value.items.length>100)throw Error('Invalid session list');
    const items=value.items.map((s:Record<string,unknown>)=>{
     if(typeof s.sessionId!=='string'||typeof s.createdAt!=='string'||!Number.isFinite(Date.parse(s.createdAt))||typeof s.expiresAt!=='string'||!Number.isFinite(Date.parse(s.expiresAt))||typeof s.current!=='boolean')throw Error('Invalid session item');
     return {sessionId:s.sessionId,createdAt:s.createdAt,expiresAt:s.expiresAt,current:s.current};
    });return {items,limit:100,scope:'current_tenant_membership'};
   }
   if(!Number.isInteger(value.revokedCount)||value.revokedCount<0||typeof value.currentRevoked!=='boolean')throw Error('Invalid revocation response');
   return {revokedCount:value.revokedCount,currentRevoked:value.currentRevoked};
  }catch(error){if((error as {code?:string}).code==='28000')throw new UnauthorizedException('Invalid or expired session');throw new ServiceUnavailableException('Session management unavailable');}
 }
 async onModuleDestroy():Promise<void>{await this.pool.end();}
}
