import http from 'node:http';
import {readFileSync,mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {createHttpAPI} from './http-api.mjs';
import {fail,validID,canonical,equal} from './http-helpers.mjs';
import {startCodexProcess} from './codex-process.mjs';
import {pathToFileURL} from 'node:url';
import {WebSocketServer,WebSocket} from 'ws';
import {Store,now} from './storage.mjs';
import {Media,fileTool} from './media.mjs';
import {migrateAttachmentTool} from './tool-migration.mjs';

const tools=[fileTool,{name:'mac_backend_status',description:'Read the active Mac backup backend status and whether history/memory is local or synchronized.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
 {name:'read_vesper_state',description:'Read one local Vesper section. section=journal reads diary, reminders reads todos, dates reads anniversaries. This does not read live VPS data.',inputSchema:{type:'object',properties:{section:{type:'string',enum:['today','reminders','dates','journal','music','memory','settings']}},required:['section'],additionalProperties:false}}];

const methods=new Set(['initialize','initialized','account/read','account/rateLimits/read','model/list','thread/start','thread/resume','thread/read','thread/items/list','thread/turns/list','turn/start','turn/interrupt']);

export function createBackend({home,token,upstream='ws://127.0.0.1:47632',workspace=join(home,'workspace'),fullAccess=false,publicOrigin='https://mac-vesper.r-vera.com'}){
  const store=new Store(home);mkdirSync(workspace,{recursive:true,mode:0o700});
  const media=new Media({home,workspace,store,token,fullAccess});
  const fileJobs=new Map();
  const watchers=new WebSocketServer({noServer:true,maxPayload:1024});
  const live=new Map();
  const send=(socket,packet)=>{if(socket.readyState===WebSocket.OPEN){if(socket.bufferedAmount>32*1024*1024){socket.close(1013,'Client too slow');return;}socket.send(JSON.stringify(packet));}};
  const publish=packet=>{for(const socket of watchers.clients)send(socket,packet);};
  const observe=packet=>{
    const p=packet.params,thread=p?.threadId;
    if(!thread||!store.owns(thread)||!packet.method)return;
    if(packet.method==='turn/started')live.set(thread,{threadId:thread,items:[]});
    const state=live.get(thread);
    if(state&&packet.method==='item/agentMessage/delta'){
      let item=state.items.find(i=>i.id===p.itemId);
      if(!item){item={id:p.itemId,text:''};state.items.push(item);}
      item.text+=p.delta||'';
    }
    // Read-only spectators receive conversation events, never account/auth RPCs.
    if(/^(turn\/(started|completed)|item\/(started|completed|agentMessage\/delta|commandExecution\/outputDelta|tool\/call))$/.test(packet.method))publish({type:'event',method:packet.method,params:p});
    if(packet.method==='turn/completed')live.delete(thread);
  };
  const status=()=>({ok:true,backendId:store.get('backendId'),backend:'mac',history:'local',memory:'local',syncEnabled:false,lastImport:store.get('lastImport'),access:fullAccess?'full':'workspace',activeTurns:live.size,version:4,capabilities:{sendChatFiles:true,localMedia:true,legacyFileTools:true}});
  const authorize=req=>equal(req.headers['x-vesper-device-token'],token)||equal(req.headers.authorization,'Bearer '+token);
  const server=http.createServer(createHttpAPI({store,media,status,authorize,fileJobs,publicOrigin,tools}));
  const wss=new WebSocketServer({noServer:true,maxPayload:20*1024*1024});
  server.on('upgrade',(req,socket,head)=>{
    let url;try{url=new URL(req.url,'http://localhost');}catch{socket.destroy();return;}
    if(!['/chat','/watch'].includes(url.pathname)||req.headers.origin||!(authorize(req)||(url.pathname==='/chat'&&equal(url.searchParams.get('token'),token)))){socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');return;}
    const target=url.pathname==='/watch'?watchers:wss;
    target.handleUpgrade(req,socket,head,ws=>target.emit('connection',ws));
  });
  watchers.on('connection',socket=>{
    const recent=store.list().slice(0,2).map(room=>({room,messages:store.messages(room.id).slice(-10)}));
    send(socket,{type:'snapshot',recent,live:[...live.values()]});
    socket.on('message',()=>socket.close(1008,'This viewer is read-only'));
    socket.on('error',()=>{});
  });
  wss.on('connection',client=>{
    const remote=new WebSocket(upstream,{headers:{Authorization:'Bearer '+token},maxPayload:32*1024*1024});
    const waiting=[],pending=new Map(),toolRequests=new Set();let queuedBytes=0;
    remote.on('open',()=>{for(const packet of waiting.splice(0))send(remote,packet);queuedBytes=0;});
    client.on('message',data=>{
      let packet;
      try{
        packet=JSON.parse(data.toString());
        if(!packet||typeof packet!=='object')throw fail('Invalid packet');
        if(!packet.method){if(!toolRequests.delete(packet.id))throw fail('Unknown tool response');send(remote,packet);return;}
        if(!methods.has(packet.method))throw fail('Method is not enabled on the Mac backend');
        const params=packet.params||{};
        if(params.threadId)store.requireThread(params.threadId);
        if(['thread/start','thread/resume'].includes(packet.method)){
          // Runtime ownership is local; never accept imported rollouts, arbitrary cwd or remote environments.
          for(const key of ['path','history','environment','environmentId'])if(params[key])throw fail('Imported thread state is not supported');
          const allowedConfig=['features.default_mode_request_user_input','compact_prompt'];
          const accessInstructions=fullAccess?'\nThis Mac backend has user-authorized Full Access: local filesystem and network commands are available without sandbox approval. For desktop app and browser UI tasks, use the vesper_computer MCP tools with platform=macos and session=vesper-rowan. macOS privacy permissions still apply. Do not send messages to other people without the user explicitly asking.':'';
          // This Codex version persists tools on start and ignores dynamicTools on resume.
          // Old rollouts are migrated before app-server starts; never rely on a resume override.
          const updated={...params};delete updated.dynamicTools;
          if(packet.method==='thread/start')updated.dynamicTools=[...(Array.isArray(params.dynamicTools)?params.dynamicTools:[]).filter(t=>t.name!==fileTool.name),fileTool];
          packet.params={...updated,config:Object.fromEntries(Object.entries(params.config||{}).filter(([k])=>allowedConfig.includes(k))),cwd:workspace,sandbox:fullAccess?'danger-full-access':'workspace-write',approvalPolicy:fullAccess?'never':'on-request',...(accessInstructions?{developerInstructions:(params.developerInstructions||'')+accessInstructions}:{})};
        }
        if(packet.method==='turn/start'){
          const receiptKey='receipt:'+params.threadId+':'+params.clientUserMessageId;
          const receipt=params.clientUserMessageId&&store.get(receiptKey);if(receipt){send(client,{id:packet.id,result:receipt});return;}
          packet.params={...params,cwd:workspace,approvalPolicy:fullAccess?'never':'on-request',sandboxPolicy:fullAccess?{type:'dangerFullAccess'}:{type:'workspaceWrite',writableRoots:[workspace],networkAccess:true,excludeTmpdirEnvVar:true,excludeSlashTmp:true}};
        }
        if(packet.id!==undefined){if(pending.has(packet.id))throw fail('Duplicate request ID');pending.set(packet.id,{method:packet.method,params:packet.params||params});}
        if(remote.readyState===WebSocket.OPEN)send(remote,packet);
        else if(remote.readyState===WebSocket.CONNECTING){queuedBytes+=data.length;if(queuedBytes>20*1024*1024)throw fail('Queue too large');waiting.push(packet);}
        else throw fail('Model service is disconnected');
      }catch(e){send(client,{id:packet?.id??null,error:{code:-32602,message:e.status?e.message:'Invalid request'}});}
    });
    remote.on('message',data=>{
      try{
        const packet=JSON.parse(data.toString()),request=pending.get(packet.id);
        if(packet.method&&packet.id!==undefined)toolRequests.add(packet.id);
        else if(request){
          pending.delete(packet.id);
          if(!packet.error&&request.method==='thread/start'&&packet.result?.thread?.id)store.register(packet.result.thread.id);
          if(!packet.error&&request.method==='turn/start'){
            const p=request.params,turn=packet.result?.turn;
            if(p.clientUserMessageId&&turn?.id){store.set('receipt:'+p.threadId+':'+p.clientUserMessageId,packet.result);const text=p.input?.filter(i=>i.type==='text').at(-1)?.text||'';store.record(p.threadId,{id:p.clientUserMessageId,role:'user',content:text,createdAt:now(),status:'delivered',metadata:{threadId:p.threadId,turnId:turn.id}});publish({type:'user',threadId:p.threadId,text});}
          }
        }
        const p=packet.params;
        if(packet.method==='item/completed'&&p.item?.type==='agentMessage'&&store.owns(p.threadId))store.record(p.threadId,{id:p.item.id,role:'agent',content:p.item.text,createdAt:now(),status:'delivered',metadata:{threadId:p.threadId,turnId:p.turnId,phase:p.item.phase}});
        observe(packet);
        send(client,packet);
      }catch{client.close(1011,'Model response could not be processed');}
    });
    remote.on('error',()=>client.close(1011,'Mac model service unavailable'));
    remote.on('close',()=>client.close(1012,'Mac model service disconnected'));
    client.on('close',()=>remote.close());client.on('error',()=>remote.close());
  });
  return {server,store,close:async()=>{for(const c of [...wss.clients,...watchers.clients])c.terminate();await new Promise(resolve=>server.close(resolve));store.db.close();}};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  process.umask(0o077);
  const home=process.env.VESPER_BACKEND_HOME;if(!home)throw new Error('VESPER_BACKEND_HOME required');
  const token=readFileSync(join(home,'device-token'),'utf8').trim();if(token.length<32)throw new Error('Invalid local token');
  const workspace=join(home,'workspace');mkdirSync(workspace,{recursive:true,mode:0o700});
  let access={};try{access=JSON.parse(readFileSync(join(home,'access.json'),'utf8'));}catch{}
  const backend=createBackend({home,token,workspace,fullAccess:access.mode==='full'});
  // Run with no model process/writer active. Backups are private and only Mac-owned IDs qualify.
  const migration=migrateAttachmentTool({home,store:backend.store});
  if(migration.changed)console.log('Registered attachment tool for existing Mac conversations:',migration.changed);
  const child=startCodexProcess({home,workspace});
  child.stderr.on('data',()=>{});child.on('error',()=>{console.error('Could not start Mac app-server');process.exit(1);});
  child.on('exit',()=>{console.error('Mac app-server exited');process.exit(1);});
  backend.server.listen(47631,'127.0.0.1',()=>console.log('Vesper Mac backend listening on loopback:47631'));
  for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>{child.kill('SIGTERM');backend.server.close(()=>process.exit(0));setTimeout(()=>process.exit(0),1500).unref();});
}
