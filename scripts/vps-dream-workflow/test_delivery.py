import ast
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import types
import unittest
from unittest.mock import Mock
import patch
import vesper_wake_delivery as delivery


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        root = os.environ.get('VESPER_TEST_RUNTIME_ROOT')
        runner = (Path(root)/'vesper_wake_runner.py') if root else Path('/tmp/vesper-dream-runner-before.py')
        workflow = (Path(root)/'vesper_wake_workflow.py') if root else Path('/tmp/vesper-dream-workflow-before.py')
        runner_source = patch.transform_runner(runner.read_text())
        workflow_source = patch.transform_workflow(workflow.read_text())
        self.assertEqual(patch.transform_runner(runner_source), runner_source)
        self.assertEqual(patch.transform_workflow(workflow_source), workflow_source)
        namespace = {}
        exec(compile(workflow_source, str(workflow), 'exec'), namespace)
        self.describe = namespace['describe']
        self.db = sqlite3.connect(':memory:'); self.db.row_factory = sqlite3.Row
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE jobs(id TEXT PRIMARY KEY,source TEXT,status TEXT,finished REAL,conversation_id TEXT,push_json TEXT,error TEXT)')
        self.ident = 'dream:Asia/Shanghai:2026-10-21T00:00:00+08:00'
        self.db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?)', (self.ident,'morning-dream','saved',1000,'chat-1',None,None))
        self.db.commit()
        @contextmanager
        def database():
            with self.db: yield self.db
        def update(ident, **fields):
            self.db.execute('UPDATE jobs SET '+','.join(k+'=?' for k in fields)+' WHERE id=?', (*fields.values(),ident))
        self.env = {'delivery':delivery,'time':types.SimpleNamespace(time=lambda:1010),'json':json,
            'store':types.SimpleNamespace(db=database,access=lambda:{'messages':['text']},get=lambda *args:{'enabled':True}),
            'sleep_gate':lambda now:False,'recent_chat':lambda:False,'current_preferences':lambda:{},
            'front_busy':lambda now:False,'update':update,'http':Mock(return_value={'delivered':1})}
        functions = [node for node in ast.parse(runner_source).body if isinstance(node,ast.FunctionDef) and node.name=='deliver']
        exec(compile(ast.Module(body=functions,type_ignores=[]),str(runner),'exec'), self.env)

    def row(self):
        return dict(self.db.execute('SELECT * FROM jobs WHERE id=?',(self.ident,)).fetchone())

    def test_transport_id_is_valid_stable_unique_and_keeps_existing_keys(self):
        key = delivery.request_id(self.ident)
        self.assertRegex(key, r'^[a-zA-Z0-9:_-]{1,128}$')
        self.assertEqual(key, delivery.request_id(self.ident))
        self.assertNotEqual(key, delivery.request_id(self.ident+'different'))
        self.assertEqual(delivery.request_id('auto-123'), 'auto-123')
        self.env['deliver'](self.ident, 'greeting')
        self.assertEqual(self.env['http'].call_args.args[1]['requestId'],key)
        self.assertEqual(self.row()['status'],'completed')

    def test_permanent_failure_recorded_instead_of_running_forever(self):
        self.env['http'].side_effect = delivery.HTTPFailure('/api/wake',400)
        self.env['deliver'](self.ident, 'greeting')
        self.assertEqual(self.row()['status'],'push_failed')
        self.assertIn('400', self.row()['error'])
        job = dict(self.row(), notification='saved greeting')
        self.assertEqual(self.describe(job,[])['outcome'],'partial_failure')

    def test_transient_error_retries_but_dream_is_complete(self):
        for status in (429, 502, 'network'):
            self.env['http'].side_effect = delivery.HTTPFailure('/api/wake',status)
            self.env['deliver'](self.ident, 'greeting')
            self.assertEqual(self.row()['status'],'saved')
            job = dict(self.row(), notification='saved greeting')
            self.assertEqual(self.describe(job,[])['outcome'],'success')
            self.assertIn('尚待',self.describe(job,[])['summary'])

    def test_old_greetings_expire_without_sending_or_rerunning_model(self):
        self.env['time'].time = lambda:2801
        self.env['deliver'](self.ident, 'old greeting')
        self.env['http'].assert_not_called()
        job = dict(self.row(),notification='old greeting')
        self.assertEqual(job['status'],'completed')
        self.assertEqual(json.loads(job['push_json'])['status'],'skipped_expired')
        self.assertIn('不再补发', self.describe(job,[])['summary'])

    def test_quiet_recent_chat_and_sleep_still_respected(self):
        for field, guard in [('sleep_gate',lambda now:True), ('recent_chat',lambda:True), ('front_busy',lambda now:True), ('current_preferences',lambda:{'quiet':True})]:
            old=self.env[field];self.env[field]=guard
            self.env['deliver'](self.ident,'greeting')
            self.env['http'].assert_not_called()
            self.assertEqual(self.row()['status'],'saved')
            self.env[field]=old

    def test_incomplete_failed_interrupted_and_silent_are_not_success(self):
        for status,outcome in [('running','running'),('queued','running'),('failed','failure'),('interrupted','interrupted'),('cancelled','interrupted'),('silent','silent'),('saved','unknown')]:
            result = self.describe({'source':'morning-dream','status':status},[])
            self.assertEqual(result['outcome'],outcome)
        result = self.describe({'source':'morning-dream','status':'silent'},[])
        self.assertIn('梦已保存',result['summary'])

    def test_regular_wake_pending_behavior_unchanged(self):
        result=self.describe({'source':'automation','status':'saved'},[])
        self.assertEqual(result['outcome'],'running')
        self.assertFalse(delivery.expired_dream({'source':'automation','status':'saved','finished':1},99999))


if __name__=='__main__': unittest.main()
