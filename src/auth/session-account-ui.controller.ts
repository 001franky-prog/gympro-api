import {Controller,Get,Header} from '@nestjs/common';
import {readFileSync} from 'node:fs';import {join} from 'node:path';
@Controller('account/sessions')
export class SessionAccountUiController {
 @Get() @Header('Content-Type','text/html; charset=utf-8') @Header('Cache-Control','no-store')
 @Header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
 page(){return readFileSync(join(process.cwd(),'web/account-sessions/index.html'),'utf8');}
 @Get('app.js') @Header('Content-Type','application/javascript; charset=utf-8') @Header('Cache-Control','no-store')
 script(){return readFileSync(join(process.cwd(),'web/account-sessions/app.js'),'utf8');}
 @Get('style.css') @Header('Content-Type','text/css; charset=utf-8')
 style(){return readFileSync(join(process.cwd(),'web/account-sessions/style.css'),'utf8');}
}
