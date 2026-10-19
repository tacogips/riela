# ar-04-cli-lock-admission: lock inode hardening, orphan locks, message-retirement admission (RielaCLI)

```json
{
  "planId": "ar-04-cli-lock-admission",
  "planPath": "impl-plans/active/automatic-retention-04-cli-lock-admission.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCLI/SessionExecutionLock.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Tests/RielaCLITests/SessionExecutionLockTests.swift",
    "Tests/RielaCLITests/SessionMessageRetentionAdmissionTests.swift",
    "impl-plans/progress/ar-04-cli-lock-admission.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

This plan covers design §4.5 (orphan execution locks) and the admission rules
in §4.3.

- **Inode race.** `SessionExecutionLock.init`
  (`Sources/RielaCLI/SessionExecutionLock.swift:175`) opens with `O_CREAT` and
  takes `flock(LOCK_EX|LOCK_NB)`, but never checks that the locked inode is still
  the inode at the path. Unlinking lock files is unsafe until that check exists.
  About 1300 orphan lock files exist on the operator machine.
- **Message retirement.** Messages-only pruning (built by ar-05) writes
  `session_message_retention_tombstones`. Resume and continue must then fail
  closed through `SessionExecutionLockRegistry.acquire`. `session continue`
  delegates to `SessionResumeCommand`, which admits through
  `makeSessionExecutionAdmission(registry:)` at `SessionCommands.swift:741,798`.
  Rerun must reject such a source explicitly: `SessionRerunCommand` admits only
  its new session (`SessionCommands.swift:470,520`).
- **Executor tolerance.** The retention executor itself must be able to lock a
  messages-retired session (`allowMessagesRetired`).

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- Do not create the tombstone table in production code; ar-05 owns its DDL and
  triggers.
- Do not touch `TerminalRetentionExecutor.swift` (ar-05 switches it to the new
  options).
- Do not change session id formats or the lock path layout.

## Pinned table name and DDL

Tests create the table with this exact DDL. ar-05 uses the same DDL:

```
CREATE TABLE IF NOT EXISTS session_message_retention_tombstones(session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, pruned_at TEXT NOT NULL, message_bytes INTEGER NOT NULL)
```

## File-level changes

### `Sources/RielaCLI/SessionExecutionLock.swift`

1. Add `case messagesRetired(String)` to `SessionExecutionLockError`, with
   description `session '<id>' workflow messages expired under retention`.
2. `acquire(sessionId:allowRetired:allowMessagesRetired:)`: add
   `allowMessagesRetired: Bool = false`. The retired-session check is unchanged:
   it is skipped only when `allowRetired`. After it, when neither `allowRetired`
   nor `allowMessagesRetired` is set, the DB file exists and the table exists,
   a row for the id throws `.messagesRetired`. `allowRetired: true` skips both
   checks. On a throw, release the just-acquired lock, as the current
   retired-session branch does implicitly by not storing it. Keep that order.
3. `SessionExecutionLock.init` inode check: after `flock` succeeds, compare
   `fstat(fd)` with `stat(url.path)` on `st_dev` and `st_ino`. If `stat` fails
   with ENOENT, or the values differ, close the descriptor and retry
   open-and-flock. After 8 attempts, throw `.unavailable("lock file replaced
   concurrently")`.
4. Add to `SessionExecutionLockRegistry`:

   ```swift
   struct OrphanLockRemovalResult: Codable, Equatable, Sendable { var selectedCount: Int; var removedCount: Int; var skippedBusy: Int }
   func removeOrphanLocks(limit: Int = 2000, dryRun: Bool, sessionExists: (String) throws -> Bool) -> OrphanLockRemovalResult
   ```

   Rules:
   - List the lock root. Consider only regular files named `<id>.lock`, where
     `<id>` matches the existing id regex. Skip symlinks.
   - A candidate is a file where `!sessionExists(id)` and
     `heldLocks[id] == nil`, processed in sorted order and stopping at `limit`
     candidates.
   - In a dry run, count `selectedCount` and nothing else.
   - Otherwise, for each candidate:
     1. `open(path, O_RDWR|O_CLOEXEC)`. Do NOT pass `O_CREAT`; ENOENT means
        skip.
     2. `flock(LOCK_EX|LOCK_NB)`. EWOULDBLOCK increments `skippedBusy`; close
        and continue.
     3. Re-check `sessionExists(id)` under the lock. If it now exists, unlock,
        close and continue.
     4. Re-check inode equality as in the init check.
     5. `unlink`, then unlock and close, and increment `removedCount`.
   - Any error from `sessionExists` skips that file.
5. Add `func sessionMessagesRetired(sessionId: String) throws -> Bool` on the
   registry. It does a strictReadOnly lookup in the same DB, and returns false if
   the DB or table is missing.

### `Sources/RielaCLI/SessionCommands.swift`

Edit only inside `SessionRerunCommand.run` (around line 408). Right after
`CLIWorkflowSessionResolution.loadPersistedSession(...)` returns `loaded`, call
`SessionExecutionLockRegistry(sessionStoreRoot: loaded.storeRoot).sessionMessagesRetired(sessionId: <source session id>)`.
When it is true, fail with the error text `workflow messages expired under
retention`, using the same failure path and exit code the command uses for other
load failures. Make no other edits in this file.

## Patterns to imitate

- The existing retired-session check inside `acquire` (lines 57-64).
- `LockReservingWorkflowRuntimeIDGenerator`: its error mapping.
- `Tests/RielaCLITests/WorkflowCommandScenarioTests.swift:58-84`: how it runs
  workflow run, resume and rerun with `--workflow-definition-dir`,
  `--mock-scenario` and `--session-store` under a temp dir.

## Pitfalls

- Never pass `O_CREAT` in orphan removal. Re-creating a deleted lock file during
  a sweep defeats the purpose.
- The inode check must not change behavior when nothing races. The existing
  `SessionExecutionLockTests` must stay green.
- Do not map `messagesRetired` to `alreadyRunning`. Callers distinguish the two.
- Do not add the messages check to `loadPersistedSession`. That would break
  `session status`, `logs` and `export` for retired sessions.

## Tests

`SessionExecutionLockTests` (extend):

- three lock files for ids absent from an empty store DB, with one held by
  another registry -> `removedCount == 2`, `skippedBusy == 1`, and the held
  file is still present
- a lock file for a session present in `cli_workflow_sessions` -> kept
- a dry run -> `selectedCount` counted and every file still present
- `limit: 1` -> exactly one removed
- a symlink named `x.lock` -> untouched
- inode retry: acquire lock A, then from the test unlink and re-create the path
  before a second registry's acquire. The second acquire succeeds on the new
  inode, and a third acquire then reports `alreadyRunning`. Drive this through a
  small internal test seam (a `beforeVerify` closure on the lock init, defaulting
  to a no-op), not through timing.
- table row present -> `acquire` throws `.messagesRetired`;
  `acquire(..., allowMessagesRetired: true)` succeeds;
  `acquire(..., allowRetired: true)` succeeds; a results-tombstoned id with
  `allowMessagesRetired: true` still throws `.retiredSession`

`SessionMessageRetentionAdmissionTests` (new): run a mock workflow to completion
with a temp `--session-store`. Create the message tombstone table and insert the
completed session id.

- `session rerun <id> <step>` -> non-success exit, and the output contains
  `workflow messages expired under retention`
- `session resume <id>` -> non-success exit, and the output names the
  messages-retired error. The DB state is unchanged: no new session row.

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "SessionExecutionLockTests|SessionMessageRetentionAdmissionTests" > tmp/automatic-retention/ar-04-cli-lock-admission/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ (pre-existing SessionExecutionLockTests
   count + 9) and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionTests|WorkflowCommandScenarioTests" > tmp/automatic-retention/ar-04-cli-lock-admission/regression.log 2>&1'
   ```
   Must exit 0. If it fails only because of peer RielaCLI edits in progress,
   record that as peer drift.
3. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/SessionExecutionLock.swift Sources/RielaCLI/SessionCommands.swift Tests/RielaCLITests/SessionExecutionLockTests.swift Tests/RielaCLITests/SessionMessageRetentionAdmissionTests.swift > tmp/automatic-retention/ar-04-cli-lock-admission/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `grep -n "allowMessagesRetired" Sources/RielaCLI/SessionExecutionLock.swift` matches.
- `grep -n "func removeOrphanLocks" Sources/RielaCLI/SessionExecutionLock.swift` matches.
- `grep -n "workflow messages expired under retention" Sources/RielaCLI/SessionCommands.swift`
  matches.
- The progress records exist in `impl-plans/progress/ar-04-cli-lock-admission.md`.
