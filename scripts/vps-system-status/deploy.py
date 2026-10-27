"""Install the read-only Studio metrics route beside the live history gateway."""

from pathlib import Path
import shutil
import time

root = Path('/home/ubuntu/vesper-codex-history')
router = root / 'vesper_backend/router.py'
source = router.read_text()
old_import = 'from . import agent_instructions_routes\n'
old_routes = "ROUTES = (('agent-instructions', agent_instructions_routes.dispatch),"
assert source.count(old_import) == 1 and source.count(old_routes) == 1
backup = root / 'deploy-backups' / f'system-status-router-{int(time.time())}.py'
shutil.copy2(router, backup)
shutil.copy2('/tmp/vesper_system_status_routes.py', root / 'vesper_backend/system_status_routes.py')
router.write_text(source.replace(old_import, 'from . import agent_instructions_routes, system_status_routes\n')
                   .replace(old_routes, "ROUTES = (('system-status', system_status_routes.dispatch), ('agent-instructions', agent_instructions_routes.dispatch),"))
print(f'Installed Studio metrics route; backup: {backup}')
