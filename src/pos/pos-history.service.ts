import {BadRequestException,ForbiddenException,Injectable,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {OnModuleInit,OnModuleDestroy} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';
import pg from 'pg';
import {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import * as v from '../inventory/inventory-validation.js';
import {historyInput,historyPage} from './pos-history-validation.js';
@Injectable()
export class PosHistoryService implements OnModuleInit,OnModuleDestroy {
 private readonly pool:pg.Pool;private ready=false;
 constructor(config:ConfigService,private readonly bearer:SessionBearerTokenService){const url=config.get<string>('DATABASE_URL');if(!url)throw Error('DATABASE_URL is required');this.pool=new pg.Pool({connectionString:url,max:5,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('POS database pool error'));}
 async onModuleInit(){this.ready=false;const q=await this.pool.query(`SELECT current_database()='gympro_saas' AND current_user='gympro_app' AND NOT rolsuper AND NOT rolbypassrls
 AND has_function_privilege(current_user,to_regprocedure('security.read_pos_sale_history(bytea,uuid,uuid,date,date,uuid,integer)'),'EXECUTE')
 AND NOT has_table_privilege(current_user,'app.pos_sale_returns','SELECT,INSERT,UPDATE,DELETE')
 AND NOT has_table_privilege(current_user,'app.pos_sale_return_items','SELECT,INSERT,UPDATE,DELETE')
 AND NOT has_table_privilege(current_user,'app.pos_sales','SELECT,INSERT,UPDATE,DELETE')
 AND NOT has_table_privilege(current_user,'app.pos_sale_items','SELECT,INSERT,UPDATE,DELETE')
 AND NOT has_table_privilege(current_user,'app.inventory_products','SELECT,INSERT,UPDATE,DELETE')
 AND NOT has_table_privilege(current_user,'app.inventory_stock_movements','SELECT,INSERT,UPDATE,DELETE')
 AND (SELECT count(*)=2 AND bool_and(relrowsecurity AND relforcerowsecurity) FROM pg_class WHERE oid IN ('app.pos_sale_returns'::regclass,'app.pos_sale_return_items'::regclass)) AS safe FROM pg_roles WHERE rolname=current_user`);if(q.rows.length!==1||q.rows[0]?.safe!==true)throw Error('POS requires restricted function-only database access');this.ready=true;}
 private authorize(req:GymProAuthenticatedRequest,tenant:string,branch:string,sale?:string){const s=req.gymproSession;if(!s||![s.sessionId,s.tenantId,s.membershipId,s.userId].every(v.isUuid))throw new UnauthorizedException('Invalid or expired session');if(!v.isUuid(tenant)||!v.isUuid(branch)||(sale!==undefined&&!v.isUuid(sale)))throw new BadRequestException('Invalid sale identifier');if(!v.sameUuid(s.tenantId,tenant))throw new ForbiddenException('Tenant access denied');if(!this.ready)throw new ServiceUnavailableException('Sales unavailable');const hash=this.bearer.hashAuthorization(req.headers?.authorization);if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');return hash;}
 private input<T>(fn:()=>T):T{try{return fn();}catch{throw new BadRequestException('Invalid sale request');}}
 private async query(sql:string,args:unknown[]){try{return (await this.pool.query(sql,args)).rows;}catch(e){const x=(e&&typeof e==='object'?e:{}) as {code?:string;message?:string};if(x.code==='28000'&&x.message==='Invalid session')throw new UnauthorizedException('Invalid or expired session');if(x.code==='42501'&&x.message==='Permission denied')throw new ForbiddenException('Sale access denied');if(x.code==='22023'||x.code==='23505')throw new BadRequestException('Invalid sale request');throw new ServiceUnavailableException('Sales unavailable');}}
 async list(req:GymProAuthenticatedRequest,t:string,b:string,query:unknown){const hash=this.authorize(req,t,b);const input=this.input(()=>historyInput(query));const rows=await this.query('SELECT security.read_pos_sale_history($1::bytea,$2::uuid,$3::uuid,$4::date,$5::date,$6::uuid,$7::integer) AS receipt',[hash,t,b,input.from,input.through,input.cursor,input.limit]);try{if(rows.length!==1)throw Error('Invalid result');return historyPage(rows[0]?.receipt,t,b,input);}catch{throw new ServiceUnavailableException('Sale history unavailable');}}
 async onModuleDestroy(){this.ready=false;await this.pool.end();}
}
