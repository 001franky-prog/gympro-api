import {describe,it,expect,vi} from 'vitest';
import {PosUiController} from './pos-ui.controller.js';
import type {Response} from 'express';
describe('POS operator assets',()=>{
 for(const [name,type]of [['index','text/html'],['app','application/javascript'],['style','text/css']] as const)it(`serves ${name} with no-store and restrictive browser headers`,async()=>{const setHeader=vi.fn();const out=await new PosUiController()[name]({setHeader} as unknown as Response);expect(out.length).toBeGreaterThan(100);expect(setHeader).toHaveBeenCalledWith('Cache-Control','no-store');expect(setHeader).toHaveBeenCalledWith('Content-Type',type+'; charset=utf-8');expect(setHeader).toHaveBeenCalledWith('X-Content-Type-Options','nosniff');expect(setHeader).toHaveBeenCalledWith('Content-Security-Policy',expect.stringContaining("frame-ancestors 'none'"));});
});
