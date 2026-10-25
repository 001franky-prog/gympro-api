import { describe, it, expect, vi } from 'vitest';
import type { ExecutionContext } from '@nestjs/common';
import { LoginAttemptLimiter } from './login-attempt-limiter.js';
import { LoginRateLimitGuard } from './login-rate-limit.guard.js';
const input={tenantId:'tenant-a',email:'staff@example.invalid',password:'not-recorded'};
describe('Login request admission control',()=>{
 it('admits five identity attempts then returns cooldown',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)expect(l.consume('a',input,0)).toBe(0);expect(l.consume('a',input,0)).toBe(60);});
 it('normalizes email and tenant casing',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)l.consume('a',input,0);expect(l.consume('a',{...input,email:' STAFF@EXAMPLE.INVALID ',tenantId:'TENANT-A'},0)).toBe(60);});
 it('admits a different peer independently',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)l.consume('a',input,0);expect(l.consume('b',input,0)).toBe(0);});
 it('bounds identity rotation by peer',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<15;i++)expect(l.consume('a',{...input,email:`u${i}@example.invalid`},0)).toBe(0);expect(l.consume('a',{...input,email:'new@example.invalid'},0)).toBe(60);});
 it('bounds malformed requests',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<15;i++)l.consume('a',null,0);expect(l.consume('a',[],0)).toBe(60);});
 it('does not extend cooldown on rejected requests',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)l.consume('a',input,0);expect(l.consume('a',input,59000)).toBe(1);expect(l.consume('a',input,60000)).toBe(0);});
 it('normalizes mapped IPv4 socket peers',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)l.consume('::ffff:127.0.0.1',input,0);expect(l.consume('127.0.0.1',input,0)).toBe(60);});
 it('fails closed when bounded storage is full',()=>{const l=new LoginAttemptLimiter(60000,2);expect(l.consume('a',input,0)).toBe(0);expect(l.consume('b',input,0)).toBe(60);expect(l.consume('b',input,60000)).toBe(0);});
 it('password changes do not bypass identity budget',()=>{const l=new LoginAttemptLimiter();for(let i=0;i<5;i++)l.consume('a',input,0);expect(l.consume('a',{...input,password:'changed'},0)).toBe(60);});
 it('guard ignores spoofed forwarding headers and emits 429/Retry-After',()=>{
  const guard=new LoginRateLimitGuard();const setHeader=vi.fn();let forwarded='1.1.1.1';
  const context={switchToHttp:()=>({getRequest:()=>({socket:{remoteAddress:'127.0.0.1'},body:input,headers:{'x-forwarded-for':forwarded}}),getResponse:()=>({setHeader})})} as unknown as ExecutionContext;
  for(let i=0;i<5;i++)expect(guard.canActivate(context)).toBe(true);
  forwarded='9.9.9.9';try{guard.canActivate(context);throw Error('expected rejection');}catch(error){expect((error as {getStatus():number}).getStatus()).toBe(429);}
  expect(setHeader).toHaveBeenCalledWith('Retry-After',expect.stringMatching(/^\d+$/));
 });
});
