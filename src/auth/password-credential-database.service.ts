import {Injectable,OnModuleInit,OnModuleDestroy,UnauthorizedException,ServiceUnavailableException} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';import pg from 'pg';
@Injectable()
export class PasswordCredentialDatabaseService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;
 constructor(config:ConfigService){const url=config.get<string>('AUTH_DATABASE_URL');if(!url)throw Error('AUTH_DATABASE_URL is not configured');this.pool=new pg.Pool({connectionString:url,max:3,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Credential database pool error'));}
 async onModuleInit(){const r=await this.pool.query('SELECT current_user role,current_database() db');if(r.rows.length!==1||r.rows[0].role!=='gympro_auth'||r.rows[0].db!=='gympro_saas')throw Error('Credential database identity verification failed');}
 private async query(sql:string,args:unknown[]){try{return await this.pool.query(sql,args);}catch(e){const failure=e as {code?:string,message?:string};console.error('Password change database failure',failure.code??'unknown',typeof failure.message==='string'&&/^Password change validation: (hash length|hash format|unchanged hash)$/.test(failure.message)?failure.message:'details withheld');if((e as {code?:string}).code==='28000')throw new UnauthorizedException('Invalid credentials or expired session');throw new ServiceUnavailableException('Password change unavailable');}}
 async read(hash:Buffer):Promise<string>{const r=await this.query('SELECT security.read_own_credential($1::bytea) hash',[hash]);if(r.rows.length!==1||typeof r.rows[0]?.hash!=='string')throw new ServiceUnavailableException('Password change unavailable');return r.rows[0].hash;}
 async change(hash:Buffer,oldHash:string,newHash:string){const r=await this.query('SELECT security.change_own_password($1::bytea,$2::text,$3::text) result',[hash,oldHash,newHash]);const v=r.rows[0]?.result;if(r.rows.length!==1||v?.changed!==true||v?.signedOut!==true||!Number.isInteger(v.revokedCount)||v.revokedCount<1)throw new ServiceUnavailableException('Password change unavailable');return {changed:true,signedOut:true,revokedCount:v.revokedCount};}
 async onModuleDestroy(){await this.pool.end();}
}
