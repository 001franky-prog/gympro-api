import {describe,it,expect,beforeAll,afterAll} from 'vitest';
import {ConfigService} from '@nestjs/config';
import {AuthDatabaseService} from './auth-database.service.js';
const fixture=()=>{const raw=process.env.GYMPRO_AUTH_TEST_FIXTURE;if(!raw)throw Error('Run isolated fixture runner: GYMPRO_AUTH_TEST_FIXTURE missing');return JSON.parse(raw);};
describe('Tenant membership portable fixtures',()=>{
 let service:AuthDatabaseService;let f:ReturnType<typeof fixture>;
 beforeAll(async()=>{f=fixture();service=new AuthDatabaseService(new ConfigService());await service.onModuleInit();});
 afterAll(async()=>{if(service)await service.onModuleDestroy();});
 it('M01: authorizes exact active membership',async()=>{expect(await service.verifyActiveTenantMembership(f.ownerId,f.tenantId)).toBe(f.membershipId);});
 it('M02: rejects pending user with invited membership',async()=>{expect(await service.verifyActiveTenantMembership(f.pendingId,f.otherTenantId)).toBeNull();});
 it('M03: rejects owner in unassigned tenant',async()=>{expect(await service.verifyActiveTenantMembership(f.ownerId,f.otherTenantId)).toBeNull();});
 it('M04: rejects invalid user UUID',async()=>{expect(await service.verifyActiveTenantMembership('not-a-uuid',f.tenantId)).toBeNull();});
 it('M05: rejects invalid tenant UUID',async()=>{expect(await service.verifyActiveTenantMembership(f.ownerId,'invalid-tenant')).toBeNull();});
});
