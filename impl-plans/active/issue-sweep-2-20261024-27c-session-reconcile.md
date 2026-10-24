# ISW2-27c: `riela session reconcile` for orphaned running sessions

**Status**: Active (not started)
**planId**: ISW2-27c-session-reconcile
**Issue**: https://github.com/tacogips/riela/issues/27 (P4, plus CLI resume parity and docs)
**Design Reference**: design-docs/specs/design-cancellation-and-orphan-session-resilience.md, section "2026-10-24 Contract (issue #27)": the P4 contract, and P1 items 6-7
**dependsOn**: ISW2-32-recovery-hydration, ISW2-27a-cancelled-status, ISW2-74a-dynamic-workflow-policy (serial operator amendment)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-27c-session-reconcile.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-27c/

## Intent and context

Sessions whose runner died with SIGKILL, or during shutdown, stay `running` forever. Every persisted runner already holds an exclusive non-blocking `flock` on `runtime-records/execution-locks/<sessionId>.lock` for its whole lifetime (`Sources/RielaCLI/SessionExecutionLock.swift:32-82,172-205`), and the kernel releases that lock when the process dies. So a session that is `running` but whose lock we can acquire is orphaned.

Terminal retention already uses this "acquire or treat as live" pattern (`Sources/RielaCLI/TerminalRetentionExecutor.swift:88-95`). This plan adds a dry-run-by-default sweep that marks orphans `cancelled`.

## Non-goals

- No pid/host/heartbeat fields.
- No passive reporting in `session status/health/list`.
- No GraphQL, web or library surface.
- No changes to nested invocation records.
- No `--older-than` filter.
- No detach/reattach.

## Write ownership

- `Sources/RielaCLI/SessionReconcileCommand.swift` (new)
- `Sources/RielaCLI/RielaClientFamilyArguments.swift`: only `SessionClientSubcommand` gains `case reconcile`
- `Sources/RielaCLI/RielaCommand.swift`: only `SessionCommand` gains `case reconcile([String])`
- `Sources/RielaCLI/RielaCommand+SessionParsing.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`: `runSession` dispatch and one help line
- `Sources/RielaCLI/CLISurfaceEnumeration.swift`: add `ParsedSessionReconcileArguments.helpMessage()` to the option-universe list
- `Sources/RielaCLI/SessionCommands.swift`: only `blocksResume` (shared with ISW2-32)
- `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`: only the two terminal predicates in `persist(sessionId:)` at about lines 158 and 163 (shared with ISW2-32, assigned here by review RV-27a-1)
- `Sources/RielaCore/SurfaceCatalog+Rows.swift`: one row in `sessionRows`
- `Tests/RielaCLITests/SessionReconcileCommandTests.swift` (new)
- `docs/session-cancellation-and-reconcile.md` (new)
- `impl-plans/progress/issue-sweep-2-20261024-27c-session-reconcile.md` (new)

## File-level changes

