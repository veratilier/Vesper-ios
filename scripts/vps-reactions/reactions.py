"""Atomic per-bubble reactions; ordinary message uploads cannot overwrite them."""
import json
import unicodedata


def valid_emoji(value):
    return (isinstance(value, str) and len(value.encode('utf-8')) <= 64 and
            (not value or (not any(c.isspace() for c in value) and
                          any(unicodedata.category(c) == 'So' for c in value))))


def preserve(connection, message_id, metadata):
    # The dedicated endpoint owns this field, including an empty removal map.
    metadata.pop('reactions', None)
    previous = connection.execute('SELECT metadata_json FROM messages WHERE id=?', (message_id,)).fetchone()
    if previous:
        reactions = json.loads(previous['metadata_json']).get('reactions')
        if isinstance(reactions, dict):
            metadata['reactions'] = reactions


def dispatch(handler, path, services):
    if len(path) != 3 or path[0] != 'conversations' or path[2] != 'reactions':
        return False
    if handler.command != 'POST':
        handler.send_json(405, {'error': 'Method not allowed'})
        return True
    body = handler.body()
    mid, part, emoji = body.get('messageId'), body.get('partId'), body.get('emoji')
    actor = body.get('by', 'user')
    bubble = body.get('bubbleId', part.split('#reaction-')[0] if isinstance(part, str) else '')
    quote = body.get('quote', '')
    if (actor not in ('user', 'agent') or not isinstance(bubble, str) or not isinstance(quote, str) or len(quote) > 1600 or
            not isinstance(mid, str) or not mid or len(mid) > 512 or
            not isinstance(part, str) or len(part) > 1024 or
            not (part == mid or part.startswith(mid + '#')) or not (bubble == mid or bubble.startswith(mid + '#')) or not valid_emoji(emoji)):
        handler.send_json(400, {'error': 'Invalid reaction'})
        return True
    with services.db() as connection:
        connection.execute('BEGIN IMMEDIATE')
        room = connection.execute('SELECT codex_thread_id FROM conversations WHERE vesper_conversation_id=?', (path[1],)).fetchone()
        if services.conversation_delete.is_deleted(connection, path[1], room['codex_thread_id'] if room else None):
            handler.send_json(410, {'error': 'Conversation deleted'})
            return True
        row = connection.execute('SELECT * FROM messages WHERE vesper_conversation_id=? AND id=?', (path[1], mid)).fetchone()
        deleted = connection.execute('SELECT 1 FROM message_tombstones WHERE vesper_conversation_id=? AND (stable_id=? OR stable_id=?)', (path[1], mid, row['item_id'] if row else mid)).fetchone()
        if not row or deleted:
            handler.send_json(404, {'error': 'Message not found'})
            return True
        metadata = json.loads(row['metadata_json'])
        if row['role'] != ('user' if actor == 'agent' else 'agent') or row['status'] != 'delivered' or metadata.get('blockType', '') not in ('agentMessage', 'assistantMessage', 'userMessage', 'text', ''):
            handler.send_json(409, {'error': 'React only to the other participant’s delivered message'})
            return True
        reactions = metadata.get('reactions', {})
        if not isinstance(reactions, dict):
            reactions = {}
        if emoji:
            if part not in reactions and len(reactions) >= 128:
                handler.send_json(400, {'error': 'Too many reactions'})
                return True
            reactions[part] = {'emoji': emoji, 'by': actor, 'updatedAt': services.now(), 'bubbleId': bubble, 'quote': quote}
        else:
            reactions.pop(part, None)
        metadata['reactions'] = reactions
        # Preserve original message dates and conversation unread/order state.
        connection.execute('UPDATE messages SET metadata_json=? WHERE id=? AND vesper_conversation_id=?',
                           (json.dumps(metadata, ensure_ascii=False), mid, path[1]))
    handler.send_json(200, {'messageId': mid, 'reactions': reactions})
    return True
