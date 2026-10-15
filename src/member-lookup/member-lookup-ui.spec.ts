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
describe('Operator member lookup interactions',()=>{
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
 it('searches with an encoded term and selects a member without a write',async()=>{await login();get('member-search').value='A&B';fetcher.mockResolvedValueOnce(response({items:[{id,fullName:'<img onerror=alert(1)>',memberNumber:'GP-1',status:'active'}],nextCursor:null}));await emit('member-search-form','submit');expect(fetcher.mock.calls[2][0]).toContain('q=A%26B');const item=get('member-search-results').children[0];expect(item.children[0].children[0].textContent).toContain('<img');get('card-id').value=branch;await item.children[1].listeners.click({});expect(get('member-id').value).toBe(id);expect(get('card-id').value).toBe('');expect(fetcher).toHaveBeenCalledTimes(3);});
 it('rejects a short term without an API request',async()=>{await login();get('member-search').value='a';await emit('member-search-form','submit');expect(fetcher).toHaveBeenCalledTimes(2);expect(get('notice').textContent).toContain('2 to 100');});
 it('clears results and selected member on branch change',async()=>{await login();get('member-search').value='Member';fetcher.mockResolvedValueOnce(response({items:[{id,fullName:'Member',memberNumber:'GP-1',status:'active'}],nextCursor:id}));await emit('member-search-form','submit');const button=get('member-search-results').children[0].children[1];get('branch').value=id;await emit('branch','change');expect(get('member-search-results').children).toHaveLength(0);expect(get('more-members').hidden).toBe(true);await button.listeners.click({});expect(get('member-id').value).toBe('');});
 it('clears member information on logout',async()=>{await login();get('member-search').value='Member';get('selected-member').textContent='Private name';fetcher.mockResolvedValueOnce(response(undefined,204));await emit('logout');expect(get('selected-member').textContent).toBe('');expect(get('member-search').value).toBe('');});
 it('uses the original query when loading another page',async()=>{await login();get('member-search').value='Member';fetcher.mockResolvedValueOnce(response({items:[{id,fullName:'Member',memberNumber:'GP-1',status:'active'}],nextCursor:id}));await emit('member-search-form','submit');get('member-search').value='Changed';fetcher.mockResolvedValueOnce(response({items:[],nextCursor:null}));await emit('more-members');expect(fetcher.mock.calls[3][0]).toContain('q=Member');expect(fetcher.mock.calls[3][0]).toContain('cursor='+id);});
 it('shows permission denial without creating member results',async()=>{await login();get('member-search').value='Member';fetcher.mockResolvedValueOnce(response({},403));await emit('member-search-form','submit');expect(get('member-search-results').children).toHaveLength(0);expect(get('notice').textContent).toContain('does not have access');});
});
