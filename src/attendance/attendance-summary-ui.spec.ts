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
describe('Operator daily attendance summary',()=>{
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
 const summary={day:'2026-10-15',checkIns:2,distinctMembers:1,checkOuts:3,currentOccupancy:0,generatedAt:'2026-10-15T10:00:00Z'};
 it('loads the server-selected day and renders separate metrics',async()=>{await login();fetcher.mockResolvedValueOnce(response(summary));await emit('summary-form','submit');expect(fetcher.mock.calls[2][0]).toContain('/attendance/summary');expect(fetcher.mock.calls[2][0]).not.toContain('?day=');expect(get('summary-checkins').textContent).toBe('2');expect(get('summary-checkouts').textContent).toBe('3');expect(get('summary-members').textContent).toBe('1');expect(get('summary-occupancy').textContent).toBe('0');expect(get('summary-caption').textContent).toContain('2026-10-15');});
 it('passes the chosen date without a write request',async()=>{await login();get('summary-day').value='2026-10-15';fetcher.mockResolvedValueOnce(response(summary));await emit('summary-form','submit');expect(fetcher.mock.calls[2][0]).toContain('?day=2026-10-15');expect(fetcher.mock.calls[2][1].method).toBe('GET');});
 it('clears metrics on branch changes',async()=>{await login();fetcher.mockResolvedValueOnce(response(summary));await emit('summary-form','submit');await emit('branch','change');expect(get('summary-checkins').textContent).toBe('—');expect(get('summary-caption').textContent).toContain('Load a summary');});
 it('clears metrics on logout',async()=>{await login();fetcher.mockResolvedValueOnce(response(summary));await emit('summary-form','submit');fetcher.mockResolvedValueOnce(response(undefined,204));await emit('logout');expect(get('summary-members').textContent).toBe('—');});
 it('rejects negative counts',async()=>{await login();fetcher.mockResolvedValueOnce(response({...summary,currentOccupancy:-1}));await emit('summary-form','submit');expect(get('notice').textContent).toContain('Invalid summary');});
 it('reports permission denial without changing attendance',async()=>{await login();fetcher.mockResolvedValueOnce(response({},403));await emit('summary-form','submit');expect(get('notice').textContent).toContain('does not have access');expect(fetcher).toHaveBeenCalledTimes(3);});
});
