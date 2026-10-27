// Stage 1 creates an actual legacy thread without file tools; restart the backend, then stage 2 resumes it.
import {readFileSync,writeFileSync,rmSync,readdirSync} from 'node:fs';
import {homedir,tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import assert from 'node:assert/strict';
import {WebSocket} from 'ws';
import {DatabaseSync} from 'node:sqlite';
import {Store} from './storage.mjs';

const prepare=process.argv.includes('--prepare'),home=join(homedir(),'Library/Application Support/VesperBackend');
const statePath=join(home,'media-legacy-acceptance.json'),token=readFileSync(join(home,'device-token'),'utf8').trim();
const origin='https://mac-vesper.r-vera.com';
const req=async(path,method='GET',body)=>{const response=await fetch(origin+path,{method,headers:{'x-vesper-device-token':token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});const value=await response.json();assert.equal(response.status,200,JSON.stringify(value));return value;};
let state=prepare?{marker:'legacy-files-'+randomUUID()}:JSON.parse(readFileSync(statePath,'utf8'));
if(prepare){assert.ok(!readdirSync(home).includes('media-legacy-acceptance.json'),'Finish existing acceptance first');state.room=state.marker;state.source=join(tmpdir(),state.marker+'.png');}
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aNOkAAAAASUVORK5CYII=','base64'),text='# 旧对话附件测试\nSynthetic Markdown only.';
const ws=new WebSocket(prepare?'ws://127.0.0.1:47632':origin.replace('https','wss')+'/chat',{headers:{Authorization:'Bearer '+token}});
let seq=0,complete=false,result,callID,failure;const pending=new Map();
const rpc=(method,params={})=>new Promise((resolve,reject)=>{const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(new Error(method+' timeout'));},30000);pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});ws.send(JSON.stringify({id,method,params}));});
ws.on('message',async raw=>{
  const packet=JSON.parse(raw),p=packet.params||{};
  if(packet.method==='item/tool/call'){
    try{
      assert.equal(prepare,false);assert.equal(p.tool||p.name,'send_chat_file');const args=typeof p.arguments==='string'?JSON.parse(p.arguments):p.arguments;
      assert.equal(args.files.length,2);assert.ok(args.files.some(f=>f.path===state.source));assert.ok(args.files.some(f=>f.text===text));callID=p.callId||p.itemId||String(packet.id);
      result=(await req('/api/codex/tools','POST',{name:'send_chat_file',arguments:args,conversationId:state.room,threadId:state.thread,turnId:p.turnId,itemId:callID})).result;
      ws.send(JSON.stringify({id:packet.id,result:{success:true,contentItems:[{type:'inputText',text:JSON.stringify(result)}]}}));
    }catch(e){failure=e;ws.send(JSON.stringify({id:packet.id,result:{success:false,contentItems:[{type:'inputText',text:e.message}]}}));}
  }else if(pending.has(packet.id)){const h=pending.get(packet.id);pending.delete(packet.id);packet.error?h.reject(new Error(packet.error.message)):h.resolve(packet.result);}
  else if(packet.method==='turn/completed'){complete=true;if(p.turn?.error)failure=new Error(p.turn.error.message);}
  else if(packet.id!==undefined&&packet.method)ws.send(JSON.stringify({id:packet.id,error:{code:-32601,message:'Outside isolated test scope'}}));
});
const wait=async()=>{for(let i=0;i<120&&!complete;i++)await new Promise(r=>setTimeout(r,1000));if(failure)throw failure;assert.ok(complete,'No completed turn');};
try{
  await once(ws,'open');await rpc('initialize',{clientInfo:{name:'vesper_legacy_files_acceptance',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
  if(prepare){
    const oldTool=(await req('/api/codex/tools')).tools.find(t=>t.name==='mac_backend_status');
    state.thread=(await rpc('thread/start',{model:'gpt-6.1-sol',dynamicTools:[oldTool],developerInstructions:'Isolated acceptance test. For the first request, reply briefly without tools or file access.'})).thread.id;
    const store=new Store(home);try{store.register(state.thread);store.saveRoom(state.room,{title:'Legacy attachment acceptance',codexThreadId:state.thread});}finally{store.db.close();}
    await rpc('turn/start',{threadId:state.thread,input:[{type:'text',text:'请只回复：旧对话测试。'}],effort:'low'});await wait();
    const index=new DatabaseSync(join(home,'codex','state_5.sqlite'),{readOnly:true});state.rollout=index.prepare('SELECT rollout_path FROM threads WHERE id=?').get(state.thread).rollout_path;index.close();
    const bytes=readFileSync(state.rollout),split=bytes.indexOf(10),header=JSON.parse(bytes.subarray(0,split));assert.ok(!header.payload.dynamic_tools.some(t=>t.name==='send_chat_file'));
    writeFileSync(statePath,JSON.stringify(state),{mode:0o600,flag:'wx'});
    console.log('LEGACY_THREAD_CREATED_WITHOUT_FILE_TOOL');
  }else{
    const backup=readFileSync(join(home,'tool-migration-backups',state.thread+'-before-file-tool.jsonl')),current=readFileSync(state.rollout);
    assert.deepEqual(current.subarray(current.indexOf(10)),backup.subarray(backup.indexOf(10)),'Migration changed existing history');
    const resumed=await rpc('thread/resume',{threadId:state.thread,excludeTurns:true,developerInstructions:'Isolated file test. Actually call send_chat_file once with the requested synthetic files, then reply briefly. Use no other tool or file.'});assert.equal(resumed.thread.id,state.thread);
    writeFileSync(state.source,png);
    await rpc('turn/start',{threadId:state.thread,clientUserMessageId:state.marker,input:[{type:'text',text:'请使用 send_chat_file 实际发送 '+JSON.stringify({files:[{name:state.marker+'.png',path:state.source,mimeType:'image/png'},{name:state.marker+'.md',text,mimeType:'text/markdown'}],message:'旧对话发送测试'})+'。'}],effort:'low'});await wait();assert.ok(result,'Old thread still has no file tool');
    for(const [i,bytes] of [png,Buffer.from(text)].entries()){const response=await fetch(result.attachments[i].url);assert.equal(response.status,200);assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes);}
    const history=await req('/history/conversations/'+state.room);assert.equal(history.messages.find(m=>m.id==='files:'+state.thread+':'+callID).metadata.attachments.length,2);
    console.log('SAME_LEGACY_THREAD_ID_OK · ORIGINAL_HISTORY_PRESERVED · REAL_FILE_TOOL_AND_PUBLIC_DOWNLOAD_OK');
  }
}finally{
  ws.terminate();
  if(!prepare){
    await req('/history/conversations/'+state.room,'DELETE').catch(()=>{});rmSync(state.source,{force:true});rmSync(statePath,{force:true});
    const db=new DatabaseSync(join(home,'backend.sqlite3'));for(const row of db.prepare('SELECT key,value FROM media').all())if(JSON.parse(row.value).name.startsWith(state.marker+'.')){rmSync(join(home,'media',row.key),{force:true});db.prepare('DELETE FROM media WHERE key=?').run(row.key);}db.close();
  }
}
