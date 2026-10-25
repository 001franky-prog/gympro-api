import {describe,it,expect} from 'vitest';import {createHash,randomBytes} from 'node:crypto';
import {isolatedRecoveryEnabled,exactRecoveryBody,recoveryDigest} from './recovery-lab.service.js';
const enabled={NODE_ENV:'production',AUTH_DATABASE_URL:'postgresql://gympro_auth@127.0.0.1:55432/gympro_saas',GYMPRO_ACCOUNT_RECOVERY_MODE:'isolated-inbox',GYMPRO_RECOVERY_INBOX_PASSWORD:'separate-test-inbox-password'};
describe('Recovery rehearsal boundary',()=>{
 it('allows only explicit isolated configuration',()=>expect(isolatedRecoveryEnabled(enabled)).toBe(true));
 it.each([
  {GYMPRO_ACCOUNT_RECOVERY_MODE:undefined},
  {AUTH_DATABASE_URL:'postgresql://gympro_auth@127.0.0.1:5432/gympro_saas'},
  {AUTH_DATABASE_URL:'postgresql://gympro_auth@remote.invalid:55432/gympro_saas'},
  {AUTH_DATABASE_URL:'postgresql://postgres@127.0.0.1:55432/gympro_saas'},
  {GYMPRO_RECOVERY_INBOX_PASSWORD:'short'},
  {NODE_ENV:'development'}
 ])('rejects unsuitable configuration %j',overrides=>expect(isolatedRecoveryEnabled({...enabled,...overrides})).toBe(false));
 it('rejects client-supplied account identity',()=>expect(()=>exactRecoveryBody({email:'a@example.invalid',userId:'spoof'},['email'])).toThrow());
 it('rejects noncanonical tokens',()=>{for(const raw of ['',null,'bad','A'.repeat(42)+'B'])expect(()=>recoveryDigest(raw)).toThrow();});
 it('hashes the canonical raw token without retaining it',()=>{const raw=randomBytes(32).toString('base64url');expect(recoveryDigest(raw)).toEqual(createHash('sha256').update(raw).digest());});
 it('does not mutate the expected field list',()=>{const keys=['token','newPassword','confirmPassword'];exactRecoveryBody({token:'x',newPassword:'y',confirmPassword:'y'},keys);expect(keys).toEqual(['token','newPassword','confirmPassword']);});
});
