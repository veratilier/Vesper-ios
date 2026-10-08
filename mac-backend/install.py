"""Install the dedicated Mac backend and tunnel as login LaunchAgents; preserve existing services."""
import json,os,plistlib,secrets,shutil,subprocess,sys,re
from shlex import quote as shlex_quote
from pathlib import Path

source=Path(__file__).resolve().parent
home=Path.home()/'Library/Application Support/VesperBackend'
home.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(home,0o700)
runtime=home/'service';runtime.mkdir(exist_ok=True)
for name in ['server.mjs','storage.mjs','media.mjs','tool-migration.mjs','watch.mjs','package.json','package-lock.json']:
    shutil.copy2(source/name,runtime/name)
subprocess.run(['npm','ci','--ignore-scripts','--omit=dev'],cwd=runtime,check=True)
token=home/'device-token'
if not token.exists():token.write_text(secrets.token_urlsafe(48))
os.chmod(token,0o600)
codex_home=home/'codex';codex_home.mkdir(exist_ok=True,mode=0o700)
auth=codex_home/'auth.json'
if not auth.exists():auth.symlink_to(Path.home()/'.codex/auth.json')
config=codex_home/'config.toml'
if not config.exists():
    config.write_text('model = "gpt-6.1-sol"\nmodel_reasoning_effort = "medium"\nweb_search = "live"\n[features]\napps = false\nplugins = false\n')
    os.chmod(config,0o600)
access=home/'access.json'
if '--full-access' in sys.argv:
    access.write_text(json.dumps({'mode':'full','computerUse':True}));os.chmod(access,0o600)
if access.exists() and json.loads(access.read_text()).get('mode')=='full':
    text=config.read_text()
    for key,value in [('sandbox_mode','danger-full-access'),('approval_policy','never')]:
        pattern=r'^'+key+r'\s*=.*$'
        if re.search(pattern,text,re.M):text=re.sub(pattern,key+' = "'+value+'"',text,flags=re.M)
        else:text=key+' = "'+value+'"\n'+text
    device=shutil.which('agent-device') or str(Path.home()/'.local/bin/agent-device')
    if not Path(device).exists():raise RuntimeError('Install agent-device before enabling Mac computer use')
    if '[mcp_servers.vesper_computer]' not in text:
        text+='\n[mcp_servers.vesper_computer]\ncommand = '+json.dumps(device)+'\nargs = ["mcp"]\nstartup_timeout_sec = 20\ntool_timeout_sec = 90\n'
    if '[mcp_servers.vesper_computer.env]' not in text:
        candidates=[Path(os.environ.get('DEVELOPER_DIR','/nonexistent')),Path('/Applications/Xcode.app/Contents/Developer'),Path.home()/'Downloads/Xcode-beta.app/Contents/Developer']
        developer=next((p for p in candidates if p.exists()),None)
        text+='\n[mcp_servers.vesper_computer.env]\nAGENT_DEVICE_STATE_DIR = '+json.dumps(str(home/'computer'))+'\nAGENT_DEVICE_PLATFORM = "macos"\nAGENT_DEVICE_SESSION = "vesper-rowan"\n'
        if developer:text+='DEVELOPER_DIR = '+json.dumps(str(developer))+'\n'
    config.write_text(text);os.chmod(config,0o600)
    skill=Path.home()/'.codex/skills/agent-device'
    if skill.exists():shutil.copytree(skill,codex_home/'skills/agent-device',dirs_exist_ok=True)
bin_dir=Path.home()/'.local/bin';bin_dir.mkdir(parents=True,exist_ok=True)
viewer=bin_dir/'vesper-watch'
viewer.write_text('#!/bin/sh\nexec '+shlex_quote(shutil.which('node'))+' '+shlex_quote(str(runtime/'watch.mjs'))+' "$@"\n')
os.chmod(viewer,0o700)
tunnel_id='c1ae531e-fbd6-454f-a434-c267285821ca'
tunnel=home/'tunnel.json'
tunnel.write_text(json.dumps({'tunnel':tunnel_id,'credentials-file':str(Path.home()/'.cloudflared'/f'{tunnel_id}.json'),'ingress':[{'hostname':'mac-vesper.r-vera.com','service':'http://127.0.0.1:47631'},{'service':'http_status:404'}]}))
os.chmod(tunnel,0o600)
pair=home/'Mac connection.txt'
pair.write_text('Vesper Mac backup — private pairing information\n\nAPI: https://mac-vesper.r-vera.com\nHistory: https://mac-vesper.r-vera.com/history\nChat: wss://mac-vesper.r-vera.com/chat\nDevice token: '+token.read_text().strip()+'\n\nKeep this file private. It authorizes access to this backend.\n')
os.chmod(pair,0o600)
agents=Path.home()/'Library/LaunchAgents';agents.mkdir(exist_ok=True)
entries=[('com.vera.vesper.mac-backend',[shutil.which('node'),str(runtime/'server.mjs')],{'VESPER_BACKEND_HOME':str(home),'VESPER_CODEX_BIN':shutil.which('codex'),'PATH':os.environ['PATH']}),
         ('com.vera.vesper.mac-tunnel',[shutil.which('cloudflared'),'tunnel','--config',str(tunnel),'run',tunnel_id],{})]
for name,args,env in entries:
    target=agents/f'{name}.plist'
    value={'Label':name,'ProgramArguments':args,'EnvironmentVariables':env,'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'WorkingDirectory':str(home),'StandardOutPath':str(home/f'{name}.log'),'StandardErrorPath':str(home/f'{name}.error.log')}
    target.write_bytes(plistlib.dumps(value));os.chmod(target,0o600)
    subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(target)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(target)],check=True)
print('Installed independent Mac backend and tunnel. Pairing credentials saved in private Application Support file.')
