# ISW2-27a Progress — First-class cancelled status

**Plan:** `impl-plans/active/issue-sweep-2-20261024-27a-cancelled-status.md`  
**Issue:** tacogips/riela#27 P1  
**Implementation branch:** `feat/issue-sweep-2-20261024`  
**Status:** Assigned implementation and required verification are complete; pending independent review.

## Implementation

- Added persisted `.cancelled` to `WorkflowSessionStatus` and `WorkflowStepExecutionStatus`; both decoders map unknown string cases to `.failed` and encoders preserve raw values.
- Added `WorkflowSession.isCancellation` with legacy `.failed + failureKind .cancelled` tolerance and `WorkflowSessionStatus.isTerminal`.
- `markSessionFailed` now persists cancelled status and marks running executions cancelled only for `.cancelled`; `.stalled` and `.leaseLost` remain failed. The unpersisted terminal-event projection follows the same status mapping. Exit code remains 1.
- Cancelled resume returns terminal without new execution; cancelled sources are accepted for rerun and accepted-history import.
- Updated owned SQLite, nested invocation, fanout, cross-workflow, lease-release, live persistence, task dispatch, director, work reservation, scoped parity, observability and health-rendering predicates. Loop outcome notifications are suppressed for cancelled status.
- SQLite pending-cancellation validation accepts `isCancellation`, and the terminal transition guard recognizes cancelled as terminal while retaining the different-terminal rejection.
- `TaskDispatch+Handover.swift` validates `.cancelled` for cancellation triggers and `.failed` for other failure triggers, so immediate operator handover accepts the persisted cancellation terminal.

## Changed test files and reason

