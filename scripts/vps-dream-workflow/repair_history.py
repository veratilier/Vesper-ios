"""Expire only verified old morning pushes; never edits dreams or chat messages."""
import json
import sqlite3
import time
from pathlib import Path


def repair(wake_path, history_path, backup_dir):
    now=time.time()
    wake=sqlite3.connect(wake_path);wake.row_factory=sqlite3.Row
    history=sqlite3.connect('file:'+str(history_path)+'?mode=ro',uri=True);history.row_factory=sqlite3.Row
    backup_dir.mkdir(parents=True,exist_ok=True);backup_dir.chmod(0o700)
    backup_path=backup_dir/'wake-before-repair.sqlite3'
    with sqlite3.connect(backup_path) as destination: wake.backup(destination)
    backup_path.chmod(0o600)
    repaired=[]
    try:
        with wake:
            wake.execute('BEGIN IMMEDIATE')
            for row in wake.execute("SELECT * FROM jobs WHERE source='morning-dream' AND status='saved' AND finished<=?",(now-1800,)).fetchall():
                cycle=wake.execute("SELECT * FROM sleep_cycles WHERE id=? AND status='saved' AND memory_id IS NOT NULL",(row['id'].removeprefix('dream:'),)).fetchone()
                if not cycle or not cycle['body'] or not row['notification']: continue
                messages=history.execute("SELECT content,metadata_json FROM messages WHERE vesper_conversation_id=? AND role='agent' AND turn_id=?",(row['conversation_id'],row['turn_id'])).fetchall()
                confirmed=any(m['content']==row['notification'] and json.loads(m['metadata_json'] or '{}').get('wakeRunId')==row['id'] for m in messages)
                if not confirmed: continue
                receipt=json.dumps({'status':'skipped_expired','reason':'Dream and greeting verified saved; old push not replayed'})
                wake.execute("UPDATE jobs SET status='completed',push_json=?,error=NULL WHERE id=? AND status='saved'",(receipt,row['id']))
                repaired.append(row['id'])
        return repaired
    finally:
        wake.close();history.close()


if __name__=='__main__':
    root=Path.home()
    backup=root/'vesper-codex-history/deploy-backups'/('dream-records-'+time.strftime('%Y%m%d-%H%M%S'))
    print(json.dumps({'repaired':repair(root/'.vesper/wake.sqlite3',root/'.vesper/chat-history.sqlite3',backup), 'backup':str(backup)}))
