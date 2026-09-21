# Native redesign handoff

Scope: Vera's supplied redesign specification plus the black/white/blue appearance and simplified Chat toolbar supplement. ROWAN.md belongs to ChatGPT and is deliberately outside this app change.

## Implementation

- Shared AppStore, ChatSession and per-conversation composer drafts under both shells. Native TabView/NavigationStack; the Vesper sidebar remains. Navigation and palette preferences are independent.
- Appearance popover: Apple Native / Vesper plus white / black / blue. Original supplied white/black scenes and emblems are included. Alternate Home Screen icons are compiled on macOS from those originals by scripts/prepare_icons.sh. Blue restores the existing icon.
- Chat header: Appearance and Archive. New Chat is inside Archive; Call stays in the attachment drawer. Sidebar weekly usage is outside the scrolling links.
- Memory: Timeline (recent/current/recalled), actual saved-tag relations, original-source Vault, memory details and immutable version history. Corrections and confirmation/demotion use existing APIs. Confidence is explicitly unrecorded when the backend has no confidence field; weight is not presented as confidence.
- A main room ID is stored in the existing profile document. Additional conversations remain in Archive. Native Chat uses a navigation push, so the system edge-back gesture returns to its list. Drafts are kept separately per conversation.
- History API supports latest-first pagination and scoped/full-history search. iOS reads the latest 200 messages and can load older pages; search opens and highlights the original message. Legacy web clients retain their existing response mode.
- Memory recall is refreshed through developerInstructions, never inserted as an extra user message. Raw saved history is independent of the app-server context. The app-server remains responsible for token-triggered compaction; compact_prompt asks it to incrementally preserve pending tasks, decisions, people, preferences and current technical state. This is not a second client-side summarizer or timer.
- New threads register search_native_history for read-only original-message retrieval. Existing threads retain their original tool catalog; the backend app-server does not advertise a supported dynamic-tools update for already created threads. Their manual history search still works.
- Desire: six-anchor Catmull–Rom interpolation, 1.2-second value transition, continuously changing multiscale waves, foam and caustics. No changes to Desire calculations or storage.
- Notes: editable draggable cards, lift/shadow, styles, rotation, zoom and layout persistence in each note's separate layout field. Layout-only mutations re-read the server body to avoid replacing newer text.
- Opening: deforming Canvas cloth mesh with fold lighting, wind motion and an Enter-driven opening before the existing fade. Reduce Motion skips the animation.

## Backend companion

Vesper-web / sites-release-ca9c513 contains additive memory evidence/source tables, immutable snapshots before corrections, evidence links, embedding-assisted Memory search and the VPS history paging/search endpoints.

Deploy the Worker through its existing wrangler.production.jsonc configuration, preserving all variables. Deploy the updated vps/codex_history_server.py to the existing history service and restart that service. Do not replace databases, credentials, timers or create duplicate services. SQLite/D1 additions are additive. This is separate from the wake runner and does not claim to fix the independent ChatGPT automation shown in earlier screenshots.

Semantic retrieval uses the existing embedding provider settings; without those credentials it retains the existing lexical-vector fallback. No provider configuration or live semantic behavior was verified in this workspace.

## Verification and release state

- Backend production build passed.
- SQLite regression passed: >1,000 messages, same timestamps, no pagination gaps/duplicates, scoped literal search, injection-like queries.
- Evidence regression passed: exact whitespace retained, repeat writes idempotent, changed originals append a new snapshot, owner isolation and source-link isolation.
- Full TypeScript check still reports errors in unchanged app/page.tsx, app/watch-player.tsx, capacitor.config.ts and existing test import settings. No reported errors in the changed memory modules.
- iOS project generation is deterministic and shell script syntax is checked. New Swift source syntax was checked; this is not an Xcode type check.
- iOS simulator compilation/tests, alternate icon generation on macOS, real-device visuals and live endpoint verification are outstanding.
- The initial git push was rejected by automatic approval review because this redesign was not explicitly authorized for external publication. No alternative upload route was attempted. Changes are local until Vera authorizes publishing this scope to the named repositories/branches. The required native build gate therefore could not be run between phases.
