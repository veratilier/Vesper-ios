"""Stage the gateway path, then explicitly activate or roll back the root route.

Run on the VPS as root. Every edit makes a timestamped backup and validates Nginx
before reloading. The original app-server and history locations remain intact.
"""
from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import shutil
import subprocess

SITES = [pathlib.Path('/etc/nginx/sites-enabled/codex-auth'),
         pathlib.Path('/etc/nginx/sites-enabled/codex')]
BACKUP_DIR = pathlib.Path('/etc/nginx/gateway-backups')
MARKER = '# Vesper gateway canary'
CANARY = '''    # Vesper gateway canary
    location = /gateway {
        access_log off;
        proxy_pass http://127.0.0.1:4520;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Authorization "Bearer $arg_token";
        proxy_set_header Origin "";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
    location = /gateway/health {
        access_log off;
        proxy_pass http://127.0.0.1:4520/gateway/health;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 3s;
        proxy_buffering off;
    }

'''


def change(contents: str, action: str) -> str:
    if action == 'canary':
        if MARKER in contents:
            return contents
        needle = '    location / {\n'
        if needle not in contents:
            raise ValueError('Root location not found')
        return contents.replace(needle, CANARY + needle, 1)
    if MARKER not in contents:
        raise ValueError('Canary must be installed before route activation')
    if action == 'activate':
        old, new = ':4500;', ':4520;'
    else:
        old, new = ':4520;', ':4500;'
    pattern = re.compile(r'(    location / \{\n\s*proxy_pass http://127\.0\.0\.1)' + re.escape(old))
    result, count = pattern.subn(lambda match: match.group(1) + new, contents, count=1)
    if count == 0 and not re.search(r'    location / \{\n\s*proxy_pass http://127\.0\.0\.1' + re.escape(new), contents):
        raise ValueError('Unexpected root proxy target')
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['canary', 'activate', 'rollback'])
    args = parser.parse_args()
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backups: dict[pathlib.Path, pathlib.Path] = {}
    try:
        BACKUP_DIR.mkdir(exist_ok=True)
        for path in SITES:
            old = path.read_text()
            new = change(old, args.action)
            if new == old:
                continue
            backup = BACKUP_DIR / (path.name + '.gateway-' + timestamp + '.bak')
            shutil.copy2(path, backup)
            backups[path] = backup
            path.write_text(new)
        subprocess.run(['nginx', '-t'], check=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
    except Exception:
        for path, backup in backups.items():
            shutil.copy2(backup, path)
        subprocess.run(['nginx', '-t'], check=False)
        raise
    print(f'{args.action}: nginx verified and reloaded')


if __name__ == '__main__':
    main()
