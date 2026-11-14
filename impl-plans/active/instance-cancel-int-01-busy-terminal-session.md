# instance-cancel-int-01: Busy check ignores launches whose session is persisted terminal + ConfiguredLaunchCancelTests

**planId**: instance-cancel-int-01-busy-terminal-session
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-cancel.md §8.1 (D1, D2 "Required code fix (DR-01)", "Required deterministic regression coverage"); design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §3.1, §3.3; design-docs/user-qa/qa-instance-cancel-post-merge.md item 2
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-int-01-busy-terminal-session.md
**Evidence root**: tmp/instance-cancel-integration/int-01/

## Intent and context

Branch `feat/instance-cancel` (per-execution RielaApp instance cancel) has
origin/main `4841a578` merged in as `8ab7f848`. Main added a manual-run busy
check to `RielaWebWorkflowRequestHandler.launchConfiguredWorkflow`
(`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`). That
check returns HTTP 409 `instance_busy` unless `allowOverlap == true`, using
two rules:

1. **Rule 1:** an in-process `runtime.launches` entry with the same
   `identity` and `snapshot["status"] == "running"` is busy.
2. **Rule 2:** `LiveRootSessionProbe.liveRootSessions` (a store-live
   created/running root session holding its flock) is busy.

There are two problems:

- `ConfiguredLaunchCancelTests.testConfiguredLaunchCancellationIsIdentityAndSessionScoped`
  launches identity `one` twice without `allowOverlap`, so the second launch
  now gets 409 (expected main behavior).
- Confirmed window: the runner persists the root session `cancelled` before
  the launch task calls `job.finish(result)` (which sets the snapshot to
  `failed`). `riela instance cancel --wait` returns success as soon as the
  store reads `cancelled`. During that window, rule 1 still reports busy.
  The user requires that after a cancel, a new run is not refused with
  `instance_busy`.

## Non-goals

- Do not change rule 2, `LiveRootSessionProbe`, `allowOverlap` or
  `--allow-overlap` parsing, the 409 body shape, `run_limit`, the CLI
  mapping in `InstanceAppCommands.swift`, `WebWorkflowLaunch`, the cancel
  registries, or the cancel coordinator.
- Do not edit `docs/`, `README.md`, the design docs, or any file outside
  `writePaths`.
- Do not add sleeps or timing-based waits to prove the window. Coverage must
  be deterministic.

## File-level changes

### Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift

Modify only the rule-1 filter inside `launchConfiguredWorkflow(identity:source:configuration:variables:allowOverlap:)`
(the `if !allowOverlap { let running = runtime.launches.values.filter { ... } }`
block).

- A `running` launch with the same identity counts as busy **unless** its
  `snapshot["sessionId"]` is a known string **and** that root session's
  persisted status is terminal (`.cancelled`, `.completed` or `.failed`).
- Read the persisted status with the same read-only access the probe uses:
  `SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: context.sessionStoreRoot)).loadStrictReadOnly(sessionId:)`
  (imitate `Sources/RielaCLI/LiveRootSessionProbe.swift:liveRootSessions`).
  Before any load, first check `FileManager.default.fileExists` on the DB
  path (`SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`).
  If the DB is missing, the launch stays busy.
- **Fail-closed:** if the DB is missing, the record is missing (`notFound`),
  or the load throws any error, the launch **still counts as busy**. Only a
  successfully loaded terminal status removes it.
- A launch without a session id still blocks with `runningSessionId:
  "pending"`, exactly as today.
- A launch whose persisted status is `.created` or `.running` still blocks,
  with that session id.
- Keep the blocker ordering: in-process launches sorted by `createdAt`
  first, then rule 2.
- Pitfall: never open the store writable. Do not use
  `SQLiteWorkflowRuntimePersistenceStore.load` (non-strict) or anything
  that creates a schema or DB. The probe test
  `LiveRootSessionProbeTests.testMissingStoreDoesNotCreateAnything` shows
  the required read-only behavior.
- Pitfall: do not change the earlier `runtime.launches` pruning filter at
  the top of the function.
- Optional: extract a small `private` helper in the same file, for example
  `func launchSessionIsPersistedTerminal(_ sessionId: String) -> Bool`
  (returns false on any error). No new file, no public API.

### Tests/RielaCLITests/ConfiguredLaunchCancelTests.swift

1. In `testConfiguredLaunchCancellationIsIdentityAndSessionScoped`:
   - The **second** `launchConfiguredWorkflow` call passes `allowOverlap: true`.
     Keep both `XCTAssertEqual(..., 202)` assertions.
   - After the `launches did not start` guard (both are running), add: a
     third launch for `one` without `allowOverlap` returns status 409 with
     body `error.code == "instance_busy"` and
     `error.runningSessionId == ids[0]` (the oldest). Imitate the body
     decoding used in `Tests/RielaAppSupportTests/ConfiguredRunOverlapTests.swift`
     or decode `RielaHTTPResponse` the way other `RielaCLITests` do.
   - Every existing assertion stays unchanged, including the
     `cancelLaunch` results, `[ids[1]]` inventory, snapshot keys, `failed`
     launch status, persisted `.cancelled` and the `failureReason` string.
   - End-to-end check: after the existing `ids[1]` cancel, wait until the
     store reads `.cancelled` for `ids[1]` (bounded poll, ≤10 s, same style
     as the existing loops). Then assert that a launch for `one` without
     `allowOverlap` returns 202. Cancel that launch through
     `runtime.cancelLaunch` once its session id is known (or rely on
     `runtime.shutdown()`), and keep the final empty-inventory assertion.
