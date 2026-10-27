"""Run on the VPS with this directory uploaded. Backs up and patches exact known hooks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import time


def patches(root):
    return [
        (root / 'vesper_backend/router.py',
         'ROUTES = (',
         "from . import agent_instructions_routes\nROUTES = (('agent-instructions', agent_instructions_routes.dispatch), "),
        (root / 'vesper_backend/codex_provider.py',
         'from pathlib import Path\n',
         'from pathlib import Path\nfrom vesper_agent_instructions import prepare as prepare_agent_instructions\n'),
        (root / 'vesper_backend/codex_provider.py',
         '    def call(self,method,params,timeout=90):\n',
         '    def call(self,method,params,timeout=90):\n        params = prepare_agent_instructions(method, params)\n'),
        (root / 'vesper_morning_dream.py',
         "snapshot = rpc.call('thread/resume', {'threadId': selected['thread_id'], 'dynamicTools': tools,",
         "snapshot = rpc.call('thread/resume', {'threadId': selected['thread_id'], 'dynamicTools': tools,\n                                  'developerInstructions': '延续当前聊天中与 Vera 的称呼和相处方式。此次是睡眠结束后的梦境与问候；遵循本轮梦境保存和简短问候要求，不将梦当成真实经历。仅使用此次实际提供的工具。',"),
    ]


def install(root, agents, bundle):
    changes = {}
    for path, old, new in patches(root):
        text = changes.get(path, path.read_text())
        if new in text:
            continue
        if text.count(old) != 1:
            raise RuntimeError('Unexpected source; refusing to overwrite: ' + str(path))
        changes[path] = text.replace(old, new, 1)
    for path, text in changes.items():
        compile(text, str(path), 'exec')
    changes[root / 'vesper_agent_instructions.py'] = (bundle / 'vesper_agent_instructions.py').read_text()
    changes[root / 'vesper_backend/agent_instructions_routes.py'] = (bundle / 'agent_instructions_routes.py').read_text()
    # Reinstalling code must never erase the owner's subsequent AGENTS.md edits.
    if not agents.exists():
        changes[agents] = (bundle / 'AGENTS.md').read_text()
    backup = root / 'deploy-backups' / ('agent-instructions-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True, exist_ok=False)
    manifest = []
    for index, (path, text) in enumerate(changes.items()):
        existed = path.exists()
        saved = backup / str(index)
        if existed:
            shutil.copy2(path, saved)
        manifest.append({'path': str(path), 'backup': str(saved) if existed else None,
                         'sha256': hashlib.sha256(text.encode()).hexdigest()})
    (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    for path, text in changes.items():
        temporary = path.with_name(path.name + '.installing')
        temporary.write_text(text)
        temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
        os.replace(temporary, path)
    print(json.dumps({'backup': str(backup), 'changed': [str(p) for p in changes]}, indent=2))


if __name__ == '__main__':
    install(Path.home() / 'vesper-codex-history', Path.home() / 'AGENTS.md', Path(__file__).parent)
