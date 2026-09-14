# System calls, Calendar and Reminders

Calendar & Reminders is available in Settings. Permission prompts are separate. EventKit reads the next seven days of events and incomplete reminders, and lets the user create events/reminders in the system default calendar/list and complete reminders. Data is not automatically uploaded or exposed to AI tools. Calendar/account sync remains managed by iOS. Test grants, denials, permission revocation, creation and reminder completion on a signed device.

SystemCalls wraps CallKit for existing foreground call invitations and user-started calls. The system answer, end and mute actions drive the native call view. Speech starts after CallKit audio activation and pauses on deactivation; backgrounding stops the camera. Existing STT/TTS and call transcript persistence remain in use. Test microphone/Speech denial, system mute/end, another incoming phone call, lock/unlock and Bluetooth routing on a real device. Availability can depend on region/device; surface system errors rather than reporting a successful invitation.

## Remote incoming calls are not deployed

This change does not register PushKit or claim closed-app incoming calls work. The repository has no working VoIP APNs registration or call-signalling backend yet. That requires a configured Apple Push Notifications capability/provisioning profile, server-side APNs credentials (never commit the key), authenticated device-token registration and removal, and an authenticated call invitation endpoint. Use the app bundle's `.voip` APNs topic, the correct development/production environment, an expiring call UUID and conversation binding. The PushKit handler must promptly report a real incoming call to CallKit and finish its callback; do not reuse VoIP pushes for normal messages or background polling. Cancelled/stale/duplicate calls need explicit handling, and accepting must reconnect the correct conversation before opening the media session.

The current live invitation tool still requires the app to be active. A future remote call implementation must verify delivery, answer/decline, cancellation, reconnect and audio on a signed iPhone before removing that requirement. No APNs key, remote notification capability or new server timer was silently installed by this patch.

References: https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit and https://developer.apple.com/documentation/eventkit/accessing-the-event-store
