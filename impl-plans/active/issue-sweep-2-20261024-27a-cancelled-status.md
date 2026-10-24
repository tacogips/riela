# ISW2-27a: first-class `cancelled` session and step status

**Status**: Active (not started)
**planId**: ISW2-27a-cancelled-status
**Issue**: https://github.com/tacogips/riela/issues/27 (P1)
**Design Reference**: design-docs/specs/design-cancellation-and-orphan-session-resilience.md, section "2026-10-24 Contract (issue #27)", subsection "P1 contract", items 1-8
**dependsOn**: none (serial operator amendment)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-27a-cancelled-status.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-27a/

## Intent and context

Graceful cancellation (SIGINT/SIGTERM, task cancellation, operator move) is persisted today as `status = failed, failureKind = cancelled`. The path is `finalizeInterruptedSessionFailed` in `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:9`, which calls `InMemoryWorkflowRuntimeStore.markSessionFailed` (`Sources/RielaCore/RuntimeStore.swift:601`). This plan adds a real `cancelled` terminal status for sessions and step executions.

`WorkflowSessionFailureKind.cancelled` already exists (`RuntimeSession.swift:37`) and is **kept** on cancelled sessions.

## Non-goals

- No `session reconcile` and no `blocksResume` change in `SessionCommands.swift`. ISW2-27c owns both.
- No gateway adapter change; ISW2-27b owns it.
- No exit-code change: cancelled runs still exit 1.
- Resuming a `cancelled` session stays terminal; it is not made resumable.
- No pid/heartbeat fields. No row rewrites of old stores. No web or RielaApp UI work.
- Do not touch `Sources/RielaCLI/SessionCommands.swift`, `CLIWorkflowSessionStore.swift`, `WorkflowRunCommand.swift` or `FailClosedSQLiteWorkflowRuntimeStore.swift` (ISW2-32).

## Write ownership

Sources:

- `Sources/RielaCLI/TaskDispatch+Handover.swift`
- `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift`
- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`
- `Sources/RielaCore/SessionObservability.swift`
- `Sources/RielaCore/LoopOutcomeNotification.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Sources/RielaCLI/SpecialistCommands.swift`
- `Sources/RielaCLI/SessionObservabilityRendering.swift`
- `Sources/RielaWork/WorkStore+Reservation.swift`
- `Sources/RielaCLI/WorkflowRunLivePersistence.swift`: only the terminal predicate at about line 146
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`: only the predicate at about line 174
- `Sources/RielaCore/RuntimeHistoryImport.swift`: only the source-status guard at about lines 59-61
- `Sources/RielaCore/DeterministicWorkflowRunner+History.swift`: only the execution predicate at about line 57
- `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`: only the terminal predicate at about line 342
- `Sources/RielaCLI/TaskDispatch.swift`: only the predicates at about lines 265, 438 and 445
- `Sources/RielaCLI/TaskDispatch+Director.swift`: only the predicates at about lines 185, 239, 270, 370 and 543
- `Sources/RielaCLI/ScopedParityCommands.swift`: only the terminal-session guard at about line 365

Tests:

