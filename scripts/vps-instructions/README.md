# Vesper shared instructions

The live, private source of truth is `/home/ubuntu/AGENTS.md` on the existing VPS.
The `AGENTS.md` in this directory is a starter document, not a copy to overwrite the owner's live preferences. The initial migration also copies the owner's existing contact wording preferences into the live document. Keep private wording out of public deployment logs.

## Loading

- Updated native clients fetch authenticated `GET /agent-instructions` from their selected VPS history connection before sending and before preparing a resumed connection. They verify the content digest and compose the document with existing contact/project preferences, device rules, and call-specific context. A changed document causes the existing thread to be reconfigured, not replaced. Mac/iPad clients using VPS use the same code when updated. The separate local Mac backend remains independent.
- VPS `vesper_backend.codex_provider.Rpc.call` freshly reads the same file for `thread/start` and explicit instruction updates on `thread/resume`. This covers wake, arrival, screen companion, lock-screen/watch interactions, and the tool-free dream generator.
- Morning dreams explicitly supply their scene supplement when resuming the current conversation, so they also use the common document.
- A resume used only to inspect a thread and supplying no instruction update leaves the stored scene instructions alone. Ordinary `turn/start`, permissions, tool catalogs, model settings, schedules, sleep and budgets are unchanged.
- Long-running turns retain the instructions with which they started. Subsequent native sends and new background jobs read the new file. Old installed clients do not have the explicit refresh mechanism; install the updated app for existing conversations.
- Existing `nativeInstructions`, contact/project instructions, wake addenda and selfPrompt are retained. Function-specific rules remain with their scenarios; the shared document governs continuity, rather than duplicating all tool schemas.

## Installation and rollback

Upload this directory to a temporary VPS directory, run `python3 install.py`, then restart only `vesper-codex-history.service`. The wake timer starts a fresh process for each run; the foreground Codex service need not be restarted. Install first during a gap between active background tasks.

The installer checks exact source hooks before editing, compiles the edits, atomically replaces files, and records previous files in `vesper-codex-history/deploy-backups/agent-instructions-<timestamp>/manifest.json`. Existing `AGENTS.md` is never overwritten on reinstall. Restore backed-up files (and remove only new files listed as having no backup) to roll back, then restart history. Existing chat, memory and wake databases are never migrated or reset by this installer.

For an intentional instruction edit, back up the live file, write a new UTF-8 file under 24,000 bytes, validate with `vesper_agent_instructions.document()`, and atomically replace the source. The read and revision-checked save API is protected by the existing device-token authentication. Missing, invalid or oversized documents produce an error instead of silently falling back to a different identity.

Run `python3 -m unittest discover -s scripts/vps-instructions -p 'test_*.py'` locally. The native regression test is `ChatConnectionRecoveryTests.testSharedInstructionsRefreshExistingChatAndKeepProjectAndCallContext`.

Native Codex AGENTS discovery alone is insufficient here: non-repository discovery checks only the current directory, and instruction discovery is scoped to a run. See the [official loading rules](https://developers.openai.com/codex/guides/agents-md/). Vesper therefore explicitly supplies the common document through its existing developer-instruction field.

## Native editor
Settings → Ash & Activity → Agent Instructions reads the live VPS file. Authenticated POST /agent-instructions accepts content and its loaded SHA-256 revision. Concurrent stale writes return 409; writes are locked and replaced atomically with mode 0600. AGENTS.md.previous keeps the immediately previous document locally. The native editor preserves drafts on errors/conflicts and requires confirmation before discarding unsaved changes. Changes apply to subsequent turns or background runs.
