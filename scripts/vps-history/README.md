# VPS history reconciliation

`vesper_codex_records.py` mirrors the deployed VPS module at
`/home/ubuntu/vesper-codex-history/vesper_codex_records.py`. It uses the existing
history service and its `vesper_conversation_delete` module; it is not a new service.

## 2026-10-12 connection latency fix

The synchronizer used one OR/json_extract table scan for each completed reply.
The active conversation had 2,455 saved messages and 1,049 assistant lookups;
those lookups alone took 11.463 seconds. It now loads and indexes that room's saved
records once, keeping delivered edits and deletion tombstones intact.

Measured authenticated localhost reads of the latest 80 messages:

- Before: 12.924 seconds.
- After a service restart: first request 4.111 seconds (cold rollout parsing).
- Subsequent requests: 0.080 and 0.082 seconds.

These are server HTTP timings, not total phone connection times. Public requests
also incur network transfer, and the client initializes/resumes its WebSocket.
Keep the post-resume history read: it catches replies completed between the first
HTTP request and subscription to the thread.

## Verification and deployment

Run `python3 -m unittest test_codex_records -q` with this module first on Python's
import path and the installed history service available. The tests use temporary
databases and synthetic rollout files; they must not target production storage.
Nine existing tests passed, covering offline replies, preserved edits, tombstones,
conversation deletion, incremental parsing, and safe terminal history.

Before replacing the live module, compare its checksum with the inspected version,
back it up, and validate Python syntax. Replace only this module and restart
`vesper-codex-history.service`; leave the Codex app-server running. Check an
authenticated history request without printing credentials or message bodies.