2. Add a **deterministic** test `testBusyCheckIgnoresRunningLaunchWhoseSessionIsPersistedTerminal`
   (`@MainActor`, same fixture style; extract a private fixture helper in
   this file if useful). The workflow command for the 202 case should exit
   quickly (for example `/bin/sh -c true`), so no process is left running.
   - Setup: create `let stale = WebWorkflowLaunch(profile: "default",
     identity: "one")`, then `stale.append(#"{"sessionId":"stale-1"}"#)`, then
     `runtime.launches[stale.id] = stale`. Do not call `finish`, so the
     snapshot stays `running`. Persist root session `stale-1`
     (`workflowId: "cancel-test"`, `status: .cancelled`, no lock) through
     `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:
     canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)).save(WorkflowRuntimePersistenceSnapshot(session:))`.
     Imitate `Tests/RielaCLITests/LiveRootSessionProbeTests.swift:testFiltersClassificationOrderingAndSameProcessLiveness`.
   - Case A, persisted `.cancelled`: launch without `allowOverlap` → 202.
   - Case B, a separate stale launch with no `append` (no session id): launch
     without `allowOverlap` → 409 with `runningSessionId == "pending"`.
   - Case C, a stale launch with session `live-1` persisted `.running`: 409
     with `runningSessionId == "live-1"`.
   - Case D, a stale launch with session `ghost-1` that is not persisted:
     409 with `runningSessionId == "ghost-1"` (fail-closed).
   - Use a fresh fixture root, runtime and store for each case, or remove the
     earlier stale entries between cases, so cases do not mask each other.
     Call `await runtime.shutdown()` at the end of each case that launched.
   - Fixture roots go under `tmp/instance-cancel/…` like the existing test,
     with `defer` removal.

## Invariants

- `allowOverlap: true` bypasses both rules exactly as before.
- 409 body shape: `{"error":{"code":"instance_busy","runningSessionId":"<sid|pending>"}}`.
- The store is never created or migrated by the busy check.
- Rule 2 stays fail-open (the existing `try?` stays).

## Acceptance criteria

- Case A fails before the source change (409) and passes after it (202).
  Record both runs.
- All tests in `ConfiguredLaunchCancelTests` pass.
- Overlap tests in `RielaAppSupportTests` and the `InstanceApp` tests are
  unaffected.

## Verification (run from the worktree root; capture full log and exit status)

1. Before the source change, run only the new test (stash nothing; write
   the test first):
   `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter ConfiguredLaunchCancelTests/testBusyCheckIgnoresRunningLaunchWhoseSessionIsPersistedTerminal" > tmp/instance-cancel-integration/int-01/before.log 2>&1; echo $? > tmp/instance-cancel-integration/int-01/before.exit`
   Expected: non-zero, with a Case A 409 failure.
2. After the change:
   `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter ConfiguredLaunchCancelTests" > tmp/instance-cancel-integration/int-01/after.log 2>&1; echo $? > tmp/instance-cancel-integration/int-01/after.exit`
   Expected: exit 0, 0 failures.
3. `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter 'ConfiguredRunOverlap|InstanceApp|LiveRootSession'" > tmp/instance-cancel-integration/int-01/overlap.log 2>&1; echo $?`
   Expected: exit 0.
4. `/usr/bin/arch -arm64 /bin/zsh -lc "swiftlint lint Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift Tests/RielaCLITests/ConfiguredLaunchCancelTests.swift"`
   Expected: no violations.

## Done criteria (mechanical)

- `grep -n "allowOverlap: true" Tests/RielaCLITests/ConfiguredLaunchCancelTests.swift` matches.
- `grep -n "testBusyCheckIgnoresRunningLaunchWhoseSessionIsPersistedTerminal" Tests/RielaCLITests/ConfiguredLaunchCancelTests.swift` matches.
- `before.exit` is non-zero and `after.exit` is `0`.
- The progress log lists pre/post sha256 of both write paths, the commands,
  the exit codes and the log paths.

## Concurrency / drift rules

Before each edit, re-read the file fresh and record its sha256 in the
progress log. After the edit, record the new sha256. If a file changed
between your read and your write and you did not make that change, stop and
report drift. Do not touch the files of other plans
(`Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift`,
`Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift`). No git commands
other than read-only `git diff`/`git status`.

## Implementation status (Step 6)

Assigned implementation and focused verification completed; formal reviews and integration remain downstream. See the plan-local progress log for evidence.
