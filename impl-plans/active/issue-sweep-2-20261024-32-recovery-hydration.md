# ISW2-32: hydrate only the session family on resume and rerun

**Status**: Active (not started)
**planId**: ISW2-32-recovery-hydration
**Issue**: https://github.com/tacogips/riela/issues/32
**Design Reference**: design-docs/specs/design-cli-session-store-decode-resilience.md, section "Recovery hydration scope (issue #32, 2026-10-24)", Contract 1-6
**dependsOn**: ISW2-27a-cancelled-status (serial operator amendment)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-32-recovery-hydration.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-32/

## Intent and context

`riela session resume` (`Sources/RielaCLI/SessionCommands.swift:743`), `riela session rerun` (`:471`) and `riela workflow run --resume` (`Sources/RielaCLI/WorkflowRunCommand.swift:322-333`) all seed the in-memory runtime store with the entire persisted store before the first JSONL event. The work happens in `makeSeededProductionRuntimeStore(... hydrateSessions: true)`, which calls `seedRuntimeStoreFromPersistedCLIState` (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:534-597`). That function decodes every CLI record, every record's snapshot messages, and every canonical snapshot. `FailClosedSQLiteWorkflowRuntimeStore.hydrate()` (`Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift:45-50`) then runs a second full `loadAll()`.

The cost before the first event is therefore O(entire store). This plan hydrates only the target's **session family**: every canonical snapshot that shares the target's `root_session_id`, plus the target itself. Identity high-water marks stay metadata-only. The fresh-run precedent is `impl-plans/fresh-run-identity-hydration.md` (#156).

## Non-goals

- Fresh-run behaviour, decode tolerance and warnings stay as they are.
- No schema change and no new index; `idx_workflow_runtime_snapshots_root` already exists at `SQLiteWorkflowRuntimePersistenceStore.swift:741`.
- No timeout or abort logic for the unreproduced low-CPU wait.
- No change to how the runner reads sessions (`DeterministicWorkflowRunner+Recovery.swift`).
- Do not touch `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`. ISW2-27a owns it; put the new query in a new extension file.

## Write ownership

- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`: only `hydrate` becomes `hydrate(familyOf:)`. Do **not** touch the terminal predicates in `persist(sessionId:)` (about lines 158 and 163); ISW2-27c edits those later.
- `Sources/RielaCLI/SessionCommands.swift`: only the two `makeSeededProductionRuntimeStore` call sites
- `Sources/RielaCLI/WorkflowRunCommand.swift`: only `makeProductionDurableRuntime`
- `Sources/RielaCLI/WorkflowPackageParityCommands.swift`: only the call site at about line 449
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` (new)
- `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`
- `Tests/RielaCLITests/StartupIdentityRealStoreBenchmarks.swift`
- `Tests/RielaCLITests/SessionRecoveryHydrationScopeTests.swift` (new)
- `impl-plans/progress/issue-sweep-2-20261024-32-recovery-hydration.md` (new)

## File-level changes

### 1. `SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` (new, RielaCore)

- `public func sessionFamilyIds(of sessionId: String) throws -> [String]`
  - Validate the id with the existing `isSafeId`. If that is private, copy its check by calling `load` with the same guard pattern; do not widen access in the main file.
  - Missing database or table: return `[]`.
  - Otherwise, one SQL statement: select `workflow_execution_id` from `workflow_runtime_snapshots` where `root_session_id = (SELECT root_session_id ... WHERE workflow_execution_id = ?)`, ordered by `created_at, workflow_execution_id`.
  - If the target has no snapshot row, return `[]`. The caller adds the target itself.
- `public func loadFamily(ids: [String]) throws -> [WorkflowRuntimePersistenceSnapshot]`
  - Loop over the existing `load(sessionId:)`.
  - Skip `.notFound`; rethrow every other error.
- Imitate the open/query/mapping style of `SQLiteWorkflowRuntimePersistenceStore.sessionExists(sessionId:)` and `load(sessionId:strictReadOnly:)`.

### 2. `CLIWorkflowSessionStore.swift`

Add the hydration type:

```swift
enum RuntimeStoreHydration: Equatable, Sendable { case none; case family(of: String) }
```

`makeSeededProductionRuntimeStore(sessionStoreRoot:executionLocks:hydration:)`:

- Replace `hydrateSessions: Bool = true` with a required `hydration` parameter that has **no default**.
- Always run the existing metadata-only identity block first: `observeStartupIdentities` and `observePersistedIdentities`, with the 3-attempt `staleProjection` retry. Move it out of the `else` branch.
- For `.family(of:)`, then call `seedRuntimeStoreFromPersistedCLIState(_:sessionStoreRoot:familyOf:)`.

`seedRuntimeStoreFromPersistedCLIState(_:sessionStoreRoot:familyOf:)`:

- Compute `ids = [target] ∪ persistenceStore.sessionFamilyIds(of: target)`. Order: target first, then the rest, de-duplicated.
- For each id, keep today's per-session order:
  1. Try `sessionStore.load(sessionId:)`. It returns `CLIWorkflowSessionStoreError.notFound` for an absent or undecodable row, and that error must be treated as "no CLI record".
  2. If the CLI record exists, seed its session and then that id's canonical `workflowMessages` (skipping `.notFound`).
  3. Otherwise, seed the canonical snapshot's session and messages if it exists.
- Remove the `loadRawSessionIdentities` loop and both `loadAll()` loops from this function. Identity is now covered by item 2 above.
- Keep the durable-supervisor comment, reworded for family scope.
- Do **not** delete `loadAll()`, `loadRawSessionIdentities()` or `observePersistedExecutionIdentities`; other callers and tests may use them.

### 3. `FailClosedSQLiteWorkflowRuntimeStore.swift`

- `func hydrate(familyOf sessionId: String) async throws` replaces `hydrate()`.
- It seeds `persistence.loadFamily(ids: [sessionId] + persistence.sessionFamilyIds(of: sessionId))`, keeping the same seed calls.

### 4. Call sites

- `SessionCommands.swift:471` (rerun): `.family(of: persisted.session.sessionId)`.
- `SessionCommands.swift:743` (resume): `.family(of: persisted.session.sessionId)`.
- `WorkflowRunCommand.swift:322`: `hydration: options.resumeSessionId.map { .family(of: $0) } ?? .none`.
- `WorkflowRunCommand.swift:333`: `if let id = options.resumeSessionId { try await durableStore.hydrate(familyOf: id) }`.
- `WorkflowPackageParityCommands.swift:449`: `.none`. It is a fresh run; its request has no `resumeSessionId` (lines 458-463).

### 5. Tests

- `CLIWorkflowSessionStoreResilienceTests.swift`: update existing calls (lines 152, 181, 238, 282) to the new signatures. Assertions that relied on whole-store hydration must use `.family(of:)` with an id inside the fixture's family, or assert the new family-only behaviour. Do not delete coverage of unreadable-record identity: the next id must still exceed an unreadable row.
- `StartupIdentityRealStoreBenchmarks.swift`: mechanical signature update only.
- `SessionRecoveryHydrationScopeTests.swift` (new): use `RielaCLITemporaryDirectory` and never `~/.riela`.
  - Build the fixture as in `impl-plans/fresh-run-identity-hydration.md` and the existing resilience tests:
    - 200 unrelated sessions, each with a CLI record and a canonical snapshot whose executions carry about 256 KiB payloads, backend events and messages;
    - one target parent, `failed` with `maxStepsExceeded`;
    - one reserved cross-workflow child, whose `rootSessionId` and `parentSessionId` are the target;
    - one canonical-only reserved snapshot whose root is the target (no CLI record).
  - Write records through `CLIWorkflowSessionStore.save(_:runtimeSnapshot:)`.

## Invariants

- The next allocated session id, step execution id and communication id stay above every persisted value, including unrelated and unreadable ones.
- The CLI record wins over the canonical snapshot for the same id, as it does today.
- No SQL `UPDATE` or `DELETE` is added to any read path.
- Callers that pass a `resumeSessionId`/`rerunFromSessionId` always use `.family`; fresh runs always use `.none`.

## Pitfalls

- A target with no canonical row (CLI-only) must still be seeded as a family of one. `sessionFamilyIds` returns `[]`; do not throw.
- A rerun creates a **new** session: its id must come from the high-water marks (unrelated sessions included), never from a counter seeded only by the family.
- Do not call `loadAll()` anywhere in the new path. A grep check below enforces this.
- `root_session_id` is `COALESCE(rootSessionId, workflow_execution_id)`, so a top-level parent's own row matches its children. Do not also filter on `parent_session_id`.

## Test cases (`SessionRecoveryHydrationScopeTests`)

- `.family(target)` → `loadSession` returns sessions for the target, the child and the canonical-only snapshot, and returns nil for each of 10 sampled unrelated ids.
- After `.family(target)`, `createSession` for the target's workflow → the new id is greater than the highest unrelated numeric suffix.
- `.family(target)` seeding finishes in under 5 s (generous `XCTAssertLessThan` on wall time). Record the actual time in the progress log.
- `.none` → `loadSession(target)` is nil and identity is still advanced.
- A CLI-only target, with no canonical row → it is seeded and the call does not throw.
- `FailClosedSQLiteWorkflowRuntimeStore.hydrate(familyOf:)` → seeds only family ids.
- CLI path: `SessionResumeCommand` with an injected JSONL writer, on a target that is resumable (`maxStepsExceeded`), using a provider-free fixture workflow from `Tests/RielaCLITests` (imitate an existing session-resume test in `WorkflowCommandLivePersistenceTests`) → the first JSONL record arrives within 5 s. Do the same for `SessionRerunCommand` on that target and its step.

## Verification (log every command under tmp/issue-sweep-2-20261024/isw2-32/)

Record `exitStatus`, `testsRun` and `failureCount` (from "Executed N tests, with M failures") for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-32/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "SessionRecoveryHydrationScopeTests|CLIWorkflowSessionStoreResilienceTests" > tmp/issue-sweep-2-20261024/isw2-32/focused.log 2>&1'` → exit 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCommandLivePersistenceTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|WorkflowCommandSessionDiscoveryTests" > tmp/issue-sweep-2-20261024/isw2-32/regression.log 2>&1'` → exit 0. Run the nested-resume and session regression suites, and add every suite name containing `NestedPublication` or `NestedRecovery` found with `ls Tests/RielaCLITests Tests/RielaCoreTests`.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <each owned Swift file>'` → no new warnings in owned files.
5. `grep -n "loadAll()" Sources/RielaCLI/CLIWorkflowSessionStore.swift Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift` → no match inside `seedRuntimeStoreFromPersistedCLIState` or `hydrate(familyOf:)`. The `public func loadAll()` definition may remain.

If the build fails in a file outside the write ownership, a wave-1 sibling (ISW2-27a, ISW2-27b, ISW2-74a) may be mid-edit. Do not edit that file. Record the failure in the progress log and rebuild after a short interval.

## Execution protocol

- Before each edit, read the target file fresh and save a pre-hash and an intent note under `tmp/issue-sweep-2-20261024/isw2-32/snapshots/`. Save a post-hash after the edit.
- If a file changed unexpectedly between read and write, stop, re-read, and re-apply only your intended hunk.
- Edit only the listed files and your own progress log.

## Done criteria

- [ ] `hydrateSessions:` no longer appears in `Sources/` (`grep -rn "hydrateSessions" Sources` is empty).
- [ ] Verification 1-5 pass, with logs.
- [ ] The progress log records the root-cause summary, measured seeding times (family against legacy whole-store, if measured once), and every verification record.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.

> Operator amendment 2 (2026-10-24): every remaining plan also owns its own active plan file (this file) so it can update its completion checklist.
