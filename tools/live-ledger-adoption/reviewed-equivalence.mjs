import {readFileSync} from 'node:fs';
const pairs=JSON.parse(readFileSync(new URL('./reviewed-pairs.json',import.meta.url),'utf8'));
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
export function canonicalCatalog(catalog){const out={...catalog};for(const group of ['constraints','indexes'])if(Array.isArray(catalog[group]))out[group]=catalog[group].map(row=>{const pair=pairs[group].find(p=>same(row,p.left)||same(row,p.right));return pair?pair.right:row;});return out;}
export function compareReviewed(actual,expected){const a=canonicalCatalog(actual),b=canonicalCatalog(expected),differences=[];for(const key of Object.keys(b))if(!same(a[key],b[key]))differences.push(key);if(differences.length)throw Error('Unreviewed schema/security drift in: '+differences.join(', '));}
