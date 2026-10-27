# Dream workflow status repair

Diagnosis: the October 19–21 morning dreams and greetings were persisted, but `jobs.status` stayed `saved`. The push request reused the sleep cycle ID (`dream:Asia/Shanghai:…+08:00`), which violates `/api/wake`'s `[a-zA-Z0-9:_-]{1,128}` validation. Exceptions were silently swallowed; the workflow treated `saved` as a running dream.

- Preserve original job/thread IDs; derive a stable SHA-256 transport request ID only for IDs outside the API contract. Valid existing push IDs remain unchanged for idempotency.
- Persist permanent notification errors as `push_failed`; transient errors retain the outbox and error receipt. A saved dream/greeting is complete even while an optional push is pending.
- Expire morning push attempts after 30 minutes from the saved greeting. Chat and memory stay intact; no old greetings or model runs are replayed. Respect all existing sleep, quiet, activity and message permission gates.
- Render running, failed, interrupted, silent, saved, and push outcomes accurately. Other wake presentation is unchanged.
- Repair historical pending pushes only after verifying the matching saved sleep cycle, memory reference, and exact message/turn metadata in history. Back up wake SQLite before changes.

Upload this folder to the VPS, stop the wake timer, wait for the active wake service to finish, run `patch.py`, run tests with `VESPER_TEST_RUNTIME_ROOT=/home/ubuntu/vesper-codex-history`, then `repair_history.py`, restart history service and resume the timer. Patches back up runtime files under `deploy-backups/dream-workflow-*`. Do not restart Codex or send test user messages.

Rollback: stop the timer and wait for executor exit; restore the four backed up Python files (remove the new helper if no prior backup), restart history and resume timer. Historical repairs affect only old optional notification state and should normally remain; the full wake backup is for inspected manual recovery, not wholesale replacement after new jobs have run.
