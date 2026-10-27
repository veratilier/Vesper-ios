"""Read completed public items from the existing Codex rollout; no new runtime or log copies."""
import json
import re
import sqlite3
import threading
import uuid
from collections import OrderedDict
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
import vesper_conversation_delete as deletion

LOCK = threading.Lock()
CACHE = OrderedDict()
MAX_ITEMS = 10000
NATIVE_WAKE_HEADER = 'Earlier assistant messages from autonomous wakes in this same conversation.'


def collapse_wake_context(text):
    """Collapse only Vesper's quoted JSON context in the read-only pane display."""
    pattern = r'(?m)^[ \t•›>]*' + re.escape(NATIVE_WAKE_HEADER).replace(r'\ ', r'\s+')
    position = 0
    while match := re.search(pattern, text[position:]):
        start, header_end = position + match.start(), position + match.end()
        array = text.find('[', header_end, header_end + 1200)
        if array < 0:
            break
        depth, quoted, escaped, end = 0, False, False, None
        for index in range(array, min(len(text), array + 18000)):
            char = text[index]
            if escaped:
                escaped = False
            elif quoted and char == '\\':
                escaped = True
            elif char == '"':
                quoted = not quoted
            elif not quoted:
                if char == '[': depth += 1
                elif char == ']':
                    depth -= 1
                    if depth == 0: end = index + 1; break
        if end is None:
            break  # An incomplete/unrecognized pane region is retained verbatim.
        replacement = '[Vesper wake context collapsed]\n'
        text = text[:start] + replacement + text[end:]
        position = start + len(replacement)
    return text


def records(thread_id):
    ident = str(uuid.UUID(thread_id))
    home = deletion.CODEX_HOME.resolve()
    with closing(sqlite3.connect(f"file:{home / 'state_5.sqlite'}?mode=ro", uri=True)) as con:
        row = con.execute('SELECT rollout_path FROM threads WHERE id=?', (ident,)).fetchone()
    if not row:
        raise ValueError('Codex source history is unavailable for this chat')
    path = Path(row[0]).resolve()
    if not any(path.is_relative_to(home / folder) for folder in ('sessions', 'archived_sessions')):
        raise ValueError('Codex source history path is outside its session storage')
    with LOCK, path.open('rb') as stream:
        stat = path.stat()
        state = CACHE.get(ident)
        if not state or state['file'] != (str(path), stat.st_ino) or stat.st_size < state['offset']:
            state = {'file': (str(path), stat.st_ino), 'offset': 0, 'items': OrderedDict(), 'bytes': 0, 'truncated': False}
        stream.seek(state['offset'])
        while line := stream.readline():
            if not line.endswith(b'\n'):
                break  # Retry a currently-being-written item on the next read.
            state['offset'] = stream.tell()
            try:
                event = json.loads(line)
                payload = event.get('payload', {})
                if event.get('type') != 'event_msg' or payload.get('type') != 'item_completed' or payload.get('thread_id') != ident:
                    continue
                item = payload.get('item', {})
                kind, item_id = item.get('type'), item.get('id')
                if not item_id or kind not in ('AgentMessage', 'UserMessage', 'CommandExecution', 'FileChange', 'DynamicToolCall', 'McpToolCall'):
                    continue
                parts = [part.get('text', '') for part in item.get('content', []) if isinstance(part, dict)]
                # Native sends quoted wake history as its own input chunk before
                # the real request. It is not an earlier user/assistant turn.
                if kind == 'UserMessage' and len(parts) > 1 and parts[0].startswith(NATIVE_WAKE_HEADER):
                    parts = parts[1:]
                text = '\n'.join(parts)
                if kind == 'UserMessage' and text.strip().lower().startswith(('[vesper response preference — not user content:', '旧记忆背景（只作为长期背景')):
                    continue
                timestamp = payload.get('started_at_ms') or payload.get('completed_at_ms')
                at = datetime.fromtimestamp(timestamp / 1000, timezone.utc).isoformat().replace('+00:00', 'Z') if timestamp else event.get('timestamp', '')
                record = {'id': item_id, 'type': kind, 'turnId': payload.get('turn_id', ''), 'createdAt': at,
                          'text': text, 'phase': item.get('phase'), 'status': item.get('status', 'completed')}
                if kind == 'CommandExecution':
                    command = item.get('command', [])
                    record.update(title=' '.join(command) if isinstance(command, list) else str(command),
                                  output=str(item.get('aggregated_output') or item.get('formatted_output') or '')[:8000], exitCode=item.get('exit_code'))
                elif kind == 'FileChange':
                    record.update(title='File changes', output='\n'.join(item.get('changes', {}))[:8000])
                elif kind in ('DynamicToolCall', 'McpToolCall'):
                    record['title'] = item.get('tool', kind)  # Never expose raw tool arguments/credentials.
                previous = state['items'].get(item_id, {})
                state['bytes'] += len(json.dumps(record)) - len(json.dumps(previous))
                state['items'][item_id] = record
                while len(state['items']) > MAX_ITEMS or state['bytes'] > 8_000_000:
                    _, removed = state['items'].popitem(last=False)
                    state['bytes'] -= len(json.dumps(removed)); state['truncated'] = True
            except (ValueError, TypeError, AttributeError, OverflowError):
                continue  # A malformed record cannot erase the saved chat.
        CACHE[ident] = state; CACHE.move_to_end(ident)
        while len(CACHE) > 4:
            CACHE.popitem(last=False)
        return list(state['items'].values()), state['truncated']


