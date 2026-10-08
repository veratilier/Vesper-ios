"""Install the dedicated Mac backend and tunnel as login LaunchAgents; preserve existing services."""
import json,os,plistlib,secrets,shutil,subprocess
from pathlib import Path

source=Path(__file__).resolve().parent
home=Path.home()/'Library/Application Support/VesperBackend'
home.mkdir(parents=True,exist_ok=True,mode=0o700)
os.chmod(home,0o700)
runtime=home/'service';runtime.mkdir(exist_ok=True)
for name in ['server.mjs','storage.mjs','package.json','package-lock.json']:
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
