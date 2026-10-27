import importlib.util
import unittest
import sqlite3
import time
from unittest.mock import patch
from types import SimpleNamespace
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


spec = importlib.util.spec_from_file_location('vesper_daily_quotes', Path(__file__).with_name('vesper_daily_quotes.py'))
quotes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quotes)


class QuoteScheduleTests(unittest.TestCase):
    def test_daily_slots_are_spaced_and_stable(self):
        day = '2026-10-25'
        for count in range(1, 6):
            times = [quotes.due_time(day, slot, count) for slot in range(count)]
            self.assertEqual(times, [quotes.due_time(day, slot, count) for slot in range(count)])
            self.assertEqual(times, sorted(times))
            for slot, stamp in enumerate(times):
                local = datetime.fromtimestamp(stamp, ZoneInfo('Asia/Shanghai'))
                self.assertEqual(local.strftime('%Y-%m-%d'), day)
                minute = local.hour * 60 + local.minute
                width = 720 // count
                self.assertGreaterEqual(minute, 540 + slot * width)
                self.assertLess(minute, 540 + (slot + 1) * width)

    def test_missed_slot_and_previous_failures_remain_eligible_today(self):
        con = sqlite3.connect(':memory:')
        con.row_factory = sqlite3.Row
        self.addCleanup(con.close)
        values = {}
        store = SimpleNamespace(db=lambda: con, get=lambda c, key, default=None: values.get(key, default),
                                put=lambda c, key, value: values.__setitem__(key, value))
        now = datetime(2026, 10, 28, 20, 55, tzinfo=quotes.ZONE).timestamp()
        listing = {'preferences': {'dailyCount': 1, 'notify': False}, 'cards': [], 'occupiedIds': []}
        runner = SimpleNamespace(store=store, http=lambda path: listing)
        quotes._attempts(runner)
        con.execute('INSERT INTO daily_quote_attempts VALUES(?,?,?,?,?)', ('2026-10-28', 0, 4, now - 1, 'temporary outage'))
        published = []
        def publish(runner, day, slot, state):
            published.append((day, slot))
            listing['cards'].append({'id': f'{day}-{slot}', 'day': day})
        with patch.object(quotes.time, 'time', return_value=now), \
             patch.object(quotes, 'datetime') as clock, patch.object(quotes, '_publish', side_effect=publish):
            clock.now.return_value = datetime.fromtimestamp(now, quotes.ZONE)
            clock.strptime.side_effect = datetime.strptime
            quotes.run_due(runner)
        self.assertEqual(published, [('2026-10-28', 0)])

    def test_deleted_scheduled_slot_is_not_recreated(self):
        con = sqlite3.connect(':memory:'); con.row_factory = sqlite3.Row; self.addCleanup(con.close)
        values = {}
        store = SimpleNamespace(db=lambda: con, get=lambda c, key, default=None: values.get(key, default),
                                put=lambda c, key, value: values.__setitem__(key, value))
        now = datetime(2026, 10, 28, 20, 55, tzinfo=quotes.ZONE).timestamp()
        runner = SimpleNamespace(store=store, http=lambda path: {'preferences': {'dailyCount': 1}, 'cards': [], 'occupiedIds': ['2026-10-28-0']})
        with patch.object(quotes.time, 'time', return_value=now), patch.object(quotes, 'datetime') as clock, patch.object(quotes, '_publish') as publish:
            clock.now.return_value = datetime.fromtimestamp(now, quotes.ZONE)
            clock.strptime.side_effect = datetime.strptime
            quotes.run_due(runner)
        publish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
