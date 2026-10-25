import {describe,it,expect,beforeAll,afterAll} from 'vitest';
import {ConfigService} from '@nestjs/config';
import {AuthDatabaseService} from './auth-database.service.js';
const fixture=()=>{const raw=process.env.GYMPRO_AUTH_TEST_FIXTURE;if(!raw)throw Error('Run isolated fixture runner: GYMPRO_AUTH_TEST_FIXTURE missing');return JSON.parse(raw);};
describe('Auth database portable fixtures',()=>{
 let service:AuthDatabaseService;let f:ReturnType<typeof fixture>;
 beforeAll(async()=>{f=fixture();service=new AuthDatabaseService(new ConfigService());await service.onModuleInit();});
 afterAll(async()=>{if(service)await service.onModuleDestroy();});
 it('A01: finds exact active fixture identity and Argon2id hash',async()=>{const u=await service.findUserCredentials(f.ownerEmail);expect(u?.user_id).toBe(f.ownerId);expect(u?.account_status).toBe('active');expect(u?.password_hash).toMatch(/^\$argon2id\$/);});
 it('A02: finds pending fixture without password',async()=>{const u=await service.findUserCredentials(f.pendingEmail);expect(u?.user_id).toBe(f.pendingId);expect(u?.account_status).toBe('pending');expect(u?.password_hash).toBeNull();});
 it('A03: rejects unknown fixture email',async()=>{expect(await service.findUserCredentials(f.unknownEmail)).toBeNull();});
 it('A04: rejects empty email',async()=>{expect(await service.findUserCredentials('')).toBeNull();});
});
