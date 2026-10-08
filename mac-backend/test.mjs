import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {once} from 'node:events';
import {WebSocketServer,WebSocket} from 'ws';
import {createBackend} from './server.mjs';

async function fixture(t,options={}){
  const home=mkdtempSync(join(tmpdir(),'vesper-mac-test-')),token='synthetic-backend-token-12345678901234567890';
  const upstream=new WebSocketServer({port:0,host:'127.0.0.1'});await once(upstream,'listening');
  const backend=createBackend({home,token,upstream:'ws://127.0.0.1:'+upstream.address().port,...options});
  backend.server.listen(0,'127.0.0.1');await once(backend.server,'listening');
  const origin='http://127.0.0.1:'+backend.server.address().port;
  t.after(async()=>{for(const c of upstream.clients)c.terminate();upstream.close();await backend.close();rmSync(home,{recursive:true,force:true});});
  const req=async(path,method='GET',body,auth=token)=>{const r=await fetch(origin+path,{method,headers:{'x-vesper-device-token':auth,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});return {status:r.status,value:await r.json()};};
  return {backend,upstream,origin,token,req};
}
test('independent auth, documents, thread ownership, idempotent history and deletion',async t=>{
  const f=await fixture(t);
  assert.equal((await f.req('/api/state','GET',null,'vps-token')).status,401);
  const state=await f.req('/api/state');assert.equal(state.value.backend.backend,'mac');assert.equal(state.value.documents.profile.value.mainConversationId,undefined);
  assert.equal((await f.req('/history/conversations/room','POST',{codexThreadId:'vps-thread'})).status,409);
  f.backend.store.register('mac-thread');
  assert.equal((await f.req('/history/conversations/room','POST',{codexThreadId:'mac-thread'})).status,200);
  for(let i=0;i<2;i++)assert.equal((await f.req('/history/conversations/room/messages','POST',{id:'m1',role:'user',content:'中文 test',metadata:{threadId:'mac-thread'}})).status,200);
  const history=await f.req('/history/conversations/room');assert.equal(history.value.messages.length,1);
  assert.equal(history.value.messages[0].content,'中文 test');
  await f.req('/history/conversations/room/messages/m1','DELETE');
  f.backend.store.record('mac-thread',{id:'m1',role:'user',content:'do not resurrect',metadata:{threadId:'mac-thread'}});
  assert.equal((await f.req('/history/conversations/room')).value.messages.length,0);
  await f.req('/history/conversations/room','DELETE');assert.equal((await f.req('/history/conversations/room','POST',{})).status,410);
});
test('explicit Full Access applies to start, resume and every turn; spectator cannot send commands',async t=>{
  const f=await fixture(t,{fullAccess:true}),received=[];let connections=0;
  f.backend.store.register('local-thread');
  f.upstream.on('connection',socket=>{
    connections++;
    socket.on('message',raw=>{
      const p=JSON.parse(raw);received.push(p);
      if(['thread/start','thread/resume'].includes(p.method)){
        assert.equal(p.params.sandbox,'danger-full-access');assert.equal(p.params.approvalPolicy,'never');
        if(p.method==='thread/start')assert.equal(p.params.dynamicTools.filter(t=>t.name==='send_chat_file').length,1);
        else assert.equal(p.params.dynamicTools,undefined,'Do not pretend this Codex supports replacing tools on resume');
        assert.match(p.params.developerInstructions,/vesper_computer/);
        socket.send(JSON.stringify({id:p.id,result:{thread:{id:'local-thread'}}}));
      }else if(p.method==='turn/start'){
        assert.deepEqual(p.params.sandboxPolicy,{type:'dangerFullAccess'});assert.equal(p.params.approvalPolicy,'never');
        socket.send(JSON.stringify({id:p.id,result:{turn:{id:'t'}}}));
        socket.send(JSON.stringify({method:'turn/started',params:{threadId:'local-thread',turn:{id:'t'}}}));
        socket.send(JSON.stringify({method:'item/agentMessage/delta',params:{threadId:'local-thread',itemId:'a',delta:'中英 mixed'}}));
      }
    });
  });
  const spectator=new WebSocket(f.origin.replace('http','ws')+'/watch',{headers:{'x-vesper-device-token':f.token}}),events=[];
  t.after(()=>spectator.terminate());spectator.on('message',raw=>events.push(JSON.parse(raw)));
  await once(spectator,'open');assert.equal(connections,0);
  const client=new WebSocket(f.origin.replace('http','ws')+'/chat',{headers:{'x-vesper-device-token':f.token}});
  t.after(()=>client.terminate());await once(client,'open');
  for(const [id,method,params] of [[1,'thread/start',{}],[2,'thread/resume',{threadId:'local-thread'}],[3,'turn/start',{threadId:'local-thread',clientUserMessageId:'user',input:[{type:'text',text:'hello'}]}]]){
    const reply=once(client,'message');client.send(JSON.stringify({id,method,params}));await reply;
  }
  for(let i=0;i<30&&!events.some(e=>e.method==='item/agentMessage/delta');i++)await new Promise(r=>setTimeout(r,10));
  assert.ok(events.some(e=>e.type==='user'&&e.text==='hello'));
  assert.ok(events.some(e=>e.method==='item/agentMessage/delta'&&e.params.delta==='中英 mixed'));
  assert.equal((await f.req('/health')).value.access,'full');
  const closed=once(spectator,'close');spectator.send(JSON.stringify({method:'turn/start'}));assert.equal((await closed)[0],1008);
  assert.equal(received.length,3);assert.equal(connections,1);
  const bad=new WebSocket(f.origin.replace('http','ws')+'/watch',{headers:{'x-vesper-device-token':'vps-token'}});
  const rejected=await once(bad,'error');assert.match(rejected[0].message,/401/);
});
test('websocket streams events, returns tools and refuses foreign threads/config imports',async t=>{
  const f=await fixture(t);let requests=0,toolResult=false;
  f.upstream.on('connection',socket=>socket.on('message',raw=>{
    const p=JSON.parse(raw);requests++;
    if(p.id==='tool-1'){toolResult=p.result.success;socket.send(JSON.stringify({method:'turn/completed',params:{threadId:'mac-thread',turn:{id:'turn-1',status:'completed'}}}));return;}
    if(p.method==='thread/start'){assert.equal(p.params.sandbox,'workspace-write');assert.notEqual(p.params.cwd,'/');socket.send(JSON.stringify({id:p.id,result:{thread:{id:'mac-thread'}}}));}
    else if(p.method==='turn/start'){
      socket.send(JSON.stringify({id:p.id,result:{turn:{id:'turn-1'}}}));
      socket.send(JSON.stringify({method:'item/agentMessage/delta',params:{threadId:'mac-thread',turnId:'turn-1',itemId:'a1',delta:'你好'}}));
      socket.send(JSON.stringify({id:'tool-1',method:'item/tool/call',params:{threadId:'mac-thread',turnId:'turn-1',name:'mac_backend_status',arguments:{}}}));
    }
  }));
  const ws=new WebSocket(f.origin.replace('http','ws')+'/chat?token='+f.token);t.after(()=>ws.terminate());
  const received=[],waiting=[];ws.on('message',raw=>{const p=JSON.parse(raw);received.push(p);for(const w of [...waiting])if(w.match(p)){waiting.splice(waiting.indexOf(w),1);w.resolve(p);}});
  const next=match=>new Promise((resolve,reject)=>{const existing=received.find(match);if(existing)return resolve(existing);const timer=setTimeout(()=>reject(new Error('packet timeout')),3000);waiting.push({match,resolve:p=>{clearTimeout(timer);resolve(p);}});});
  await once(ws,'open');
  ws.send(JSON.stringify({id:1,method:'thread/resume',params:{threadId:'vps-thread'}}));assert.ok((await next(p=>p.id===1)).error);assert.equal(requests,0);
  ws.send(JSON.stringify({id:2,method:'thread/start',params:{cwd:'/',sandbox:'danger-full-access'}}));assert.equal((await next(p=>p.id===2)).result.thread.id,'mac-thread');
  ws.send(JSON.stringify({id:3,method:'turn/start',params:{threadId:'mac-thread',clientUserMessageId:'u1',input:[{type:'text',text:'hello'}]}}));
  assert.equal((await next(p=>p.method==='item/agentMessage/delta')).params.delta,'你好');
  await next(p=>p.id==='tool-1');const result=await f.req('/api/codex/tools','POST',{name:'mac_backend_status'});assert.equal(result.value.result.backend,'mac');
  ws.send(JSON.stringify({id:'tool-1',result:{success:true,contentItems:[{type:'inputText',text:JSON.stringify(result.value)}]}}));
  await next(p=>p.method==='turn/completed');assert.equal(toolResult,true);
  const count=requests;ws.send(JSON.stringify({id:4,method:'turn/start',params:{threadId:'mac-thread',clientUserMessageId:'u1',input:[]}}));await next(p=>p.id===4);assert.equal(requests,count);
  ws.close();
});
test('replica commit is atomic, strips remote runtime IDs, updates withdrawn memories and keeps local data',async t=>{
  const f=await fixture(t),source='a'.repeat(64),store=f.backend.store;
  store.register('local-thread');store.saveRoom('local-room',{codexThreadId:'local-thread'});
  store.saveMessage('local-room',{id:'local-msg',role:'user',content:'Local original'});
  const job=store.beginImport(source);
  store.stageImport(job,'room',[{id:'vps-room',codexThreadId:'remote-thread',title:'Original'}]);
  store.stageImport(job,'message',[{id:'vps-msg',conversationId:'vps-room',role:'agent',content:'Birthday is October 29',metadata:{threadId:'remote-thread',turnId:'remote-turn',itemId:'remote-item'}}]);
  store.stageImport(job,'memory',[{id:'memory1',body:'Vera birthday October 29'}]);
  assert.equal(store.replicaRows('message').length,0);store.commitImport(job);
  const room=store.replicaRows('room')[0],message=store.messages(room.id)[0];
  assert.notEqual(room.id,'vps-room');assert.equal(room.codexThreadId,undefined);assert.equal(message.metadata.threadId,undefined);assert.equal(message.metadata.turnId,undefined);
  assert.equal(store.owns('remote-thread'),false);assert.equal(store.messages('local-room').length,1);
  assert.equal(store.recall('birthday')[0].body,'Vera birthday October 29');
  const failed=store.beginImport(source);store.stageImport(failed,'memory',[{id:'new',body:'not committed'}]);assert.equal(store.recall('birthday').length,1);
  const next=store.beginImport(source);assert.throws(()=>store.commitImport(failed));store.commitImport(next);
  assert.equal(store.recall('birthday').length,0);assert.equal(store.messages('local-room').length,1);
});
