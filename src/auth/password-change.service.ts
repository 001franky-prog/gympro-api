import {BadRequestException,Injectable,UnauthorizedException} from '@nestjs/common';
import {PasswordService} from './password.service.js';
import {PasswordCredentialDatabaseService} from './password-credential-database.service.js';
@Injectable()
export class PasswordChangeService {
 constructor(private readonly database:PasswordCredentialDatabaseService,private readonly passwords:PasswordService){}
 async change(hash:Buffer,body:unknown){
  if(!Buffer.isBuffer(hash)||hash.length!==32)throw new UnauthorizedException('Invalid or expired session');
  const bad=()=>new BadRequestException('Provide current password and matching new passwords of 12 to 256 characters');
  if(!body||typeof body!=='object'||Array.isArray(body))throw bad();const v=body as Record<string,unknown>;
  if(Object.keys(v).length!==3||typeof v.currentPassword!=='string'||!v.currentPassword||v.currentPassword.length>1024||typeof v.newPassword!=='string'||typeof v.confirmPassword!=='string'||Array.from(v.newPassword).length<12||v.newPassword.length>256||!v.newPassword.trim()||v.newPassword!==v.confirmPassword)throw bad();
  const old=await this.database.read(hash);
  if(!await this.passwords.verifyPassword(old,v.currentPassword))throw new UnauthorizedException('Current password is incorrect');
  if(await this.passwords.verifyPassword(old,v.newPassword))throw new BadRequestException('Choose a different new password');
  const next=await this.passwords.hashPassword(v.newPassword);
  return this.database.change(hash,old,next);
 }
}
