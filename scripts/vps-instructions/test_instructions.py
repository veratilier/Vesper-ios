import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import vesper_agent_instructions as agent
import agent_instructions_routes as route


class InstructionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'AGENTS.md'
        self.path.write_text('共同身份：保持已经确认的相处方式。')
        env = patch.dict(os.environ, {'VESPER_AGENT_INSTRUCTIONS': str(self.path)})
        env.start(); self.addCleanup(env.stop)

    def test_refresh_preserves_scene_and_authorization(self):
        params = {'developerInstructions': '通话：只返回一句。', 'sandbox': 'read-only', 'dynamicTools': []}
        first = agent.prepare('thread/start', params)
        self.assertIn('共同身份', first['developerInstructions'])
        self.assertTrue(first['developerInstructions'].endswith('通话：只返回一句。'))
        revision = agent.document()['revision']
        self.path.write_text('共同身份：更新后的偏好。')
        second = agent.prepare('thread/resume', first)
        self.assertNotEqual(revision, agent.document()['revision'])
        self.assertNotIn('已经确认', second['developerInstructions'])
        self.assertEqual(second['developerInstructions'].count(agent.BEGIN), 1)
        self.assertEqual(second['sandbox'], 'read-only')
        self.assertEqual(second['dynamicTools'], [])
        self.assertEqual(params['developerInstructions'], '通话：只返回一句。')

    def test_resume_without_override_keeps_existing_instructions(self):
        params = {'threadId': 'old-thread', 'excludeTurns': True}
        self.assertIs(agent.prepare('thread/resume', params), params)
        self.assertIs(agent.prepare('turn/start', params), params)

    def test_invalid_document_never_silently_disappears(self):
        for data in (b'', b' ' * 24001, b'\xff', agent.BEGIN.encode()):
            self.path.write_bytes(data)
            with self.assertRaises((ValueError, UnicodeError)):
                agent.prepare('thread/start', {})
        self.path.unlink()
        with self.assertRaises(OSError):
            agent.document()

    def test_save_conflict_and_validation_preserve_live_file(self):
        before = agent.document()
        after = agent.save('更新后的共同指令', before['revision'])
        self.assertEqual(agent.document(), after)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.with_name('AGENTS.md.previous').read_text(), before['content'])
        with self.assertRaises(agent.RevisionConflict):
            agent.save('过期页面', before['revision'])
        for invalid in ('', '中' * 8001, agent.END, None):
            with self.assertRaises(ValueError):
                agent.save(invalid, after['revision'])
        self.assertEqual(agent.document(), after)

    def test_concurrent_editors_only_one_wins(self):
        from concurrent.futures import ThreadPoolExecutor
        revision = agent.document()['revision']
        def attempt(content):
            try:
                return agent.save(content, revision)['content']
            except agent.RevisionConflict:
                return None
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, ['First edit', 'Second edit']))
        winners = [value for value in results if value is not None]
        self.assertEqual(len(winners), 1)
        self.assertEqual(agent.document()['content'], winners[0])

    def test_save_route(self):
        class Handler:
            command = 'POST'
            payload = {'content': 'New instruction', 'revision': agent.document()['revision']}
            def body(self): return self.payload
            def send_json(self, status, value): self.result = (status, value)
        handler = Handler()
        route.dispatch(handler, ['agent-instructions'], None)
        self.assertEqual(handler.result, (200, agent.document()))
        route.dispatch(handler, ['agent-instructions'], None)
        self.assertEqual(handler.result[0], 409)
        handler.payload = {'content': ''}
        route.dispatch(handler, ['agent-instructions'], None)
        self.assertEqual(handler.result[0], 400)

    def test_endpoint_read_only_and_reports_missing_document(self):
        class Handler:
            command = 'GET'
            def send_json(self, status, value): self.result = (status, value)
        handler = Handler()
        self.assertTrue(route.dispatch(handler, ['agent-instructions'], None))
        self.assertEqual(handler.result[1], agent.document())
        handler.command = 'DELETE'
        route.dispatch(handler, ['agent-instructions'], None)
        self.assertEqual(handler.result[0], 405)
        handler.command = 'GET'; self.path.unlink()
        route.dispatch(handler, ['agent-instructions'], None)
        self.assertEqual(handler.result[0], 503)
        self.assertFalse(route.dispatch(handler, ['wake'], None))


if __name__ == '__main__': unittest.main()
