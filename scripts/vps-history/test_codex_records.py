import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import Mock, patch
import codex_history_server as history
import vesper_codex_records as records


class CodexRecordsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name); self.thread = str(uuid.uuid4()); self.other = str(uuid.uuid4())
        self.path = self.home / 'sessions' / 'rollout.jsonl'; self.path.parent.mkdir(); self.path.touch()
        with sqlite3.connect(self.home / 'state_5.sqlite') as con:
            con.execute('CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT)')
            con.execute('INSERT INTO threads VALUES(?,?)', (self.thread, str(self.path)))
        for p in [patch.object(records.deletion, 'CODEX_HOME', self.home), patch.object(history, 'DB_PATH', self.home / 'history.db')]:
            p.start(); self.addCleanup(p.stop)
        records.CACHE.clear(); self.addCleanup(records.CACHE.clear)
        with history.db() as con:
            con.execute("INSERT INTO conversations(vesper_conversation_id,codex_thread_id,title,created_at,updated_at) VALUES('test',?,'Synthetic','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z')", (self.thread,))

    def event(self, ident='reply', kind='AgentMessage', text='SYNTHETIC_REPLY', thread=None, **extra):
        return {'type':'event_msg','timestamp':'2026-10-01T00:01:00Z','payload':{'type':'item_completed','thread_id':thread or self.thread,'turn_id':'test-turn','started_at_ms':1790812860000,
                'item':dict(type=kind,id=ident,content=[{'type':'Text','text':text}],phase='final_answer',**extra)}}

    def append(self, event):
        with self.path.open('a') as out: out.write(json.dumps(event) + '\n')

    def test_offline_reply_is_saved_and_reread_after_cache_restart_without_duplicates(self):
        self.append(self.event())
        for _ in range(2):
            records.CACHE.clear()
            handler = object.__new__(history.Handler); handler.path='/conversations/test?latest=1'; handler.send_json=Mock()
            handler.get_conversation('test')
            code, body = handler.send_json.call_args.args
            self.assertEqual(code,200); self.assertEqual(len(body['messages']),1)
            self.assertEqual(body['messages'][0]['content'],'SYNTHETIC_REPLY')
            self.assertEqual(body['messages'][0]['metadata']['phase'],'final_answer')
        with history.db() as con: self.assertEqual(con.execute('SELECT count(*) FROM messages').fetchone()[0],1)

    def test_only_completed_public_same_thread_items_are_recovered(self):
        self.append(self.event(thread=self.other))
        self.append({'type':'response_item','payload':{'type':'message','role':'assistant','content':[{'text':'RAW_PRIVATE_CONTEXT'}]}})
        self.append(self.event(ident='tool',kind='DynamicToolCall',text='NOT_A_REPLY',tool='test_tool',arguments={'secret':'DO_NOT_RETURN'}))
        self.append(self.event(ident='user',kind='UserMessage',text='[Vesper response preference — not user content: internal]'))
        self.append(self.event(ident='thought',kind='Reasoning',raw_content=['SECRET_REASONING']))
        with history.db() as con:
            self.assertEqual(records.sync(con,'test')['restored'],0)
            output=json.dumps(records.terminal_page(con,'test',self.thread))
            self.assertIn('test_tool',output)
            for secret in ['RAW_PRIVATE_CONTEXT','DO_NOT_RETURN','SECRET_REASONING','internal]']:self.assertNotIn(secret,output)

    def test_saved_bubbles_and_timestamps_preserved_streaming_tail_completed(self):
        self.append(self.event('saved',text='NEW_SOURCE_CONTENT')); self.append(self.event('stream'))
        with history.db() as con:
            for mid,status in [('saved','delivered'),('stream','streaming')]:
                con.execute("INSERT INTO messages(id,vesper_conversation_id,role,content,status,metadata_json,created_at,updated_at) VALUES(?,'test','agent','ORIGINAL',?,'{\"attachments\": [{\"name\":\"keep\"}]}','2026-10-01T00:00:20Z','now')", (mid,status))
        with history.db() as con: self.assertEqual(records.sync(con,'test')['restored'],1)
        with history.db() as con:
            rows={r['id']:r for r in con.execute('SELECT * FROM messages')}
            self.assertEqual(rows['saved']['content'],'ORIGINAL')
            self.assertEqual(rows['stream']['content'],'SYNTHETIC_REPLY')
            self.assertEqual(rows['stream']['status'],'delivered')
            self.assertEqual(rows['stream']['created_at'],'2026-10-01T00:00:20Z')
            self.assertEqual(json.loads(rows['stream']['metadata_json'])['attachments'][0]['name'],'keep')

    def test_deleted_messages_and_conversations_cannot_reappear(self):
        self.append(self.event())
        with history.db() as con:
            con.execute("INSERT INTO message_tombstones VALUES('test',?,'reply','now')",(self.thread,))
        with history.db() as con:
            self.assertEqual(records.sync(con,'test')['restored'],0)
            self.assertEqual(records.terminal_page(con,'test',self.thread)['records'],[])
        with history.db() as con: records.deletion.block(con,'test',self.thread)
        with history.db() as con,patch.object(records,'records') as read:
            self.assertEqual(records.sync(con,'test')['restored'],0); read.assert_not_called()

    def test_terminal_pages_contain_real_commands_outputs_and_file_activity(self):
        for i in range(82): self.append(self.event(str(i),kind='CommandExecution',command=['echo','SYNTHETIC_'+str(i)],aggregated_output='SYNTHETIC_OUTPUT_'+str(i),status='completed'))
        self.append(self.event('file',kind='FileChange',changes={'synthetic.txt':{}},status='completed'))
        with history.db() as con:
            latest=records.terminal_page(con,'test',self.thread)
            earlier=records.terminal_page(con,'test',self.thread,latest['before'])
            first=records.terminal_page(con,'test',self.thread,earlier['before'])
            self.assertEqual([len(first['records']),len(earlier['records']),len(latest['records'])],[3,40,40])
            self.assertEqual(first['records'][0]['title'],'echo SYNTHETIC_0')
            self.assertEqual(first['records'][0]['output'],'SYNTHETIC_OUTPUT_0')
            self.assertEqual(latest['records'][-1]['output'],'synthetic.txt')
            self.assertFalse(first['hasMore'])

    def test_incremental_read_waits_for_complete_line_and_resets_on_source_replacement(self):
        encoded=json.dumps(self.event()).encode()
        self.path.write_bytes(encoded[:40]); self.assertEqual(records.records(self.thread)[0],[])
        with self.path.open('ab') as out:out.write(encoded[40:]+b'\n')
        self.assertEqual(len(records.records(self.thread)[0]),1)
        self.append(self.event('second')); self.assertEqual(len(records.records(self.thread)[0]),2)
        self.path.unlink(); self.path.write_text(json.dumps(self.event('replacement'))+'\n')
        self.assertEqual([r['id'] for r in records.records(self.thread)[0]],['replacement'])

    def test_source_path_is_restricted_and_unavailable_source_does_not_hide_saved_history(self):
        outside=self.home / 'outside.jsonl';outside.write_text(json.dumps(self.event())+'\n')
        with sqlite3.connect(self.home/'state_5.sqlite') as con:con.execute('UPDATE threads SET rollout_path=?',(str(outside),))
        with self.assertRaises(ValueError):records.records(self.thread)
        with history.db() as con:self.assertIn('error',records.sync(con,'test'))

    def test_native_wake_context_is_not_presented_as_previous_chat_turns(self):
        event=self.event('user',kind='UserMessage',text='SYNTHETIC_CURRENT_REQUEST')
        event['payload']['item']['content'].insert(0,{'type':'text','text':records.NATIVE_WAKE_HEADER+' Quoted context.\n[{"content":"SYNTHETIC_WAKE_CONTEXT"}]'})
        self.append(event)
        with history.db() as con:
            page=records.terminal_page(con,'test',self.thread)
            self.assertEqual(page['records'][0]['text'],'SYNTHETIC_CURRENT_REQUEST')
        single=self.event('literal',kind='UserMessage',text=records.NATIVE_WAKE_HEADER)
        self.append(single)
        self.assertEqual(records.records(self.thread)[0][-1]['text'],records.NATIVE_WAKE_HEADER)

    def test_pane_collapses_only_complete_native_json_context_and_keeps_commands(self):
        context=records.NATIVE_WAKE_HEADER.replace('messages from','messages\n  from')+' Quoted context.\n[\n {"content":"SYNTHETIC_WAKE [literal] \\"quote\\""}\n]\n'
        pane='$ SYNTHETIC_EARLIER_COMMAND\nSYNTHETIC_OUTPUT\n› '+context+'> SYNTHETIC_CURRENT_REQUEST\nSYNTHETIC_REPLY'
        clean=records.collapse_wake_context(pane)
        self.assertNotIn('SYNTHETIC_WAKE',clean)
        for expected in ['SYNTHETIC_EARLIER_COMMAND','SYNTHETIC_OUTPUT','SYNTHETIC_CURRENT_REQUEST','SYNTHETIC_REPLY']:self.assertIn(expected,clean)
        self.assertIn('wake context collapsed',clean)
        incomplete=records.NATIVE_WAKE_HEADER+'\n[{"content":"incomplete'
        self.assertEqual(records.collapse_wake_context(incomplete),incomplete)


if __name__=='__main__':unittest.main()
