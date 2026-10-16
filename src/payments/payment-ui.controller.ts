import {Controller,Get,NotFoundException,Res} from '@nestjs/common';
import type {Response} from 'express';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
@Controller('payments')
export class PaymentUiController {
 private async asset(res:Response,file:string,type:string){res.setHeader('Content-Type',type+'; charset=utf-8');res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");try{return await readFile(join(process.cwd(),'web','payments',file),'utf8');}catch{throw new NotFoundException('Payment screen unavailable');}}
 @Get() index(@Res({passthrough:true})r:Response){return this.asset(r,'index.html','text/html');}
 @Get('app.js') app(@Res({passthrough:true})r:Response){return this.asset(r,'app.js','application/javascript');}
 @Get('style.css') style(@Res({passthrough:true})r:Response){return this.asset(r,'style.css','text/css');}
}