- `Tests/RielaCoreTests/WorkflowCancelledStatusTests.swift` (new)
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFailureStateTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`
- `Tests/RielaCoreTests/RuntimeStoreTests.swift`
- `Tests/RielaCoreTests/SpecialistSupervisorRecoveryTests.swift`
- `Tests/RielaWorkTests/WorkStoreCancellationTests.swift`
- `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift`
- `Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift`
- `Tests/RielaCLITests/TaskHandoverDispatchTests.swift`
- `Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift`
- `Tests/RielaCLITests/TaskRuntimeExampleTests.swift`
- `Tests/RielaCLITests/EventCronOverlapTests.swift`
- `Tests/RielaCLITests/ServeHTTPCommandTests.swift`
- `Tests/RielaCLITests/SpecialistMonitorControlCommandTests.swift`
- `Tests/RielaCLITests/SpecialistServiceResponsivenessTests.swift`
- `Tests/RielaCLITests/WorkflowCommandAutoImproveTests.swift`

Progress:

- `impl-plans/progress/issue-sweep-2-20261024-27a-cancelled-status.md` (new)

In the existing test files, edit only assertions that expect `failed` together with cancellation. Leave a file untouched if it already passes.

## File-level changes

1. **`RuntimeSession.swift`**
   - Add `case cancelled` to `WorkflowSessionStatus` and to `WorkflowStepExecutionStatus`.
   - Give both enums a tolerant `init(from:)`: decode a `String`; if it maps to a case use that, otherwise use `.failed`. Keep `encode` as the raw value.
   - Keep `CaseIterable` on `WorkflowSessionStatus`.
   - Add `public var isCancellation: Bool { failureKind == .cancelled && (status == .cancelled || status == .failed) }` on `WorkflowSession`.
   - Add `public var isTerminal: Bool` on `WorkflowSessionStatus` (`completed`, `failed`, `cancelled`).
2. **`RuntimeStore.swift`**
   - `markSessionFailed`: set `session.status = input.failureKind == .cancelled ? .cancelled : .failed`, and set each running execution to `.cancelled` or `.failed` by the same rule. All other fields (reason, kind, `failedAt`, budget diagnostic) stay as they are.
   - `updateStepExecution` switch (about line 563): add a `.cancelled` arm that marks the session `.cancelled` the same way the terminal `.failed` arm marks it failed.
   - Private `WorkflowStepExecutionStatus.isTerminal` (about line 885): `.cancelled` is terminal.
3. **`DeterministicWorkflowRunner+Cancellation.swift`**
   - In the unpersisted fallback (lines 72-75), set `status = failureKind == .cancelled ? .cancelled : .failed`.
   - Keep the function name; renaming is not needed.
   - `exitCode` stays 1.
4. **`DeterministicWorkflowRunner+Recovery.swift`**
   - `resolveResumeEntry`: treat `existing.status == .cancelled` exactly like the non-resumable `failed` case. Return the terminal result with `exitCode` 1. This is required because `cancelled` would otherwise fall through to `.proceed`.
   - `resolveRerunEntry`: add `.cancelled` to the allowed non-preserve sources (line 129) and update the error text to "failed, cancelled, suspended or completed".
5. **`DeterministicWorkflowRunner+CrossWorkflow.swift`**
   - In the catch block (about line 210), `terminalChild.status == .failed` becomes `terminalChild.status == .failed || terminalChild.status == .cancelled`. Nothing else changes.
6. **`SessionObservability.swift`**: both `isTerminal` switches add `.cancelled` to the terminal arm. The `failureKind == .cancelled` early returns stay.
7. **`LoopOutcomeNotification.swift`**: `.cancelled` → `nil`, so no loop outcome notification is sent for an infrastructure kill. Add an explicit arm.
8. **`SQLiteWorkflowRuntimePersistenceStore.swift`**
   - Pending-cancellation guard (about lines 834-836): `allowedPendingTerminal` accepts `snapshot.session.isCancellation`, or `status == .failed && failureKind == .stalled && pendingHandover`.
   - Terminal-transition guard (about lines 843-850): `previousStatus` counts as terminal for `.cancelled` too. The `sameTerminal` comparison stays.
9. **`SpecialistCommands.swift:555-558`**: `.cancelled` joins the `.completed, .failed` arm.
10. **`SessionObservabilityRendering.swift:11`**: health verdict is `"failed"` for `.failed`, `"cancelled"` for `.cancelled`, and otherwise `"ok"`.
11. **`WorkStore+Reservation.swift`**
    - Prelaunch (about lines 523-533) and joined (about lines 566-576) cancellation:
      - the idempotence checks use `snapshot.session.isCancellation`;
      - the writes set `status = .cancelled`;
      - the `created`/`running` guards are unchanged.
    - `acknowledgeAttemptCancellation` (about line 619): accept `canonicalOutcome.sessionStatus == .cancelled || canonicalOutcome.sessionStatus == .failed`, with `failureKind == .cancelled`.
12. **Compile-forced sites**
    - Run `swift build`. Fix any further exhaustive switch over either enum, but only inside the files listed above.
    - If a needed file is not listed, record it in the progress log as a dependency object `{path, reason}` and stop for serial reconcile. Do not edit it.
    - `LoopWorkflowStats.swift` needs no change: its `default:` already excludes `cancelled` from the failure count.
13. **Non-exhaustive terminal predicates.** These compile without change but would silently treat `cancelled` as non-terminal. Fix each one.
    - **Session checks.** Replace `status == .completed || status == .failed` with `status.isTerminal`, and `!= .completed && != .failed` with `!status.isTerminal`. Add `.cancelled` to every `terminalStatuses: [...]` set. Sites:
      - `SQLiteWorkflowRuntimePersistenceStore.swift:624`: loop concurrency lease release, so a cancelled session must release its `loop_concurrency_leases` row;
      - `SQLiteWorkflowRuntimePersistenceStore.swift:818`: work-cancellation terminal handling;
      - `SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift:174`: `recordNestedChildTerminal` must accept a cancelled child;
      - `DeterministicWorkflowRunner+Fanout.swift:342`: a cancelled branch child is terminal, so its `terminalFailureKind` is recorded;
      - `WorkflowRunLivePersistence.swift:146`: `requireCommittedCanonicalTerminal` runs for cancelled sessions;
      - `TaskDispatch.swift:265`;
      - `TaskDispatch.swift:438,445`: keep `.suspended` in that set, and add `.cancelled`;
      - `TaskDispatch+Director.swift:185,239,270,370,543`;
      - `WorkStore+Reservation.swift:927,1034`;
      - `ScopedParityCommands.swift:365`: a step call on a cancelled session is rejected the same way as on a failed one.
    - **Step-execution check.** `DeterministicWorkflowRunner+History.swift:57`: the rerun boundary accepts `.completed || .failed || .cancelled` executions.
    - **Rerun source.** `RuntimeHistoryImport.swift:59-61`: `importAcceptedHistory` accepts a `.cancelled` canonical source, alongside `failed`, `suspended` and `completed`.
    - **Recovery.** `DeterministicWorkflowRunner+Recovery.swift:73,130` is covered by item 4.
    - **Not in this plan.** `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift:158,163` belongs to ISW2-32 in wave 1. Its terminal-predicate edit is assigned to ISW2-27c (wave 2) as a shared path. Do not edit it here. Until 27c lands, the FailClosed terminal hook skips cancelled sessions; this is a known intermediate state.
    - `Sources/RielaCLI/WorkflowPreflightAttemptStore.swift:77` and `WorkflowTransactionGenerationStore.swift:179` are maps over other enums, not session status. Leave them unchanged.

## Invariants

- `failureKind == .cancelled` holds exactly when a newly written terminal status is `.cancelled`. `stalled` and `leaseLost` stay `failed`.
- Legacy rows with `failed` and `cancelled` stay readable and satisfy `isCancellation`.
- An unknown persisted status decodes as `.failed` and never crashes the reader.
- No exit-code change.

## Pitfalls

- Do not add `cancelled` as only a computed projection. It must be the persisted `status` raw value `"cancelled"`, which the generated `session_status` column picks up automatically.
- `WorkflowSessionStatus(rawValue:)` call sites (`SessionDiscoveryCommand.swift:57`, `RielaGraphQL.swift:156`, the web summaries) need no edit.
- Fanout: the `failureKind` logic at `DeterministicWorkflowRunner+Fanout.swift:322,365` stays unchanged. The status check at `:342` **must** treat `.cancelled` as terminal (item 13).
- Boolean `||` predicates and `terminalStatuses` arrays are not compile-forced. Use the grep gate in verification step 6 to find all of them, not the compiler.

## Test cases (`WorkflowCancelledStatusTests`, new)

- Runner with a node adapter that blocks until cancelled; cancel the run task → the persisted session status is `.cancelled` with `failureKind` `.cancelled`; the in-flight execution is `.cancelled`; the emitted `session_completed` event has status `cancelled`.
- `markSessionFailed` with `failureKind` `.adapterFailure` → `failed`. With `.stalled` → `failed`.
- JSON `{"status":"someFutureStatus"}` decodes as `.failed`, for both enums.
- A legacy session with `failed` and `cancelled` → `isCancellation` is true.
- Resume of a `cancelled` session → a terminal result with `exitCode` 1, and no new execution.
- Rerun from a `cancelled` source → a new session is created.
- A cross-workflow child cancelled with its parent → the nested terminal is recorded, and `childTerminalSnapshot.session.status` is `.cancelled`.
- SQLite persistence: save a `running` snapshot, then a `cancelled` snapshot → accepted. A second, different terminal write after `cancelled` → rejected by the same guard that protects `failed`.
- A cancelled source → `importAcceptedHistory` succeeds (no `messageAppendRejected`).
- Durable store: `recordNestedChildTerminal` with a cancelled child terminal snapshot → accepted, not "nested child terminal snapshot is invalid".
- A session holding a `loop_concurrency_leases` row, saved as `cancelled` → the lease row is released. Imitate `Tests/RielaCoreTests/LoopConcurrencyLeaseTests.swift`.
- A fanout branch child that ends `cancelled` → the parent's fanout records the branch as terminal with `terminalFailureKind` `cancelled`. Put this in `WorkflowCancelledStatusTests` or `DeterministicWorkflowRunnerFanoutTests`.
- Rerun boundary: a source whose executions before the boundary include a `cancelled` one → the rerun preflight accepts it (`DeterministicWorkflowRunner+History.swift:57`).
- CLI, in `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift`: a reserved task session that ends `cancelled` reaches terminal reconciliation. It is not rejected with "reserved task session did not reach a durable terminal state", and the director wait ends.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-27a/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCancelledStatusTests|RuntimeStoreTests|DeterministicWorkflowRunnerFailureStateTests|DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|DeterministicWorkflowRunnerTests|LoopConcurrencyLeaseTests|RuntimeHistoryImportHandoverTests|WorkflowPreservedHistoryTests|WorkflowRerunFinalizationEvidenceTests|WorkflowRerunInputCarryoverTests|WorkflowHistoryModelsTests" > tmp/issue-sweep-2-20261024/isw2-27a/core.log 2>&1'` → exit 0. The suite names were pinned with `ls Tests/RielaCoreTests | grep -iE 'rerun|history|nested|lease|concurrency'`.
3. `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaWorkTests" > tmp/issue-sweep-2-20261024/isw2-27a/work.log 2>&1'` → exit 0.
4. `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskCancellationIntegrationTests|TaskHandoverDispatchTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|EventCronOverlapTests|ServeHTTPCommandTests|SpecialistMonitorControlCommandTests|SpecialistServiceResponsivenessTests|WorkflowCommandAutoImproveTests|SessionPreservedHistoryTests|LoopConcurrencyPreflightTests|WorkflowHistoryAdversarialTests" > tmp/issue-sweep-2-20261024/isw2-27a/cli.log 2>&1'` → exit 0.
5. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <owned Swift files>'` → no new warnings.
6. Run two grep gates:
   - `grep -rn "status == .failed && .*failureKind == .cancelled" Sources` → empty.
   - `grep -rnE "status == \.completed \|\| .*status == \.failed|status != \.completed && .*status != \.failed|terminalStatuses: \[\.completed, \.failed\]" Sources | grep -v '^Sources/RielaApp/' > tmp/issue-sweep-2-20261024/isw2-27a/terminal-grep.log` → only the two `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift` lines (158, 163) may remain. Record each as the dependency object `{path: "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift", owner: "ISW2-27c-session-reconcile"}` in the progress log. Any other hit is either fixed or justified in the progress log.

