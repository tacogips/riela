# ISW-135: nodeTimeout retry and plain-rerun inbox carry-over

**Status**: Ready
**planId**: ISW-135-retry-timeout-rerun-carryover
**Issue**: https://github.com/tacogips/riela/issues/135
**Design Reference**: design-docs/specs/design-rerun-input-carryover-and-finalization-evidence.md (D1, D2)
**dependsOn**: none (wave 1). ISW-104 depends on this plan.
**Created**: 2026-10-24

## Intent and context

This plan makes two changes.

- **D1.** `riela session resume <sid> --retry-failed-step` must accept a
  current step that failed with `failureKind == .nodeTimeout`. An
  `AdapterExecutionError(.timeout)` maps to it in
  `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:workflowRunFailureKind`.
- **D2.** `riela session rerun <sid> <step>` without `--preserve-history`
  creates an empty session today (`resolveRerunEntry` in
  `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`). The rerun
  target therefore has no inbox. A command target such as `dispatch-plans`,
  which needs exactly one checkpoint commit/push message, fails as a result.
  The rerun must carry the target's recorded inbox from the source session
  through the existing runtime-owned import `importAcceptedHistory`
  (`Sources/RielaCore/RuntimeHistoryImport.swift`).

## Non-goals

- No new CLI flags, request fields, GraphQL fields or store tables.
- No change to `--preserve-history` (`preservedHistory` in
  `DeterministicWorkflowRunner+History.swift`); it already imports the inbox.
- No git finalization evidence binding. That is ISW-104 (D3). Do not touch
  `DeterministicWorkflowRunner+GitFinalizationEvidence.swift`.
- No side-effect deduplication for retried timed-out steps.

