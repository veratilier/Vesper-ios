#!/usr/bin/env python3
"""Patch the currently deployed gateway and minute runner without replacing them."""
import argparse
from pathlib import Path


def insert_once(path, old, new, marker):
    text = path.read_text()
    if marker in text:
        return False
    if old not in text:
        raise RuntimeError(f'{path}: expected integration point is missing')
    path.write_text(text.replace(old, new, 1))
    return True


def patch(root):
    routes = root / 'vesper_backend' / 'automation_routes.py'
    runner = root / 'vesper_wake_runner.py'
    insert_once(routes, 'from urllib.parse import urlparse, parse_qs\n',
        'from urllib.parse import urlparse, parse_qs\nimport vesper_scheduled_tasks\n',
        'import vesper_scheduled_tasks')
    insert_once(routes, "    if path == ['wake'] and self.command == 'GET':\n",
        """    if path == ['scheduled-tasks']:
        try:
            if self.command == 'GET':
                self.send_json(200, vesper_scheduled_tasks.list_tasks())
            elif self.command == 'POST':
                body = self.body()
                action = body.get('action')
                if action == 'create':
                    with db() as con:
                        existing = con.execute('SELECT 1 FROM conversations WHERE vesper_conversation_id=? AND archived_at IS NULL',
                                               (body.get('conversationId'),)).fetchone()
                    if not existing:
                        self.send_json(400, {'error': 'Choose an active chat'}); return True
                    self.send_json(200, vesper_scheduled_tasks.create(body))
                elif action == 'update':
                    if 'conversationId' in body:
                        with db() as con:
                            existing = con.execute('SELECT 1 FROM conversations WHERE vesper_conversation_id=? AND archived_at IS NULL',
                                                   (body['conversationId'],)).fetchone()
                        if not existing:
                            self.send_json(400, {'error': 'Choose an active chat'}); return True
                    self.send_json(200, vesper_scheduled_tasks.update(body))
                elif action == 'delete':
                    self.send_json(200, vesper_scheduled_tasks.delete(body))
                else:
                    self.send_json(400, {'error': 'Unknown task action'})
            else:
                self.send_json(405, {'error': 'Method not allowed'})
        except ValueError as error:
            self.send_json(400, {'error': str(error)})
        return True
    if path == ['wake'] and self.command == 'GET':
""", "if path == ['scheduled-tasks']:")
    insert_once(runner, 'import vesper_morning_dream\n',
        'import vesper_morning_dream\nimport vesper_scheduled_tasks\n',
        'import vesper_scheduled_tasks')
    insert_once(runner, 'import vesper_scheduled_tasks\n',
        'import vesper_scheduled_tasks\nimport vesper_daily_quotes\n',
        'import vesper_daily_quotes')
    insert_once(runner, '        try:tick()\n',
        '        vesper_scheduled_tasks.run_due(sys.modules[__name__])\n        try:tick()\n',
        'vesper_scheduled_tasks.run_due(sys.modules[__name__])')
    insert_once(runner, '        vesper_scheduled_tasks.run_due(sys.modules[__name__])\n',
        '        vesper_scheduled_tasks.run_due(sys.modules[__name__])\n'
        '        try:vesper_daily_quotes.run_due(sys.modules[__name__])\n'
        '        except Exception as error: print("Daily quote tick:", str(error)[:200], file=sys.stderr)\n',
        'vesper_daily_quotes.run_due(sys.modules[__name__])')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    patch(parser.parse_args().root)
