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
describe('Operator selected-member card discovery',()=>{
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
 it('looks up and displays an active card without issuing it',async()=>{await login();get('member-id').value=id;fetcher.mockResolvedValueOnce(response({card:{id:branch,memberId:id}})).mockResolvedValueOnce(response({id:branch,fullName:'Member Name',memberNumber:'GP-1',status:'active',issuedAt:'2026-10-15T00:00:00Z',revokedAt:null})).mockResolvedValueOnce(response({svg:'<svg></svg>'}));await emit('find-member-card');expect(get('card-id').value).toBe(branch);expect(get('card-name').textContent).toBe('Member Name');expect(get('card-qr').hidden).toBe(false);expect(fetcher.mock.calls.slice(2).every(c=>c[1].method==='GET')).toBe(true);});
 it('shows a clear no-card result and clears old preview',async()=>{await login();get('member-id').value=id;get('card-id').value=branch;get('card-name').textContent='Old member';fetcher.mockResolvedValueOnce(response({card:null}));await emit('find-member-card');expect(get('card-id').value).toBe('');expect(get('card-name').textContent).toBe('Member card');expect(get('card-qr').hidden).toBe(true);expect(get('notice').textContent).toContain('No card has been issued');expect(fetcher).toHaveBeenCalledTimes(3);});
 it('displays revoked details without requesting a QR',async()=>{await login();get('member-id').value=id;fetcher.mockResolvedValueOnce(response({card:{id:branch,memberId:id}})).mockResolvedValueOnce(response({id:branch,fullName:'Member',memberNumber:'GP-1',status:'revoked',issuedAt:'2026-10-15T00:00:00Z',revokedAt:'2026-10-15T01:00:00Z'}));await emit('find-member-card');expect(get('card-status').textContent).toBe('revoked');expect(get('card-qr').hidden).toBe(true);expect(fetcher).toHaveBeenCalledTimes(4);});
 it('rejects lookup without a selected member',async()=>{await login();await emit('find-member-card');expect(fetcher).toHaveBeenCalledTimes(2);expect(get('notice').textContent).toContain('Select a member first');});
 it('rejects a returned card from a different member',async()=>{await login();get('member-id').value=id;fetcher.mockResolvedValueOnce(response({card:{id,memberId:branch}}));await emit('find-member-card');expect(get('card-id').value).toBe('');expect(get('notice').textContent).toContain('Invalid card lookup');expect(fetcher).toHaveBeenCalledTimes(3);});
 it('reports card-read permission denial without issuing a card',async()=>{await login();get('member-id').value=id;fetcher.mockResolvedValueOnce(response({},403));await emit('find-member-card');expect(get('notice').textContent).toContain('does not have access');expect(fetcher).toHaveBeenCalledTimes(3);});
});
