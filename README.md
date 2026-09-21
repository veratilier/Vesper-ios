# Vesper · Native iOS

A standalone SwiftUI client for Vera's existing Vesper services. No WKWebView,
Capacitor, React runtime or bundled website. Minimum iOS 17; iPhone and iPad.

## Open on your Mac

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
| Journal | Calendar, user entry editing, agent entry reading |
| Music | Existing cloud library, AVPlayer playback, seek, previous/next, background audio and system media controls |
| Desire | Independent Vesper state, six-value flower, history |
| Album | Existing photos, category filter, full-size viewer and sharing |
| Memory | Native shared Memory library: existing-device authentication, list/search, type filters, source text, save and versioned corrections; legacy Vesper records remain accessible |
| Pandora / Reading Room | Bookshelf, book creation, page navigation, quoted margin notes |
| Settings | Device pairing, local agent instructions, existing MCP connection list, document export |
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