A sibling (ISW2-32, ISW2-27b, ISW2-74a) may break the build in a file you do not own. Do not edit that file. Record it and rebuild later.

## Execution protocol

Per-edit fresh read, with pre/post hash and intent snapshots under `tmp/issue-sweep-2-20261024/isw2-27a/snapshots/`. On drift, re-read and re-apply only your hunk. Write only to your own progress log.

## Done criteria

- [ ] Both enums have `cancelled` and tolerant decode.
- [ ] Verification 1-6 pass, with logs recorded in the progress log.
- [ ] The progress log lists every test file whose assertions changed, and the reason.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.

## Checkpoint amendment round 1 (2026-10-24): ISW2-27a-INT-RETENTION-CANCELLED

Source: `dispatch-plans` comm-000043, `reason: integration-paths-outside-writePaths`, severity mid. Everything above stays as it is; this section only adds a repair. The plan ID and the serial order do not change.

### Added write ownership

- `Sources/RielaCore/TerminalRetentionPlan.swift`: only the family status check at about line 72.
- `Tests/RielaCoreTests/TerminalRetentionPlanTests.swift`: append new test methods only.
- `Tests/RielaCoreTests/WorkflowRerunInputCarryoverTests.swift`: 27a work already modified this file. Ownership is granted so the change is attributed to 27a. Make no further edits unless the core filter fails in it.