def forget(thread_id):
    with LOCK:
        CACHE.pop(thread_id, None)


def sync(con, conversation_id):
    """Restore missing completed replies even when no phone was listening."""
    row = con.execute('SELECT codex_thread_id, archived_at FROM conversations WHERE vesper_conversation_id=?', (conversation_id,)).fetchone()
    if not row or row['archived_at'] or not row['codex_thread_id'] or deletion.is_deleted(con, conversation_id, row['codex_thread_id']):
        return {'restored': 0}
    thread = row['codex_thread_id']
    try:
        items, truncated = records(thread)
    except (OSError, ValueError, sqlite3.Error):
        return {'restored': 0, 'error': 'Codex source history could not be read; saved messages remain available'}
    con.execute('BEGIN IMMEDIATE')
    # Recheck after reading the file and obtaining the write lock.
    current = con.execute('SELECT codex_thread_id, archived_at FROM conversations WHERE vesper_conversation_id=?', (conversation_id,)).fetchone()
    if not current or current['archived_at'] or current['codex_thread_id'] != thread or deletion.is_deleted(con, conversation_id, thread):
        return {'restored': 0}
    deleted = {r[0] for r in con.execute('SELECT stable_id FROM message_tombstones WHERE vesper_conversation_id=?', (conversation_id,))}
    # Index this room once. The old OR/json_extract query scanned its entire
    # history for every rollout item, taking seconds on long conversations.
    saved_by_key = {}
    for saved in con.execute('SELECT * FROM messages WHERE vesper_conversation_id=?', (conversation_id,)):
        meta = json.loads(saved['metadata_json'])
        for key in (saved['id'], saved['item_id'], meta.get('itemId')):
            if key:
                saved_by_key.setdefault(key, saved)
    restored = 0
    for item in items:
        if item['type'] != 'AgentMessage' or item['id'] in deleted or not item['text'].strip() or len(item['text']) > 120000:
            continue
        saved = saved_by_key.get(item['id'])
        if saved and saved['status'] == 'delivered':
            continue  # Preserve saved/edited content, timestamps, attachment and call metadata.
        if saved and saved['id'] in deleted:
            continue
        metadata = json.loads(saved['metadata_json']) if saved else {}
        metadata.update(itemId=item['id'], threadId=thread, turnId=item['turnId'], blockType='agentMessage')
        if item['phase']:
            metadata['phase'] = item['phase']
        at = (saved['created_at'] if saved else '') or item['createdAt']
        values = (item['text'], json.dumps(metadata, ensure_ascii=False), at)
        if saved:
            con.execute("UPDATE messages SET content=?,metadata_json=?,created_at=?,status='delivered',item_id=?,turn_id=? WHERE id=?", (*values, item['id'], item['turnId'], saved['id']))
        else:
            changed = con.execute("INSERT OR IGNORE INTO messages(id,vesper_conversation_id,role,content,status,item_id,turn_id,metadata_json,created_at,updated_at,source,time_source) VALUES(?,?,'agent',?,'delivered',?,?,?,?,?,'codex','message')", (item['id'], conversation_id, item['text'], item['id'], item['turnId'], values[1], at, at)).rowcount
            if not changed:
                continue
        con.execute('UPDATE conversations SET updated_at=max(updated_at,?) WHERE vesper_conversation_id=?', (at, conversation_id))
        restored += 1
    return {'restored': restored, 'truncated': truncated}


def terminal_page(con, conversation_id, thread_id, before=''):
    items, truncated = records(thread_id)
    deleted = {r[0] for r in con.execute('SELECT stable_id FROM message_tombstones WHERE vesper_conversation_id=?', (conversation_id,))}
    aliases = {r[0] for r in con.execute('SELECT item_id FROM messages WHERE vesper_conversation_id=? AND id IN (SELECT stable_id FROM message_tombstones WHERE vesper_conversation_id=?)', (conversation_id, conversation_id))}
    items = [item for item in items if item['id'] not in deleted | aliases]
    end = next((index for index, item in enumerate(items) if item['id'] == before), None) if before else len(items)
    if end is None:
        raise ValueError('Terminal history cursor is no longer available')
    page = [dict(item, text=item['text'][:8000], textTruncated=len(item['text']) > 8000) for item in items[max(0, end - 40):end]]
    return {'records': page, 'hasMore': end > 40, 'before': page[0]['id'] if page else None, 'historyTruncated': truncated}
