# Vesper gateway

This authenticated, loopback-only WebSocket gateway forwards Vesper traffic to
the existing Codex app-server. It preserves thread IDs, provides a health check,
and counts connections and turns in memory. On `thread/start` and `thread/resume`, it
adds Codex's native in-place auto-compaction setting: 240,000 tokens of full
active context. The existing `compact_prompt` remains intact. The
gateway does not shorten tool output, change the model, or promise a particular
token saving.

Run `npm ci && npm test` before deploying. The service uses the same existing
token file as the app-server. Do not copy that file into the source directory.

The canary WebSocket route is `/gateway`; the authenticated health route is
`/gateway/health`. Both require the existing device token. Studio can update the
shared automatic compaction threshold through an authenticated POST to the health
route, using the previously observed threshold to prevent conflicting edits. The
gateway stores the confirmed value in its systemd state directory and applies it
to each VPS thread the next time that thread starts or resumes. Changing the
threshold does not start a compaction or change the model's context window. The
Codex internal trigger estimate differs from the latest request input displayed
in Studio. The service binds
only `127.0.0.1:4520` and must be exposed by the existing Nginx/Cloudflare
entrypoint. The root chat route now points to the gateway without changing client
chat URLs. `gateway/health` reports whether routing and compaction are active.
It records completed `contextCompaction` items by thread and exposes their last
completion time in the authenticated health response. The deployed service
persists this event ledger in its systemd `StateDirectory`. Codex does not expose
its exact internal context estimate, so the last request's provider-reported
input remains a separate reading, not a precise threshold progress meter. An
80k total threshold caused repeated compactions because Codex retained about
118k input tokens even after compaction on the existing long Ash thread. A 150k
threshold still triggered every turn because Codex's internal context estimate
is higher than provider-reported input. The 240k limit is a protective setting,
not a measured reduction in per-turn usage.

For the existing Ash conversation, an optional thread-specific handoff file is
appended to the client's full developer instructions on `thread/resume`.
`VESPER_GATEWAY_HANDOFF_THREAD_ID` selects the thread and
`VESPER_GATEWAY_HANDOFF_FILE` points to a mode-600 text file outside the source
tree. The gateway never sends that handoff to other threads or returns it from
health. The file is short context for a deliberate same-thread window reset;
the full original chat remains in Vesper history and the backed-up rollout.

`window-canary.mjs` verifies Codex's experimental token-budget reset on an
isolated thread before touching Ash. `window-reset.mjs` performs a manual reset
on one idle existing thread, then turns the experimental feature back off. It
does not create a new thread or issue a model turn. Back up the rollout and
prepare the handoff before invoking it. Restart Vesper clients afterward so
they send their complete instructions through the gateway again. The reset
itself can invalidate the prompt cache once; judge savings from a subsequent
real user turn, not from the reset event.

To disable compaction but keep routing, remove `VESPER_GATEWAY_COMPACTION=1` from
the systemd service, reload systemd and restart the gateway. To roll back the
route, run `sudo python3 /home/ubuntu/vesper-gateway/install-nginx.py rollback`.
Do not delete chat history or restart the app-server.
