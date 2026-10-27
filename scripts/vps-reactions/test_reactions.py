import json
import sqlite3
import unittest
from types import SimpleNamespace
from unittest.mock import Mock
import reactions


class ReactionsTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE conversations(vesper_conversation_id TEXT,codex_thread_id TEXT,updated_at TEXT);
            CREATE TABLE messages(id TEXT,vesper_conversation_id TEXT,role TEXT,status TEXT,item_id TEXT,metadata_json TEXT,content TEXT,created_at TEXT);
            CREATE TABLE message_tombstones(vesper_conversation_id TEXT,stable_id TEXT);
            INSERT INTO conversations VALUES('room','thread','unchanged');
            INSERT INTO messages VALUES('m','room','agent','delivered','i','{"attachments":[{"name":"keep"}]}','FIRST\n\nSECOND','unchanged');
        ''')
        self.services = SimpleNamespace(db=lambda: self.db, now=lambda: 'test-time',
                                       conversation_delete=SimpleNamespace(is_deleted=lambda *args: False))
    def call(self, emoji, part='m#text-0', room='room', actor='user'):
        handler = SimpleNamespace(command='POST', send_json=Mock(), body=lambda: {'messageId': 'm', 'partId': part, 'emoji': emoji, 'by': actor, 'quote': 'FIRST'})
        self.assertTrue(reactions.dispatch(handler, ['conversations', room, 'reactions'], self.services))
        return handler.send_json.call_args.args
    def test_sibling_add_replace_remove_and_old_upload(self):
        self.assertEqual(self.call('❤️')[0], 200)
        self.assertEqual(self.call('👍', 'm#text-1')[0], 200)
        result = self.call('😂')[1]['reactions']
        self.assertEqual(result['m#text-0']['emoji'], '😂')
        self.assertEqual(result['m#text-1']['emoji'], '👍')
        self.call('')
        stale = {'reactions': {'m#text-0': {'emoji': '❤️'}}, 'kept': True}
        reactions.preserve(self.db, 'm', stale)
        self.assertNotIn('m#text-0', stale['reactions'])
        self.assertEqual(stale['reactions']['m#text-1']['emoji'], '👍')
        row = self.db.execute('SELECT * FROM messages').fetchone()
        self.assertEqual(row['content'], 'FIRST\n\nSECOND')
        self.assertEqual(json.loads(row['metadata_json'])['attachments'][0]['name'], 'keep')
        self.assertEqual(row['created_at'], 'unchanged')
        self.assertEqual(self.db.execute('SELECT updated_at FROM conversations').fetchone()[0], 'unchanged')
        self.call('', 'm#text-1')
        reactions.preserve(self.db, 'm', stale)
        self.assertEqual(stale['reactions'], {})
    def test_scope_validation_and_tombstones(self):
        self.assertEqual(self.call('hello')[0], 400)
        self.assertEqual(self.call('👍', part=42)[0], 400)
        self.assertEqual(self.call('👍', part=None)[0], 400)
        self.assertEqual(self.call('👍', 'foreign#text-0')[0], 400)
        self.assertEqual(self.call('👍', room='other')[0], 404)
        self.db.execute("INSERT INTO message_tombstones VALUES('room','i')"); self.db.commit()
        self.assertEqual(self.call('👍')[0], 404)
    def test_completed_agent_only(self):
        for role, status in [('user', 'delivered'), ('agent', 'streaming'), ('system', 'delivered')]:
            self.db.execute('UPDATE messages SET role=?,status=?', (role, status)); self.db.commit()
            self.assertEqual(self.call('❤️')[0], 409)
    def test_agent_can_react_only_to_user_and_both_actors_are_preserved(self):
        self.assertEqual(self.call('❤️', actor='agent')[0], 409)
        self.db.execute("UPDATE messages SET role='user'"); self.db.commit()
        result = self.call('🥹', actor='agent')
        self.assertEqual(result[0], 200)
        value = result[1]['reactions']['m#text-0']
        self.assertEqual((value['by'], value['emoji'], value['quote'], value['bubbleId']), ('agent', '🥹', 'FIRST', 'm#text-0'))
        self.assertEqual(self.call('', actor='user')[0], 409)
        self.assertEqual(self.call('❤️', actor='agent')[1]['reactions']['m#text-0']['emoji'], '❤️')
        stale = {'reactions': {}}
        reactions.preserve(self.db, 'm', stale)
        self.assertEqual(stale['reactions']['m#text-0']['by'], 'agent')
        self.assertEqual(self.call('', actor='agent')[1]['reactions'], {})
        self.assertEqual(self.call('❤️', actor='system')[0], 400)

    def test_compound_emoji(self):
        for emoji in ['❤️', '🫂', '👍🏽', '👩‍💻', '🇨🇳']:
            self.assertTrue(reactions.valid_emoji(emoji))


if __name__ == '__main__':
    unittest.main()
