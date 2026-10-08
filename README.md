# Vesper · Native iOS

A standalone SwiftUI client for Vera's existing Vesper services. No WKWebView,
Capacitor, React runtime or bundled website. Minimum iOS 17; iPhone and iPad.

## Mac desktop app

Use the **VesperMac** scheme for the desktop app. See [MAC.md](MAC.md) for installation,
first connection, desktop controls and platform support.

## Build the iPhone app on your Mac

1. Clone this repository and open **Vesper.xcodeproj** in Xcode 16 or later.
2. Select the **Vesper** scheme, select your iPhone, and choose your own development
   team under Signing & Capabilities. The bundle identifier is
   `com.vera.vesper.native`, separate from the existing web-shell app.
3. Build and run. In Settings → Connection enter your existing Vesper device token.
   It is stored in the iOS Keychain; never put it in Git, an issue or build logs.
4. The default API, history and WebSocket addresses point to the existing Vesper
   services. No backend deployment or database migration is performed by this repo.

The new app does not automatically inherit Safari/Capacitor local storage. Cloud
records are reused; local-only settings must be entered again. Keep the existing
app installed until the native version has passed your device checks.

## Implemented screens

| Screen | Native implementation |
| --- | --- |
| Home | Ice-blue image background, glass cards, scrollable note preview, reminder completion, compact player, sidebar and floating navigation |
| Chat | Native multiline input, WebSocket JSON-RPC, streaming text, history list, model selection, stop, dynamic tool dispatch, explicit command/file approval |
| Notes | Read, add, edit, delete with confirmation |
| Reminders | Read, add, edit, complete, delete with confirmation |
| Dates | Add/edit dates, yearly repeat, countdown |
| Journal | Textured paper, Beijing date strip and date picker, Vera/Rowan reading, user entry editing |
| Music | Existing cloud library, AVPlayer playback, seek, previous/next, background audio and system media controls |
| Desire | Independent Vesper state, six-value flower, history |
| Album | Existing photos, category filter, full-size viewer and sharing |
| Memory | Native shared Memory library: existing-device authentication, list/search, type filters, source text, save and versioned corrections; legacy Vesper records remain accessible |
| Pandora / Reading Room | Bookshelf, book creation, page navigation, quoted margin notes |
| Settings | Device pairing, local agent instructions, existing MCP connection list, document export |
| Usage & balances | GPT weekly used/remaining/reset time, ElevenLabs subscription usage and overage, MiniMax official billing links |
| Autonomous Wake | Existing VPS switch, interval, prompt editor and activity history, gated by server config version |

## Current boundaries

This is the first native implementation, **not a claim of full web-client parity**.
Live authenticated backend behavior and physical-device layout require device
verification. The CI workflow builds the actual app and runs contract tests on an
Apple simulator; its result is separate from live-service verification.

- Chat sends text and selected photos. General file attachments, voice calling/recording,
  sticker UI, rich tool file/music cards, elicitation forms and terminal diffs
  need native adapters. Unsupported server interaction requests are rejected,
  never silently approved. Existing conversation history remains on the server.
- Agent model selection is available after the chat connects; local instructions
  apply to new threads. Legacy threads keep their registered tool catalogs.
- Album is a viewer initially. Music requires a valid playable HTTPS stream in
  the existing library; this app does not bypass provider playback restrictions.
- Home Usage reads the live Codex weekly limit on refresh and shows no invented percentage when unavailable.
- MCP connections are listed; OAuth connection editing is not yet ported.
- Movie Room, widgets, Live Activities, HealthKit, Calendar/Reminders integration,
  camera and APNs remote pushes are not activated by merely compiling this app.
  In-app reminders are Vesper records, not Apple Reminders. The existing server
  Web Push endpoint is not an APNs provider.
- Background audio is supported. A native app cannot promise arbitrary permanent
  background execution. Autonomous jobs continue to belong to the existing VPS.
- State writes re-fetch and modify only the intended item, retaining unknown JSON
  fields. The existing `/api/state` endpoint has no ETag/CAS write protection;
  simultaneous edits from two clients can still race. Avoid concurrent edits.
- No credentials, private chat records or user data are committed. Artwork comes
  from the existing Vesper project; Ballet is distributed under the bundled OFL.

## Account usage

Open **Settings → Usage & balances**, or tap **Usage** on Home. Pull to refresh
both providers, or retry either card independently. GPT quota uses a short-lived,
read-only connection to the existing Vesper Codex server; it does not start or
resume a conversation. The weekly window is selected by its reported duration,
not by assuming that `primary` or `secondary` always means weekly.

ElevenLabs uses `GET /v1/user/subscription` for account-wide included characters,
remaining allowance, reset date and current overage cost when supplied. It reuses
an existing voice key only for the official ElevenLabs API host. A separate key
with subscription read permission can be saved through **ElevenLabs access** in
the device Keychain; this does not change voice playback. Requests never follow
redirects or show provider response bodies in errors. Missing quota fields are
unavailable, not zero. Last successful readings remain visible after a failed
refresh for the same account, with their timestamps; account changes clear them.

