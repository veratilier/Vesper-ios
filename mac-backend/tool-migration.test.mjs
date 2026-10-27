import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync,realpathSync,symlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {Store} from './storage.mjs';
import {migrateAttachmentTool} from './tool-migration.mjs';

test('cold migration registers files for owned old threads, preserves original transcript and remains idempotent',t=>{
  const home=realpathSync(mkdtempSync(join(tmpdir(),'vesper-tool-upgrade-'))),store=new Store(home);
  mkdirSync(join(home,'codex','sessions'),{recursive:true});
  const index=new DatabaseSync(join(home,'codex','state_5.sqlite'));index.exec('CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT)');
  t.after(()=>{index.close();store.db.close();rmSync(home,{recursive:true,force:true});});
  const tail='\n'+JSON.stringify({type:'response_item',payload:{text:'Exact old 中文 messages, tool events and timestamps'}})+'\n';
  const oldTool={name:'send_native_voice',description:'Preserve native tools',inputSchema:{type:'object'}};
  const seed=(id,owned)=>{
    const path=join(home,'codex','sessions',id+'.jsonl'),text=JSON.stringify({type:'session_meta',payload:{id,cwd:'/existing/cwd',dynamic_tools:[oldTool]}})+tail;
    writeFileSync(path,text);index.prepare('INSERT INTO threads VALUES (?,?)').run(id,path);
    if(owned){store.register(id);store.saveRoom('room-'+id,{codexThreadId:id});}return {path,text};
  };
  const local=seed('old-mac-thread',true),foreign=seed('vps-or-desktop-thread',false);
  assert.deepEqual(migrateAttachmentTool({home,store}),{changed:1});
  const bytes=readFileSync(local.path),split=bytes.indexOf(10),header=JSON.parse(bytes.subarray(0,split));
  assert.equal(header.payload.id,'old-mac-thread');assert.equal(header.payload.cwd,'/existing/cwd');assert.deepEqual(header.payload.dynamic_tools[0],oldTool);
  assert.equal(header.payload.dynamic_tools[1].name,'send_chat_file');assert.equal(bytes.subarray(split).toString(),tail);
  assert.equal(readFileSync(join(home,'tool-migration-backups','old-mac-thread-before-file-tool.jsonl'),'utf8'),local.text);
  assert.equal(readFileSync(foreign.path,'utf8'),foreign.text);
  assert.deepEqual(migrateAttachmentTool({home,store}),{changed:0});assert.deepEqual(readFileSync(local.path),bytes);
  const untrusted=seed('invalid-thread',true);writeFileSync(untrusted.path,JSON.stringify({type:'session_meta',payload:{id:'other-id',dynamic_tools:[]}})+tail);
  assert.throws(()=>migrateAttachmentTool({home,store}),/identity/);
  const outside=join(home,'outside.jsonl');writeFileSync(outside,untrusted.text);index.prepare('UPDATE threads SET rollout_path=? WHERE id=?').run(outside,'invalid-thread');
  assert.throws(()=>migrateAttachmentTool({home,store}),/foreign rollout/);
  const alias=join(home,'codex','sessions','alias.jsonl');symlinkSync(outside,alias);index.prepare('UPDATE threads SET rollout_path=? WHERE id=?').run(alias,'invalid-thread');
  assert.throws(()=>migrateAttachmentTool({home,store}),/foreign rollout/);
});