1. **`SessionReconcileCommand.swift`**: imitate `Sources/RielaCLI/SessionPruneCommand.swift`, which uses the `ParsableArguments` struct, `helpMessage`, and the JSON error envelope.
   - Arguments struct `ParsedSessionReconcileArguments`:
     - `@Option scope: String = "project"` (`project|user`);
     - `@Option sessionStore: String?`;
     - `@Option workingDir: String?`;
     - `@Option(name: .customLong("session")) sessionIds: [String] = []`;
     - `@Flag apply = false`;
     - `@Option output = "json"` (`json|text`).
   - Resolve the root with `CLIWorkflowSessionStore.resolveRootDirectory(sessionStore:scope:workingDirectory:)`. Invalid scope or output is a usage error.
   - Candidates are scalar SQL only; never `loadAll()`. Read-only queries on the session database collect the union, de-duplicated and sorted, of:
     - `SELECT session_id FROM cli_workflow_sessions WHERE status='running'`;
     - `SELECT workflow_execution_id FROM workflow_runtime_snapshots WHERE session_status='running'`.

     If `--session` is given, intersect with it. A `--session` id that is not running is reported with verdict `notRunning`. Find the database path through `CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory:)`.
   - Per candidate, with one `SessionExecutionLockRegistry(sessionStoreRoot:)` for the whole sweep:
     - `try registry.acquire(sessionId:)`;
     - catch `.alreadyRunning` → verdict `live`;
     - catch `.retiredSession` → verdict `retired`;
     - any other lock error → verdict `skipped` with the reason;
     - success → `orphaned`.
     - Always `registry.release(sessionId:)` in a `defer` once that session is processed.
   - With `--apply` and an `orphaned` verdict, while still holding the lock:
     1. Load the CLI record (`CLIWorkflowSessionStore.load(sessionId:)`) and the canonical snapshot (`SQLiteWorkflowRuntimePersistenceStore.load(sessionId:)`).
     2. If either is no longer `running`, report `skipped` with "changed during reconcile".
     3. Otherwise set on both: `status = .cancelled`, `failureKind = .cancelled`, `failureReason = "runner process lost; reconciled by riela session reconcile"`, `failedAt = now`, `updatedAt = now`, and every `running` execution `.cancelled` with the same reason.
     4. Persist with `CLIWorkflowSessionStore(...).save(record, runtimeSnapshot: snapshot)` (one transaction).
     5. A thrown error, for example `cancellationPending`, gives verdict `skipped` with the error text. Continue the sweep.
     6. CLI-only or canonical-only sessions: update whichever exists. `save(_:)` handles CLI-only; `SQLiteWorkflowRuntimePersistenceStore.save(_:)` handles canonical-only.
   - Output JSON (sorted keys):

     ```
     { "dryRun": Bool, "sessionStore": String,
       "sessions": [{ "sessionId", "workflowId", "verdict": "orphaned|live|retired|skipped|notRunning",
                      "applied": Bool, "reason": String? }] }
     ```

     The text output is one line per session. Exit 0 unless the store cannot be opened (failure) or the usage is wrong (usage).
2. **`RielaClientFamilyArguments.swift`**: add `case reconcile` to `SessionClientSubcommand`, so `CLISurfaceEnumeration` enumerates `session reconcile`.
3. **`RielaCommand.swift`**: add `case reconcile([String])` to `SessionCommand`.
4. **`RielaCommand+SessionParsing.swift`**: map `case .reconcile:` to `.session(.reconcile(family.remainder))`. Do not special-case it before the family parse the way `prune` is.
5. **`RielaCLIApplication.swift`**: route `case let .reconcile(arguments): return SessionReconcileCommandRunner().run(arguments)`. Add a help line next to the `session prune` line (about line 355):

   `riela session reconcile [--scope project|user] [--session-store <dir>] [--working-dir <dir>] [--session <id>]... [--apply] [--output json|text]`
6. **`CLISurfaceEnumeration.swift`**: add `ParsedSessionReconcileArguments.helpMessage()` to the help-message list that feeds `longOptionTokens`.
7. **`SurfaceCatalog+Rows.swift`**: add a `sessionRows` entry imitating `session.handover`:
   - `id: "session.reconcile"`, `kind: .mutation`, `cli: "session reconcile"`;
   - `cliOptions: ["--scope", "--session-store", "--working-dir", "--session", "--apply", "--output"]`;
   - the `graphql`, `webAPI` and `library` exclusions use the existing `SurfaceExclusion.localProcess("session reconciliation")` / `notAConsoleOperation` / `notALibraryEntryPoint` helpers (see `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift:3-9`);
   - `skills: []`.
   - Regenerate the SDL only if `SurfaceCatalogTests` reports that the generated SDL changed. Follow the test's instructions, which are expected to be a no-op for a CLI-only row.
8. **`SessionCommands.swift` `blocksResume`** (about line 962): also return true for `session.status == .cancelled`. This keeps CLI resume parity: a cancelled session is terminal.
8a. **`FailClosedSQLiteWorkflowRuntimeStore.swift` `persist(sessionId:)`** (about lines 158 and 163): replace `session.status == .completed || session.status == .failed` with `session.status.isTerminal`, which ISW2-27a adds. This makes `beforeTerminalPersistence` and terminal deferral run for cancelled sessions. ISW2-32's `hydrate(familyOf:)` hunk must stay intact: re-read the file just before editing.
9. **`docs/session-cancellation-and-reconcile.md`**: cover
   - the `cancelled` status (written by ISW2-27a), including `isCancellation`, legacy rows, and exit code 1;
   - gateway cancellation (ISW2-27b);
   - `session reconcile` usage, verdicts and the flock liveness rule, and that network-filesystem stores are unsupported;
   - that P3 auto-improve is not applicable (removed) and that P5 detach/reattach is a follow-up.

   Link the design section.

