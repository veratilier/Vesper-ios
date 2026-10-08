// A fresh synthetic thread verifies real Full Access and Mac UI tools, without resuming a user chat.
import {readFileSync,writeFileSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {homedir,tmpdir} from 'node:os';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import assert from 'node:assert/strict';
import {WebSocket} from 'ws';

const home=join(homedir(),'Library/Application Support/VesperBackend');
const token=readFileSync(join(home,'device-token'),'utf8').trim();
const ws=new WebSocket('ws://127.0.0.1:47631/chat',{headers:{'x-vesper-device-token':token}});
const source=join(tmpdir(),'vesper-access-'+randomUUID()+'.txt'),target=source+'.copy';
writeFileSync(source,'Vesper synthetic full-access marker');
let nextID=0,complete=false,command=false,computer=false,failure;
const pending=new Map();
ws.on('message',raw=>{
  const packet=JSON.parse(raw),p=packet.params||{};
  if(pending.has(packet.id)){const handler=pending.get(packet.id);pending.delete(packet.id);packet.error?handler.reject(new Error(packet.error.message)):handler.resolve(packet.result);}
  if(packet.method==='item/completed'&&p.item?.type==='commandExecution')command=true;
  if(packet.method==='item/completed'&&p.item?.type==='mcpToolCall'&&p.item.server==='vesper_computer'&&p.item.status==='completed')computer=true;
  if(packet.method==='turn/completed'){complete=true;failure=p.turn?.error;}
});
const rpc=(method,params)=>new Promise((resolve,reject)=>{const id=++nextID;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});
try{
  await once(ws,'open');
  await rpc('initialize',{clientInfo:{name:'vesper_access_acceptance',version:'1'},capabilities:{experimentalApi:true}});
  ws.send(JSON.stringify({method:'initialized'}));
  const started=await rpc('thread/start',{model:'gpt-6.1-sol',developerInstructions:'This is an isolated synthetic acceptance test. Access only the two explicitly named test files and the Calculator session. Do not access user documents or other apps.'});
  await rpc('turn/start',{threadId:started.thread.id,input:[{type:'text',text:`Use the terminal to copy the synthetic file ${source} to ${target}. Then actually invoke the vesper_computer snapshot MCP tool with platform macos, session vesper-rowan, interactiveOnly true. Do not start another app or session. Reply briefly when done.`}],effort:'low'});
  for(let i=0;i<150&&!complete;i++)await new Promise(r=>setTimeout(r,1000));
  assert.ok(complete,'Model turn timed out');assert.ok(!failure,'Model turn failed');
  assert.equal(readFileSync(target,'utf8'),readFileSync(source,'utf8'));assert.ok(command,'No real command execution');
  assert.ok(computer,'No successful computer MCP call');
  console.log('FULL_ACCESS_FILE_COPY_OK · COMPUTER_MCP_MODEL_CALL_OK');
}finally{ws.terminate();rmSync(source,{force:true});rmSync(target,{force:true});}
