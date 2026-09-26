# Native chat reconnect investigation (2026-09-26)

The screenshot at 16:55 Asia/Shanghai shows saved history and a reconnect spinner.
It does not identify the failing transport stage. Settings' Connected flag checks
ordinary HTTP API connectivity, not WebSocket authentication or thread readiness.

## Confirmed client defects

Two regression tests fail against main 3792200 before the fix:

- An unavailable NWPath sets `reconnecting = true` without a recovery task or deadline.
- A fresh five-attempt loop starts after each briefly successful connection. Persistent
  heartbeat failures can reconnect forever rather than exhaust a shared budget.

Inspection also identified unbounded waits outside RPC timers: the `initialized`
notification send and history reconciliation. The HTTP request inactivity timeout
is not an independent wall-clock bound on the entire connection attempt.

The fix bounds each asynchronous phase (30 seconds in production) and the whole
attempt (120 seconds), including transports/readers that ignore cancellation.
Late completions retain the generation fence. Five recovery attempts share one
budget; only explicit Retry or a healthy connection with successful pongs after
60 seconds resets it. Offline waiting is actionable and does not show a spinner.

No history deletion, new thread creation, or resend of an unconfirmed turn is part
of recovery. Existing client message IDs and drafts remain intact.

## Diagnostic phases

A WebSocket pong first verifies upgrade/transport readiness. This is followed by
initialize, the initialized notification, thread/resume, history reconciliation,
and chat-ready. Heartbeat failures are reported separately. Authentication imposed
by the application protocol can still fail during initialize/resume after a valid
HTTP upgrade; the diagnostic stage identifies that boundary.

`Vesper / ChatConnection` logs contain phase-start, phase-ok, phase-failed and
chat-ready events, generation UUID, recovery attempt, numeric HTTP/close/error codes.
They omit URLs, tokens, NSError descriptions/userInfo, raw server error text, raw
close reasons, messages and thread contents. Raw close reason length is recorded.

## Incident evidence still needed

The paired physical iPhone was reported **unavailable** during this investigation.
No local ChatConnection log export or configured server SSH/log source was available.
Simulator fault-injection tests establish the defects above; they do not establish
which defect or server response caused the September 26 incident.

For the original event, correlate device ChatConnection records from
2026-09-26 16:50–17:00 Asia/Shanghai with server upgrade/connection/RPC records from
08:50–09:00 UTC. Do not export full request URLs, query strings, Authorization
headers, tokens, message payloads or thread contents. Check:

1. WebSocket upgrade result (101 versus 401/403/other), open/close timing and code.
2. Receipt and response/error codes for initialize, initialized, thread/resume.
3. Whether history HTTP read completed after a successful resume.
4. Ping/pong and close timing after chat-ready, distinguishing client lifecycle close.

On a connected, unlocked iPhone with the fixed build, independently verify chat-ready
and resumed streaming, background/foreground, offline/online, persistent failure to
Retry, and a lost turn/start receipt. Do not send a new message to probe an unresolved
send; use Retry/Check status to reconcile its original client ID.

## Validation

The two original stall reproductions failed before the fix. After the fix, all
55 XCTest tests pass on the local iOS 27 Simulator, including 11 new regressions.
The build type-checks/compiles the native app with Xcode 27 beta. This validation
uses injected transport failures and does not require a live token or mutate
production history. Existing lost-receipt/no-resend tests remain passing.
