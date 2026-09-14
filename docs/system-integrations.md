# In-app calls, Calendar and Reminders

Calls use an in-app invitation while Vesper is open and connected. Accept opens the call screen; Start call activates audio. Decline leaves the microphone off. InAppCalls owns audio activation, mute and end; audio interruptions end the session. Existing speech, voice playback and transcript records remain. There is no system incoming-call screen or closed-app incoming-call delivery.

Chat replies and attachments do not schedule message notifications. Anniversary notifications remain independent.

Settings → Calendar & Reminders reads the next seven days of events and incomplete reminders. Tap a writable event to open the system event editor, including recurrence handling. Tap a reminder to edit its title, notes and optional due date. Changes save to the existing item, not a duplicate. Read-only entries cannot be edited. Data stays in the configured system accounts and is not automatically sent to AI tools.

Device verification: accept/decline, microphone and speech denial, mute/end, audio interruption, transcript saving, edit/cancel/save for events and reminders, and compact voice playback. Simulator compilation does not verify device permissions or audio routing.
