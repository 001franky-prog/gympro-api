import {beforeEach,describe,it,expect,vi} from 'vitest';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {runInNewContext} from 'node:vm';
import {randomUUID} from 'node:crypto';
const source=readFileSync(join(process.cwd(),'web/operator/app.js'),'utf8');
const id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',branch='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
class Element {
 value='';disabled=false;hidden=false;className='';textContent='';dataset:Record<string,string>={};children:Element[]=[];listeners:Record<string,(e:unknown)=>unknown>={};attrs:Record<string,string>={};files:unknown[]=[];srcObject:unknown=null;src='';href='';videoWidth=0;videoHeight=0;width=0;height=0;
 addEventListener(k:string,f:(e:unknown)=>unknown){this.listeners[k]=f;}
 append(...v:Element[]){this.children.push(...v);}replaceChildren(...v:Element[]){this.children=[...v];}
 setAttribute(k:string,v:string){this.attrs[k]=v;}removeAttribute(k:string){delete this.attrs[k];}
 querySelector(selector:string):Element|null{if(selector.startsWith('[data-visit=')){const key=selector.split('"')[1];return this.children.find(x=>x.dataset.visit===key)||null;}return new Element();}
 async play(){}getContext(){return {drawImage(){},getImageData(){return {data:new Uint8ClampedArray(16)};}};}
}
const response=(data:unknown,status=200)=>({ok:status>=200&&status<300,status,json:async()=>data});
describe('Local operator UI session and request boundaries',()=>{
 let elements:Map<string,Element>;let fetcher:ReturnType<typeof vi.fn>;let stop:ReturnType<typeof vi.fn>;let revoke:ReturnType<typeof vi.fn>;let media:ReturnType<typeof vi.fn>;let decoder:ReturnType<typeof vi.fn>;
 const get=(key:string)=>{if(!elements.has(key))elements.set(key,new Element());return elements.get(key)!;};
 const emit=async(key:string,event='click')=>{await get(key).listeners[event]({preventDefault(){}});};
 beforeEach(()=>{
  elements=new Map();fetcher=vi.fn();stop=vi.fn();revoke=vi.fn();media=vi.fn(async()=>({getTracks:()=>[{stop}]}));decoder=vi.fn();
  const window={addEventListener:vi.fn(),jsQR:decoder};
  runInNewContext(source,{document:{getElementById:get,createElement:()=>new Element()},window,navigator:{mediaDevices:{getUserMedia:media}},fetch:fetcher,AbortSignal:{timeout:()=>undefined},crypto:{randomUUID},Blob,URL:{createObjectURL:()=> 'blob:test',revokeObjectURL:revoke},setTimeout:()=>1,clearTimeout(){},createImageBitmap:async()=>({width:2,height:2,close(){}})});
  get('tenant').value=id;get('branch').value=branch;get('email').value='staff@example.invalid';get('password').value='test-only';get('workspace').disabled=true;
 });
 async function login(){fetcher.mockResolvedValueOnce(response({accessToken:'test-session'})).mockResolvedValueOnce(response({tenantId:id}));await emit('login-form','submit');}
 it('verifies session tenant and clears password',async()=>{await login();expect(get('workspace').disabled).toBe(false);expect(get('password').value).toBe('');expect(get('password').disabled).toBe(true);expect(fetcher.mock.calls[1][1].headers.Authorization).toBe('Bearer test-session');expect(JSON.parse(fetcher.mock.calls[0][1].body).tenantId).toBe(id);});
 it('rejects mismatched verified tenant and revokes the new session',async()=>{fetcher.mockResolvedValueOnce(response({accessToken:'test-session'})).mockResolvedValueOnce(response({tenantId:branch})).mockResolvedValueOnce(response(undefined,204));await emit('login-form','submit');expect(get('workspace').disabled).toBe(true);expect(fetcher.mock.calls[2][0]).toBe('/auth/logout');expect(get('notice').textContent).toContain('mismatch');});
 it('clears the password on rejected login',async()=>{fetcher.mockResolvedValueOnce(response({},401));await emit('login-form','submit');expect(get('password').value).toBe('');expect(get('workspace').disabled).toBe(true);});
 it('retains a mutation request UUID after network uncertainty',async()=>{await login();get('scan-payload').value=`GP1:${id}:${branch}:${id}`;fetcher.mockRejectedValueOnce(new Error('network'));await emit('scan-form','submit');const a=JSON.parse(fetcher.mock.calls[2][1].body);fetcher.mockResolvedValueOnce(response({checkedInAt:'2026-10-15T00:00:00Z',checkedOutAt:null}));await emit('scan-form','submit');const b=JSON.parse(fetcher.mock.calls[3][1].body);expect(a.requestId).toBe(b.requestId);expect(get('notice').textContent).toContain('Check-in verified');});
 it('starts a new request after a definitive rejection',async()=>{await login();get('scan-payload').value=`GP1:${id}:${branch}:${id}`;fetcher.mockResolvedValueOnce(response({},403));await emit('scan-form','submit');const a=JSON.parse(fetcher.mock.calls[2][1].body);fetcher.mockResolvedValueOnce(response({checkedInAt:'2026-10-15T00:00:00Z'}));await emit('scan-form','submit');expect(JSON.parse(fetcher.mock.calls[3][1].body).requestId).not.toBe(a.requestId);});
 it('rejects malformed QR text before sending',async()=>{await login();get('scan-payload').value='<script>bad</script>';await emit('scan-form','submit');expect(fetcher).toHaveBeenCalledTimes(2);expect(get('notice').textContent).toContain('valid Gym Pro');});
 it('renders member names as text',async()=>{await login();fetcher.mockResolvedValueOnce(response({items:[{id,fullName:'<img src=x onerror=alert(1)>',memberNumber:'GP-1',checkedInAt:'2026-10-15T00:00:00Z',checkedOutAt:null}],nextCursor:null}));await emit('refresh-current');expect(get('current-list').children[0].children[0].children[0].textContent).toContain('<img');expect(source).not.toMatch(/innerHTML|outerHTML|insertAdjacentHTML/);});
 it('stops camera tracks on logout',async()=>{await login();await emit('start-camera');expect(media).toHaveBeenCalledOnce();fetcher.mockResolvedValueOnce(response(undefined,204));await emit('logout');expect(stop).toHaveBeenCalledOnce();expect(get('logout').disabled).toBe(true);expect(get('workspace').disabled).toBe(true);});
 it('removes QR object URLs on logout',async()=>{await login();get('card-id').value=id;fetcher.mockResolvedValueOnce(response({id,fullName:'Member',memberNumber:'GP-1',status:'active',issuedAt:'2026-10-15T00:00:00Z',revokedAt:null})).mockResolvedValueOnce(response({svg:'<svg></svg>'}));await emit('card-form','submit');expect(get('card-qr').src).toBe('blob:test');fetcher.mockResolvedValueOnce(response(undefined,204));await emit('logout');expect(revoke).toHaveBeenCalledWith('blob:test');expect(get('card-qr').hidden).toBe(true);});
 it('decodes an image locally without an upload request',async()=>{await login();get('qr-file').files=[{type:'image/png',size:100}];decoder.mockReturnValue({data:`GP1:${id}:${branch}:${id}`});await emit('qr-file','change');expect(get('scan-payload').value).toBe(`GP1:${id}:${branch}:${id}`);expect(fetcher).toHaveBeenCalledTimes(2);});
 it('keeps credentials out of persistent browser storage and URLs',()=>{expect(source).not.toMatch(/localStorage|sessionStorage|document\.cookie/);expect(source).not.toMatch(/[?&](accessToken|password|token)=/);});
});
