import {describe,it,expect} from 'vitest';
import {readFileSync} from 'node:fs';
import {PaymentUiController} from './payment-ui.controller.js';
describe('Payment UI assets',()=>{
 it('serves the payment screen with security headers',async()=>{const headers:Record<string,string>={};const res={setHeader:(k:string,v:string)=>{headers[k]=v;}};const html=await new PaymentUiController().index(res as never);expect(html).toContain('Payment workspace');expect(headers['Cache-Control']).toBe('no-store');expect(headers['Content-Security-Policy']).toContain("connect-src 'self'");});
 it('keeps payment credentials out of persistent browser storage',()=>{const js=readFileSync('web/payments/app.js','utf8');expect(js).not.toMatch(/localStorage|sessionStorage|innerHTML|document\.cookie/);expect(js).toContain('crypto.randomUUID()');});
});
