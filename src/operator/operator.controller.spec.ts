import {describe,it,expect} from 'vitest';
import type {Response} from 'express';
import {OperatorController} from './operator.controller.js';
describe('Operator asset boundaries',()=>{
 it('serves local HTML with restrictive security headers',async()=>{const headers:Record<string,string>={};const res={setHeader:(k:string,v:string)=>{headers[k]=v;}} as unknown as Response;const html=await new OperatorController().index(res);expect(html).toContain('Gym Pro');expect(html).toContain('/operator/app.js');expect(headers['Cache-Control']).toBe('no-store');expect(headers['Content-Security-Policy']).toContain("frame-ancestors 'none'");expect(headers['Content-Security-Policy']).not.toContain('unsafe-inline');});
 it('serves the local decoder without a CDN',async()=>{const res={setHeader(){}} as unknown as Response;const js=await new OperatorController().decoder(res);expect(js.length).toBeGreaterThan(1000);expect(js).toContain('jsQR');});
});
