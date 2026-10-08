// One isolated real-model turn, using synthetic files only, through the public Mac tunnel.
import {readFileSync,writeFileSync,rmSync} from 'node:fs';
import {homedir,tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import assert from 'node:assert/strict';
import {WebSocket} from 'ws';
import {DatabaseSync} from 'node:sqlite';

const home=join(homedir(),'Library/Application Support/VesperBackend'),token=readFileSync(join(home,'device-token'),'utf8').trim();
const origin=process.env.VESPER_TEST_ORIGIN||'https://mac-vesper.r-vera.com';
const request=async(path,method='GET',body)=>{
  const response=await fetch(origin+path,{method,headers:{'x-vesper-device-token':token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
  const value=await response.json();assert.equal(response.status,200,JSON.stringify(value));return value;
};
const marker='media-acceptance-'+randomUUID(),room=marker;
const source=join(tmpdir(),marker+'.png'),text='# Vesper 文件测试\nSynthetic UTF-8 Markdown.';
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aNOkAAAAASUVORK5CYII=','base64');writeFileSync(source,png);
const ws=new WebSocket(origin.replace(/^http/,'ws')+'/chat',{headers:{'x-vesper-device-token':token}});
let seq=0,thread,completed=false,deltas=0,attachmentResult,callID,failure;const pending=new Map();
const rpc=(method,params={})=>new Promise((resolve,reject)=>{
  const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(new Error(method+' timed out'));},30000);
  pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});ws.send(JSON.stringify({id,method,params}));
});
ws.on('message',async raw=>{
  const packet=JSON.parse(raw),p=packet.params||{};
  if(packet.method==='item/agentMessage/delta')deltas++;
  if(packet.method==='item/tool/call'){
    try{
      assert.equal(p.tool||p.name,'send_chat_file');const args=typeof p.arguments==='string'?JSON.parse(p.arguments):p.arguments;
      assert.equal(args.files.length,2);assert.ok(args.files.some(f=>f.path===source));assert.ok(args.files.some(f=>f.text===text));
      callID=p.callId||p.itemId||String(packet.id);
      const result=await request('/api/codex/tools','POST',{name:'send_chat_file',arguments:args,conversationId:room,threadId:thread,turnId:p.turnId,itemId:callID});
      attachmentResult=result.result;
      ws.send(JSON.stringify({id:packet.id,result:{success:true,contentItems:[{type:'inputText',text:JSON.stringify(result.result)}]}}));
    }catch(e){failure=e;ws.send(JSON.stringify({id:packet.id,result:{success:false,contentItems:[{type:'inputText',text:e.message}]}}));}
  }else if(pending.has(packet.id)){
    const promise=pending.get(packet.id);pending.delete(packet.id);packet.error?promise.reject(new Error(packet.error.message)):promise.resolve(packet.result);
  }else if(packet.method==='turn/completed'){completed=true;if(p.turn?.error)failure=new Error(p.turn.error.message);}
  else if(packet.id!==undefined&&packet.method)ws.send(JSON.stringify({id:packet.id,error:{code:-32601,message:'Outside synthetic acceptance scope'}}));
});
try{
  await once(ws,'open');await rpc('initialize',{clientInfo:{name:'vesper_media_acceptance',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
  const catalog=await request('/api/codex/tools'),tool=catalog.tools.find(t=>t.name==='send_chat_file');assert.ok(tool);
  // Simulate an older client's cached catalog. The gateway must install the attachment tool.
  const started=await rpc('thread/start',{model:'gpt-6.1-sol',dynamicTools:[],developerInstructions:'This is a synthetic Vesper attachment acceptance test. Call send_chat_file exactly once with the exact requested values. Do not access any other file or tool.'});thread=started.thread.id;
  await request('/history/conversations/'+room,'POST',{title:'Synthetic media acceptance',codexThreadId:thread});
  const files=[{name:marker+'.png',path:source,mimeType:'image/png'},{name:marker+'.md',text,mimeType:'text/markdown'}];
  await rpc('turn/start',{threadId:thread,clientUserMessageId:marker,input:[{type:'text',text:'请实际调用 send_chat_file，参数为 '+JSON.stringify({files,message:'文件和图片测试'})+'。成功后简短回复已发送。'}],effort:'low'});
  for(let i=0;i<120&&!completed;i++)await new Promise(r=>setTimeout(r,1000));
  if(failure)throw failure;assert.ok(completed,'No completed turn');assert.ok(attachmentResult,'Model did not send files');assert.ok(deltas>0);
  for(const [index,bytes] of [png,Buffer.from(text)].entries()){
    const file=attachmentResult.attachments[index];assert.equal(new URL(file.url).origin,origin);
    const response=await fetch(file.url);assert.equal(response.status,200);assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes);
    assert.equal(response.headers.get('content-type'),index===0?'image/png':'text/markdown');
  }
  const history=await request('/history/conversations/'+room);const message=history.messages.find(m=>m.id==='files:'+thread+':'+callID);
  assert.equal(message.metadata.attachments.length,2);assert.equal(message.metadata.threadId,thread);
  await rpc('thread/resume',{threadId:thread,excludeTurns:true,dynamicTools:[tool]});
  assert.ok((await request('/history/conversations/'+room)).messages.some(m=>m.id===message.id));
  console.log('REAL_MODEL_FILE_TOOL_OK · PUBLIC_PNG_AND_MARKDOWN_BYTES_OK · GROUPED_HISTORY_AND_RESUME_OK');
}finally{
  ws.terminate();rmSync(source,{force:true});
  if(thread)await request('/history/conversations/'+room,'DELETE').catch(()=>{});
  // Remove only artifacts named by this synthetic run, never a user's media.
  const db=new DatabaseSync(join(home,'backend.sqlite3'));
  for(const row of db.prepare('SELECT key,value FROM media').all())if(JSON.parse(row.value).name.startsWith(marker+'.')){rmSync(join(home,'media',row.key),{force:true});db.prepare('DELETE FROM media WHERE key=?').run(row.key);}
  db.close();
}
