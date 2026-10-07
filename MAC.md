# Vesper for Mac

A Mac Catalyst build of the native SwiftUI client, installed as **Vesper Mac.app**.
Requires macOS 26 or later and Xcode 26 or later to build. This first build is
signed locally for this Mac, not notarized for distribution to other computers.

## Build and install

Select the **VesperMac** scheme and **My Mac (Mac Catalyst)** in Xcode, or run:

```sh
./scripts/build_mac.sh --install
```

If Xcode is outside `/Applications`, set `DEVELOPER_DIR` to that Xcode's
`Contents/Developer` directory for the command. Open `/Applications/Vesper Mac.app`.
The separate `Vesper` scheme remains the iPhone/iPad app with its own signing,
extensions and deployment target. Regenerate the project after adding Swift files:

```sh
python3 scripts/generate_project.py
```

## First connection

Open **Settings → Connection**, enter your existing Vesper device token and connect.
The API/history/socket defaults use the existing Vesper services. The token is saved
in this app's Keychain; no token is embedded in the executable or source. Chat,
diary and other server data are shared with the phone after connecting. Wallpapers
and appearance preferences are local to each app installation. An unpaired Mac can
open navigation and settings but cannot read private history or send messages.

## Desktop behavior

- Persistent sidebar for Home, Chat, Letters, Collection features and Settings.
- Contacts remain beside the selected chat, with a separate conversation pane.
- Entering Chat automatically opens the main conversation. Reopening the current
  room reuses its live session; after relaunch, a per-account local preview of up
  to 100 confirmed messages appears while the server validates the room. Cached
  previews cannot send until validation finishes; the first visit needs network.
- Chat previews live in the app's sandboxed Caches directory, separate from the
  authoritative server history. They contain text and attachment metadata, not
  the device token or downloaded attachment bodies.
- Right-click messages for copy, favorite, quote and applicable media actions.
- **Command–Return** sends the current draft; normal Return can insert a newline.
- Resizable window, centered chat content, native file pickers and saved appearance.
- The top-right appearance button opens the shared wallpaper/glass controls.

## Platform boundaries and verification

- iPhone alarms, HealthKit reads, iPhone widgets, Live Activities and the iPhone
  cross-app broadcast extension are excluded from the Mac product. Unsupported
  health/alarm tools are omitted and rejected if requested by an older thread.
- Calendar, reminders, location and audio refer to the Mac and its permissions;
  the Mac app does not remotely grant access to the iPhone.
- The Mac build uses the White icon. Appearance offers icon images to copy for
  Finder → Get Info → paste onto the small icon; the iPhone alternate-icon API
  is not used for Mac changes. Music, microphone, dictation,
  calling and real server delivery require account pairing and applicable macOS
  permission/provider authorization. Do not infer success from a compiled build.
- Initial verification: Catalyst compilation, signature verification, launch,
  sidebar/chat/connection/appearance navigation, and an iOS simulator regression
  build. No private production message was sent as part of installation testing.
