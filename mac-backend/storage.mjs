import {DatabaseSync} from 'node:sqlite';
import {mkdirSync,chmodSync} from 'node:fs';
import {join} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';

export const now=()=>new Date().toISOString();
export class Store {
  constructor(home){
    mkdirSync(home,{recursive:true,mode:0o700});
    this.db=new DatabaseSync(join(home,'backend.sqlite3'));chmodSync(join(home,'backend.sqlite3'),0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY,value TEXT NOT NULL,deleted INTEGER DEFAULT 0);
      CREATE TABLE IF NOT EXISTS messages(room TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(room,id));
      CREATE TABLE IF NOT EXISTS tombstones(room TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(room,id));
      CREATE TABLE IF NOT EXISTS events(thread TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(thread,id));
      CREATE TABLE IF NOT EXISTS memory(id TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS imports(id TEXT PRIMARY KEY,source TEXT NOT NULL,created TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS import_rows(job TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(job,kind,id));
      CREATE TABLE IF NOT EXISTS replicas(source TEXT NOT NULL,kind TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(source,kind,id));`);
    if(!this.get('backendId'))this.set('backendId','mac-'+randomUUID());
    if(!this.get('doc:profile'))this.set('doc:profile',{userName:'Vera',agentName:'Rowan'});
  }
  get(key){const row=this.db.prepare('SELECT value FROM kv WHERE key=?').get(key);return row?JSON.parse(row.value):null;}
  set(key,value){this.db.prepare('INSERT OR REPLACE INTO kv VALUES (?,?)').run(key,JSON.stringify(value));}
  documents(){return Object.fromEntries(this.db.prepare("SELECT * FROM kv WHERE key LIKE 'doc:%'").all().map(r=>[r.key.slice(4),{value:JSON.parse(r.value)}]));}
  owns(id){return typeof id==='string' && !!this.db.prepare('SELECT id FROM threads WHERE id=?').get(id);}
  register(id){this.db.prepare('INSERT OR IGNORE INTO threads VALUES (?)').run(id);}
  requireThread(id){if(id && !this.owns(id))throw Object.assign(new Error('This thread does not belong to the Mac backend. Start a new Mac conversation.'),{status:409});}
  room(id){const row=this.db.prepare('SELECT * FROM conversations WHERE id=?').get(id);if(row?.deleted)throw Object.assign(new Error('Conversation deleted'),{status:410});return row?JSON.parse(row.value):this.replica('room',id);}
  replica(kind,id){const row=this.db.prepare('SELECT value FROM replicas WHERE kind=? AND id=?').get(kind,id);return row?JSON.parse(row.value):null;}
  replicaRows(kind){return this.db.prepare('SELECT value FROM replicas WHERE kind=?').all(kind).map(r=>JSON.parse(r.value));}
  saveRoom(id,patch={}){
    const prior=this.room(id);this.requireThread(patch.codexThreadId);
    if(prior?.codexThreadId && patch.codexThreadId && prior.codexThreadId!==patch.codexThreadId)throw Object.assign(new Error('Conversation already belongs to a different local thread'),{status:409});
    const value={id,title:'New Mac conversation',createdAt:now(),...prior,...patch,id,updatedAt:now(),backendId:this.get('backendId')};
    this.db.prepare('INSERT OR REPLACE INTO conversations VALUES (?,?,0)').run(id,JSON.stringify(value));return value;
  }
  saveMessage(room,message,{onlyMissing=false}={}){
    if(!this.room(room))throw Object.assign(new Error('Conversation not found'),{status:404});
    this.requireThread(message.metadata?.threadId);
    const bound=this.room(room).codexThreadId;
    if(bound && message.metadata?.threadId && bound!==message.metadata.threadId)throw Object.assign(new Error('Message belongs to a different thread'),{status:409});
    if(this.db.prepare('SELECT id FROM tombstones WHERE room=? AND id=?').get(room,message.id))return;
    if(!message.id || !['user','agent','system'].includes(message.role))throw Object.assign(new Error('Invalid message'),{status:400});
    const previous=this.db.prepare('SELECT value FROM messages WHERE room=? AND id=?').get(room,message.id);
    if(previous && onlyMissing)return;
    const value={createdAt:now(),status:'delivered',...(previous?JSON.parse(previous.value):{}),...message,conversationId:room};
    this.db.prepare('INSERT OR REPLACE INTO messages VALUES (?,?,?)').run(room,message.id,JSON.stringify(value));
    this.saveRoom(room,{});
  }
  record(thread,message){this.requireThread(thread);this.db.prepare('INSERT OR REPLACE INTO events VALUES (?,?,?)').run(thread,message.id,JSON.stringify(message));}
  messages(room){
    const conversation=this.room(room);if(!conversation)throw Object.assign(new Error('Conversation not found'),{status:404});
    if(conversation.codexThreadId)for(const row of this.db.prepare('SELECT value FROM events WHERE thread=?').all(conversation.codexThreadId))this.saveMessage(room,JSON.parse(row.value),{onlyMissing:true});
    const local=this.db.prepare('SELECT value FROM messages WHERE room=? ORDER BY json_extract(value,\'$.createdAt\'),rowid').all(room).map(r=>JSON.parse(r.value));
    const deleted=new Set(this.db.prepare('SELECT id FROM tombstones WHERE room=?').all(room).map(r=>r.id));
    return [...this.replicaRows('message').filter(m=>m.conversationId===room&&!deleted.has(m.id)),...local].sort((a,b)=>String(a.createdAt).localeCompare(String(b.createdAt)));
  }
  list(){return this.db.prepare('SELECT value FROM conversations WHERE deleted=0 ORDER BY json_extract(value,\'$.updatedAt\') DESC').all().map(r=>{const c=JSON.parse(r.value);const m=this.messages(c.id);return {...c,messageCount:m.length,preview:m.at(-1)?.content||''};});}
  deleteMessage(room,id){this.db.prepare('INSERT OR IGNORE INTO tombstones VALUES (?,?)').run(room,id);this.db.prepare('DELETE FROM messages WHERE room=? AND id=?').run(room,id);}
  isRoomDeleted(id){return !!this.db.prepare('SELECT id FROM conversations WHERE id=? AND deleted=1').get(id);}
  deleteRoom(id){const room=this.room(id);if(room)this.db.prepare('INSERT OR REPLACE INTO conversations VALUES (?,?,1)').run(id,JSON.stringify(room));this.db.prepare('DELETE FROM messages WHERE room=?').run(id);}
  remember(value){if(!value.messageId)throw Object.assign(new Error('messageId is required'),{status:400});this.db.prepare('INSERT OR REPLACE INTO memory VALUES (?,?)').run(value.conversationId+':'+value.messageId,JSON.stringify(value));}
  recall(query){
    const text=String(query||'').toLowerCase();const words=[...new Set([...text.split(/\s+/),...(text.match(/[\p{Script=Han}]{2,}/gu)||[]).flatMap(s=>Array.from({length:s.length-1},(_,i)=>s.slice(i,i+2)))])].filter(w=>w.length>=2);
    const rows=[...this.replicaRows('memory'),...this.db.prepare('SELECT value FROM memory ORDER BY rowid DESC LIMIT 500').all().map(r=>JSON.parse(r.value))];
    return rows.map(m=>({m,score:words.filter(w=>String(m.content||m.body||'').toLowerCase().includes(w)).length})).filter(r=>r.score>0).sort((a,b)=>b.score-a.score).slice(0,8).map(r=>r.m);
  }
  beginImport(source){
    if(typeof source!=='string'||!/^[a-f0-9]{64}$/.test(source))throw Object.assign(new Error('Invalid source identity'),{status:400});
    this.db.exec("DELETE FROM import_rows WHERE job IN (SELECT id FROM imports WHERE created < datetime('now','-7 days')); DELETE FROM imports WHERE created < datetime('now','-7 days')");
    const id=randomUUID();this.db.prepare('INSERT INTO imports VALUES (?,?,?)').run(id,source,now());return id;
  }
  stageImport(job,kind,rows){
    const run=this.db.prepare('SELECT source FROM imports WHERE id=?').get(job);
    if(!run||!['room','message','memory'].includes(kind)||!Array.isArray(rows)||rows.length>100)throw Object.assign(new Error('Invalid import batch'),{status:400});
    const key=id=>'copy-'+createHash('sha256').update(run.source+':'+id).digest('hex');
    for(const original of rows){
      if(!original.id||typeof original.id!=='string')throw Object.assign(new Error('Missing source ID'),{status:400});
      let value;
      const origin={backend:'vps',source:run.source,id:original.id};
      if(kind==='room')value={id:key(original.id),title:'[VPS copy] '+(original.title||'Chat'),createdAt:original.createdAt,updatedAt:original.updatedAt,source:'vps-copy',origin};
      else if(kind==='message'){
        if(!original.conversationId||!['user','agent','system'].includes(original.role))throw Object.assign(new Error('Invalid source message'),{status:400});
        if(['pending','streaming'].includes(original.status))continue;
        const metadata={...(original.metadata||{}),origin};
        // Preserve provenance, but never make remote runtime IDs usable on this backend.
        for(const k of ['threadId','turnId','itemId','toolEvents','thoughtSummary'])delete metadata[k];
        value={...original,id:key(original.conversationId+':'+original.id),conversationId:key(original.conversationId),metadata,status:'delivered'};
      }else value={...original,id:key(original.id),origin};
      this.db.prepare('INSERT OR REPLACE INTO import_rows VALUES (?,?,?,?)').run(job,kind,value.id,JSON.stringify(value));
    }
  }
  commitImport(job){
    const run=this.db.prepare('SELECT source FROM imports WHERE id=?').get(job);if(!run)throw Object.assign(new Error('Import not found'),{status:404});
    if(this.db.prepare('SELECT id FROM imports WHERE source=? ORDER BY rowid DESC LIMIT 1').get(run.source)?.id!==job)throw Object.assign(new Error('A newer copy is in progress; this stale copy will not replace it'),{status:409});
    this.db.exec('BEGIN IMMEDIATE');
    try{
      this.db.prepare('DELETE FROM replicas WHERE source=?').run(run.source);
      this.db.prepare('INSERT INTO replicas SELECT ?,kind,id,value FROM import_rows WHERE job=?').run(run.source,job);
      const counts=this.db.prepare('SELECT kind,count(*) AS count FROM import_rows WHERE job=? GROUP BY kind').all(job);
      this.db.prepare('DELETE FROM import_rows WHERE job=?').run(job);this.db.prepare('DELETE FROM imports WHERE id=?').run(job);
      const receipt={source:run.source,completedAt:now(),counts};this.set('lastImport',receipt);this.db.exec('COMMIT');return receipt;
    }catch(e){this.db.exec('ROLLBACK');throw e;}
  }
}
