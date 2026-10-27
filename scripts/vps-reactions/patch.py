"""Apply narrowly to a fresh server source snapshot, failing on unknown structure."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
chat = root / 'chat.py'
source = chat.read_text()
needle = '            target_id = existing["id"] if existing else message_id\n'
addition = '            from .reactions import preserve\n            preserve(connection, target_id, metadata)\n'
if addition not in source:
    assert source.count(needle) == 1
    chat.write_text(source.replace(needle, needle + addition))
route = root / 'history_routes.py'
source = route.read_text()
needle = 'def dispatch(self, path, services):\n'
addition = '    from . import reactions\n    if reactions.dispatch(self, path, services): return True\n'
if addition not in source:
    assert source.count(needle) == 1
    route.write_text(source.replace(needle, needle + addition))