- `Tests/RielaCoreTests/WorkflowCancelledStatusTests.swift` — new tolerant decode, raw encoding, terminal helper, legacy cancellation recognition, store cancellation, stalled behavior and accepted-history import tests.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFailureStateTests.swift` — cancellation finalization/event assertions, execution cancellation status, terminal resume and cancelled-source rerun assertions.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` — cancellation during resume now expects `.cancelled` while retaining exit code 1.
- `Tests/RielaCoreTests/WorkflowRerunInputCarryoverTests.swift` — expected rerun validation diagnostic now lists cancelled sources.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift` — cancelled child terminal snapshot expectation.
- `Tests/RielaCoreTests/SpecialistSupervisorRecoveryTests.swift` — cancelled nested child terminal expectation.
- `Tests/RielaWorkTests/WorkStoreCancellationTests.swift` — new cancelled SQLite transition/conflicting-terminal and no-local-cancellation reconciliation regressions; new cancellation writes expect `.cancelled`; the preexisting `failed + cancelled` fixture continues to expect `.failed` to preserve legacy-row coverage. The SQLite transition test is `WorkStoreReservationTests.testCancelledTerminalTransitionAcceptsCancellationAndRejectsDifferentTerminalWrite` in this file.
- `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` — task cancellation persistence expectations.
- `Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift` — task cancellation fixture persistence expectations.
- `Tests/RielaCLITests/TaskHandoverDispatchTests.swift` — stalled handover remains `.failed`; operator cancellation expects `.cancelled`.
- `Tests/RielaCLITests/ServeHTTPCommandTests.swift` — server stop cancellation expects `.cancelled` in CLI and canonical snapshots.
- `Tests/RielaCLITests/SpecialistServiceResponsivenessTests.swift` — cancelled dispatch child status expectation.
- `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` — live handover cancellation expects persisted `.cancelled` while preserving reconciliation and acknowledgement assertions.

## Verification

All commands ran from the repository root through an arm64 shell. Logs are complete under `tmp/issue-sweep-2-20261024/isw2-27a/`.

| Command | Exit | Tests run | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build-final-after-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/build-final-after-repair.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/build-final-after-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCancelledStatusTests|RuntimeStoreTests|DeterministicWorkflowRunnerFailureStateTests|DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|DeterministicWorkflowRunnerTests|LoopConcurrencyLeaseTests|RuntimeHistoryImportHandoverTests|WorkflowPreservedHistoryTests|WorkflowRerunFinalizationEvidenceTests|WorkflowRerunInputCarryoverTests|WorkflowHistoryModelsTests" > tmp/issue-sweep-2-20261024/isw2-27a/core-final-after-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/core-final-after-repair.log; exit $code'` | 0 | 146 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/core-final-after-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RielaWorkTests > tmp/issue-sweep-2-20261024/isw2-27a/work-final-after-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/work-final-after-repair.log; exit $code'` | 0 | 267 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/work-final-after-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskCancellationIntegrationTests|TaskHandoverDispatchTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|EventCronOverlapTests|ServeHTTPCommandTests|SpecialistMonitorControlCommandTests|SpecialistServiceResponsivenessTests|WorkflowCommandAutoImproveTests|SessionPreservedHistoryTests|LoopConcurrencyPreflightTests|WorkflowHistoryAdversarialTests" > tmp/issue-sweep-2-20261024/isw2-27a/cli-final-after-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/cli-final-after-repair.log; exit $code'` | 0 | 137 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/cli-final-after-repair.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-files-final-after-repair.nul > tmp/issue-sweep-2-20261024/isw2-27a/lint-final-source-complete-after-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/lint-final-source-complete-after-repair.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/lint-final-source-complete-after-repair.log` |
| `grep -rn "status == .failed && .*failureKind == .cancelled" Sources` (empty match set normalized to success) | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/cancel-grep-final-after-repair.log` |
| `grep -rnE "status == \.completed \|\| .*status == \.failed|status != \.completed && .*status != \.failed|terminalStatuses: \[\.completed, \.failed\]" Sources | grep -v '^Sources/RielaApp/'` (only documented ISW2-27c hits) | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/terminal-grep-final-after-repair-2.log` |
| `git diff --check -- $(tr '\0' ' ' < tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-files-final-after-repair.nul) impl-plans/progress/issue-sweep-2-20261024-27a-cancelled-status.md` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/diff-check-final-after-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build-adv1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/build-adv1.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/build-adv1.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RielaWorkTests > tmp/issue-sweep-2-20261024/isw2-27a/work-adv1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/work-adv1.log; exit $code'` | 0 | 268 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/work-adv1.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskCancellationIntegrationTests|TaskHandoverDispatchTests|TaskHandoverGraphQLProviderTests|TaskRemoteTakeoverTests|TaskDispatcherIntegrationTests" > tmp/issue-sweep-2-20261024/isw2-27a/cli-adv1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/cli-adv1.log; exit $code'` | 0 | 88 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/cli-adv1.log` |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaWork/WorkStore+Reservation.swift Tests/RielaWorkTests/WorkStoreCancellationTests.swift > tmp/issue-sweep-2-20261024/isw2-27a/lint-adv1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/lint-adv1.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/lint-adv1.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-files-final-after-repair.nul > tmp/issue-sweep-2-20261024/isw2-27a/lint-strict-adv1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/lint-strict-adv1.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/lint-strict-adv1.log` |

The only terminal-predicate grep hits are `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift:162,167`, assigned to ISW2-27c. The previous full work and CLI runs exposed two items assigned to this plan's `writePaths`; both are fixed and the current-source reruns pass with zero failures. Review finding `ISW2-27a-ADV-1` is addressed: `reconcileAttempt` accepts cancelled canonical outcomes while retaining the outcome equality and pending-cancellation guard. The new no-decision regression asserts reconciliation, cancelled outcome, lease deletion and task transition to verifying. The completed and failed reconciliation coverage and pending-cancellation rejection remain in the full work filter.

## Blockers / completion criteria

- [x] Status enums encode `cancelled` and tolerate unknown strings as `.failed`.
- [x] Cancellation store and runner finalizers persist session/execution status as cancelled; stalled stays failed; exit code remains 1.
- [x] Cancelled resume is terminal; rerun and import history accept cancelled sources.
- [x] Owned terminal predicates, SQLite guards, cancellation tests and plan-owned changed test-file reasons are recorded.
- [x] `reconcileAttempt` accepts cancelled terminal snapshots without a local cancellation decision while preserving its canonical outcome and pending-cancellation checks.
- [x] Build, core, full work, CLI filters, strict selected-file lint and grep gates pass.
- [ ] ISW2-27c updates the two downstream FailClosed terminal predicates.

Per-file pre-edit source snapshots and intent notes are stored under `tmp/issue-sweep-2-20261024/isw2-27a/snapshots/`.

## Checkpoint amendment: `ISW2-27a-INT-RETENTION-CANCELLED`

The current-source repair updates `TerminalRetentionPlan.make` to accept `cancelled` alongside `completed` and `failed`; the `statuses.count != 1` conflict check and protection ordering remain unchanged. The two added tests prove that a single cancelled root older than the cutoff is selected and that a cancelled root with a running child remains protected as `nonterminalOrConflictingStatus`. All five preexisting `TerminalRetentionPlanTests` methods are unchanged. The regression is grounded in the captured pre-edit source at `snapshots/retention-before-source.swift`: its line 72 admitted only `completed` and `failed`, so the cancelled-root selection assertion could not pass.

### Amendment verification (current source)

| Command | Exit | Tests run | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build-int2-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/build-int2-repair.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/build-int2-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionPlanTests|TerminalRetentionTests|WorkflowCancelledStatusTests" > tmp/issue-sweep-2-20261024/isw2-27a/retention-int2-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/retention-int2-repair.log; exit $code'` | 0 | 34 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/retention-int2-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowCancelledStatusTests|RuntimeStoreTests|DeterministicWorkflowRunnerFailureStateTests|DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|DeterministicWorkflowRunnerTests|LoopConcurrencyLeaseTests|RuntimeHistoryImportHandoverTests|WorkflowPreservedHistoryTests|WorkflowRerunFinalizationEvidenceTests|WorkflowRerunInputCarryoverTests|WorkflowHistoryModelsTests" > tmp/issue-sweep-2-20261024/isw2-27a/core-int2-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/core-int2-repair.log; exit $code'` | 0 | 146 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/core-int2-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RielaWorkTests > tmp/issue-sweep-2-20261024/isw2-27a/work-int2-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/work-int2-repair.log; exit $code'` | 0 | 268 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/work-int2-repair.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskCancellationIntegrationTests|TaskHandoverDispatchTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|EventCronOverlapTests|ServeHTTPCommandTests|SpecialistMonitorControlCommandTests|SpecialistServiceResponsivenessTests|WorkflowCommandAutoImproveTests|SessionPreservedHistoryTests|LoopConcurrencyPreflightTests|WorkflowHistoryAdversarialTests" > tmp/issue-sweep-2-20261024/isw2-27a/cli-int2-repair.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/cli-int2-repair.log; exit $code'` | 0 | 137 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/cli-int2-repair.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-files-int2-repair.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-files-int2-repair.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/lint-int2-repair.log` |
| `grep -rnE '"completed", "failed"\\]' Sources | grep -v '^Sources/RielaApp/' | grep -v '^Sources/RielaCLI/LoopCommands.swift:'` | no matches (`grepExitStatus=1`, wrapper exit 0) | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/retention-literal-grep-int2-repair.log` |
| `grep -rnE 'status == \\.completed \\|\\| .*status == \\.failed|status != \\.completed && .*status != \\.failed|terminalStatuses: \\[\\.completed, \\.failed\\]' Sources | grep -v '^Sources/RielaApp/'` | 0; only downstream `FailClosedSQLiteWorkflowRuntimeStore.swift:162,167` | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/terminal-grep-int2-repair.log` |

