import {constants} from 'node:fs';
import {mkdir,open,realpath,writeFile,rename,unlink} from 'node:fs/promises';
import {join,resolve,basename,extname,sep} from 'node:path';
import {homedir} from 'node:os';
import {createHmac,randomUUID} from 'node:crypto';

const MiB=1024*1024;
const error=(message,status=400)=>Object.assign(new Error(message),{status});
const inside=(file,root)=>file===root||file.startsWith(root+sep);
const safeName=value=>String(value||'').replace(/[\r\n\0/\\"]/g,'_').slice(0,160);
const types={'.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.webp':'image/webp','.avif':'image/avif','.heic':'image/heic','.pdf':'application/pdf','.txt':'text/plain','.md':'text/markdown','.json':'application/json','.csv':'text/csv','.mp3':'audio/mpeg','.m4a':'audio/mp4','.wav':'audio/wav','.ogg':'audio/ogg','.mp4':'video/mp4','.webm':'video/webm'};
function imageType(bytes){
  if(bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))return 'image/png';
  if(bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255)return 'image/jpeg';
  if(/^GIF8[79]a$/.test(bytes.subarray(0,6).toString('ascii')))return 'image/gif';
  if(bytes.subarray(0,4).toString()==='RIFF'&&bytes.subarray(8,12).toString()==='WEBP')return 'image/webp';
  if(bytes.subarray(4,8).toString()==='ftyp'){
    const brand=bytes.subarray(8,12).toString();
    if(['avif','avis'].includes(brand))return 'image/avif';
    if(['heic','heix','hevc','hevx','mif1'].includes(brand))return 'image/heic';
  }
}

export const fileTool={type:'function',name:'send_chat_file',
  description:'Send real files or images to Vera as Vesper chat attachments (up to 8 MiB per file, 1–8 files). Supply exactly one of path, text or base64 for each file. Prefer path for a real Mac file, screenshot or generated image; this transfers the actual bytes without printing base64. Use the absolute file path, a path relative to the Mac workspace, or the filename for an image generated under CODEX_HOME/generated_images/<current-thread-id>/. Full Access permits user-requested documents outside the workspace. Generated images must belong to this Mac thread. Supply name, optionally mimeType and a short message. For Markdown supply .md and the complete text. Images sent together are grouped by the existing Vesper client. A Markdown local path does not deliver a file to the phone. Never send credentials or private configuration. Confirm delivery only after success.',
  inputSchema:{type:'object',additionalProperties:false,properties:{files:{type:'array',minItems:1,maxItems:8,items:{type:'object',additionalProperties:false,properties:{name:{type:'string'},mimeType:{type:'string'},path:{type:'string'},text:{type:'string'},base64:{type:'string'}},required:['name']}},message:{type:'string'}},required:['files']}};

export class Media {
  constructor({home,workspace,store,token,fullAccess}){
    Object.assign(this,{home,workspace,store,token,fullAccess});this.directory=join(home,'media');
    store.db.exec('CREATE TABLE IF NOT EXISTS media(key TEXT PRIMARY KEY,value TEXT NOT NULL)');
  }
  descriptor(key){const row=this.store.db.prepare('SELECT value FROM media WHERE key=?').get(key);return row?JSON.parse(row.value):null;}
  attachment(record,origin){return {...record,url:origin+'/api/media/'+record.key};}
  async put(bytes,input,origin,{maxSize=8*MiB}={}){
    const name=safeName(input.name);if(!name)throw error('File name required');
    if(bytes.length>maxSize)throw error('File exceeds '+maxSize/MiB+' MiB',413);
    const detected=imageType(bytes),requested=String(input.mimeType||types[extname(name).toLowerCase()]||'application/octet-stream').toLowerCase();
    if(requested.startsWith('image/')&&!detected)throw error('File is not a supported image');
    const type=detected||(/^(text\/(plain|markdown|csv)|application\/(pdf|json)|audio\/[a-z0-9.+-]+|video\/(mp4|webm))$/.test(requested)?requested:'application/octet-stream');
    const extension=extname(name).slice(1).replace(/[^a-z0-9]/gi,'').slice(0,12).toLowerCase()||'bin';
    const key=createHmac('sha256',this.token).update(name+'\0'+type+'\0').update(bytes).digest('hex')+'.'+extension;
    await mkdir(this.directory,{recursive:true,mode:0o700});
    const temporary=join(this.directory,'.'+randomUUID());
    try{await writeFile(temporary,bytes,{mode:0o600,flag:'wx'});await rename(temporary,join(this.directory,key));}
    finally{await unlink(temporary).catch(()=>{});}
    const record={key,name,type,size:bytes.length};this.store.db.prepare('INSERT OR REPLACE INTO media VALUES (?,?)').run(key,JSON.stringify(record));
    return this.attachment(record,origin);
  }
  async pathBytes(path,threadId){
    if(typeof path!=='string'||!path||path.includes('\0'))throw error('Invalid file path');
    const home=await realpath(this.home),generated=join(home,'codex','generated_images');
    // VPS-style generated-image shorthand resolves to this backend's independent CODEX_HOME.
    if(path.startsWith('~/.codex/generated_images/'))path=join(generated,path.slice('~/.codex/generated_images/'.length));
    else if(path.startsWith('~/'))path=join(homedir(),path.slice(2));
    else if(!path.includes('/')&&threadId){
      const candidate=join(generated,threadId,path);
      try{path=await realpath(candidate);}catch{path=resolve(this.workspace,path);}
    }else path=resolve(this.workspace,path);
    const requestedIndex=path.split(sep).lastIndexOf('generated_images');
    if(requestedIndex!==-1&&(!threadId||path.split(sep)[requestedIndex+1]!==threadId))throw error('Generated image must belong to the current Mac conversation',409);
    let actual;try{actual=await realpath(path);}catch{throw error('File not found',404);}
    const generatedIndex=actual.split(sep).lastIndexOf('generated_images');
    if(generatedIndex!==-1){
      if(!threadId||actual.split(sep)[generatedIndex+1]!==threadId||!inside(actual,join(generated,threadId)))throw error('Generated image must belong to the current Mac conversation',409);
    }
    const workspace=await realpath(this.workspace);
    const allowedGenerated=threadId&&inside(actual,join(generated,threadId));
    if(!this.fullAccess&&!inside(actual,workspace)&&!allowedGenerated)throw error('File is outside this backend workspace',403);
    const components=actual.split(sep);
    if((inside(actual,home)&&!inside(actual,workspace)&&!allowedGenerated)||
       components.some(p=>['.ssh','.aws','.gnupg','.config','.env','.DS_Store','Keychains'].includes(p))||
       (inside(actual,join(homedir(),'.codex'))&&!allowedGenerated)||
       /^(auth\.json|device-token|config\.toml|\.env(?:\..*)?|.*\.(?:key|pem|p12|mobileprovision))$/i.test(basename(actual)))throw error('Private credentials or backend configuration cannot be sent',403);
    const handle=await open(actual,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
    try{
      const stat=await handle.stat();if(!stat.isFile())throw error('Choose a regular file');
      if(stat.size>8*MiB)throw error('File exceeds 8 MiB',413);
      // Bound reads even if a file grows after stat; never buffer a device or FIFO.
      const bytes=Buffer.alloc(Math.min(stat.size+1,8*MiB+1));let length=0;
      while(length<bytes.length){const result=await handle.read(bytes,length,bytes.length-length,null);if(!result.bytesRead)break;length+=result.bytesRead;}
      if(length!==stat.size)throw error('File changed while being read; retry');
      return bytes.subarray(0,length);
    }finally{await handle.close();}
  }
  async deliver(input,context){
    const room=this.store.room(context.conversationId);
    if(!room||!context.threadId||room.codexThreadId!==context.threadId)throw error('Use the current Mac conversation and thread',409);
    this.store.requireThread(context.threadId);
    if(!Array.isArray(input.files)||input.files.length<1||input.files.length>8)throw error('Send between 1 and 8 files');
    const files=[];
    // Validate and read the whole batch before publishing any attachment.
    for(const file of input.files){
      if(!file||typeof file!=='object'||Array.isArray(file)||!safeName(file.name))throw error('File name required');
      if(['path','text','base64'].filter(k=>file[k]!==undefined).length!==1)throw error('Supply exactly one of path, text or base64');
      let bytes;
      if(file.path!==undefined)bytes=await this.pathBytes(file.path,context.threadId);
      else if(typeof file.text==='string'){if(file.text.length>8*MiB)throw error('File exceeds 8 MiB',413);bytes=Buffer.from(file.text);}
      else if(typeof file.base64==='string'){
        if(file.base64.length>12*MiB)throw error('File exceeds 8 MiB',413);
        if(file.base64.length%4||!/^[A-Za-z0-9+/]*={0,2}$/.test(file.base64))throw error('Invalid base64');
        bytes=Buffer.from(file.base64,'base64');
      }else throw error('Invalid file contents');
      if(bytes.length>8*MiB)throw error('File exceeds 8 MiB',413);
      if(String(file.mimeType||types[extname(file.name).toLowerCase()]||'').startsWith('image/')&&!imageType(bytes))throw error('File is not a supported image');
      files.push({bytes,file});
    }
    const attachments=[];for(const {bytes,file} of files)attachments.push(await this.put(bytes,file,context.origin));
    const message=String(input.message||'').slice(0,2000),result={attachments,message};
    const callID=String(context.itemId||randomUUID()),id='files:'+context.threadId+':'+callID;
    this.store.saveMessage(room.id,{id,role:'agent',content:message||'文件',createdAt:new Date().toISOString(),status:'delivered',source:'codex',metadata:{attachments,attachmentOnly:!message,itemId:id,threadId:context.threadId,turnId:context.turnId,blockType:'agentMessage',showTurnStatus:false}});
    return result;
  }
  async upload(req,origin){
    const chunks=[];let size=0;
    for await(const chunk of req){size+=chunk.length;if(size>33*MiB)throw error('Upload exceeds 32 MiB',413);chunks.push(chunk);}
    const request=new Request('http://local/upload',{method:'POST',headers:{'content-type':req.headers['content-type']||''},body:Buffer.concat(chunks)});
    let form;try{form=await request.formData();}catch{throw error('Invalid upload form');}
    const file=form.get('file');if(!file||typeof file.arrayBuffer!=='function')throw error('File required');
    return this.put(Buffer.from(await file.arrayBuffer()),{name:file.name,mimeType:file.type},origin,{maxSize:32*MiB});
  }
  async serve(key,req,res){
    if(!/^[a-f0-9]{64}\.[a-z0-9]{1,12}$/.test(key))throw error('File not found',404);
    const record=this.descriptor(key);if(!record)throw error('File not found',404);
    let handle;try{handle=await open(join(this.directory,key),constants.O_RDONLY|constants.O_NOFOLLOW);}catch{throw error('File not found',404);}
    const inline=/^(image\/(png|jpeg|gif|webp|avif|heic)|audio\/|video\/)/.test(record.type);
    res.writeHead(200,{'Content-Type':record.type,'Content-Length':record.size,'Content-Disposition':`${inline?'inline':'attachment'}; filename*=UTF-8''${encodeURIComponent(record.name)}`,'X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; sandbox",'Cache-Control':'public, max-age=31536000, immutable','ETag':'"'+key+'"'});
    if(req.method==='HEAD'){await handle.close();res.end();return;}
    const stream=handle.createReadStream();stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);
  }
}
