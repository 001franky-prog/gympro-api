import {BadRequestException,Injectable,OnModuleDestroy,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import {ConfigService} from '@nestjs/config';import pg from 'pg';import {createHash,randomBytes,timingSafeEqual} from 'node:crypto';
import {PasswordService} from './password.service.js';
export function isolatedRecoveryEnabled(env:Record<string,string|undefined>=process.env):boolean{
 try{const url=new URL(env.AUTH_DATABASE_URL??'');const port=Number(url.port);return env.NODE_ENV==='production'&&env.GYMPRO_ACCOUNT_RECOVERY_MODE==='isolated-inbox'&&url.hostname==='127.0.0.1'&&port>=55432&&port<=55462&&url.pathname==='/gympro_saas'&&url.username==='gympro_auth'&&(env.GYMPRO_RECOVERY_INBOX_PASSWORD?.length??0)>=12&&(env.GYMPRO_RECOVERY_INBOX_PASSWORD?.length??0)<=200;}catch{return false;}
}
export function exactRecoveryBody(body:unknown,keys:string[]):Record<string,unknown>{if(!body||typeof body!=='object'||Array.isArray(body)||Object.keys(body).sort().join('|')!==[...keys].sort().join('|'))throw new BadRequestException('Invalid recovery request');return body as Record<string,unknown>;}
export function recoveryDigest(raw:unknown):Buffer{if(typeof raw!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(raw))throw new BadRequestException('Invalid or expired recovery link');const decoded=Buffer.from(raw,'base64url');if(decoded.length!==32||decoded.toString('base64url')!==raw)throw new BadRequestException('Invalid or expired recovery link');return createHash('sha256').update(raw,'utf8').digest();}
type Letter={id:string;recipient:string;purpose:string;token:string;expiresAt:string};
@Injectable()
export class RecoveryLabService implements OnModuleDestroy{
 private readonly pool:pg.Pool;private readonly letters:Letter[]=[];
 constructor(config:ConfigService,private readonly passwords:PasswordService){this.pool=new pg.Pool({connectionString:config.get<string>('AUTH_DATABASE_URL'),max:3,connectionTimeoutMillis:5000,idleTimeoutMillis:30000});this.pool.on('error',()=>console.error('Recovery lab pool error'));}
 assertEnabled(){if(!isolatedRecoveryEnabled())throw new ServiceUnavailableException('Account recovery is not enabled');}
 private async query(sql:string,args:unknown[]){try{return await this.pool.query(sql,args);}catch(e){const code=(e as {code?:string}).code;if(code==='28000'||code==='22023')throw new BadRequestException('Invalid or expired recovery link');console.error('Recovery lab database error',code??'unknown');throw new ServiceUnavailableException('Account recovery unavailable');}}
 async issue(purpose:'verify_email'|'reset_password',body:unknown,session?:Buffer){this.assertEnabled();let email:string|null=null;
  if(purpose==='verify_email')exactRecoveryBody(body,[]);else{const b=exactRecoveryBody(body,['email']);if(typeof b.email!=='string'||b.email.length>255||!/^\S+@\S+\.\S+$/.test(b.email.trim()))throw new BadRequestException('Enter a valid email');email=b.email.trim().toLowerCase();}
  const raw=randomBytes(32).toString('base64url');const result=await this.query('SELECT security.account_recovery_issue($1::text,$2::bytea,$3::bytea,$4::text) letter',[purpose,recoveryDigest(raw),session??null,email]);const letter=result.rows[0]?.letter;
  if(letter){if(this.letters.length>=1000)this.letters.shift();this.letters.push({id:randomBytes(12).toString('hex'),recipient:letter.recipient,purpose,token:raw,expiresAt:letter.expiresAt});}
  return {accepted:true,message:'If the account is eligible, a message has been sent to its inbox.'};
 }
 inbox(key:unknown){this.assertEnabled();const expected=process.env.GYMPRO_RECOVERY_INBOX_PASSWORD??'';if(typeof key!=='string'||key.length>200||!timingSafeEqual(createHash('sha256').update(key).digest(),createHash('sha256').update(expected).digest()))throw new UnauthorizedException('Inbox access denied');return {demoOnly:true,delivery:'local-memory',items:this.letters.filter(x=>Date.parse(x.expiresAt)>Date.now()).map(x=>({...x}))};}
 async verify(body:unknown){this.assertEnabled();const b=exactRecoveryBody(body,['token']);const r=await this.query('SELECT security.account_recovery_consume($1::text,$2::bytea,NULL::text) receipt',['verify_email',recoveryDigest(b.token)]);if(r.rows[0]?.receipt?.verified!==true)throw new ServiceUnavailableException('Verification unavailable');return {verified:true};}
 async reset(body:unknown){this.assertEnabled();const b=exactRecoveryBody(body,['token','newPassword','confirmPassword']);const digest=recoveryDigest(b.token);
  if(typeof b.newPassword!=='string'||Array.from(b.newPassword).length<12||b.newPassword.length>256||!b.newPassword.trim()||b.newPassword!==b.confirmPassword)throw new BadRequestException('Provide matching new passwords of 12 to 256 characters');
  const v=await this.query('SELECT security.account_recovery_validate_reset($1::bytea) valid',[digest]);if(v.rows[0]?.valid!==true)throw new BadRequestException('Invalid or expired recovery link');
  const hash=await this.passwords.hashPassword(b.newPassword);const r=await this.query('SELECT security.account_recovery_consume($1::text,$2::bytea,$3::text) receipt',['reset_password',digest,hash]);const receipt=r.rows[0]?.receipt;
  if(receipt?.changed!==true||receipt?.signedOut!==true||!Number.isInteger(receipt.revokedCount))throw new ServiceUnavailableException('Reset unavailable');return {changed:true,signedOut:true,revokedCount:receipt.revokedCount};
 }
 async onModuleDestroy(){this.letters.length=0;await this.pool.end();}
}