## Write ownership (writePaths)

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+RerunCarryover.swift` (new)
- `Sources/RielaCore/RuntimeHistoryImport.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFailureStateTests.swift`
- `Tests/RielaCoreTests/WorkflowRerunInputCarryoverTests.swift` (new)
- `Tests/RielaCoreTests/RuntimeHistoryImportHandoverTests.swift`
- `Tests/RielaCLITests/SessionAddonRecoveryTests.swift`
- `Tests/RielaCLITests/SessionPreservedHistoryTests.swift`
- `Tests/RielaCLITests/SurfaceParitySessionLineageTests.swift`
- `Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`
- `docs/preserved-history-recovery.md`
- `impl-plans/progress/issue-sweep-20261024-135-retry-timeout-rerun-carryover.md`

Edit `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` and the
CLI test files listed here only to update assertions that encode the old
fresh-input rerun behavior: an empty rerun session, exact `executions.count`
or step-id lists, or a nil `parentSessionId`. Never weaken lineage or
identity assertions. These must stay asserted unchanged:

- `recovery.entryMode`, `sourceSessionId`, `sourceStepId`,
  `sourceStepExecutionId`, `parentSessionId` and `childSessionIds`;
- terminal-resume behavior.

## Contract for ISW-104 (pin exactly)

In the new file `DeterministicWorkflowRunner+RerunCarryover.swift`, add an
`extension DeterministicWorkflowRunner` with:

```swift
func rerunCarriedInbox(source: WorkflowSession, targetStepId: String) async throws -> WorkflowHistoryImportInput?
```

- It returns nil when nothing is carried. Otherwise it returns
  `WorkflowHistoryImportInput(sessionId: "", sourceSessionId: source.sessionId, executions: <canonical source producer executions in source order>, messages: <canonical source messages in createdOrder>)`.
- ISW-104 adds evidence executions to the returned `executions` before import,
  so keep the "create session → set sessionId → `store.importAcceptedHistory`"
  step in `resolveRerunEntry`, not inside this function.

## File-level changes

1. **`DeterministicWorkflowRunner+Recovery.swift`**:
   - `resolveResumeEntry`: `retryableFailureKind` also accepts `.nodeTimeout`.
     The new error text is
     `"--retry-failed-step requires an adapter-failed, policy-blocked or timed-out current step with no accepted output"`.
     All other guards stay unchanged;
   - `resolveRerunEntry`: when `request.preserveHistory == false`, first check
     the source status. It must be `.failed`, `.suspended` or `.completed`;
     otherwise throw
     `DeterministicWorkflowRunnerError.rerunValidation("rerun source session must be failed, suspended or completed")`.
     Then call `rerunCarriedInbox` before `createSession`. If the result is
     non-nil, set its `sessionId` after `createSession` and call
     `store.importAcceptedHistory`, mirroring the existing preserve-history
     branch;
   - keep the existing order: target validation, then the preflight
     (preserve-history or carry-over), then `validateCrossWorkflowDispatchTargets`,
     then `createSession`. Any rejection must happen before `createSession`.
2. **`DeterministicWorkflowRunner+RerunCarryover.swift`**: implement D2 steps
   1-4 exactly as in the design.
   - `T` is `source.executions.last { $0.stepId == targetStepId }`; nil → nil.
   - Read the ids from
     `T.inputSnapshot?["mergedVariables"]` → object → `_rielaInput` → object →
     `communicationIds` → array of strings. If any of these is absent, return
     nil (fresh input).
   - `try await store.listMessages(for: source.sessionId, toStepId: nil)`.
     For each recorded id: the message exists, `toStepId == targetStepId`,
     `routingScope == .workflow` and `lifecycleStatus` is `.delivered` or
     `.consumed`. Otherwise throw
     `rerunValidation("cannot carry rerun input: recorded inbox communication <id> is missing or unaccepted; use --preserve-history or rerun an earlier step")`.
   - Keep a message only when its `sourceStepExecutionId` names a source
     execution with `status == .completed` and `acceptedOutput != nil`. Skip
     the rest; these are manager, handover or event injections.
   - Return nil when no message is kept.
3. **`RuntimeHistoryImport.swift`**: in
   `InMemoryWorkflowRuntimeStore.importAcceptedHistory`, the `.session` source
   guard also accepts `canonicalSource.status == .completed`. Update the error
   string to "requires a failed, suspended or completed source session in the
   same workflow". Change nothing else. The bundle path and per-execution
   checks stay as they are.
4. **`Sources/RielaCLI/SessionCommands.swift`**: in
   `nonBudgetFailureResumeMessage`, show `retryGuidance` for `.nodeTimeout`
   too. The wording becomes "to explicitly retry the failed step".
5. **`docs/preserved-history-recovery.md`**:
   - replace "Ordinary rerun without the flag still starts with fresh input."
     with a short D2 paragraph: what is carried, what is skipped, the
     preflight rejection message, and the accepted source states;
   - add `nodeTimeout` to the retry guidance.

   ISW-104 appends a separate paragraph later, so do not add finalization
   text here.

## Invariants

- The runtime store owns identities. Imported executions get new ids and
  `importedFrom`; imported messages get new communication ids. No backend
  events, usage or finalization tokens are imported. The importer already
  enforces all of this, so do not reimplement it.
- `newExecutionCount` excludes imported producers.
- A rerun that carries nothing behaves exactly as today.
- A preflight rejection never creates a session.

## Pitfalls

- Do not copy messages by appending new ones through `appendWorkflowMessage`.
  Use the importer only.
- Pass the canonical source execution and message structs exactly as loaded.
  The importer compares them field by field (`inputSnapshot`,
  `acceptedOutput`, `attempt`).
- Deduplicate producer executions: one producer can send several carried
  messages.
- `importAcceptedHistory` sets `parentSessionId` to the source. The rerun
  lineage already says so, which is expected.
- The fanout-branch ambiguity check (`validateRerunTarget`) still runs first.
- `FailClosedSQLiteWorkflowRuntimeStore.importAcceptedHistory` is a
  pass-through. No change is needed there; it is in RielaCLI, not owned here.

## Tests

`DeterministicWorkflowRunnerFailureStateTests` (imitate
`testExplicitRetryOfFailedAdapterStepKeepsSessionHistory`):

| Situation | Expected outcome |
| --- | --- |
| An adapter throws `AdapterExecutionError(.timeout, ...)`, so the session fails with `nodeTimeout`; then resume with `retryFailedStep = true` and a succeeding adapter | same session id; status `.completed`; executions `[.failed, .completed]` |
| A `nodeTimeout` session resumed without `retryFailedStep` | stays `.failed` (terminal result) |
| `retryFailedStep` on a completed session | throws `resumeValidation` with the new text |

`WorkflowRerunInputCarryoverTests` (new; imitate the store and runner setup in
`Tests/RielaCoreTests/WorkflowPreservedHistoryTests.swift`):

| Situation | Expected outcome |
| --- | --- |
| Workflow `checkpoint` → `consumer` (command-like step that fails unless its `_rielaInput.messages` has exactly one message from `checkpoint`) → `tail`. The source fails at `tail`. Plain rerun of `consumer` | `consumer` succeeds. Its `_rielaInput.communicationIds` are new ids, not source ids. The new session has one imported `checkpoint` execution whose `importedFrom.sessionId` is the source and whose `communicationIds` maps to the source id. `newExecutionCount` counts only re-executed steps |
| The same source with `completed` status | the carry-over still works |
| A recorded communication id is deleted from the source (or its lifecycle is `superseded`) | `rerunValidation` "cannot carry rerun input ..."; the store has no new session |
| Target never executed in the source | rerun starts with an empty inbox, as before |
| Target inbox holds only a non-execution message (`sourceStepExecutionId` not an accepted execution) | nothing is carried; rerun proceeds |
| Source status `.running` | `rerunValidation` "rerun source session must be failed, suspended or completed" |

`DeterministicWorkflowRunnerTests` (assertion update only):

| Situation | Expected outcome |
| --- | --- |
| `testRerunCreatesNewSessionStartingAtRequestedStep` (around line 538-574; `twoStepWorkflow` completed source step-a → step-b; plain rerun of step-b) | `rerun.session.executions.map(\.stepId) == ["step-a", "step-b"]`. `executions[0].importedFrom?.sessionId == first.session.sessionId`, and `executions[0].importedFrom?.executionId` equals the source step-a execution id. `executions[1].importedFrom == nil` (exactly one newly executed step-b). `newExecutionCount == 1`. All existing lineage assertions unchanged |

`RuntimeHistoryImportHandoverTests`: add one case, importing from a
`completed` session source succeeds. The existing handover and bundle cases
must stay green.

`SessionAddonRecoveryTests`: add one CLI rerun case. Run
`session rerun <sid> <consumer-step>` on a mock-scenario workflow where the
consumer requires its inbox, and assert exit 0. Follow
`testSessionResumeAndRerunProvideBuiltinAddonResolver` setup.

## Verification commands

Run from the repository root. Logs go under
`tmp/issue-sweep-20261024/ISW-135/`, each ending with an `exitStatus=$?` line:

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-135/build.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter DeterministicWorkflowRunnerFailureStateTests > tmp/issue-sweep-20261024/ISW-135/failure-state.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/failure-state.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowRerunInputCarryoverTests > tmp/issue-sweep-20261024/ISW-135/carryover.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/carryover.log'
arch -arm64 /bin/zsh -lc 'swift test --filter RuntimeHistoryImportHandoverTests > tmp/issue-sweep-20261024/ISW-135/import.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/import.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowPreservedHistoryTests > tmp/issue-sweep-20261024/ISW-135/preserved.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/preserved.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerTests|DeterministicWorkflowRunnerBudgetTests|WorkflowSessionEntryValidationTests" > tmp/issue-sweep-20261024/ISW-135/runner-rerun.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/runner-rerun.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "SessionAddonRecoveryTests|SessionPreservedHistoryTests|SurfaceParitySessionLineageTests|WorkflowCommandSessionDiscoveryTests|SessionCommandJSONLStreamingTests|WorkflowCommandInspectionTests|WorkflowCommandPackageLifecycleTests" > tmp/issue-sweep-20261024/ISW-135/cli-rerun.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/cli-rerun.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift Sources/RielaCore/DeterministicWorkflowRunner+RerunCarryover.swift Sources/RielaCore/RuntimeHistoryImport.swift Sources/RielaCLI/SessionCommands.swift Tests/RielaCoreTests/WorkflowRerunInputCarryoverTests.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerFailureStateTests.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift > tmp/issue-sweep-20261024/ISW-135/lint.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-135/lint.log'
```

