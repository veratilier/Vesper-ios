import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync,symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';
import {createBackend} from './server.mjs';

const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aNOkAAAAASUVORK5CYII=','base64');
async function fixture(t,fullAccess=false){
  const home=mkdtempSync(join(tmpdir(),'vesper-media-test-')),token='synthetic-media-token-12345678901234567890';
  const backend=createBackend({home,token,fullAccess});backend.server.listen(0,'127.0.0.1');await once(backend.server,'listening');
  const origin='http://127.0.0.1:'+backend.server.address().port;
  const req=async(path,body,auth=token)=>{const r=await fetch(origin+path,{method:body?'POST':'GET',headers:{'x-vesper-device-token':auth,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,value:await r.json()};};
  backend.store.register('mac-thread');backend.store.saveRoom('room',{codexThreadId:'mac-thread'});
  const send=(files,itemId='call-1',extra={})=>req('/api/codex/tools',{name:'send_chat_file',conversationId:'room',threadId:'mac-thread',turnId:'turn-1',itemId,arguments:{files},...extra});
  t.after(async()=>{await backend.close();rmSync(home,{recursive:true,force:true});});
  return {backend,home,token,origin,req,send};
}
test('actual PNG + UTF-8 Markdown are delivered, grouped and preserved across restart',async t=>{
  const f=await fixture(t),path=join(f.home,'workspace','image.png');writeFileSync(path,png);
  assert.ok((await f.req('/api/codex/tools')).value.tools.some(t=>t.name==='send_chat_file'));
  const files=[{name:'image.png',path},{name:'中文.md',text:'# 你好\nVesper test',mimeType:'text/markdown'}];
  const [response,concurrent]=await Promise.all([f.send(files),f.send(files)]);assert.equal(response.status,200);assert.equal(response.value.result.attachments.length,2);assert.deepEqual(concurrent.value.result,response.value.result);
  for(const [index,expected] of [png,Buffer.from('# 你好\nVesper test')].entries()){
    const a=response.value.result.attachments[index];assert.equal(a.size,expected.length);
    assert.match(a.url,/^https:\/\/mac-vesper\.r-vera\.com\/api\/media\/[a-f0-9]{64}\./);
    const downloaded=await fetch(f.origin+'/api/media/'+a.key);assert.equal(downloaded.status,200);
    assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()),expected);
    assert.equal(downloaded.headers.get('content-type'),index===0?'image/png':'text/markdown');
    assert.match(downloaded.headers.get('content-disposition'),index===0?/^inline/:/^attachment/);
    const head=await fetch(f.origin+'/api/media/'+a.key,{method:'HEAD'});assert.equal(head.status,200);assert.equal(head.headers.get('content-length'),String(expected.length));
    assert.equal(readFileSync(join(f.home,'media',a.key)).length,expected.length);
  }
  const saved=f.backend.store.messages('room');assert.equal(saved.length,1);assert.equal(saved[0].id,'files:mac-thread:call-1');assert.equal(saved[0].metadata.attachments.length,2);assert.equal(saved[0].metadata.turnId,'turn-1');
  writeFileSync(path,'file modified after delivery');
  const repeated=await f.send(files);assert.deepEqual(repeated.value.result,response.value.result);assert.equal(f.backend.store.messages('room').length,1);
  const reordered=await f.send(files.map(f=>Object.fromEntries(Object.entries(f).reverse())));assert.deepEqual(reordered.value.result,response.value.result);
  assert.equal((await f.send([{name:'different.txt',text:'other'}])).status,409);
  const other=createBackend({home:f.home,token:f.token});
  assert.equal(other.store.messages('room')[0].metadata.attachments[0].key,response.value.result.attachments[0].key);
  other.store.db.close();
});
test('rejects foreign threads, credentials, invalid bytes, oversized and partly invalid batches',async t=>{
  const f=await fixture(t,true);
  assert.equal((await f.req('/api/codex/tools',{name:'send_chat_file'},'wrong-token')).status,401);
  assert.equal((await f.send([{name:'x.txt',text:'x'}],'foreign',{threadId:'vps-thread'})).status,409);
  assert.equal((await f.send([{name:'x.txt',text:'x'}],'room',{conversationId:'missing'})).status,409);
  for(const files of [[],[{name:'x.txt',text:'x',base64:'AA=='}],[{name:'x.bin',base64:'a=?!'}],[{name:'fake.png',text:'not a PNG',mimeType:'image/png'}],[{name:'huge.txt',text:'a'.repeat(8*1024*1024+1)}],[{name:'good.txt',text:'good'},{name:'missing.txt',path:'does-not-exist'}]]){
    assert.notEqual((await f.send(files,'invalid')).status,200);
    assert.equal(f.backend.store.messages('room').length,0);
    assert.equal(f.backend.store.db.prepare('SELECT count(*) AS n FROM media').get().n,0);
  }
  const credential=join(f.home,'device-token');writeFileSync(credential,'synthetic private secret');
  assert.equal((await f.send([{name:'renamed.txt',path:credential}],'secret')).status,403);
  symlinkSync(credential,join(f.home,'workspace','innocent.txt'));
  assert.equal((await f.send([{name:'renamed.txt',path:'innocent.txt'}],'symlink')).status,403);
  for(const thread of ['mac-thread','other-thread']){mkdirSync(join(f.home,'codex','generated_images',thread),{recursive:true});writeFileSync(join(f.home,'codex','generated_images',thread,'actual.png'),png);}
  assert.equal((await f.send([{name:'actual.png',path:'~/.codex/generated_images/other-thread/actual.png'}],'foreign-generated')).status,409);
  assert.equal((await f.send([{name:'actual.png',path:'~/.codex/generated_images/mac-thread/actual.png'}],'generated')).status,200);
  assert.equal((await f.send([{name:'actual.png',path:'actual.png'}],'filename')).status,200);
  assert.equal((await fetch(f.origin+'/api/media/'+'.'.repeat(64))).status,404);
  assert.equal((await fetch(f.origin+'/api/media/'+'0'.repeat(64)+'.png')).status,404);
});
test('uploads from phone retain bytes; Full Access can send an explicit ordinary Mac file',async t=>{
  const f=await fixture(t,true),form=new FormData();form.set('file',new File([png],'phone.jpg',{type:'image/jpeg'}));
  let response=await fetch(f.origin+'/api/media',{method:'POST',headers:{'x-vesper-device-token':'vps-token'},body:form});assert.equal(response.status,401);
  response=await fetch(f.origin+'/api/media',{method:'POST',headers:{'x-vesper-device-token':f.token},body:form});assert.equal(response.status,200);
  const result=await response.json();assert.equal(result.type,'image/png');assert.equal(result.size,png.length);
  assert.deepEqual(Buffer.from(await (await fetch(f.origin+'/api/media/'+result.key)).arrayBuffer()),png);
  const outside=join(tmpdir(),'vesper-file-'+f.token.slice(-8)+'.pdf');writeFileSync(outside,'%PDF-1.4\nSynthetic acceptance document');t.after(()=>rmSync(outside,{force:true}));
  assert.equal((await f.send([{name:'document.pdf',path:outside}],'document')).status,200);
  const limited=await fixture(t,false);assert.equal((await limited.send([{name:'document.pdf',path:outside}])).status,403);
});
