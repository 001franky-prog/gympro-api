import {beforeEach,describe,it,expect,vi} from 'vitest';
import {BadRequestException,ForbiddenException,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {ConfigService} from '@nestjs/config';
import type {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const db=vi.hoisted(()=>({query:vi.fn(),end:vi.fn(),on:vi.fn()}));
vi.mock('pg',()=>{class Pool{query=db.query;end=db.end;on=db.on;}return {Pool,default:{Pool}};});
import {AttendanceCheckoutService} from './attendance-checkout.service.js';
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',branch='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const req={headers:{authorization:'Bearer test'},gymproSession:{sessionId:id,tenantId:id,membershipId:id,userId:id}} as GymProAuthenticatedRequest;
const config={get:()=> 'postgresql://test-only'} as unknown as ConfigService;
const bearer={hashAuthorization:()=>Buffer.alloc(32)} as unknown as SessionBearerTokenService;
const row={id,tenant_id:id,branch_id:branch,member_id:id,visit_id:id,request_id:id,checked_in_at:new Date('2026-10-15T00:00:00Z'),business_date:'2026-10-15',checked_out_at:new Date('2026-10-15T01:00:00Z'),actor_snapshot:{private:true}};
describe('Attendance check-out boundaries',()=>{
 beforeEach(()=>{vi.clearAllMocks();db.query.mockReset();db.end.mockResolvedValue(undefined);});
 async function ready(){const s=new AttendanceCheckoutService(config,bearer);db.query.mockResolvedValueOnce({rows:[{safe:true}]});await s.onModuleInit();return s;}
 it('binds verified token and route identifiers; returns public receipt only',async()=>{
  const s=await ready();db.query.mockResolvedValueOnce({rows:[row]});const receipt=await s.checkOut(req,id,branch,id,{requestId:id});
  expect(db.query.mock.calls.at(-1)![1]).toEqual([Buffer.alloc(32),id,branch,id,id]);expect(receipt).not.toHaveProperty('actor_snapshot');expect(receipt.branchId).toBe(branch);
 });
 it.each([{},null,[],{requestId:'bad'},{requestId:id,checkedOutAt:'2026-01-01'},{requestId:id,branchId:branch}])('rejects invalid or client-controlled body %j',async(body)=>{
  const s=await ready();await expect(s.checkOut(req,id,branch,id,body)).rejects.toBeInstanceOf(BadRequestException);expect(db.query).toHaveBeenCalledTimes(1);
 });
 it('rejects missing session',async()=>{const s=await ready();await expect(s.checkOut({} as GymProAuthenticatedRequest,id,branch,id,{requestId:id})).rejects.toBeInstanceOf(UnauthorizedException);});
 it('rejects route tenant mismatch',async()=>{const s=await ready();await expect(s.checkOut(req,branch,branch,id,{requestId:id})).rejects.toBeInstanceOf(ForbiddenException);});
 it('rejects before startup',async()=>{const s=new AttendanceCheckoutService(config,bearer);await expect(s.checkOut(req,id,branch,id,{requestId:id})).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('rejects unsafe startup',async()=>{const s=new AttendanceCheckoutService(config,bearer);db.query.mockResolvedValueOnce({rows:[{safe:false}]});await expect(s.onModuleInit()).rejects.toThrow();});
 it.each([{code:'28000',message:'Invalid or expired session',type:UnauthorizedException},{code:'42501',message:'Attendance access denied',type:ForbiddenException},{code:'22023',message:'private',type:BadRequestException},{code:'08006',message:'private',type:ServiceUnavailableException}])('maps database failure $code safely',async(e)=>{const s=await ready();db.query.mockRejectedValueOnce(e);await expect(s.checkOut(req,id,branch,id,{requestId:id})).rejects.toBeInstanceOf(e.type);});
 it.each([{...row,tenant_id:branch},{...row,branch_id:id},{...row,request_id:branch},{...row,checked_out_at:new Date('2026-10-14T00:00:00Z')},{...row,checked_in_at:new Date('invalid')}])('rejects invalid database receipt',async(r)=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[r]});await expect(s.checkOut(req,id,branch,id,{requestId:id})).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('closes pool and blocks work after shutdown',async()=>{const s=await ready();await s.onModuleDestroy();expect(db.end).toHaveBeenCalledOnce();await expect(s.checkOut(req,id,branch,id,{requestId:id})).rejects.toBeInstanceOf(ServiceUnavailableException);});
});
