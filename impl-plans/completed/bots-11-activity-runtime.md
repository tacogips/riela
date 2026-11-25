# bots-11-activity-runtime: recorder in production runs, process-exit settlement, retention

```json
{
  "planId": "bots-11-activity-runtime",
  "planPath": "impl-plans/active/bots-11-activity-runtime.md",
  "dependsOn": ["bots-03-activity-core", "bots-09-run-linkage"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/BotRuntime",
    "Tests/RielaCLITests/BotActivityRuntime",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/SessionReconcileCommand.swift",
    "Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift",
    "Sources/RielaCLI/TerminalRetentionExecutor.swift",
    "impl-plans/progress/bots-11-activity-runtime.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/WorkflowRunCommand.swift", "intendedEdit": "Set request.activityRecorder where the run request is built (line 212-). Keep plan 09's botContext and link code unchanged."},
    {"path": "Sources/RielaCLI/SessionCommands.swift", "intendedEdit": "Set activityRecorder (and botContext rebuilt from the session's link) on the resume and rerun requests built at lines 618 and 894."},
    {"path": "Sources/RielaCLI/SessionReconcileCommand.swift", "intendedEdit": "After a session is marked failed as orphaned in reconcile(sessionId:...) (line 169-), call the process-exit settlement for that session."},
    {"path": "Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift", "intendedEdit": "After an abandoned invocation closes a child session, call the process-exit settlement for that child session."},
    {"path": "Sources/RielaCLI/TerminalRetentionExecutor.swift", "intendedEdit": "At the three session delete sites (near lines 382, 587, 758) also delete the session's activity rows and bot link row in the same transaction."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §6.4 (who injects the recorder), §6.6 (wait source), §6.7
(`processExit`), §4.1 (retention). Plan 03 built the recorder and the runner
hook; nothing uses it in production yet. This plan turns it on for real runs
and closes the two paths the runner cannot see: a process that died, and a
session deleted by retention.

Current code:

- Run request for `riela workflow run`: `WorkflowRunCommand.swift:212`.
- Resume and rerun requests: `SessionCommands.swift:618`, `:894`.
- Orphan reconcile: `SessionReconcileCommandRunner.reconcile(sessionId:...)`
  (`SessionReconcileCommand.swift:169-`), abandoned nested invocations:
  `SessionAbandonedInvocationReconciler.swift:53-`.
- Retention deletes session rows in `TerminalRetentionExecutor.swift` near
  `:382`, `:587`, `:758`.
- Plan 03: `SQLiteWorkflowActivityRecorder`, `BotStore.settleOpenActivity`,
  `BotStore.deleteActivity(sessionIds:in:)`. Plan 09: `BotRunLinker`.

## Non-goals

- No recorder for parity, staged-verification or package-parity runners
  (`ScopedParityCommands.swift`, `WorkflowStagedVerification.swift`,
  `WorkflowPackageParityCommands.swift`): they keep running without activity.
- No CLI or GraphQL read of activity (plan 12).
- No change to what retention selects for deletion.

## Changes

### `Sources/RielaCLI/BotRuntime/BotActivityRuntime.swift` (new)

- `enum BotActivityRuntime`
  - `static func recorder(sessionStoreRoot: String) -> any WorkflowActivityRecording`
    → `SQLiteWorkflowActivityRecorder(sessionStoreRoot: canonical root)`. Use
    the same canonical root function the runtime store uses
    (`canonicalRuntimeStoreRoot(sessionStoreRoot:)`).
  - `static func botContext(forExistingSession sessionId: String, sessionStoreRoot: String) -> BotRunContext?`:
    looks up the link of the session's root id; nil when unlinked or the bot
    is gone. A paused bot still returns a context (pause does not stop
    running or resumed work).
  - `static func settleProcessExit(sessionId: String, sessionStoreRoot: String, now: Date)`:
    calls `BotStore.settleOpenActivity(reason: .processExit)`; errors are
    written to stderr with the prefix `riela activity settle:` and ignored.
  - `static func deleteRuntimeRows(sessionIds: [String], in db: SQLiteDatabase) throws`:
    `BotStore.deleteActivity` plus `DELETE FROM bot_session_links WHERE session_id = ?`,
    each guarded by `db.tableExists`.

### Wiring

- `WorkflowRunCommand`: `request.activityRecorder = BotActivityRuntime.recorder(...)`
  for every local, non-remote run that persists to a session store (the same
  condition under which live persistence is configured). Runs without a bot
  get a recorder too: their stream is `session`-sourced or `acp`-sourced and
  permission waits stay 0.
- `SessionCommands` resume and rerun: set `activityRecorder`, and
  `botContext` from `botContext(forExistingSession:)` for resume. For rerun
  the new session is unlinked unless the source root session is linked, in
  which case link the new session to the same bot with `source = "run"` and
  `sourceRef = <source session id>` and pass the context.
- Reconcilers: call `settleProcessExit` right after the session is persisted
  as failed/orphaned, inside the same lock scope.
- Retention: call `deleteRuntimeRows` beside the existing deletes.

## Imitate

- `SessionCommandLivePersistence.swift:makeDurableSessionRuntime` for
  canonical root handling.
- The existing `if try db.tableExists(...)` guards in
  `TerminalRetentionExecutor.swift:381-390`.

## Pitfalls

- Stores created before generation 13 are migrated on the first writable
  open; the retention code may run against a database where the tables do not
  exist yet. Always guard with `tableExists`.
- The recorder must use the canonical runtime root, or its rows land in a
  different database than the sessions.
- Do not settle sessions that the reconciler decided are `live`, `retired`
  or `skipped`.
- Remote runs (`--endpoint`) must not create a local recorder.
- Nothing here may fail a run: recorder construction cannot throw.

## Tests (`Tests/RielaCLITests/BotActivityRuntime/`)

`BotActivityRuntimeTests` (temporary roots, mock scenario runs):
- `workflow run` of a two-step mock workflow → `activity_events` has
  `stepStarted`, `stepFinished`, `settled` per step in seq order;
  `activity_state.source == "session"`.
- the same run with `--bot` → rows exist and the link row exists.
- a store seeded with a running session, an open tool call and a pending
  request, then `session reconcile --apply` (or `reconcileOrphanedRoots`) →
  tool call `interrupted`, request `cancelled` with `resolved_by settlement`,
  one `settled` event with reason `processExit`; running it again adds no
  event.
- retention pruning a terminal session (use the existing retention test
  helpers under `Tests/RielaCLITests` for a minimal prune) → no
  `activity_events`, `activity_state`, `activity_requests` or
  `bot_session_links` rows remain for it; rows of another session remain.
- retention against a generation-12-shaped database without the tables →
  no error.
- resume of a suspended bot-linked session → the resumed request carries a
  bot context (assert through the link and a recorded `stepStarted`).

## Verification

```
mkdir -p tmp/bots-overview/bots-11-activity-runtime
arch -arm64 /bin/zsh -lc 'swift test --filter "BotActivityRuntimeTests|BotRunLinkageTests|SessionReconcileCommandTests|SessionAbandonedInvocationTests|TerminalRetentionTests|TerminalRetentionPolicyTests"' > tmp/bots-overview/bots-11-activity-runtime/test.log 2>&1
```

Exit 0. The existing suites are in
`Tests/RielaCLITests/SessionReconcileCommandTests.swift`,
`SessionAbandonedInvocationTests.swift`, `TerminalRetentionTests.swift` and
`TerminalRetentionPolicyTests.swift` (the filter matches class names; if a
class name differs from its file name, use the class name and record the
exact filter in the progress log). Evidence: activity rows are written by real runs, settled on
process exit and removed by retention; reconcile and retention suites are
unchanged.

## Done criteria

- `grep -n "activityRecorder" Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/SessionCommands.swift` shows the three request sites.
- `grep -n "deleteRuntimeRows" Sources/RielaCLI/TerminalRetentionExecutor.swift` shows three call sites.
- Verification exits 0; progress log written.