If `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` was not
edited, drop it from the lint list. Lint every edited test file.

Each command must show exitStatus 0. Every test filter must show testsRun > 0
and failureCount 0. Some suites in these filters are not owned here:
`SessionCommandJSONLStreamingTests`, `WorkflowCommandInspectionTests`,
`WorkflowCommandPackageLifecycleTests` and
`DeterministicWorkflowRunnerBudgetTests`/`WorkflowSessionEntryValidationTests`.
A failure in one of them caused by the new behavior must be reported as a
dependency object naming that test file path. Do not edit those files.

## Edit discipline

Follow the same rules as every plan:

- record a fresh read and a pre/post `shasum -a 256` for each edit in the
  progress log;
- on drift, stop, re-read, and re-apply the recorded intent only;
- do not edit files outside writePaths;
- run no index- or worktree-changing git commands.

## Completion criteria

- [ ] D1 and D2 are implemented, and the `rerunCarriedInbox` signature
      matches the pinned contract.
- [ ] Every test table row passes, and all verification commands exit 0 with
      integer evidence recorded.
- [ ] `docs/preserved-history-recovery.md` describes D2 and `nodeTimeout`.
- [ ] `git diff --stat` touches only the writePaths.

## Progress log expectations

`impl-plans/progress/issue-sweep-20261024-135-retry-timeout-rerun-carryover.md`
records hashes, commands, integer fields, log paths, any updated legacy
assertions (with the reason) and any drift.
