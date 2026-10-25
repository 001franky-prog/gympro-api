import {describe,it,expect,vi} from 'vitest';
import {SelfSessionController} from './self-session.controller.js';
import type {SelfSessionService} from './self-session.service.js';
import type {SessionBearerTokenService} from './session-bearer-token.service.js';
const request={headers:{authorization:'Bearer test-only'}};
const setup=()=>{const manage=vi.fn().mockResolvedValue({revokedCount:1,currentRevoked:false});const hash=Buffer.alloc(32,7);const hashAuthorization=vi.fn().mockReturnValue(hash);const controller=new SelfSessionController({manage} as unknown as SelfSessionService,{hashAuthorization} as unknown as SessionBearerTokenService);return {controller,manage,hash};};
describe('Self session controller',()=>{
 it('lists using server token hash',async()=>{const x=setup();await x.controller.list(request);expect(x.manage).toHaveBeenCalledWith(x.hash,'list');});
 it('revokes others without client identity',async()=>{const x=setup();await x.controller.others(request,{});expect(x.manage).toHaveBeenCalledWith(x.hash,'revoke_others');});
 it.each([null,[],{tenantId:'spoof'},{userId:'spoof'},{tokenHash:'spoof'}])('rejects nonempty or invalid command body %j',body=>{const x=setup();expect(()=>x.controller.others(request,body)).toThrow('Invalid session management request');expect(x.manage).not.toHaveBeenCalled();});
 it('rejects malformed session id before database call',()=>{const x=setup();expect(()=>x.controller.revoke(request,'bad',{})).toThrow('Invalid session identifier');expect(x.manage).not.toHaveBeenCalled();});
 it('passes target and authenticated hash for scoped revocation',async()=>{const x=setup(),id='11111111-1111-4111-8111-111111111111';await x.controller.revoke(request,id,{});expect(x.manage).toHaveBeenCalledWith(x.hash,'revoke',id);});
});
