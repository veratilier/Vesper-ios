// Live, isolated acceptance room; never reads or resumes a VPS/Desktop thread.
import {readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import assert from 'node:assert/strict';
import {WebSocket} from 'ws';
const token=readFileSync(join(homedir(),'Library/Application Support/VesperBackend/device-token'),'utf8').trim();
const origin=process.env.VESPER_TEST_ORIGIN||'https://mac-vesper.r-vera.com';
const req=async(path,method='GET',body)=>{const r=await fetch(origin+path,{method,headers:{'x-vesper-device-token':token,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});const value=await r.json();assert.equal(r.status,200,JSON.stringify(value));return value;};
const health=await req('/api/backend');assert.equal(health.backend,'mac');console.log('HTTP_AUTH_OK',health.backendId);
const ws=new WebSocket(origin.replace(/^http/,'ws')+'/chat',{headers:{Authorization:'Bearer '+token}});
const pending=new Map(),packets=[];let seq=0,toolCalls=0,deltas=0;
const send=m=>ws.send(JSON.stringify(m));
const rpc=(method,params={})=>new Promise((resolve,reject)=>{const id=String(++seq),timer=setTimeout(()=>{pending.delete(id);reject(new Error(method+' timeout'));},30000);pending.set(id,{resolve:v=>{clearTimeout(timer);resolve(v);},reject:e=>{clearTimeout(timer);reject(e);}});send({id,method,params});});
ws.on('message',async raw=>{
  const p=JSON.parse(raw.toString());packets.push(p);
  if(p.method==='item/agentMessage/delta')deltas++;
  if(p.method==='item/tool/call'){
    try{assert.equal(p.params.tool||p.params.name,'mac_backend_status');const r=await req('/api/codex/tools','POST',{name:'mac_backend_status',arguments:{}});toolCalls++;send({id:p.id,result:{success:true,contentItems:[{type:'inputText',text:JSON.stringify(r.result)}]}});}catch{send({id:p.id,result:{success:false,contentItems:[{type:'inputText',text:'Acceptance tool failed'}]}});}
  }else if(p.id!==undefined&&pending.has(p.id)){const item=pending.get(p.id);pending.delete(p.id);p.error?item.reject(new Error(JSON.stringify(p.error))):item.resolve(p.result);}
  else if(p.id!==undefined&&p.method)send({id:p.id,error:{code:-32601,message:'Not authorized in acceptance test'}});
});
const complete=async id=>{const deadline=Date.now()+120000;while(Date.now()<deadline){const event=packets.find(p=>p.method==='turn/completed'&&p.params.turn.id===id);if(event){assert.equal(event.params.turn.status,'completed',JSON.stringify(event));return;}await new Promise(r=>setTimeout(r,250));}throw new Error('turn timeout');};
try{
  await once(ws,'open');await rpc('initialize',{clientInfo:{name:'vesper_mac_acceptance',version:'1.0'},capabilities:{experimentalApi:true}});send({method:'initialized',params:{}});
  const catalog=await req('/api/codex/tools');const models=await rpc('model/list',{});assert.ok(models.data?.length);console.log('MODEL_LIST_OK',models.data.length);
  const started=await rpc('thread/start',{model:'gpt-6.1-sol',dynamicTools:catalog.tools.map(t=>({...t,type:'function'})),developerInstructions:'This is an isolated Vesper backend acceptance test. Follow the simple test requests. Do not access files or other services.'});
  const thread=started.thread.id,room='acceptance-'+randomUUID();
  await req('/history/conversations/'+room,'POST',{title:'Mac backend acceptance test',codexThreadId:thread});console.log('FRESH_LOCAL_THREAD',thread);
  const first=await rpc('turn/start',{threadId:thread,clientUserMessageId:'test-'+randomUUID(),input:[{type:'text',text:'请仅回复：Mac 收发测试成功。'}],effort:'low'});await complete(first.turn.id);assert.ok(deltas>0);console.log('STREAMING_REPLY_OK',deltas);
  const second=await rpc('turn/start',{threadId:thread,clientUserMessageId:'test-'+randomUUID(),input:[{type:'text',text:'请调用一次 mac_backend_status 工具，并根据工具结果用中文简短告诉我当前后端及是否已经同步 VPS 历史。必须实际调用工具。'}],effort:'low'});await complete(second.turn.id);assert.equal(toolCalls,1);console.log('DYNAMIC_TOOL_ROUNDTRIP_OK');
  const history=await req('/history/conversations/'+room);assert.ok(history.messages.filter(m=>m.role==='agent').length>=2);assert.ok(history.messages.filter(m=>m.role==='user').length>=2);console.log('LOCAL_HISTORY_OK',history.messages.length);
  const resumed=await rpc('thread/resume',{threadId:thread,excludeTurns:true});assert.equal(resumed.thread.id,thread);console.log('LOCAL_RESUME_OK');
  await req('/history/conversations/'+room,'DELETE');console.log('ACCEPTANCE_OK');
}finally{ws.close();}
