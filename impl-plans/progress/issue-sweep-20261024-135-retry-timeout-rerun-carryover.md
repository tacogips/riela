# ISW-135 implementation progress

**Plan**: `ISW-135-retry-timeout-rerun-carryover`  
**Issue**: `tacogips/riela#135`  
**Workflow mode**: full `issue-resolution`  
**Branch**: `feat/issue-sweep-20261024`  
**Status**: completed and merged (PR #177); review follow-up 2026-10-24 applied (D2 time-cut carry, running-source guard only when evidence is carried, unaccepted-producer rejection, lineage and execution-count fixes).

## Readiness and design alignment

`dependsOn` is empty and `acceptedPlanIds` is empty, so no predecessor admission was required. The assigned plan's D1/D2 design and the D2 signature pinned for ISW-104 were read before edits. Changes preserve runtime-store identity ownership, import canonical source records through `importAcceptedHistory`, and leave ISW-104 finalization evidence binding untouched.

## Completion criteria

- [x] D1 permits `.nodeTimeout` retry while retaining existing failed-current-step/no-output guards and updates retry error/guidance.
- [x] D2 preflights only failed, suspended, or completed sources; validates the recorded target inbox before session creation; imports accepted producer executions/messages with remapped identities.
- [x] `rerunCarriedInbox(source:targetStepId:)` matches the pinned internal contract; returns canonical producer executions in source order and messages by `createdOrder`.
- [x] Completed session sources import; `newExecutionCount` remains based on non-imported executions.
- [x] Existing rerun lineage assertions remain; the step-b test expects `[step-a imported, step-b new]`.
- [x] Recovery docs describe D2, rejected inbox evidence, source states, and timeout retry.
- [x] CLI/SQLite rerun regression asserts imported checkpoint lineage and remapped consumer inbox identity.
- [x] All required behavior filters/build/strict selected-file lint pass with positive test counts where applicable.

## Changes

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`: timeout retry and plain-rerun source/preflight/import flow.
- `Sources/RielaCore/DeterministicWorkflowRunner+RerunCarryover.swift`: pinned inbox selection and canonical filtering.
- `Sources/RielaCore/RuntimeHistoryImport.swift`: completed same-workflow sources accepted.
- `Sources/RielaCLI/SessionCommands.swift`: timeout retry guidance.
- Tests: timeout retry/error, canonical inbox import/id remapping, completed-source import, preflight rejection/no-session checks, non-execution producer skip, CLI mock-scenario consumer rerun with persisted SQLite identity assertions, and updated rerun lineage assertions.
- `docs/preserved-history-recovery.md`: D2 and timeout behavior.

## Edit evidence

Per-edit intended hunks are recorded in `tmp/issue-sweep-20261024/ISW-135/evidence/edit-001-intent.txt` through `edit-016-intent.txt`; the corresponding pre-edit hash records are adjacent. Test-integrity repair intents and hashes are recorded in `repair-ti-1-edit-001-*`, `repair-ti-1-edit-002-*`, and `repair-ti-1-edit-003-*`. The original implementation snapshot remains in `final-source-post.sha256`; the final complete post-repair hashes are in `repair-ti-1-source-post-final2.sha256`. Progress edit pre-hashes and intents are recorded in the adjacent `repair-ti-1-progress-edit-002-*` through `repair-ti-1-progress-edit-005-*` files. The exact changed Swift file set passed to lint is NUL-delimited in `tmp/issue-sweep-20261024/ISW-135/evidence/changed-swift-files.nul`.

## Verification

Each command ran from the repository root through `arch -arm64 /bin/zsh -lc`. Logs are complete and include their final `exitStatus` line.

| Command | exitStatus | testsRun | failureCount | Log |
|---|---:|---:|---:|---|
| `swift build` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-135/build-final.log` |
| `swift test --filter DeterministicWorkflowRunnerFailureStateTests` | 0 | 2 | 0 | `tmp/issue-sweep-20261024/ISW-135/failure-state-final.log` |
| `swift test --filter WorkflowRerunInputCarryoverTests` | 0 | 7 | 0 | `tmp/issue-sweep-20261024/ISW-135/carryover-rerun2.log` |
| `swift test --filter RuntimeHistoryImportHandoverTests` | 0 | 5 | 0 | `tmp/issue-sweep-20261024/ISW-135/import-final.log` |
| `swift test --filter WorkflowPreservedHistoryTests` | 0 | 6 | 0 | `tmp/issue-sweep-20261024/ISW-135/preserved-final.log` |
| `swift test --filter "DeterministicWorkflowRunnerTests|DeterministicWorkflowRunnerBudgetTests|WorkflowSessionEntryValidationTests"` | 0 | 57 | 0 | `tmp/issue-sweep-20261024/ISW-135/runner-rerun-final.log` |
| `swift test --filter "SessionAddonRecoveryTests|SessionPreservedHistoryTests|SurfaceParitySessionLineageTests|WorkflowCommandSessionDiscoveryTests|SessionCommandJSONLStreamingTests|WorkflowCommandInspectionTests|WorkflowCommandPackageLifecycleTests"` | 0 | 14 | 0 | `tmp/issue-sweep-20261024/ISW-135/cli-rerun-final2.log` |
| `if [ -s tmp/issue-sweep-20261024/ISW-135/evidence/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-20261024/ISW-135/evidence/changed-swift-files.nul; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-135/lint-final2.log` |

### Test-integrity repair: ISW135-TI-1

The CLI case now loads both persisted records through `CLIWorkflowSessionStore`. It asserts `[checkpoint, consumer]`, checkpoint `importedFrom` session/execution ids, a new consumer execution, `newExecutionCount == 1`, and exactly one remapped consumer communication id mapped back to the source id. The prompt references `_rielaInput.latest.payload.status`. No `Sources/` files changed; the other tests in `SessionAddonRecoveryTests.swift` are unchanged.

| Command | exitStatus | testsRun | failureCount | Log |
|---|---:|---:|---:|---|
| `swift test --filter SessionAddonRecoveryTests` | 0 | 3 | 0 | `tmp/issue-sweep-20261024/ISW-135/cli-addon-recovery-fix-final2.log` |
| `swift test --filter "SessionAddonRecoveryTests|SessionPreservedHistoryTests|SurfaceParitySessionLineageTests|WorkflowCommandSessionDiscoveryTests|SessionCommandJSONLStreamingTests|WorkflowCommandInspectionTests|WorkflowCommandPackageLifecycleTests"` | 0 | 14 | 0 | `tmp/issue-sweep-20261024/ISW-135/cli-rerun-fix-final4.log` |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-20261024/ISW-135/evidence/changed-swift-files.nul` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-135/lint-fix-final2.log` |

## Prior attempts resolved

- The first failure-state filter used the prescribed suite name before a dedicated `XCTestCase` existed and ran zero tests (`failure-state-attempt-001.log`). A dedicated suite was added; the final filter now runs two passing tests.
- An early CLI probe used the time-signal add-on's incomplete mock output and failed on an unrelated missing field; it was replaced with a purpose-built two-agent mock-scenario workflow. The final CLI filter includes that case and passes.
- The CLI aggregate has intermittently failed two live-session timing assertions in `WorkflowCommandSessionDiscoveryTests`; unchanged reruns passed all 14 tests. Failed attempts are retained in `cli-rerun-final.log`, `cli-rerun-fix-final.log`, and `cli-rerun-fix-final3.log`; passing current-source reruns are `cli-rerun-final2.log` and `cli-rerun-fix-final4.log`.
- Test-integrity finding `ISW135-TI-1` identified that the initial mock-scenario CLI check did not prove carry-over. It is repaired by persisted-session and identity assertions. The final suite, aggregate, and strict manifest lint pass (`cli-addon-recovery-fix-final2.log`, `cli-rerun-fix-final4.log`, `lint-fix-final2.log`).

## Scope and handoff

No files outside this plan's write paths were intentionally edited. Shared-branch work from other plans remains intact. Formal integration review, review-dependent updates, staging, commit, and push belong to downstream workflow steps; `gitPush=false` remains in force.