### Problem

`TerminalRetentionPlan.make` (`Sources/RielaCore/TerminalRetentionPlan.swift:72`) marks a family `nonterminalOrConflictingStatus` when any member's `statuses` is not a subset of the string literal `["completed", "failed"]`. `statuses` holds raw `session_status` strings: `TerminalRetentionMetadata.swift:12,20,89` reads them from `workflow_runtime_snapshots.session_status` and `cli_workflow_sessions.status`. Both are generated columns over `session.status` (`CLIWorkflowSessionStore.swift:431`), so a cancelled session reports `"cancelled"` in both sources. Since 27a persists `"cancelled"`, every family with a cancelled member is never pruned by automatic retention or `riela gc`. Before 27a, the same runs were stored as `failed` and were pruned.

### Ordered changes

1. In `TerminalRetentionPlan.make`, the terminal set becomes `"completed"`, `"failed"` and `"cancelled"`. A preferred, optional form derives it from `WorkflowSessionStatus.allCases.filter(\.isTerminal).map(\.rawValue)` (27a added `isTerminal` in `RuntimeSession.swift`; the enum is `CaseIterable`). Either form is acceptable. Keep the `statuses.count != 1` check unchanged.
2. Append two methods to `TerminalRetentionPlanTests`, using the existing `row(...)` and `plan(...)` helpers:
   - `row("cancelled-root", status: ["cancelled"])` (25 h old, retention 24 h) → `selected.map(\.rootId) == ["cancelled-root"]`, `protected` is empty.
   - `row("root", status: ["cancelled"])` plus `row("child", hours: 1, status: ["running"], parent: "root", root: "root")` with `cap: 1` → `selected` is empty, and `protected.first?.protection == "nonterminalOrConflictingStatus"` with ids `["child", "root"]`.
   - Optional: `row("mixed", status: ["cancelled", "failed"])` → protected (conflicting projection). This pins that `count != 1` is kept.