## Invariants

- A session whose lock is held by any live process is never modified (byte-identical `record_json` and `session_json`).
- `created` and `suspended` sessions are never candidates.
- A dry run performs no writes: no `save`, and no lock files beyond the `O_CREAT` the lock registry already does.
- The lock is released for every candidate, including on error paths.

## Pitfalls

- Hold the lock **across** the re-read and the save. Releasing it before saving opens a resume race.
- Do not use `TerminalRetentionExecutor` or the prune runner. They delete payloads.
- `SessionExecutionLockRegistry.acquire` returns early if the same registry already holds the id. Use one registry per sweep and release each id before moving on, so ids never collide.
- In the test, a "live" session must be held by a **different** registry instance (a separate fd), simulating another process. Holding it by the same registry would falsely acquire.

## Test cases (`SessionReconcileCommandTests`)

Use `RielaCLITemporaryDirectory`, and build records with `CLIWorkflowSessionStore.save(_:runtimeSnapshot:)`.

- Fixture: two `running` sessions A and B, one `created`, one `suspended`, one `completed`. B's lock is held by a separate `SessionExecutionLockRegistry`.
- Dry run → A `orphaned`, B `live`; created, suspended and completed are absent; every `record_json` is byte-identical before and after.
- `--apply` → A becomes status `cancelled`, `failureKind` `cancelled`, the stable reason, and its running executions are `cancelled` in both the CLI record and the canonical snapshot. B is byte-identical, `applied` is false.
- `--apply --session B` → B `live`, unchanged.
- `--session <completed id>` → `notRunning`.
- A canonical-only running snapshot with no CLI record → reconciled.
- A tombstoned running id → `retired`.
- Parser: `riela session reconcile --apply --output json` routes to the command; an unknown option gives exit 2.
- `blocksResume`: a resume of a cancelled session through `SessionResumeCommand` → terminal, with no new execution.
- FailClosed: a `FailClosedSQLiteWorkflowRuntimeStore` with a recording `beforeTerminalPersistence` closure; mark a session failed with `failureKind` `.cancelled` (status becomes `cancelled`) → the closure runs exactly once, and the canonical snapshot reads `cancelled`. Imitate the existing FailClosed terminal-hook tests (find them with `grep -rln beforeTerminalPersistence Tests`).

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-27c/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27c/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "SessionReconcileCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|CommandParsingTests" > tmp/issue-sweep-2-20261024/isw2-27c/focused.log 2>&1'` → exit 0.
3. `arch -arm64 /bin/zsh -lc '.build/debug/riela session reconcile --session-store "$PWD/tmp/issue-sweep-2-20261024/isw2-27c/empty-store" --output json > tmp/issue-sweep-2-20261024/isw2-27c/cli-smoke.log 2>&1'` → exit 0, and the output is `{"dryRun":true,...,"sessions":[]}`.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <owned Swift files>'` → no new warnings.
5. `grep -n "status == .completed || session.status == .failed" Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift` → empty.

## Execution protocol

Per-edit fresh read, with pre/post hash and intent snapshots under `tmp/issue-sweep-2-20261024/isw2-27c/snapshots/`. `SessionCommands.swift` and `FailClosedSQLiteWorkflowRuntimeStore.swift` were edited by ISW2-32: re-read each immediately before your edit, and confirm that ISW2-32's hunks are intact afterwards. Write only to your own progress log.

## Done criteria

- [ ] `riela session reconcile` exists, defaults to a dry run, and `--apply` marks only lock-free running sessions `cancelled`.
- [ ] Verification 1-4 pass, with logs.
- [ ] The docs file exists, and the progress log records the verification evidence.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.
