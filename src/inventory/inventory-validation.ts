export const isUuid=(v:unknown):v is string=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
export function sameUuid(a:unknown,b:string){return isUuid(a)&&a.toLowerCase()===b.toLowerCase();}
export function object(v:unknown,keys:string[]):Record<string,unknown>{
 if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).some(k=>!keys.includes(k)))throw Error('Invalid fields');
 return v as Record<string,unknown>;
}
export function uuid(v:unknown):string{if(!isUuid(v))throw Error('Invalid identifier');return v.toLowerCase();}
export function text(v:unknown,min:number,max:number):string{if(typeof v!=='string')throw Error('Invalid text');const s=v.trim();if(Array.from(s).length<min||Array.from(s).length>max||!(/\S/u.test(s)))throw Error('Invalid text length');return s;}
export function description(v:unknown):string|null{if(v===undefined||v===null)return null;if(typeof v!=='string'||Array.from(v.trim()).length>2000)throw Error('Invalid description');return v.trim()||null;}
export function price(v:unknown):string{if(typeof v!=='string'||!/^(0|[1-9]\d{0,11})(?:\.\d{1,2})?$/.test(v))throw Error('Invalid decimal price');const [a,b='']=v.split('.');return a+'.'+b.padEnd(2,'0');}
export function sku(v:unknown):string{if(typeof v!=='string')throw Error('Invalid SKU');const s=v.trim().toUpperCase();if(!/^[A-Z0-9][A-Z0-9_-]{0,31}$/.test(s))throw Error('Invalid SKU');return s;}
export function status(v:unknown):'draft'|'active'|'inactive'{if(v!=='draft'&&v!=='active'&&v!=='inactive')throw Error('Invalid status');return v;}
export function delta(v:unknown):number{if(typeof v!=='number'||!Number.isInteger(v)||v===0||v< -2147483648||v>2147483647)throw Error('Invalid quantity delta');return v;}
export function quantity(v:unknown):string{if(typeof v!=='string'||!/^(0|[1-9]\d{0,18})$/.test(v)||BigInt(v)>9223372036854775807n)throw Error('Invalid stock quantity');return v;}
export function timestamp(v:unknown):string{
 if(typeof v!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(v))throw Error('Invalid timestamp');
 const date=v.slice(0,10);const d=new Date(date+'T00:00:00Z');const t=new Date(v);
 if(!Number.isFinite(d.getTime())||d.toISOString().slice(0,10)!==date||!Number.isFinite(t.getTime())||Number(v.slice(11,13))>23||Number(v.slice(14,16))>59||Number(v.slice(17,19))>59)throw Error('Invalid timestamp');
 return t.toISOString();
}
export function createInput(body:unknown){const x=object(body,['sku','productName','description','salePrice','requestId']);return {sku:sku(x.sku),productName:text(x.productName,2,150),description:description(x.description),salePrice:price(x.salePrice),requestId:uuid(x.requestId)};}
export function updateInput(body:unknown){const x=object(body,['productName','description','salePrice','status','requestId']);return {productName:text(x.productName,2,150),description:description(x.description),salePrice:price(x.salePrice),status:status(x.status),requestId:uuid(x.requestId)};}
export function adjustmentInput(body:unknown){const x=object(body,['quantityDelta','reason','requestId']);return {quantityDelta:delta(x.quantityDelta),reason:text(x.reason,2,500),requestId:uuid(x.requestId)};}
export function pageInput(query:unknown){const x=object(query,['limit','cursor']);let limit=25;if(x.limit!==undefined){if(typeof x.limit!=='string'||!/^([1-9]\d?|100)$/.test(x.limit))throw Error('Invalid page limit');limit=Number(x.limit);}return {limit,cursor:x.cursor===undefined?null:uuid(x.cursor)};}
export function productRow(row:Record<string,unknown>,tenant:string){
 if(!sameUuid(row.tenant_id,tenant)||!isUuid(row.id)||typeof row.sale_price!=='string'||price(row.sale_price)!==row.sale_price||row.currency_code!=='MMK'||row.unit_code!=='piece'||!(row.updated_at instanceof Date)||!Number.isFinite(row.updated_at.getTime()))throw Error('Invalid product row');
 const name=text(row.product_name,2,150),code=sku(row.sku),desc=description(row.description),state=status(row.status);
 if(name!==row.product_name||code!==row.sku||desc!==row.description)throw Error('Noncanonical product row');
 return {id:row.id,tenantId:tenant,sku:code,productName:name,description:desc,unitCode:'piece',salePrice:row.sale_price,currencyCode:'MMK',status:state,updatedAt:row.updated_at.toISOString()};
}
export function productReceipt(value:unknown,tenant:string,request:string,expected:{productName:string;description:string|null;salePrice:string;status:string;sku?:string;id?:string}){
 if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid product result');const x=value as Record<string,unknown>;
 if(!sameUuid(x.tenantId,tenant)||!isUuid(x.id)||!sameUuid(x.requestId,request)||x.productName!==expected.productName||x.description!==expected.description||x.salePrice!==expected.salePrice||x.status!==expected.status||x.unitCode!=='piece'||x.currencyCode!=='MMK'||(expected.sku!==undefined&&x.sku!==expected.sku)||(expected.id!==undefined&&!sameUuid(x.id,expected.id)))throw Error('Product receipt mismatch');
 if(sku(x.sku)!==x.sku)throw Error('Noncanonical receipt SKU');
 const createdAt=timestamp(x.createdAt),updatedAt=timestamp(x.updatedAt);if(updatedAt<createdAt)throw Error('Reversed product timestamps');
 return {id:x.id,tenantId:tenant,sku:sku(x.sku),productName:text(x.productName,2,150),description:description(x.description),unitCode:'piece',salePrice:price(x.salePrice),currencyCode:'MMK',status:status(x.status),createdAt,updatedAt,requestId:request};
}
export function stockReceipt(value:unknown,tenant:string,branch:string,product:string){
 if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid stock result');const x=value as Record<string,unknown>;
 if(!sameUuid(x.tenantId,tenant)||!sameUuid(x.branchId,branch)||!sameUuid(x.productId,product))throw Error('Stock scope mismatch');return {tenantId:tenant,branchId:branch,productId:product,quantity:quantity(x.quantity)};
}
export function adjustmentReceipt(value:unknown,tenant:string,branch:string,product:string,input:ReturnType<typeof adjustmentInput>){
 if(!value||typeof value!=='object'||Array.isArray(value))throw Error('Invalid adjustment result');const x=value as Record<string,unknown>;
 if(!isUuid(x.id)||!sameUuid(x.tenantId,tenant)||!sameUuid(x.branchId,branch)||!sameUuid(x.productId,product)||!sameUuid(x.requestId,input.requestId)||x.quantityDelta!==input.quantityDelta||x.reason!==input.reason)throw Error('Adjustment receipt mismatch');
 return {id:x.id,tenantId:tenant,branchId:branch,productId:product,requestId:input.requestId,quantityDelta:input.quantityDelta,balanceAfter:quantity(x.balanceAfter),reason:input.reason,createdAt:timestamp(x.createdAt)};
}
