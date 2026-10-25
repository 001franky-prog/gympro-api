import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,existsSync,renameSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {runInNewContext} from 'node:vm';
const sourceText=readFileSync(new URL('./rehearse.mjs',import.meta.url),'utf8');
const start=sourceText.indexOf('function restoreOriginal(){');
const end=sourceText.indexOf('\nlet expandDefaults=',start);
assert.ok(start>=0&&end>start,'Rollback implementation boundary not found');
const implementation=sourceText.slice(start,end)+'\nrestoreOriginal();';
function fixture(t,{active=true,parked=true,occupied=false}={}){
 const root=mkdtempSync(join(tmpdir(),'gympro-rollback-test-'));t.after(()=>rmSync(root,{recursive:true,force:true}));
 const source=join(root,'source'),candidate=join(root,'candidate'),previous=join(root,'previous');
 const directory=(path,marker)=>{mkdirSync(path);writeFileSync(join(path,'marker'),marker);};
 if(parked)directory(previous,'original');
 if(active)directory(source,parked?'candidate':'original');
 if(occupied)directory(candidate,'retained-candidate');
 const context={source,candidate,previous,originalParked:parked,rollbackDone:false,existsSync,renameSync,assert,
 verifyInputs:path=>assert.equal(readFileSync(join(path,'marker'),'utf8'),'original'),state:()=>{}};
 return {root,source,candidate,previous,context,run:()=>runInNewContext(implementation,context)};
}
test('active candidate rolls back and is preserved separately',t=>{
 const f=fixture(t);f.run();assert.equal(readFileSync(join(f.source,'marker'),'utf8'),'original');assert.equal(readFileSync(join(f.candidate,'marker'),'utf8'),'candidate');assert.equal(existsSync(f.previous),false);assert.equal(f.context.rollbackDone,true);assert.equal(f.context.originalParked,false);
});
test('interruption after parking original restores it without touching prepared candidate',t=>{
 const f=fixture(t,{active:false,occupied:true});f.run();assert.equal(readFileSync(join(f.source,'marker'),'utf8'),'original');assert.equal(readFileSync(join(f.candidate,'marker'),'utf8'),'retained-candidate');
});
test('already-original state is left unchanged',t=>{
 const f=fixture(t,{parked:false});f.run();assert.equal(readFileSync(join(f.source,'marker'),'utf8'),'original');assert.equal(existsSync(f.candidate),false);
});
test('occupied retention destination prevents overwrite and preserves both releases',t=>{
 const f=fixture(t,{occupied:true});assert.throws(f.run,/unexpectedly occupied/);assert.equal(readFileSync(join(f.source,'marker'),'utf8'),'candidate');assert.equal(readFileSync(join(f.previous,'marker'),'utf8'),'original');assert.equal(readFileSync(join(f.candidate,'marker'),'utf8'),'retained-candidate');
});
test('failed original rename preserves recoverable releases and supports subsequent restoration',t=>{
 const f=fixture(t);f.context.renameSync=(a,b)=>{if(a===f.previous)throw Error('injected rename failure');return renameSync(a,b);};
 assert.throws(f.run,/injected rename failure/);assert.equal(existsSync(f.source),false);assert.equal(readFileSync(join(f.previous,'marker'),'utf8'),'original');assert.equal(readFileSync(join(f.candidate,'marker'),'utf8'),'candidate');
 f.context.renameSync=renameSync;f.run();assert.equal(readFileSync(join(f.source,'marker'),'utf8'),'original');assert.equal(f.context.rollbackDone,true);
});