3. Record the fail-before/pass-after evidence and the changed files in `impl-plans/progress/issue-sweep-2-20261024-27a-cancelled-status.md`. Evidence that the test fails before the change can be the assertion failure from a run of the new test before step 1, or a reasoned citation of line 72 if the source was already edited. Say which one you used.

### Forbidden changes

- Do not touch `Sources/RielaCLI/TerminalRetentionExecutor.swift` (locking, lineage, protection ordering) or `Sources/RielaCLI/TerminalRetentionMetadata.swift`.
- Do not make `running`, `created` or `suspended` prunable, and do not remove the `statuses.count != 1` conflict check.
- Do not edit `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift:162,167`; ISW2-27c owns them.
- Do not edit, weaken or delete the five existing `TerminalRetentionPlanTests` methods or `Tests/RielaCLITests/TerminalRetentionTests.swift`.
- Do not edit `Sources/RielaCLI/LoopCommands.swift:294`. That line is the `riela loop list --status` value allowlist, not a terminal predicate. Record it in the progress log as the follow-up `{path: "Sources/RielaCLI/LoopCommands.swift", reason: "--status filter does not accept 'cancelled'"}`.

### Amendment verification (logs under tmp/issue-sweep-2-20261024/isw2-27a/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build-int2.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-2-20261024/isw2-27a/build-int2.log'` → exitStatus=0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionPlanTests|TerminalRetentionTests|WorkflowCancelledStatusTests" > tmp/issue-sweep-2-20261024/isw2-27a/retention-int2.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-2-20261024/isw2-27a/retention-int2.log'` → exitStatus=0, testsRun > 0, failureCount 0. The log shows the two new methods passing.
3. Rerun the core, work and full 137-test CLI filters from Verification 2-4 above into `core-int2.log`, `work-int2.log` and `cli-int2.log`. The CLI rerun also covers the earlier repair request ISW2-27a-INT-1. Each must show exitStatus=0 and failureCount 0.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaCore/TerminalRetentionPlan.swift Tests/RielaCoreTests/TerminalRetentionPlanTests.swift > tmp/issue-sweep-2-20261024/isw2-27a/lint-int2.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-2-20261024/isw2-27a/lint-int2.log'` → exitStatus=0.
5. `grep -rnE '"completed", "failed"\]' Sources | grep -v '^Sources/RielaApp/' | grep -v '^Sources/RielaCLI/LoopCommands.swift:'` → empty (pipeline rc 1). Write the matches to `retention-literal-grep.log`. The appended `exitStatus=` line records the echo, so judge the gate by the empty match list.
6. Re-run the two grep gates from Verification 6 above. The terminal-predicate gate must still leave only the FailClosed lines owned by ISW2-27c.

### Amendment done criteria

- [ ] Line 72 accepts `cancelled`; `count != 1` is unchanged.
- [ ] Two new `TerminalRetentionPlanTests` methods pass; the five existing methods are byte-identical.
- [ ] Amendment verification 1-6 pass, with log paths and integer evidence in the progress log, along with the LoopCommands follow-up.