MiniMax opens the official China or international billing console. Its speech
balance is not automatically queried or manually recorded in the app. No backend
deployment, credential export, billing mutation or synthetic voice request is
needed to view usage.

Protocol references: [Codex rate limits](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt),
[ElevenLabs subscription](https://elevenlabs.io/docs/api-reference/user/subscription/get),
[MiniMax account billing](https://platform.minimax.io/docs/faq/about-account).

## Home Screen widgets

The **Vesper · Days** widget already lets you edit a title and date by touching
and holding the widget on your Home Screen. **Vesper · Picture** lets you choose
one of three bundled Vesper scenes and edit a short caption the same way. Both
work without a Vesper account or network connection; the picture choices are
bundled artwork, not personal photos selected from your photo library.

The existing Desire, Usage and Notes widgets still use the App Group snapshot
shared with the app. The Broadcast extension separately requires shared App
Group and Keychain entitlements. CI builds for an iOS simulator with signing
disabled; this does not prove that your Apple team can sign all three targets
for a physical iPhone. If Xcode fails while installing, inspect the first
Signing & Capabilities error for **Vesper**, **VesperWidgets** or
**VesperBroadcast** and ensure the same team is selected for each target.

## Development

Sources are grouped in `Vesper/Core` and `Vesper/Views`. The project has no package
manager dependency. After adding source files, run:

```sh
python3 scripts/generate_project.py
```

On a Mac, run tests using an available simulator:

```sh
xcodebuild test -project Vesper.xcodeproj -scheme Vesper \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Choose a simulator name actually installed in your Xcode. Before shipping, check
small/large iPhones, iPad, Dynamic Type, Chinese keyboard, interactive keyboard
dismissal, expired credentials, connection interruption, and wake config versions
1 and 2. Do not report physical-device tests from simulator or source checks.

## Shared Memory library

Memory uses the existing Vesper device connection via `/api/shared-memory`; no separate Memory login or password is required. Deploy the Vesper-web shared-memory endpoint and its SHARED_MEMORY_DB binding first (see that repository's docs/shared-memory.md). The backend accesses the same memory-db used by the independent Memory page/MCP. Nothing is packaged as a stale data snapshot. Existing Vesper records remain under the legacy entry, with no automatic import or deletion. Chat-side automatic memory retrieval is unchanged. Real-account and physical-device verification is separate from CI.

## Native chat sending and synchronization

### VPS monitor

In a VPS chat, open the top-right menu and tap the display icon. **画面** shows
Rowan's actual current VPS browser page and its capture time; **终端** shows the
existing current-chat commands, outputs and terminal controls. Pinch to zoom the
browser frame. Idle, login maintenance, capture failure and disconnected states
are shown explicitly. A retained disconnected image is labelled as the last frame.

The screen reads the exact HTTPS `/browser/display` route on the paired history
origin, using the existing device bearer token. Redirects are rejected. Frame
polling runs only while the screen tab is visible and the app is active. Viewing
does not submit a model turn or browse on Rowan's behalf. The VPS adapter masks
browser inputs and preserves its existing page/element state and idle lifetime.
The Mac chat retains its own terminal entry.

Verification: three iOS simulator tests passed for paired origin/authentication,
invalid/live/idle frame handling and preserved zoom when frames update. Server
verification and deployment instructions are in Vesper-web's
`vps/BROWSER_DISPLAY.md`.

Regular chat sends save the outgoing message to an account-scoped local outbox
before submitting the model turn. Confirmed messages and their memory evidence
sync to the existing services asynchronously. Failed uploads remain on disk and
retry while the app can run, including after relaunch or reconnection. The outbox
never replays model turns; uncertain sends require an actual server receipt.
Message deletion waits for outstanding uploads so a late write cannot restore a
deleted row. Existing IDs make history retries idempotent.

Regular chat no longer calls memory recall before sending. Rowan can use
`recall_native_memory` during a reply when past experiences or preferences are
relevant. Its results remain untrusted historical context. Ordinary messages use
the existing model conversation; this does not shorten that conversation or
change its model/reasoning setting. Native voice-call recall is unchanged.
Attachments still upload before submission, and disconnected sessions still need
to reconnect. First-use tool preparation can also require a network request.

### Receive and reconnect latency

- Automatic legacy phase repair is limited to the visible recent-message window
  and two history pages in total. Sending or starting a turn cancels that work;
  cancelled/background page requests cannot time out and disconnect the chat.
- The production connection installs the cached tool catalog and stable session
  instructions when resuming, avoiding a second resume on the first send.
  A background catalog refresh retains the previous valid account-scoped value.
- Incoming reply, terminal and completion records enter the durable history queue
  immediately. Network history/memory writes do not block the socket reader or
  turn completion. Explicit tool delivery keeps its existing save confirmation.
