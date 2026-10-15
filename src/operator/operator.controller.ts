import {Controller,Get,NotFoundException,Res} from '@nestjs/common';
import type {Response} from 'express';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
@Controller('operator')
export class OperatorController {
 private async asset(res:Response,file:string,type:string,vendor=false){
  res.setHeader('Content-Type',type+'; charset=utf-8');
  res.setHeader('Cache-Control','no-store');
  res.setHeader('X-Content-Type-Options','nosniff');
  res.setHeader('Referrer-Policy','no-referrer');
  res.setHeader('Permissions-Policy','camera=(self), microphone=()');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
  try{return await readFile(vendor?join(process.cwd(),'node_modules','jsqr','dist',file):join(process.cwd(),'web','operator',file),'utf8');}catch{throw new NotFoundException('Operator asset unavailable');}
 }
 @Get() index(@Res({passthrough:true})r:Response){return this.asset(r,'index.html','text/html');}
 @Get('app.js') app(@Res({passthrough:true})r:Response){return this.asset(r,'app.js','application/javascript');}
 @Get('style.css') style(@Res({passthrough:true})r:Response){return this.asset(r,'style.css','text/css');}
 @Get('vendor/jsqr.js') decoder(@Res({passthrough:true})r:Response){return this.asset(r,'jsQR.js','application/javascript',true);}
}
