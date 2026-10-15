import 'reflect-metadata';
import {beforeEach,describe,expect,it,vi} from 'vitest';
import {BadRequestException,ForbiddenException,ServiceUnavailableException,UnauthorizedException} from '@nestjs/common';
import {GUARDS_METADATA} from '@nestjs/common/constants';
import type {ConfigService} from '@nestjs/config';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import type {SessionBearerTokenService} from '../auth/session-bearer-token.service.js';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
const mocks=vi.hoisted(()=>({query:vi.fn(),end:vi.fn(),on:vi.fn()}));
vi.mock('pg',()=>({default:{Pool:class{query=mocks.query;end=mocks.end;on=mocks.on;}}}));
import {InventoryHistoryService} from './inventory-history.service.js';
import {InventoryHistoryController} from './inventory-history.controller.js';
import {historyInput,stockHistoryPage} from './inventory-history-validation.js';
const t='11111111-1111-4111-8111-111111111111',b='22222222-2222-4222-8222-222222222222',p='33333333-3333-4333-8333-333333333333',requestId='44444444-4444-4444-8444-444444444444',other='55555555-5555-4555-8555-555555555555';



const row={id:other,tenantId:t,branchId:b,productId:p,createdAt:'2026-10-15T12:00:00Z',kind:'adjustment',quantityDelta:10,balanceAfter:'10',reason:'Opening stock',actorMembershipId:p,actorName:'Inventory manager',sku:'WATER',productName:'Drinking water',saleId:null,returnId:null};
const query={from:'2026-10-15',through:'2026-10-15'},result={tenantId:t,branchId:b,productId:p,...query,items:[row],nextCursor:null};
const req={headers:{authorization:'Bearer test'},gymproSession:{sessionId:other,tenantId:t,membershipId:other,userId:other}} as unknown as GymProAuthenticatedRequest;
let service:InventoryHistoryService;let hash:ReturnType<typeof vi.fn>;
describe('Inventory stock history',()=>{
 beforeEach(async()=>{vi.clearAllMocks();hash=vi.fn(()=>Buffer.alloc(32));service=new InventoryHistoryService({get:()=> 'postgresql://gympro_app@localhost/gympro_saas'} as unknown as ConfigService,{hashAuthorization:hash} as unknown as SessionBearerTokenService);mocks.query.mockResolvedValue({rows:[{safe:true}]});await service.onModuleInit();mocks.query.mockReset();});
 const list=()=>service.list(req,t,b,p,query);
 it('validates scope and strips private snapshots',async()=>{mocks.query.mockResolvedValue({rows:[{receipt:{...result,items:[{...row,actorSnapshot:{sessionId:'private'},productSnapshot:{private:true}}]}}]});const out=await list();expect(out.items[0]!.actorName).toBe('Inventory manager');expect(out.items[0]).not.toHaveProperty('actorSnapshot');expect(out.items[0]).not.toHaveProperty('productSnapshot');expect(mocks.query.mock.calls[0]![1]).toEqual([Buffer.alloc(32),t,b,p,query.from,query.through,null,25]);});
 it('uses the server default last 30 days',async()=>{mocks.query.mockResolvedValue({rows:[{receipt:{...result,from:'2026-09-16'}}]});await service.list(req,t,b,p,{});expect(mocks.query.mock.calls[0]![1]).toEqual([Buffer.alloc(32),t,b,p,null,null,null,25]);});
 for(const q of [null,[],{status:'active'},{tenantId:t},{productId:p},{from:'2026-10-15'},{through:'2026-10-15'},{from:'2026-02-30',through:'2026-03-01'},{from:'2026-10-15',through:'2026-10-14'},{from:'2025-01-01',through:'2026-01-02'},{from:['2026-10-15'],through:'2026-10-15'},{limit:'0'},{limit:'101'},{limit:25},{cursor:'bad'}])it(`rejects invalid query ${JSON.stringify(q)}`,async()=>{await expect(service.list(req,t,b,p,q)).rejects.toBeInstanceOf(BadRequestException);expect(mocks.query).not.toHaveBeenCalled();});
 it('rejects missing sessions',async()=>{await expect(service.list({headers:{}} as GymProAuthenticatedRequest,t,b,p,{})).rejects.toBeInstanceOf(UnauthorizedException);});
 it('rejects another tenant',async()=>{await expect(service.list(req,other,b,p,{})).rejects.toBeInstanceOf(ForbiddenException);});
 it('rejects malformed product IDs',async()=>{await expect(service.list(req,t,b,'bad',{})).rejects.toBeInstanceOf(BadRequestException);});
 it('rejects malformed token hashes',async()=>{hash.mockReturnValue(Buffer.alloc(31));await expect(list()).rejects.toBeInstanceOf(UnauthorizedException);});
 for(const [code,message,expected]of [['28000','Invalid session',UnauthorizedException],['42501','Permission denied',ForbiddenException],['22023','Private cursor',BadRequestException],['42501','permission denied for table users',ServiceUnavailableException],['ECONNREFUSED','Private credentials',ServiceUnavailableException]] as const)it(`maps ${code}/${message} safely`,async()=>{mocks.query.mockRejectedValue({code,message});await expect(list()).rejects.toBeInstanceOf(expected);await expect(list()).rejects.not.toThrow('Private');});
 for(const change of [{tenantId:other},{branchId:other},{productId:other},{id:'bad'},{quantityDelta:0},{quantityDelta:'10'},{quantityDelta:1.5},{balanceAfter:10},{balanceAfter:'-1'},{kind:'unknown'},{kind:'sale'},{kind:'refund'},{saleId:p},{returnId:p},{actorMembershipId:'bad'},{actorName:''},{reason:'  Opening stock '},{sku:' water '},{createdAt:'2026-02-30T00:00:00Z'},{createdAt:'2026-10-14T17:29:59Z'}])it(`rejects invalid movement ${JSON.stringify(change)}`,async()=>{mocks.query.mockResolvedValue({rows:[{receipt:{...result,items:[{...row,...change}]}}]});await expect(list()).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('accepts valid sale, refund and void references',()=>{for(const kind of ['sale','refund','void']){const x={...row,kind,quantityDelta:kind==='sale'?-2:2,saleId:p,returnId:kind==='sale'?null:p};expect(stockHistoryPage({...result,items:[x]},t,b,p,historyInput(query)).items[0]!.kind).toBe(kind);}});
 it('accepts a Yangon midnight boundary',()=>expect(stockHistoryPage({...result,items:[{...row,createdAt:'2026-10-14T17:30:00Z'}]},t,b,p,historyInput(query)).items).toHaveLength(1));
 it('preserves bigint balances as decimal text',()=>expect(stockHistoryPage({...result,items:[{...row,balanceAfter:'9223372036854775807'}]},t,b,p,historyInput(query)).items[0]!.balanceAfter).toBe('9223372036854775807'));
 it('rejects duplicate movements',()=>expect(()=>stockHistoryPage({...result,items:[row,row]},t,b,p,historyInput(query))).toThrow());
 it('requires next cursor to equal the last page row',()=>{expect(stockHistoryPage({...result,nextCursor:other},t,b,p,historyInput({...query,limit:'1'})).nextCursor).toBe(other);expect(()=>stockHistoryPage({...result,nextCursor:p},t,b,p,historyInput({...query,limit:'1'}))).toThrow();});
 it('rejects a repeated input cursor',()=>expect(()=>stockHistoryPage(result,t,b,p,historyInput({...query,cursor:other}))).toThrow());
 it('accepts empty history',()=>expect(stockHistoryPage({...result,items:[]},t,b,p,historyInput(query)).items).toEqual([]));
 it('rejects inconsistent default date windows',()=>expect(()=>stockHistoryPage(result,t,b,p,historyInput({}))).toThrow());
 it('rejects empty function results',async()=>{mocks.query.mockResolvedValue({rows:[]});await expect(list()).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('fails closed after unsafe startup',async()=>{mocks.query.mockResolvedValue({rows:[{safe:false}]});await expect(service.onModuleInit()).rejects.toThrow('restricted');await expect(list()).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('closes the pool and blocks reads after shutdown',async()=>{await service.onModuleDestroy();expect(mocks.end).toHaveBeenCalledOnce();await expect(list()).rejects.toBeInstanceOf(ServiceUnavailableException);});
 it('requires all authorization guards',()=>expect(Reflect.getMetadata(GUARDS_METADATA,InventoryHistoryController)).toEqual([AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard]));
 it('requires inventory read permission',()=>expect(Reflect.getMetadata('gympro.required_permission',InventoryHistoryController.prototype.list)).toBe('inventory.products.read'));
});
