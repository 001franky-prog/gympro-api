import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BadRequestException, ForbiddenException } from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import type { SessionBearerTokenService } from '../auth/session-bearer-token.service.js';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
const db=vi.hoisted(()=>({query:vi.fn(),end:vi.fn(),on:vi.fn()}));
vi.mock('pg',()=>{class Pool {query=db.query;end=db.end;on=db.on;} return {Pool,default:{Pool}};});
import { SubscriptionExpirationService } from './subscription-expiration.service.js';
import { MemberBlacklistService } from './member-blacklist.service.js';
import { FocMembershipService } from './foc-membership.service.js';
import { MembershipDiscountService } from './membership-discount.service.js';
import { MembershipPromotionService } from './membership-promotion.service.js';
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const branch='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const timestamp=new Date('2026-10-15T00:00:00Z');
const req={headers:{authorization:'Bearer test'},gymproSession:{sessionId:id,tenantId:id,membershipId:id,userId:id}} as GymProAuthenticatedRequest;
const config={get:()=> 'postgresql://test-only'} as unknown as ConfigService;
const bearer={hashAuthorization:()=>Buffer.alloc(32)} as unknown as SessionBearerTokenService;
const identity={database_name:'gympro_saas',database_user:'gympro_app',is_superuser:false,bypasses_rls:false,
 schema_usage:true,security_schema_usage:true,can_execute:true,can_create:true,can_set_status:true,can_activate:true,can_renew:true,
 can_select:false,can_insert:false,can_update:false,can_delete:false,
 history_select:false,history_insert:false,history_update:false,history_delete:false,
 subscription_select:false,subscription_insert:false,subscription_update:false,subscription_delete:false,
 member_select:false,member_insert:false,member_update:false,member_delete:false,
 can_call_calculator:false,direct_promotion_access:false,direct_purchase_access:false};
describe('Remaining B8 branch service boundaries',()=>{
 beforeEach(()=>{vi.clearAllMocks();db.query.mockReset();db.end.mockResolvedValue(undefined);});
 async function ready<T extends {onModuleInit():Promise<void>}>(service:T){db.query.mockResolvedValueOnce({rows:[identity]});await service.onModuleInit();return service;}
 it('expiration binds the route branch and returns the public receipt',async()=>{
  const s=await ready(new SubscriptionExpirationService(config,bearer));
  db.query.mockResolvedValueOnce({rows:[{id,tenant_id:id,subscription_id:id,coverage_starts_on:'2026-09-15',coverage_ends_on:'2026-10-15',processed_on:'2026-10-15',expired_at:timestamp,created_at:timestamp}]});
  await s.expire(req,id,id,{},branch);
  expect(db.query.mock.calls.at(-1)![0]).toContain('expire_branch_member_subscription');
  expect(db.query.mock.calls.at(-1)![1]).toEqual([Buffer.alloc(32),id,branch,id]);
 });
 it('blacklist binds branch before the member and action parameters',async()=>{
  const s=await ready(new MemberBlacklistService(config,bearer));
  db.query.mockResolvedValueOnce({rows:[{id,tenant_id:id,member_id:id,request_id:id,event_type:'blacklist',reason:'Test reason',previous_status:'active',resulting_status:'blacklisted',recorded_at:timestamp,created_at:timestamp}]});
  await s.change(req,id,id,'blacklist',{reason:'Test reason',requestId:id},branch);
  expect(db.query.mock.calls.at(-1)![0]).toContain('change_branch_member_blacklist');
  expect(db.query.mock.calls.at(-1)![1]).toEqual([Buffer.alloc(32),id,branch,id,'blacklist','Test reason',id]);
 });
 it('FOC binds branch and retains dedicated function use',async()=>{
  const s=await ready(new FocMembershipService(config,bearer));
  db.query.mockResolvedValueOnce({rows:[{id,tenant_id:id,subscription_id:id,request_id:id,reason:'Test reason',listed_price_amount:'50000.00',currency_code:'MMK',granted_at:timestamp,created_at:timestamp}]});
  await s.grant(req,id,id,{planId:id,planPriceId:id,reason:'Test reason',requestId:id},branch);
  expect(db.query.mock.calls.at(-1)![0]).toContain('grant_branch_foc_membership');
  expect(db.query.mock.calls.at(-1)![1]).toEqual([Buffer.alloc(32),id,branch,id,id,id,'Test reason',id]);
 });
 it.each(['activation','renewal'] as const)('discounted %s binds the route branch',async(kind)=>{
  const s=await ready(new MembershipDiscountService(config,bearer));
  db.query.mockResolvedValueOnce({rows:[{id,tenant_id:id,subscription_id:id,promotion_id:id,request_id:id,purchase_kind:kind,renewal_id:kind==='renewal'?id:null,listed_price_amount:'50000.00',discount_amount:'5000.00',agreed_price_amount:'45000.00',currency_code:'MMK',applied_at:timestamp,created_at:timestamp}]});
  if(kind==='activation')await s.activate(req,id,id,{planId:id,planPriceId:id,promotionId:id,requestId:id},branch);
  else await s.renew(req,id,id,{planPriceId:id,promotionId:id,requestId:id},branch);
  expect(db.query.mock.calls.at(-1)![0]).toContain(kind==='activation'?'activate_branch_discounted_membership':'renew_branch_discounted_membership');
  expect(db.query.mock.calls.at(-1)![1][2]).toBe(branch);
 });
 const promo={id,tenant_id:id,promotion_code:'TEST',promotion_name:'Test promotion',description:null,plan_id:null,branch_id:branch,discount_kind:'percentage',discount_value:'10.00',currency_code:'MMK',starts_on:'2026-10-15',ends_on:null,status:'draft',created_at:timestamp,updated_at:timestamp};
 it('promotion creation derives branch only from the route',async()=>{
  const s=await ready(new MembershipPromotionService(config,bearer));db.query.mockResolvedValueOnce({rows:[promo]});
  await s.create(req,id,{promotionCode:'TEST',promotionName:'Test promotion',discountKind:'percentage',discountValue:'10',startsOn:'2026-10-15'},branch);
  expect(db.query.mock.calls.at(-1)![1][6]).toBe(branch);
 });
 it('promotion creation rejects a body branch on a branch route',async()=>{
  const s=await ready(new MembershipPromotionService(config,bearer));
  await expect(s.create(req,id,{promotionCode:'TEST',promotionName:'Test promotion',discountKind:'percentage',discountValue:'10',startsOn:'2026-10-15',branchId:id},branch)).rejects.toBeInstanceOf(BadRequestException);
 });
 it('promotion status calls the branch-bound function',async()=>{
  const s=await ready(new MembershipPromotionService(config,bearer));db.query.mockResolvedValueOnce({rows:[{...promo,status:'active'}]});
  await s.setStatus(req,id,id,'active',{},branch);expect(db.query.mock.calls.at(-1)![0]).toContain('set_branch_membership_promotion_status');
 });
 it('database branch denial maps to Forbidden',async()=>{
  const s=await ready(new MembershipDiscountService(config,bearer));db.query.mockRejectedValueOnce({code:'42501',message:'Branch access denied'});
  await expect(s.renew(req,id,id,{planPriceId:id,promotionId:id,requestId:id},branch)).rejects.toBeInstanceOf(ForbiddenException);
 });
});
