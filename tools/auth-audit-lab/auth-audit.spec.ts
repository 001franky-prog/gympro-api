import {describe,it,expect} from 'vitest';import {auditQuery} from './auth-audit.service.js';
describe('Authentication audit query boundary',()=>{
 it('defaults to 25',()=>expect(auditQuery({})).toEqual({limit:25,before:null}));
 it('accepts bounded page and UUID',()=>expect(auditQuery({limit:'50',before:'11111111-1111-4111-8111-111111111111'}).limit).toBe(50));
 for(const value of ['0','51','-1','1.5','01','NaN'])it('rejects limit '+value,()=>expect(()=>auditQuery({limit:value})).toThrow());
 it('rejects array query',()=>expect(()=>auditQuery({limit:['25']})).toThrow());
 it('rejects spoofed identity',()=>expect(()=>auditQuery({userId:'victim'})).toThrow());
 it('rejects malformed cursor',()=>expect(()=>auditQuery({before:'not-a-uuid'})).toThrow());
});
