import {beforeEach,describe,it,expect,vi} from 'vitest';
import {BadRequestException,ForbiddenException,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import type {ConfigService} from '@nestjs/config';
import type {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
const db=vi.hoisted(()=>({query:vi.fn(),end:vi.fn(),on:vi.fn()}));
vi.mock('pg',()=>{class Pool{query=db.query;end=db.end;on=db.on;}return {Pool,default:{Pool}};});
import {AttendanceReadService} from './attendance-read.service.js';
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',branch='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const req={headers:{authorization:'Bearer test'},gymproSession:{sessionId:id,tenantId:id,membershipId:id,userId:id}} as GymProAuthenticatedRequest;
const config={get:()=> 'postgresql://test-only'} as unknown as ConfigService;
const bearer={hashAuthorization:()=>Buffer.alloc(32)} as unknown as SessionBearerTokenService;
const row={id,tenant_id:id,branch_id:branch,member_id:id,member_number:'GP-0001',full_name:'Test Member',subscription_id:id,checked_in_at:new Date('2026-10-15T00:00:00.123Z'),business_date:'2026-10-15',checked_out_at:null,cursor_at:'2026-10-15T00:00:00.123456Z',actor_snapshot:{private:true}};
describe('Attendance reading boundaries',()=>{
 beforeEach(()=>{vi.clearAllMocks();db.query.mockReset();db.end.mockResolvedValue(undefined);});
 async function ready(){const s=new AttendanceReadService(config,bearer);db.query.mockResolvedValueOnce({rows:[{safe:true}]});await s.onModuleInit();return s;}
 it('binds verified session, branch and defaults; returns public fields',async()=>{
  const s=await ready();db.query.mockResolvedValueOnce({rows:[row]});const r=await s.list(req,id,branch,{});expect(db.query.mock.calls.at(-1)![1]).toEqual([Buffer.alloc(32),id,branch,false,null,null,50,null,null]);expect(r.items[0]).not.toHaveProperty('actor_snapshot');expect(r.items[0]).not.toHaveProperty('cursor_at');expect(r.nextCursor).toBeNull();
 });
 it('uses exact microseconds and UUID as the pagination cursor',async()=>{
  const s=await ready();db.query.mockResolvedValueOnce({rows:[{...row,id:branch},row]});const first=await s.list(req,id,branch,{limit:'1'});expect(first.items).toHaveLength(1);expect(first.nextCursor).toBeTruthy();
  db.query.mockResolvedValueOnce({rows:[row]});const last=await s.list(req,id,branch,{limit:'1',cursor:first.nextCursor});expect(db.query.mock.calls.at(-1)![1].slice(-2)).toEqual([row.cursor_at,branch]);expect(last.nextCursor).toBeNull();
 });
 it('binds explicit date interval',async()=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[]});await s.list(req,id,branch,{from:'2026-10-01',to:'2026-11-01',limit:'100'});expect(db.query.mock.calls.at(-1)![1].slice(3,7)).toEqual([false,'2026-10-01','2026-11-01',100]);});
 it('uses occupancy mode without dates',async()=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[row]});await s.list(req,id,branch,{},true);expect(db.query.mock.calls.at(-1)![1][3]).toBe(true);});
 it.each([null,[],{limit:'0'},{limit:'101'},{limit:10},{limit:['1','2']},{from:'2026-02-30',to:'2026-03-01'},{from:'2026-01-01'},{from:'2026-02-01',to:'2026-01-01'},{from:'2026-01-01',to:'2027-01-01'},{tenantId:id},{cursor:'bad'},{cursor:Buffer.from('{}').toString('base64url')}])('rejects invalid query %j',async(q)=>{const s=await ready();await expect(s.list(req,id,branch,q)).rejects.toBeInstanceOf(BadRequestException);expect(db.query).toHaveBeenCalledTimes(1);});
 it('rejects dates for occupancy',async()=>{const s=await ready();await expect(s.list(req,id,branch,{from:'2026-10-01',to:'2026-10-02'},true)).rejects.toBeInstanceOf(BadRequestException);});
 it('rejects missing session',async()=>{const s=await ready();await expect(s.list({}as GymProAuthenticatedRequest,id,branch,{})).rejects.toBeInstanceOf(UnauthorizedException);});
 it('rejects route tenant mismatch',async()=>{const s=await ready();await expect(s.list(req,branch,branch,{})).rejects.toBeInstanceOf(ForbiddenException);});
 it('rejects before startup',async()=>{const s=new AttendanceReadService(config,bearer);await expect(s.list(req,id,branch,{})).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('rejects unsafe startup',async()=>{const s=new AttendanceReadService(config,bearer);db.query.mockResolvedValueOnce({rows:[{safe:false}]});await expect(s.onModuleInit()).rejects.toThrow();});
 it.each([{code:'28000',message:'Invalid or expired session',type:UnauthorizedException},{code:'42501',message:'Attendance access denied',type:ForbiddenException},{code:'22023',message:'private',type:BadRequestException},{code:'08006',message:'private',type:ServiceUnavailableException}])('maps database failure $code safely',async(e)=>{const s=await ready();db.query.mockRejectedValueOnce(e);await expect(s.list(req,id,branch,{})).rejects.toBeInstanceOf(e.type);});
 it.each([{...row,tenant_id:branch},{...row,branch_id:id},{...row,business_date:'2026-02-30'},{...row,cursor_at:'invalid'},{...row,checked_in_at:new Date('invalid')}])('rejects invalid or mismatched result',async(r)=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[r]});await expect(s.list(req,id,branch,{})).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('rejects duplicate rows',async()=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[row,row]});await expect(s.list(req,id,branch,{})).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('rejects closed visit in occupancy results',async()=>{const s=await ready();db.query.mockResolvedValueOnce({rows:[{...row,checked_out_at:new Date('2026-10-15T01:00:00Z')}]});await expect(s.list(req,id,branch,{},true)).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('closes pool and blocks reading after shutdown',async()=>{const s=await ready();await s.onModuleDestroy();expect(db.end).toHaveBeenCalledOnce();await expect(s.list(req,id,branch,{})).rejects.toBeInstanceOf(ServiceUnavailableException);});
});
