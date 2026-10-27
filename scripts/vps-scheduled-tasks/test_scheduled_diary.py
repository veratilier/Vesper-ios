import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location('vesper_scheduled_diary', Path(__file__).with_name('vesper_scheduled_diary.py'))
diary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diary)


class FakeRunner:
    def __init__(self, entries=None, bad_read=False):
        self.entries = entries or {}
        self.calls = []
        self.bad_read = bad_read

    def http(self, path, body):
        self.calls.append(body)
        if body['name'] == 'read_vesper_state':
            if self.bad_read:
                return {'result': {'section': 'journal', 'value': None}}
            return {'result': {'section': 'journal', 'value': self.entries.copy()}}
        if body['name'] == 'write_vesper_state':
            args = body['arguments']
            self.entries[args['date']] = {**self.entries.get(args['date'], {}), 'agent': args['text']}
            return {'result': {'saved': True, 'date': args['date']}}
        raise AssertionError(body)


class ScheduledDiaryTests(unittest.TestCase):
    def test_tools_require_existing_owner_permissions(self):
        self.assertEqual(diary.available(set()), set())
        self.assertEqual(diary.available({'write_vesper_state'}), set())
        self.assertEqual(diary.available({'read_vesper_state'}), {diary.READ})
        self.assertEqual(diary.available({'read_vesper_state', 'write_vesper_state'}), {diary.READ, diary.WRITE})

    def test_read_returns_only_requested_date(self):
        runner = FakeRunner({'2026-10-25': {'user': 'private'}, '2026-10-24': {'agent': 'older'}})
        self.assertEqual(diary.execute(runner, diary.READ, {'date': '2026-10-25'}, {}),
                         {'date': '2026-10-25', 'entry': {'user': 'private'}})

    def test_read_keeps_large_entry_valid_and_bounded(self):
        runner = FakeRunner({'2026-10-25': {'user': 'U' * 25000, 'agent': 'A' * 25000}})
        result = diary.execute(runner, diary.READ, {'date': '2026-10-25'}, {})
        self.assertEqual(len(result['entry']['user']), 7000)
        self.assertEqual(len(result['entry']['agent']), 7000)
        self.assertTrue(result['entry']['userTruncated'])
        self.assertTrue(result['entry']['agentTruncated'])

    def test_write_preserves_user_entry_and_verifies(self):
        runner = FakeRunner({'2026-10-25': {'user': 'Vera text'}})
        result = diary.execute(runner, diary.WRITE, {'date': '2026-10-25', 'content': 'Ash text'}, {})
        self.assertEqual(result, {'date': '2026-10-25', 'saved': True, 'verified': True, 'alreadyPresent': False})
        self.assertEqual(runner.entries['2026-10-25'], {'user': 'Vera text', 'agent': 'Ash text'})
        self.assertEqual([call['name'] for call in runner.calls],
                         ['read_vesper_state', 'write_vesper_state', 'read_vesper_state'])

    def test_existing_agent_entry_is_not_overwritten(self):
        runner = FakeRunner({'2026-10-25': {'agent': 'Original'}})
        result = diary.execute(runner, diary.WRITE, {'date': '2026-10-25', 'content': 'Replacement'}, {})
        self.assertFalse(result['saved'])
        self.assertEqual(runner.entries['2026-10-25']['agent'], 'Original')
        self.assertEqual(len(runner.calls), 1)

    def test_invalid_or_failed_read_never_writes(self):
        runner = FakeRunner(bad_read=True)
        with self.assertRaises(RuntimeError):
            diary.execute(runner, diary.WRITE, {'date': '2026-10-25', 'content': 'Text'}, {})
        self.assertEqual(len(runner.calls), 1)
        with self.assertRaises(ValueError):
            diary.execute(runner, diary.READ, {'date': '2026-02-30'}, {})


if __name__ == '__main__':
    unittest.main()
