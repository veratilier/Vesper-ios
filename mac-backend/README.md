# Vesper Mac backup backend

Independent backend for the existing native client. Public origin:
`https://mac-vesper.r-vera.com`; history suffix `/history`; WebSocket
`wss://mac-vesper.r-vera.com/chat`. The named Cloudflare tunnel runs on this Mac
and never routes through the VPS. The Mac must remain awake, online and logged in.

## Runtime and authentication

`python3 mac-backend/install.py` installs a private runtime under
`~/Library/Application Support/VesperBackend` and two independent LaunchAgents:

- `com.vera.vesper.mac-backend`: Node 24 gateway on loopback 47631, supervising
  Codex app-server on loopback 47632.
- `com.vera.vesper.mac-tunnel`: named tunnel `vesper-mac-backend`.

The installer preserves an existing device token; it never prints it or embeds it
in the app. `Mac connection.txt` in that private directory contains pairing details.
In iPhone Settings → Connection → Mac backup, enter that token and choose
**Save and switch to Mac backup**. VPS addresses and its Keychain token remain under
their original keys. The new token uses a distinct Keychain account. No automatic
failover or replay occurs. A failed preflight preserves the current connection.

Codex uses a separate `CODEX_HOME`, configuration, workspace, SQLite database and
thread registry. Its login file links to this Mac's existing ChatGPT login; the
model account is shared, while Vesper's backend access token is independent. No VPS
or Codex Desktop thread/state database is copied. Server RPC rejects foreign thread
IDs and import paths. Filesystem commands retain workspace sandbox and approval
handling; authenticated native tools execute through the connected client.

Stop only these services using `launchctl bootout gui/$(id -u)/<label>`.
Re-run install to update/restart them. Original VPS, Mac client and other tunnels
are not modified. The tunnel's credentials stay in `~/.cloudflared`, not Git.

## Compatibility inspected

- Native `APIClient`: `x-vesper-device-token` for `/api/*`, bearer authentication
  for history, HTTPS/WSS only.
- VPS source `Vesper-web/vps/codex_history_server.py`: conversation list/upsert,
  message upsert, cursor paging, search and deletion contracts.
- Native `ChatSession`: initialize/initialized, model/list, account rate limits,
  thread start/resume/read/items, turn start/interrupt, incremental events and
  bidirectional `item/tool/call` responses. Tool HTTP results use `{result: ...}`.
- Installed Codex's generated JSON schema plus the official
  [App Server protocol](https://learn.chatgpt.com/docs/app-server).

VPS SSH inspection was attempted but timed out; this release does not assert that
the offline source exactly matches the currently running VPS revision.

## History and memory

New Mac messages and memory evidence persist in `backend.sqlite3`. Model final
events are also recorded independently of mobile history uploads; reads reconcile
missing messages. Tombstones prevent deleted messages from returning. Duplicate
accepted `clientUserMessageId` requests return a stored receipt without another turn.

**Copy VPS history & memory to Mac** is a manual one-way snapshot operation. The
iPhone uses its existing VPS credential to read the old history and active Shared
Memory records, and the new credential to stage batches on Mac. VPS receives no
writes. A commit replaces only the completed source replica inside one SQLite
transaction. Failed/interrupted copies leave the previous replica usable; a stale
copy cannot supersede a newer import. Retired/withdrawn memories disappear on the
next complete copy. Mac-authored data remains separate.

Copies retain original text, timestamps and provenance. Imported conversation and
message IDs are namespaced, and remote runtime thread/turn/item IDs are removed.
Copied history is available through `search_native_history`; copied memories are
available through `recall_native_memory`. Imported rooms are not set as the main
chat. There is no automatic bidirectional sync or resumed VPS model context.

No real source history/memory transfer was performed during acceptance: the VPS
was not reachable over SSH and its Mac Keychain credential could not be retrieved
noninteractively. The iPhone copy button uses its own existing credential.

## Supported first-stage scope

Text chat, streaming, local durable history, local memory recall, status/document
tools and the native client's tool callbacks. VPS-specific remote MCP catalog,
media uploads, music server integrations and autonomous wake are not mirrored.
Unsupported endpoints return an explicit error rather than claiming success.

## Verification

`npm ci --ignore-scripts && npm test` runs isolated HTTP/WebSocket/SQLite contract
tests for auth, foreign-thread rejection, stream/tool round trip, idempotent writes,
deletions and atomic replica replacement. No real model is used in these tests.

`node mac-backend/smoke.mjs` runs a separately named synthetic acceptance room via
the public HTTPS/WSS origin with the installed Mac model login. It verifies actual
Chinese replies, incremental deltas, a `mac_backend_status` tool call, history
recovery and same-backend resume, then removes the test room from the chat list.
It never reads/resumes production VPS or Desktop threads. It consumes model usage.

Native verification: 4 connection-profile tests plus 53 existing connection recovery
tests passed; iOS simulator test build and signed iPhone build succeeded.
