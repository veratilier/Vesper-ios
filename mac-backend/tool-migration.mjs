// Cold-start compatibility for Codex versions whose thread/resume cannot replace dynamicTools.
// Only the tool registry in an owned Mac rollout header is changed; conversation bytes are retained.
import {DatabaseSync} from 'node:sqlite';
import {existsSync,readdirSync,realpathSync,readFileSync,writeFileSync,renameSync,mkdirSync,openSync,closeSync,fstatSync,constants,unlinkSync} from 'node:fs';
import {join,resolve,sep} from 'node:path';
import {randomUUID} from 'node:crypto';
import {fileTool} from './media.mjs';

export function migrateAttachmentTool({home,store}){
  const codexHome=join(home,'codex');if(!existsSync(codexHome))return {changed:0};
  const stateFile=readdirSync(codexHome).filter(n=>/^state_\d+\.sqlite$/.test(n)).sort((a,b)=>Number(b.match(/\d+/)[0])-Number(a.match(/\d+/)[0]))[0];
  if(!stateFile)return {changed:0};
  const index=new DatabaseSync(join(codexHome,stateFile),{readOnly:true});let changed=0;
  try{
    const owned=store.db.prepare("SELECT DISTINCT json_extract(value,'$.codexThreadId') AS id FROM conversations WHERE deleted=0").all();
    for(const {id} of owned){
      if(!store.owns(id))continue;
      const row=index.prepare('SELECT rollout_path FROM threads WHERE id=?').get(id);if(!row)continue;
      const path=realpathSync(row.rollout_path),root=realpathSync(codexHome);
      if(![join(root,'sessions')+sep,join(root,'archived_sessions')+sep].some(prefix=>path.startsWith(prefix))||path!==resolve(row.rollout_path))throw new Error('Mac tool migration refused a foreign rollout path');
      const fd=openSync(path,constants.O_RDONLY|constants.O_NOFOLLOW);let original;
      try{if(!fstatSync(fd).isFile())throw new Error('Invalid Mac rollout');original=readFileSync(fd);}finally{closeSync(fd);}
      const newline=original.indexOf(10);if(newline<0)throw new Error('Mac rollout header is incomplete');
      const header=JSON.parse(original.subarray(0,newline).toString('utf8'));
      if(header.type!=='session_meta'||header.payload?.id!==id)throw new Error('Mac rollout identity did not match its registered thread');
      const tools=header.payload.dynamic_tools||[];if(!Array.isArray(tools))throw new Error('Invalid persisted Mac tools');
      if(tools.some(t=>t.name===fileTool.name))continue;
      header.payload.dynamic_tools=[...tools,fileTool];
      const backupDirectory=join(home,'tool-migration-backups');mkdirSync(backupDirectory,{recursive:true,mode:0o700});
      const backup=join(backupDirectory,id+'-before-file-tool.jsonl');
      if(!existsSync(backup))writeFileSync(backup,original,{mode:0o600,flag:'wx'});
      const temporary=path+'.tool-migration-'+randomUUID();
      try{
        // Preserve every byte after the first header line, including original messages/timestamps.
        writeFileSync(temporary,Buffer.concat([Buffer.from(JSON.stringify(header)),original.subarray(newline)]),{mode:0o600,flag:'wx'});
        if(!readFileSync(path).equals(original))throw new Error('Mac rollout changed during tool migration');
        renameSync(temporary,path);changed++;
      }finally{if(existsSync(temporary))unlinkSync(temporary);}
    }
  }finally{index.close();}
  return {changed};
}