The required follow-up remains `Sources/RielaCLI/LoopCommands.swift`: its `--status` filter allowlist does not accept `cancelled`; it is not a terminal predicate and was not changed. The only terminal-predicate matches remain owned by `ISW2-27c-session-reconcile`.

Amendment completion:
- [x] Cancelled is included in the terminal-retention set; mixed cancelled/running families remain protected.
- [x] Both new retention regressions pass; the five prior retention tests are unchanged.
- [x] Build, retention/core/work/CLI tests, strict selected-file lint, and both grep gates have current-source evidence above.

### Integration review rerun — `ISW2-27a-INT-RETENTION-CANCELLED`

Addressed finding `opus-luna-design-and-implement-review-loop-session-2-integration-review-attempt-1-finding-1`. The reported defect was that cancelled sessions were excluded from the terminal-status set and therefore protected from retention. The current implementation already includes `cancelled`; this rerun verified the source and regression behavior without further source changes. The retained `statuses.count != 1` check continues to protect conflicting projections, including a family containing both a cancelled root and a running child.

| Command | Exit | Tests run | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27a/build-review-rerun-1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/build-review-rerun-1.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/build-review-rerun-1.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionPlanTests|TerminalRetentionTests|WorkflowCancelledStatusTests" > tmp/issue-sweep-2-20261024/isw2-27a/retention-review-rerun-1.log 2>&1; code=$?; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/retention-review-rerun-1.log; exit $code'` | 0 | 34 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/retention-review-rerun-1.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-review-rerun-1.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-27a/changed-swift-review-rerun-1.nul > tmp/issue-sweep-2-20261024/isw2-27a/lint-review-rerun-1.log 2>&1; code=$?; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run." > tmp/issue-sweep-2-20261024/isw2-27a/lint-review-rerun-1.log; code=0; fi; echo exitStatus=$code >> tmp/issue-sweep-2-20261024/isw2-27a/lint-review-rerun-1.log; exit $code'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/lint-review-rerun-1.log` |
| `grep -rnE '"completed", "failed"\\]' Sources | grep -v '^Sources/RielaApp/' | grep -v '^Sources/RielaCLI/LoopCommands.swift:'` (no matches) | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/retention-literal-review-rerun-1.log` |
| `grep -rnE 'status == \\.completed \\\\|\\| .*status == \\.failed|status != \\.completed && .*status != \\.failed|terminalStatuses: \\[\\.completed, \\.failed\\]' Sources | grep -v '^Sources/RielaApp/'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-27a/terminal-review-rerun-1.log` |

The last grep contains only the two previously assigned downstream checks in `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift:162,167` (ISW2-27c-session-reconcile). The string-literal gate is empty after excluding the `Sources/RielaCLI/LoopCommands.swift` status-filter allowlist; that follow-up remains recorded above. The active plan amendment checklist is complete. Pre-edit content, hashes, and exact update intent are preserved in `tmp/issue-sweep-2-20261024/isw2-27a/snapshots/`.
