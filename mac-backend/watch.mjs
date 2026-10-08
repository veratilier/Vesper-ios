#!/usr/bin/env node
import {readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {WebSocket} from 'ws';

const home=process.env.VESPER_BACKEND_HOME||join(homedir(),'Library/Application Support/VesperBackend');
const token=readFileSync(join(home,'device-token'),'utf8').trim();
const endpoint=process.env.VESPER_WATCH_URL||'ws://127.0.0.1:47631/watch';
const printed=new Set();let socket,stopping=false;
// Strip control characters so command output cannot execute terminal escape sequences.
const clean=value=>String(value||'').replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g,'');
const line=value=>process.stdout.write(clean(value)+'\n');
function connect(){
  socket=new WebSocket(endpoint,{headers:{'x-vesper-device-token':token}});
  socket.on('open',()=>line('Vesper MAC · 实时只读查看 · Ctrl+C 退出'));
  socket.on('message',raw=>{
    const event=JSON.parse(raw);
    if(event.type==='snapshot'){
      for(const {room,messages} of event.recent||[]){
        line('\n── '+room.title+' ──');
        for(const m of messages){if(printed.has(m.id))continue;printed.add(m.id);line((m.role==='user'?'你':'Rowan')+': '+m.content);}
      }
      for(const state of event.live||[])for(const item of state.items||[]){printed.add(item.id);line('\nRowan（正在回复）: '+item.text);}
      return;
    }
    if(event.type==='user'){line('\n你: '+event.text);return;}
    const p=event.params||{},item=p.item;
    if(event.method==='item/agentMessage/delta'){
      if(!printed.has(p.itemId)){printed.add(p.itemId);process.stdout.write('\nRowan: ');}
      process.stdout.write(clean(p.delta));
    }else if(event.method==='item/completed'&&item?.type==='agentMessage'){
      if(!printed.has(item.id)){printed.add(item.id);line('\nRowan: '+item.text);}else line('');
    }else if(event.method==='item/started'&&item?.type==='commandExecution')line('\n[终端] '+item.command);
    else if(event.method==='item/commandExecution/outputDelta')process.stdout.write(clean(p.delta));
    else if(event.method==='item/tool/call')line('\n[工具] '+(p.tool||p.name));
    else if(event.method==='item/started'&&item?.type==='mcpToolCall')line('\n[电脑工具] '+item.server+'/'+item.tool);
    else if(event.method==='turn/completed')line('\n['+(p.turn?.status||'完成')+']');
  });
  socket.on('error',()=>line('查看连接暂时不可用，正在重连…'));
  socket.on('close',()=>{if(!stopping)setTimeout(connect,2000);});
}
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>{stopping=true;socket?.terminate();process.exit(0);});
connect();
