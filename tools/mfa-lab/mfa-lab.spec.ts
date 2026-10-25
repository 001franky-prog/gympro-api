import {describe,it,expect} from 'vitest';import {randomBytes} from 'node:crypto';import {base32,decode32,totp,matchingStep,encryptSecret,decryptSecret,backupDigest,newBackupCodes} from './mfa-crypto.js';import {mfaLabEnabled,mfaBody} from './mfa-lab.service.js';
const seed=base32(Buffer.from('12345678901234567890'));
describe('MFA cryptography and rehearsal boundary',()=>{
 it.each([[59,'94287082'],[1111111109,'07081804'],[1111111111,'14050471'],[1234567890,'89005924'],[2000000000,'69279037'],[20000000000,'65353130']] as const)('matches RFC 6238 SHA-1 vector at %i', (time,expected)=>expect(totp(seed,Math.floor(time/30),8)).toBe(expected));
 it('roundtrips canonical base32 secret',()=>{const b=randomBytes(20);expect(decode32(base32(b))).toEqual(b);expect(()=>decode32('invalid')).toThrow();});
 it('rejects malformed or out-of-window codes',()=>{expect(matchingStep(seed,'bad',59000)).toBeNull();expect(matchingStep(seed,'287082',59000)).toBe(1);expect(matchingStep(seed,'287082',300000)).toBeNull();});
 it('authenticates ciphertext with its user/version context',()=>{const key=randomBytes(32),cipher=encryptSecret(seed,key,'user:version');expect(decryptSecret(cipher,key,'user:version')).toBe(seed);expect(()=>decryptSecret(cipher,key,'different-user')).toThrow();expect(()=>decryptSecret(cipher,randomBytes(32),'user:version')).toThrow();});
 it('uses fresh encryption nonces',()=>{const key=randomBytes(32);expect(encryptSecret(seed,key,'a').iv).not.toBe(encryptSecret(seed,key,'a').iv);});
 it('generates ten distinct high-entropy backup codes and stable hashes',()=>{const codes=newBackupCodes();expect(new Set(codes).size).toBe(10);expect(backupDigest(codes[0])).toEqual(backupDigest(codes[0]!.replaceAll('-','').toUpperCase()));expect(backupDigest('bad')).toBeNull();});
 const env={NODE_ENV:'production',AUTH_DATABASE_URL:'postgresql://gympro_auth@127.0.0.1:55432/gympro_saas',DATABASE_URL:'postgresql://gympro_app@127.0.0.1:55432/gympro_saas',SESSION_DATABASE_URL:'postgresql://gympro_session@127.0.0.1:55432/gympro_saas',GYMPRO_MFA_MODE:'isolated-totp',GYMPRO_MFA_LAB_KEY:Buffer.alloc(32,7).toString('base64')};
 it('accepts only explicit same-cluster loopback rehearsal configuration',()=>expect(mfaLabEnabled(env)).toBe(true));
 it.each([{GYMPRO_MFA_MODE:undefined},{AUTH_DATABASE_URL:'postgresql://gympro_auth@127.0.0.1:5432/gympro_saas'},{GYMPRO_MFA_LAB_KEY:'bad'},{DATABASE_URL:'postgresql://gympro_app@remote.invalid:55432/gympro_saas'},{NODE_ENV:'test'}])('rejects unsuitable configuration %j',overrides=>expect(mfaLabEnabled({...env,...overrides})).toBe(false));
 it('rejects client-supplied counter or identity',()=>{expect(()=>mfaBody({code:'123456',step:42},['code'])).toThrow();expect(()=>mfaBody({code:'123456',userId:'spoof'},['code'])).toThrow();});
});
