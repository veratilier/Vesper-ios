import {randomUUID,createHash} from 'node:crypto';
import {body,json,fail,validID,canonical} from './http-helpers.mjs';
/** HTTP business endpoints are independent from the model WebSocket transport. */
export function createHttpAPI({store,media,status,authorize,fileJobs,publicOrigin,tools,log=entry=>console.log(JSON.stringify(entry))}) {
  return async(req,res)=>{
    const requestId=randomUUID(),started=Date.now();res.setHeader('X-Vesper-Request-ID',requestId);
    let service='gateway';
    try{
      const url=new URL(req.url,'http://localhost'),p=url.pathname,method=req.method;
      service=p.startsWith('/api/media')?'media':p.startsWith('/history')?'chat':p.startsWith('/api/memory')?'memory':p.startsWith('/api/codex')?'tools':p==='/api/state'?'documents':'gateway';
      // Like VPS media URLs, a random-looking capability key allows native image/file previews
      // without placing the backend device token in a link or image request.
      if(p.startsWith('/api/media/')&&['GET','HEAD'].includes(method))return await media.serve(p.slice('/api/media/'.length),req,res);
      if(req.headers.origin)throw fail('Browser origins are not accepted',403);
      if(!authorize(req))throw fail('Unauthorized',401);
      if(p==='/health'||p==='/api/backend')return json(res,200,status());
      if(p==='/api/media'&&method==='POST')return json(res,200,await media.upload(req,publicOrigin));
      if(p==='/api/backend/import'&&method==='POST'){
        const b=await body(req);
        if(b.action==='begin')return json(res,200,{jobId:store.beginImport(b.source)});
        if(b.action==='append'){store.stageImport(b.jobId,b.kind,b.rows);return json(res,200,{ok:true});}
        if(b.action==='commit')return json(res,200,{ok:true,receipt:store.commitImport(b.jobId)});
        throw fail('Unknown import action');
      }
      if(p==='/api/state'){
        if(method==='GET'){const key=url.searchParams.get('key');return json(res,200,key?{key,value:store.get('doc:'+key)}:{documents:store.documents(),backend:status()});}
        if(method==='PUT'){const b=await body(req);if(!validID(b.key))throw fail('Invalid document key');if(b.key==='profile'&&b.value?.mainConversationId&&!store.room(b.value.mainConversationId))throw fail('Main conversation must exist on this Mac',409);store.set('doc:'+b.key,b.value);return json(res,200,{ok:true});}
      }
      if(p==='/api/codex/tools'){
        if(method==='GET')return json(res,200,{tools,backend:status()});
        if(method==='POST'){
          const b=await body(req,12*1024*1024);if(b.name==='mac_backend_status')return json(res,200,{result:status()});
          if(b.name==='send_chat_file'){
            const context={conversationId:b.conversationId,threadId:b.threadId,turnId:b.turnId,itemId:b.itemId,origin:publicOrigin};
            if(!validID(context.conversationId)||!validID(context.threadId)||!validID(context.turnId))throw fail('Current Mac conversation, thread and turn are required');
            const identity=b.itemId?'file-receipt:'+b.threadId+':'+b.turnId+':'+String(b.itemId):null;
            const signature=createHash('sha256').update(JSON.stringify(canonical({conversationId:b.conversationId,arguments:b.arguments}))).digest('hex');
            const previous=identity&&store.get(identity);
            store.requireThread(b.threadId);
            const room=store.room(b.conversationId);if(!room||room.codexThreadId!==b.threadId)throw fail('Use the current Mac conversation and thread',409);
            if(previous&&previous.signature!==signature)throw fail('This tool call ID belongs to a different file request',409);
            let result=previous?.result;
            if(!previous){
              const current=identity&&fileJobs.get(identity);
              if(current&&current.signature!==signature)throw fail('This tool call ID belongs to a different file request',409);
              if(current)result=await current.promise;
              else{
                const promise=media.deliver(b.arguments||{},context).then(result=>{if(identity)store.set(identity,{signature,result});return result;});
                if(identity)fileJobs.set(identity,{signature,promise});
                try{result=await promise;}finally{if(identity)fileJobs.delete(identity);}
              }
            }
            return json(res,200,{ok:true,name:b.name,result});
          }
          if(b.name==='read_vesper_state'){
            const section=b.arguments?.section||'today',key={today:'todos',reminders:'todos',dates:'anniversaries',journal:'diary',music:'music',settings:'settings'}[section];
            if(section!=='memory'&&!key)throw fail('Unknown section');
            return json(res,200,{result:{section,value:section==='memory'?store.replicaRows('memory').slice(0,40):store.get('doc:'+key),storage:'mac-local'}});
          }
          throw fail('This tool has not been configured on the Mac backend',501);
        }
      }
      if(p==='/api/memory/messages'&&method==='POST'){store.remember(await body(req));return json(res,200,{ok:true,saved:true,storage:'mac-local',synced:false});}
      if(p==='/api/memory/context'&&method==='POST'){
        const b=await body(req);if(b.action==='acknowledge')return json(res,200,{ok:true});
        return json(res,200,{status:'prepared',deliveryId:randomUUID(),additionalContext:{memoryScope:store.get('lastImport')?'Mac-local plus manually copied VPS memories; see original source and copy timestamp.':'Mac-local only; VPS memories have not been synchronized.',lastImport:store.get('lastImport'),originalMessages:store.recall(b.query)}});
      }
      if(p==='/api/mcp/connections'&&method==='GET')return json(res,200,{connections:[]});
      if(p==='/api/letters/reminders'&&method==='GET')return json(res,200,{reminders:[]});
      if(p==='/history/health')return json(res,200,status());
      if(p==='/history/inbox')return json(res,200,{messages:[],items:[]});
      if(p==='/history/activity')return json(res,200,{days:[],timezone:'Asia/Shanghai'});
      if(p==='/history/conversations'&&method==='GET')return json(res,200,{conversations:store.list()});
      if(p==='/history/search'&&method==='GET'){
        const q=(url.searchParams.get('q')||'').toLowerCase(),room=url.searchParams.get('conversationId');
        const rooms=[...store.list(),...store.replicaRows('room').filter(c=>!store.isRoomDeleted(c.id))];
        const rows=[...new Map(rooms.map(c=>[c.id,c])).values()].filter(c=>!room||c.id===room).flatMap(c=>store.messages(c.id)).filter(m=>q&&m.content?.toLowerCase().includes(q));
        const offset=Math.max(0,Number(url.searchParams.get('offset'))||0);return json(res,200,{results:rows.slice(offset,offset+60),hasMore:rows.length>offset+60});
      }
      const reaction=p.match(/^\/history\/conversations\/([^/]+)\/reactions$/);
      if(reaction&&method==='POST'){
        const id=decodeURIComponent(reaction[1]);if(!validID(id))throw fail('Invalid ID');
        return json(res,200,store.react(id,await body(req)));
      }
      const match=p.match(/^\/history\/conversations\/([^/]+)(?:\/messages(?:\/([^/]+))?)?$/);
      if(match){
        const id=decodeURIComponent(match[1]),messageID=match[2]&&decodeURIComponent(match[2]);if(!validID(id)||messageID&&!validID(messageID))throw fail('Invalid ID');
        if(p.endsWith('/messages')&&method==='POST'){store.saveMessage(id,await body(req));return json(res,200,{ok:true});}
        if(messageID&&method==='DELETE'){store.deleteMessage(id,messageID);return json(res,200,{ok:true,deleted:1});}
        if(method==='POST'||method==='PATCH')return json(res,200,{conversation:store.saveRoom(id,await body(req))});
        if(method==='DELETE'){store.deleteRoom(id);return json(res,200,{ok:true,deleted:true});}
        if(method==='GET'){
          const all=store.messages(id),before=url.searchParams.get('before');let end=before?all.findIndex(m=>m.id===before):all.length;
          if(end<0)throw fail('Invalid history cursor');
          const limit=Math.min(500,Math.max(1,Number(url.searchParams.get('limit'))||40)),around=url.searchParams.get('around');
          if(around){const index=all.findIndex(m=>m.id===around);if(index<0)throw fail('Message not found',404);end=Math.min(all.length,index+Math.ceil(limit/2));}
          const start=Math.max(0,end-limit),messages=all.slice(start,end);
          return json(res,200,{conversation:store.room(id),messages,tombstones:store.db.prepare('SELECT id AS stableId FROM tombstones WHERE room=?').all(id),hasMore:start>0,before:messages[0]?.id||''});
        }
      }
      throw fail('This feature is not yet available on the Mac backend',501);
    }catch(e){if(res.headersSent)res.destroy();else json(res,e.status||500,{error:e.status?e.message:'Mac backend request failed'});}
    finally {log({event:'api_request',service,method:req.method,status:res.statusCode,requestId,elapsedMs:Date.now()-started});}
  };
}
