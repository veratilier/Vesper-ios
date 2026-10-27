"""Apply narrow checked changes to the deployed wake runner and presentation."""
from pathlib import Path
import json
import shutil
import time
import os

DREAM_PRESENTATION = '''    if job.get('source') == 'morning-dream':
        status = job['status']
        outcome = ('running' if status in {'queued', 'running'} else
                   'failure' if status == 'failed' else 'partial_failure' if status == 'push_failed' else
                   'silent' if status == 'silent' else 'interrupted' if status in {'cancelled', 'interrupted'} else
                   'success' if status == 'completed' or (status == 'saved' and job.get('finished') and job.get('notification')) else 'unknown')
        if status == 'saved' and outcome == 'success':
            summary = '梦已保存，早安消息已写入聊天；系统通知尚待送达。'
        elif status == 'push_failed':
            summary = '梦已保存，早安消息已写入聊天；系统通知未确认送达。'
        elif status == 'completed':
            receipt = job.get('push_json')
            try: receipt = json.loads(receipt) if isinstance(receipt, str) else (receipt or {})
            except (ValueError, TypeError): receipt = {}
            summary = ('梦已保存，早安消息已写入聊天；已过通知时效，不再补发。'
                       if receipt.get('status') == 'skipped_expired' else '梦已保存，早安消息已写入聊天。')
        elif status == 'silent':
            summary = '梦已保存；聊天消息未授权，本轮保持安静。'
        elif outcome == 'running':
            summary = '梦与早安消息正在准备。'
        else:
            summary = '晨间梦未完成。'
        return {'title': '晨间的梦', 'summary': summary,
                'outcome': outcome, 'silentReason': job.get('silent_reason') or ''}
'''


def replace_once(text, old, new):
    if new in text:
        return text
    if text.count(old) != 1:
        raise RuntimeError('Unexpected runtime source; refusing replacement: ' + old[:80])
    return text.replace(old, new, 1)


def transform_runner(text):
    text = replace_once(text, 'import vesper_morning_dream\n', 'import vesper_morning_dream\nimport vesper_wake_delivery as delivery\n')
    text = replace_once(text,
        'if r.returncode or not status.startswith(\'2\'):raise RuntimeError(f\'HTTP {path.split("?")[0]} failed ({status or "network"})\')',
        "if r.returncode or not status.startswith('2'):raise delivery.HTTPFailure(path, status)")
    old = '''def deliver(ident,message):
    if sleep_gate(time.time()):return
    if 'text' not in store.access()['messages']:return
    with store.db() as con:job=dict(con.execute('SELECT * FROM jobs WHERE id=?',(ident,)).fetchone())'''
    new = '''def deliver(ident,message):
    with store.db() as con:job=dict(con.execute('SELECT * FROM jobs WHERE id=?',(ident,)).fetchone())
    if delivery.expired_dream(job, time.time()):
        update(ident,status='completed',push_json=json.dumps({'status':'skipped_expired','reason':'Greeting already saved in chat; push expired'}),error=None)
        return
    if sleep_gate(time.time()):return
    if 'text' not in store.access()['messages']:return'''
    text = replace_once(text, old, new)
    text = replace_once(text,
        "    receipt=http('/api/wake',{'requestId':ident,'message':message,'conversationId':job['conversation_id']})",
        """    try:
        receipt=http('/api/wake',{'requestId':delivery.request_id(ident),'message':message,'conversationId':job['conversation_id']})
    except Exception as error:
        permanent = isinstance(error, delivery.HTTPFailure) and error.permanent
        update(ident,status='push_failed' if permanent else 'saved',error=str(error)[:220],
               push_json=json.dumps({'status':'failed' if permanent else 'retry_pending','httpStatus':getattr(error,'status',None)}))
        return""")
    return text


def transform_workflow(text):
    if DREAM_PRESENTATION in text:
        return text
    start = text.index("    if job.get('source') == 'morning-dream':")
    end = text.index('    meaningful =', start)
    if "'running' if status in {'queued', 'running', 'saved'}" not in text[start:end]:
        raise RuntimeError('Unexpected dream presentation')
    return 'import json\n' + text[:start] + DREAM_PRESENTATION + text[end:]


def install(root, bundle):
    changes = {
        root/'vesper_wake_runner.py': transform_runner((root/'vesper_wake_runner.py').read_text()),
        root/'vesper_wake_workflow.py': transform_workflow((root/'vesper_wake_workflow.py').read_text()),
        root/'vesper_wake_delivery.py': (bundle/'vesper_wake_delivery.py').read_text(),
    }
    # Surface notification receipt separately from the completed dream.
    path = root/'vesper_wake_store.py'
    changes[path] = replace_once(path.read_text(), "job['calls'] = calls\n        job.update(workflow.describe(job, calls))",
        "job['calls'] = calls\n        job['push_json'] = original['push_json']\n        job.update(workflow.describe(job, calls))\n        job.pop('push_json', None)")
    for path, content in changes.items(): compile(content, str(path), 'exec')
    backup = root/'deploy-backups'/('dream-workflow-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True)
    for path, content in changes.items():
        if path.exists(): shutil.copy2(path, backup/path.name)
        temporary = path.with_name(path.name+'.installing')
        temporary.write_text(content); temporary.chmod(0o600); os.replace(temporary, path)
    print(json.dumps({'backup':str(backup), 'changed':[p.name for p in changes]}))


if __name__ == '__main__':
    install(Path.home()/'vesper-codex-history', Path(__file__).parent)
