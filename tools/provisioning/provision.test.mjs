import {test} from 'node:test';import assert from 'node:assert/strict';import {normalize,initialPermissions} from './provision.mjs';
const valid=()=>({requestId:'11111111-2222-4333-8444-555555555555',tenantCode:' demo_one ',tenantName:' Demo Gym ',tenantType:'independent',branchCode:' br001 ',branchName:' Main Branch ',email:' OWNER@EXAMPLE.INVALID ',fullName:' Demo Owner ',password:'SeparateDemoPassword!'});
test('normalizes public identifiers without changing password',()=>{const input=valid(),r=normalize(input);assert.equal(r.tenantCode,'DEMO_ONE');assert.equal(r.email,'owner@example.invalid');assert.equal(r.password,input.password);});
test('rejects extra client-controlled status',()=>assert.throws(()=>normalize({...valid(),status:'active'})));
test('rejects malformed request UUID',()=>assert.throws(()=>normalize({...valid(),requestId:'bad'})));
test('rejects invalid tenant type and unsafe codes',()=>{assert.throws(()=>normalize({...valid(),tenantType:'root'}));assert.throws(()=>normalize({...valid(),tenantCode:'bad;sql'}));});
test('rejects malformed email and blank name',()=>{assert.throws(()=>normalize({...valid(),email:'bad'}));assert.throws(()=>normalize({...valid(),fullName:' '}));});
test('rejects weak-length and oversized passwords',()=>{assert.throws(()=>normalize({...valid(),password:'short'}));assert.throws(()=>normalize({...valid(),password:'x'.repeat(257)}));});
test('initial permissions exclude financial, FOC and discount grants',()=>{assert.ok(initialPermissions.length>0);assert.ok(initialPermissions.every(x=>!x.startsWith('finance.')&&!x.includes('grant_foc')&&!x.includes('apply_discount')));});
