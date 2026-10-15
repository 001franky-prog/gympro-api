// The application uses only node-qrcode's Promise-based SVG renderer.
declare module 'qrcode' {
 const QRCode:{toString(text:string,options:{type:'svg';errorCorrectionLevel:'M';margin:number;width:number}):Promise<string>};
 export default QRCode;
}
