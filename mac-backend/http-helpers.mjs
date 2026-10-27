import {timingSafeEqual} from 'node:crypto';
export const fail=(message,status=400)=>Object.assign(new Error(message),{status});
export const validID=id=>typeof id==='string'&&/^[a-zA-Z0-9_.:-]{1,180}$/.test(id);
export const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
export function equal(a,b){const x=Buffer.from(a||''),y=Buffer.from(b||'');return x.length===y.length&&timingSafeEqual(x,y);}
export async function body(req,limit=4*1024*1024){let size=0,chunks=[];for await(const c of req){size+=c.length;if(size>limit)throw fail('Request too large',413);chunks.push(c);}try{return JSON.parse(Buffer.concat(chunks).toString()||'{}');}catch{throw fail('Invalid JSON');}}
export function json(res,status,value){res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(value));}
