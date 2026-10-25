import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { isSessionPersistenceEnabled, SESSION_SECURITY_POLICY } from './session-security-policy.js';
import { ProductionAuthPolicyService } from './production-auth-policy.service.js';
describe('Production authentication mode',()=>{
 beforeEach(()=>{vi.stubEnv('NODE_ENV','production');vi.stubEnv('GYMPRO_SESSION_MODE','');vi.stubEnv('GYMPRO_DEV_SESSION_WRITES','');vi.stubEnv('GYMPRO_DEV_SESSION_CONFIRM','');});
 afterEach(()=>vi.unstubAllEnvs());
 it('requires explicit mode',()=>expect(isSessionPersistenceEnabled()).toBe(false));
 it('rejects unknown mode',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','enabled');expect(isSessionPersistenceEnabled()).toBe(false);});
 it('accepts persistent mode',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');expect(isSessionPersistenceEnabled()).toBe(true);});
 it('rejects development write override',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');vi.stubEnv('GYMPRO_DEV_SESSION_WRITES','enabled');expect(isSessionPersistenceEnabled()).toBe(false);});
 it('rejects development confirmation override',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');vi.stubEnv('GYMPRO_DEV_SESSION_CONFIRM','I_UNDERSTAND_THE_RISK');expect(isSessionPersistenceEnabled()).toBe(false);});
 it('does not enable test writes',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');vi.stubEnv('NODE_ENV','test');expect(isSessionPersistenceEnabled()).toBe(false);});
 it('does not enable development writes using production mode',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');vi.stubEnv('NODE_ENV','development');expect(isSessionPersistenceEnabled()).toBe(false);});
 it('stops production initialization without approved mode',()=>expect(()=>new ProductionAuthPolicyService().onModuleInit()).toThrow('Production authentication requires'));
 it('permits approved production initialization',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');expect(()=>new ProductionAuthPolicyService().onModuleInit()).not.toThrow();});
 it('rejects mixed mode during initialization',()=>{vi.stubEnv('GYMPRO_SESSION_MODE','persistent');vi.stubEnv('GYMPRO_DEV_SESSION_WRITES','enabled');expect(()=>new ProductionAuthPolicyService().onModuleInit()).toThrow('Production authentication requires');});
 it('preserves disabled immutable baseline',()=>{expect(SESSION_SECURITY_POLICY.persistenceEnabled).toBe(false);expect(Object.isFrozen(SESSION_SECURITY_POLICY)).toBe(true);});
 it('keeps nonproduction initialization compatible',()=>{vi.stubEnv('NODE_ENV','test');expect(()=>new ProductionAuthPolicyService().onModuleInit()).not.toThrow();});
});
