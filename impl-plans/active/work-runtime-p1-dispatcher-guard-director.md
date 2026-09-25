# Work Runtime P1-7a: A1 GuardPolicy split and negative verification

## Current executable contract — A1 only (2026-09-25)

Mode and executionMode `issue-resolution`; issue `comm-000001`, “Finish reviewed
P1-7a A1 GuardPolicy split and negative verification”; intake `comm-000002`,
execution `codex-design-and-implement-review-loop-session-1`. No GitHub issue
supplied. Runner-resolved immutable user-scope workflow 0.3.34 is authoritative.
Step 3 `comm-000004`, `step3-design-review-attempt-1-exec-4`, accepted design
`design-docs/specs/design-work-runtime-consolidation.md` §17.10 without findings.
Step 5 `comm-000006`, `step5-impl-plan-review-attempt-1-exec-6`, accepted this A1-only plan without findings; implementation and formal reviews remain pending. Stable planId `p1-dispatch`, dependsOn `[]`,
planPath `impl-plans/active/work-runtime-p1-dispatcher-guard-director.md`,
progressFile `impl-plans/progress/p1-dispatch.md`; current manifest
`impl-plans/active/work-runtime-p1-7a-resume-comm000006-37c80ecd-dispatch.json`.
One author `/root` owns this plan; historical read-only references are
`/root/policy_inspect`, `/root/live_inspect`, `/root/tests_inspect`. No reference
repository or Cursor CLI behavior mapping applies.

Intent: finish the accepted split and missing A1 assertions on the existing
branch, then seal fresh final-source evidence. Checkpoint
`8b263ab07e22bb48a390489f395a7a4ea6a5d58b` on `feat/remaining-impl-plans`
and all nine dirty paths in `protectedDirtyPaths` must be preserved. These are
`Sources/RielaCLI/TaskDispatch.swift`, `Sources/RielaCLI/TaskRunCancellation.swift`,
`Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCore/RuntimePublication.swift`,
`Sources/RielaCore/RuntimeStore.swift`, `Sources/RielaWork/TaskGuardCoordinator.swift`,
`Tests/RielaCLITests/TaskCancellationIntegrationTests.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`, and
`impl-plans/progress/p1-dispatch.md`. Planning preserves them byte-for-byte;
implementation extends them through reviewed fresh-read edits without reverting
previous work. Preserve all earlier receipts, especially
`tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-1/`.
Its V0 exit 0, V1 63/63, canonical 94/94, cancellation-host 49/49, live 2/2 and
strict SwiftLint exit 0 are historical, not evidence for new source or missing
rows. A1 remains unsealed. A2/A3 and parent P1 remain open.

### Planning checkpoint and current execution boundary

- P0 complete: Step 3 accepts §17.10, comm-000004.
- P1 depends P0: this sole author updates the active plan/current manifest.
- P2 complete: independent Step 5 `comm-000006` accepted the plan without findings.
- P3 depends P2: serial checkpoint owner commits and non-force pushes only
  `design-docs/specs/design-work-runtime-consolidation.md`, this plan and the
  current manifest. Check `git diff --cached --name-only` against those exact
  three paths, record accepted hashes and `git show --format= --name-only HEAD`,
  then `git push origin HEAD:feat/remaining-impl-plans` without force. Do not stage
  the nine existing dirty files. Preserve 8b263ab as an ancestor; no reset/stash.
  Failed checkpoint publication stops implementation dispatch.

After P3, native Riela dispatch runs only A0/A1. `implementationDispatchAllowed`
is false pending P2/P3; the serial checkpoint owner enables it only after both
receipts exist. The current `writePaths` is the exact A1 allowlist, and shared
paths are reserved for serial documentation/finalization. A2–A5 remain the
future removal DAG, with their paths/commands recorded as deferred in the same
manifest. They are not dispatched or counted complete in this execution.
After complete A1 implementation evidence, the workflow performs A1-only formal
test-integrity, single Sol adversarial and Astra integration reviews, followed
by scoped documentation and finalization. These are downstream workflow gates,
not missing Step 6 implementation tasks and not completion of deferred A4/A5.

Non-goals: no legacy removal even after A1 passes; no external repository edits,
new framework/polling loop/public API/discovery shim, second split/active manifest,
assertion weakening, dependency or lockfile regeneration, broad formatting,
unrelated repair or parent P1 completion. No reset, stash, force push, main merge,
extra worktree, private branch or concurrent Git operation. No registry discovery.
Shared indexes, lockfiles and global archiving remain serial and outside A1 scope.

### Accepted exact split and remaining A1 ownership

**Accepted responsibility split for A1.** Retain the sole new write path,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift`, in the
current manifest and active plan. This is the justified equivalent
to `+LiveInactivity.swift`: the two live methods (54 lines) and adapter (27 lines)
alone would leave the 1,111-line source at 1,030 lines. Group the already coupled
guard-policy outcomes instead of introducing a second split or shared framework.
Move these seven existing methods, preserving names and assertions:

- `testFailedTaskRetriesWithinBudgetAndStopsAtLimit`
- `testLastAdmittedRecoveryAttemptCanSucceed`
- `testRetryDisabledAdapterFailureWaitsWithoutPendingRequest`
- `testCancelledTaskDoesNotRetryOrCreateLegacyIncident`
- `testSecondRunStopsWhenEarlierDurableSessionExhaustsWallClockBudget`
- `testTaskInactivityPersistsViolationAndStopsExactAttempt`
- `testTaskProgressPreventsInactivityAction`

Move `DelayedScenarioNodeAdapter` (keep file-private via its existing `private`
access) and `failedRepairScenario(in:)` (keep a private extension helper) with
their callers. Current contiguous ranges 233–259, 658–838 and 1045–1110 total
274 lines, leaving approximately 837 in the original file. Keep
`TaskExampleHarness`, its resolvers and `TaskDispatcherIntegrationTests: XCTestCase`
in the original; the harness already has internal access. Keep placement,
admission, dry-run and CLI rerun tests there. The new file contains a non-private
`extension TaskDispatcherIntegrationTests` with the needed imports; no duplicate
XCTestCase, public helper API, test renaming, Package.swift edit or discovery shim.
The existing SwiftPM `RielaCLITests` target includes this directory; ordinary
non-private `test…` methods in the extension retain their existing suite identity
and filters. Future implementation must prove discovery rather than assume it:
`swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch list` must list
every moved and added test once, followed by positive execution counts. The original file must be strictly below 1,000 lines and the new file at or
below 1,000 after all additions; recheck
with `wc -l`, independently of SwiftLint's looser warning threshold.

| Remaining A1 row | Exact future owner and proof |
| --- | --- |
| Unclassified failure | New `TaskDispatcherIntegrationTests+GuardPolicy.swift`: `testUnclassifiedFailureDoesNotAutomaticallyRetry`; actual unclassified failure must wait without an automatic pending retry. Retain retry-disabled and retry-positive tests above. |
| Historical/current gates and substantive findings | Same new file: extend `testLastAdmittedRecoveryAttemptCanSucceed` as the explicit equivalent of `testHistoricalMissingGateResolvesOnlyAfterMatchingAcceptedGate`; add `testCurrentMissingOrRejectedGateAndSubstantiveFindingsStillBlock`. Cover matching/mismatched lineage, missing/rejected/needs-work latest gates, similar-ID high/mid substantive findings, required human acceptance, durable resolution cause and reopened replay. |
| Director authorization | Existing `Tests/RielaCLITests/TaskRuntimeExampleTests.swift`: retain `testConfiguredDirectorChildRunsOrdinarilyAndCannotAcceptFailedWork`; add `testDirectorEscalationRequiresConfigurationThresholdAndCapacity` covering no configuration, below threshold, exhausted child capacity and no recursion. |
| Live stop/progress | New split: retain the two live methods; extend `testTaskInactivityPersistsViolationAndStopsExactAttempt` with separately evidenced no-heartbeat and stops-after-progress subcases. Preserve subsecond continuing-progress success and exact-session acknowledgment before replacement. |
| Warning and replay races | New split: add `testTaskInactivityWarningAndReplayPreserveSingleObservation` and `testTaskInactivityProgressTerminalAndCancellationRacesPreservePrecedence`. Cover warnings without cancellation, repeated immutable observation, progress recheck, terminal completion and cancellation precedence, reopened replay and no duplicate evidence/decision/request or premature replacement. Use controlled synchronization; no second polling framework or synthetic terminal-success seeds. |
| First terminal-hook classification | Existing `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift`: complete the first-hook `adapterFailure` assertion in `testTerminalFirstOrdinaryFailureSurvivesLateSIGINTAndExternalRequest` and `testTerminalFirstRetryableFailurePreservesOnePendingRequestAfterLateCancellation`; retain outcome/reopen checks, explicit retry-disabled/enabled policies, both signal/request branches and cancellation-first fences. |

The table above is the required A1 mapping. Each future progress receipt must name
every row/subcase, exact suite/method, owner, assertions and complete log reference. Moved tests do not count as newly
implemented missing coverage. Preserve all existing A1 gates below, including
fresh V0, policy-focused, canonical regression, cancellation-host, full four-suite
V1 and strict changed-file SwiftLint on the final source (include the new file in
the lint manifest). Extend the live filter to select the two new race tests;
retain positive counts for every named case. Record HEAD, hashes including the
new file, full foreground logs and terminal exits in a fresh evidence directory;
never overwrite attempt-1. No test deletion or zero-selection pass opens A1.
A2/A3 still require published `tacogips/rielflow` receiving-boundary false/null
rejection and authenticated ordinary acceptance; unpublished local `c2b16ab`
does not satisfy this dependency. The existing publication question remains at
`design-docs/user-qa/qa-p1-7a-rielflow-publication.md`; no new user decision is
needed for this bounded split, subject to independent review.


### Current A1 deliverables and completion

The sole implementation owner writes the original integration test and new
GuardPolicy extension for the exact move, named policy/race negatives and shared
harness use; `TaskRuntimeExampleTests.swift` owns director negatives;
`TaskCancellationIntegrationTests.swift` owns both first-hook assertions.
`TaskDispatch.swift`, `TaskGuardCoordinator.swift`, `TaskRunCancellation.swift`,
`RuntimePublication.swift`, `RuntimeStore.swift` and `WorkflowRunCommand.swift`
retain their existing bounded repair responsibilities from the table below;
only demonstrated A1 defects justify further edits. `TaskCommandMutationTests.swift`
and `TaskDispatcherTests.swift` retain existing A1 regression/guard assertions;
no assertion deletion is permitted. Progress belongs only to this owner.

Before Step 6 returns complete, append to `impl-plans/progress/p1-dispatch.md`:
all six remaining rows and every named subcase, exact suite/method, responsible
file, meaningful asserted outcomes, complete log and terminal exit, positive
counts and source-manifest identity. Include discovery/execution of all seven
moved methods, exactly two moved helpers, original <1,000/new ≤1,000 line counts,
fresh V0/V1/canonical/cancellation-host/policy/race/strict lint receipts, and
unchanged source identity after checks. Preserve historical entries. Record
A2/A3 deferred and formal reviews pending; do not self-accept those gates.
After joining read-only/test investigations, compare current hashes with each
edit intent and repair any drift serially before sealing evidence.

Downstream A1 review requires actual test-integrity, single Sol adversarial and
Astra integration identities, decisions and reviewed hashes. After acceptance,
serial documentation owner updates this plan, current manifest, design and
progress status to A1 complete/A2–A5 open; inspect README and change it only if
accepted A1 behavior needs a user-facing correction. Renew review after material
repairs. Final exact-file allowlist includes only reviewed changes (including
preserved dirty implementations reviewed as part of A1); no tmp artifacts.
Commit/non-force push occurs through workflow finalization gates, not Step 6.

### File ownership and exact intended changes

The table below retains the full future removal ownership for context. Only
the A1 paths enumerated in the current manifest `writePaths` may change now;
all other rows are deferred and grant no current write permission. `sharedPaths`
is serial checkpoint/A1 documentation ownership, with full A5 still deferred.
All paths are repository-relative. No directory glob authorizes extra edits.

| Paths | Change and boundary |
| --- | --- |
| `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` | Delete only after A1 receipt. |
| `Sources/RielaCLI/RielaCommand.swift`, `ParsedWorkflowOptions.swift`, `RielaArgumentParser+WorkflowAndMemory.swift` | Remove policy/mutation types and obsolete option plumbing; reject removed flags/aliases and preserve supervisor-mode, default-loop-guard and agent-silence controls. |
| `Sources/RielaCLI/WorkflowCommands.swift`, `WorkflowRunCommand.swift`, `ProductionNodeAdapter.swift`, `RielaCLIApplication.swift` | Remove old execution branch, request serialization and scenario wrapper; preserve plain/mock, remote authentication, actual task reservation and required/optional gate finalization behavior. |
| `Sources/RielaCLI/SessionCommands.swift`, `SessionCommandModels.swift`, `RielaCommand+SessionParsing.swift`, `LoopCommands.swift`; `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Conditional obsolete consumers only; fresh-read callers first. Preserve session resume/rerun, loops, routines and specialist/event stores/dispatch. |
| Additional: `Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift`, `WorkflowRunCommand+TaskReservation.swift`; `Sources/RielaCore/WorkflowRunResult.swift` | Delete obsolete record writer after A1; remove `!options.autoImprove` from reservation guard without weakening other admission checks; remove optional supervision result and its callers. Do not delete existing user artifacts. |
| Atomic failure repair: `Sources/RielaCore/RuntimePublication.swift`, `Sources/RielaCore/RuntimeStore.swift` | Carry typed failure classification in the existing step-update input and apply it with failed status before the first canonical save. Preserve other callers and advisory routing. No TaskDispatch-only projection workaround. |
| Live inactivity: `Sources/RielaCLI/TaskRunCancellation.swift`; existing `Sources/RielaCLI/TaskDispatch.swift`, `Sources/RielaWork/TaskGuardCoordinator.swift` | Extend the existing observer, use canonical progress and the existing guard/shared applier, use step creation time before the first heartbeat, preserve cancellation acknowledgment and terminal reconciliation; exact A1 sequence below. No second polling loop. |
| Causal policy: `Sources/RielaCLI/TaskDispatch.swift`, `Sources/RielaWork/TaskGuardCoordinator.swift` | Terminal-only retry-capacity exhaustion, evidence-backed synthetic gate-absence resolution, and authorized director escalation precedence; preserve shared applier and hard-stop ordering. |
| Existing ownership: `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` | Correct the terminal-first non-retry fixture using explicit retry-disabled policy and adapterFailure assertions; add paired retry-enabled coverage without weakening cancellation fences. Exact A1 sequence below. |
| Sole new write path: `Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift` | Move the seven methods and two helpers listed above; implement remaining guard-policy negatives and live race coverage in the same XCTest suite. Both files remain ≤1,000 lines. |
| `Tests/RielaWorkTests/TaskDispatcherTests.swift`; `Tests/RielaCLITests/TaskCommandMutationTests.swift`, `TaskDispatcherIntegrationTests.swift`, `TaskRuntimeExampleTests.swift` | A1 replacement behavior and durable invariants, then unchanged regression coverage after removal. |
| `Tests/RielaCLITests/CommandParsingTests.swift`, `WorkflowCommandAutoImproveTests.swift`, `WorkflowCommandInspectionTests.swift`, `WorkflowCommandPackageLifecycleTests.swift`, `WorkflowRunHelpTests.swift` | After A1, replace obsolete assertions with rejection/preservation cases; retain cancellation without auto-improve, plain/mock and authenticated remote regressions. |
| Additional: `Tests/RielaCLITests/RielaExampleCatalog.swift`; retained `RielaExampleParityTests.swift` | Remove deleted catalog entries; retain both task examples; reconcile observed mock counts without deriving expectations from actual output or dropping assertions. |
| `Tests/RielaCLITests/SurfaceParityCLITests.swift` | After A1, change `testOptionUniverseContainsRealFlagsAndRejectsRetiredOnes` to reject the removed auto-improve option while preserving max-steps/mock-scenario assertions. |
| `examples/catalog/chat-persona-and-agent-trio.md` | After A1, replace obsolete invocation and links with the accepted task-example guidance; retain specialist/event guidance. |
| `examples/monja-project-task-orchestrator/executor.ts`, `examples/monja-agent-collaboration/riela.ts`, `examples/monja-agent-collaboration/verify-workflow.ts` | After A1, remove only the proven `--no-auto-improve` argument; preserve all other command arguments and behavior. |
| Eight exact files in the manifest under `examples/auto-improve/`, `examples/default-superviser/`, `examples/supervised-mock-retry/` | Delete after A1 only. No edit to replacement bundles is planned. |
| `impl-plans/progress/p1-dispatch.md` | Only this owner writes task status and evidence receipts; historical receipts remain intact. |

Source inspection found `SurfaceCatalog+Rows.swift` uses `supervisionDeleted`
exclusions: retain these and `Tests/RielaCoreTests/SurfaceCatalogTests.swift`
read-only unless a reviewed bounded amendment establishes a necessary change.
Do not remove any symbol solely because its name includes supervisor.
Any further decoder, helper, split test file or documentation path requires an
exact-path reviewed amendment to this plan/manifest before edit. If a Swift file
would exceed the project's size limit, request the narrow responsibility split
in that amendment; do not silently expand ownership.

Inspection/regression-only owners are
`Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`,
`Sources/RielaWork/WorkEvidenceProjector.swift`,
`Sources/RielaWork/DeterministicDirector.swift`, `Sources/RielaWork/WorkGuard.swift`,
`Sources/RielaWork/WorkFindingMerge.swift`, `Sources/RielaWork/WorkStore.swift`, and
`Sources/RielaCLI/WorkflowRunLivePersistence.swift`. The accepted causal repair
requires no change to these paths; remove the prior live-persistence write grant.
Do not weaken terminal immutability or alter the CLI's one-second throttle.

### Dependency waves, deliverables and invariants

Current execution stops implementation after A1. A2–A5 retain their dependencies
below for a future authorized execution; A2 additionally requires published
receiving-side false/null rejection and authenticated acceptance. The current
A1-only review/finalization gates above do not mark those waves complete.

- **A0 / wave 1, no task dependency:** Fresh-read accepted design and manifest;
  record HEAD, status, baseline source hashes and legacy reference inventory.
  Record each proposed edit intent and behavior-to-test mapping. Run V7 baseline.
  Record the identified external HTTP GraphQL `ExecuteWorkflowInput` owner:
  `tacogips/rielflow`, `packages/rielflow-graphql/src/schema-contract.ts`, local
  branch `feat/p1-7a-remote-field-rejection`, commit `c2b16ab`. Intake reports 91
  related tests plus typecheck/build passing and three separately reproduced
  non-schema full-suite failures. These are reported local results, not published
  integration: the archived remote rejected push with 403. Record pending user
  direction under the accepted `design-docs/user-qa/qa-p1-7a-rielflow-publication.md`;
  do not rediscover the owner or edit the external repository from this plan.
  This dependency record permits local A1 after dispatch gates. A2/A3 acceptance
  and P1-7a closure require actual published receiving-side false/null rejection
  and ordinary authenticated acceptance, with source/service identity, exact
  test paths/commands, complete logs and terminal exits. Outbound omission or
  mocked errors are insufficient.
- **A1 / wave 1, depends A0:** Complete the matrix below using real dispatch,
  canonical sessions and durable WorkStore evidence; reuse existing fixtures.
  Test missing behavior first and narrowly repair only listed integration paths.
  Current `TaskDispatch.swift` evaluates guards after terminal reconciliation,
  while inactivity derives from a running execution: do not substitute a
  synthetic terminal snapshot for positive live inactivity proof. Then run V0
  and canonical-regression, cancellation-host and fresh V1 with every named suite positive. Seal `before-removal` source
  manifest, logs, command, exit and row-to-test evidence before proceeding.
  No legacy implementation/test/example deletion or disabling occurs in A0/A1.
  Execute the detailed A1 sequence below serially; neither retry-only success
  nor supplementary suites replace the complete four-suite V1 barrier.
- **A2 / wave 2, depends A1:** Recheck the sealed source and legacy file presence;
  remove only authorized obsolete files/plumbing. Implement removed CLI aliases
  and coordinate externally owned remote-field rejection only after owner/path
  authorization; test false/null values as presence, and prove plain
  runs create no task/store. Preserve similarly named user runtime variables.
  Rewrite legacy tests after the barrier and update catalog/help expectations.
  Shared session/loop options must reject obsolete paths while retained commands
  behave normally. No general unknown-field policy is introduced.
- **A3 / wave 3, depends A2:** Run final-source commands below serially, record
  positive counts by suite and complete logs; classify every retained reference.
  Recompute source identity after checks. If source changes, renew affected gates.
  Finish both V5 groups and full serial broad run; preserve failed receipts.
- **A4 / wave 3, depends A3:** Formal independent test-integrity review, one Sol
  adversarial review and Astra combined-tree review must accept no material
  P1-7a defect. Evidence includes actual reviewer identity/decision and exact
  reviewed source/files. Repair findings serially under the same owner, then
  rerun affected checks and obtain renewed reviews. Advisory self-check is not
  formal acceptance.
- **A5 / serial finalization, depends A4:** Update README, accepted design status,
  this plan and owner progress from exact evidence; retain parent P1 and unrelated
  broad failures as open. Review final docs/diff and produce exact unique file
  allowlist. Commit reviewed files only and non-force push to
  `origin/feat/remaining-impl-plans`, recording actual hashes and paths. Do not
  commit tmp evidence, unrelated files or modify global plan indexes/lockfiles.

| A1 behavior | Exact existing or proposed test intent |
| --- | --- |
| Inactivity | Add `TaskDispatcherIntegrationTests.testTaskInactivityPersistsViolationAndStopsExactAttempt` and `testTaskProgressPreventsInactivityAction`: drive a real reserved running session through controlled backend progress, prove durable guard decision and exact terminal acknowledgment; progress case must not falsely stop. These two existing tests have historical 2/2 evidence; the additional variants and races above remain incomplete. |
| Bounded retry / failure recovery | Preserve and extend existing dirty `TaskDispatcherIntegrationTests.testFailedTaskRetriesWithinBudgetAndStopsAtLimit` and `testLastAdmittedRecoveryAttemptCanSucceed`: historical failures were repaired; current remaining coverage still applies. Assert first canonical failed snapshot and reopened evidence contain `adapterFailure`, controlled runner failure, ordinary pending-request consumption, distinct sessions and no over-budget launch; success on last admitted attempt is allowed. |
| Gate recovery | Retain `TaskRuntimeExampleTests.testRejectedGateRecoveryConsumesPendingRequestAndAcceptsSecondAttempt`: no direct success seeding, rejected required gate retained, ordinary second attempt and stable refused replay. |
| Cancellation | Retain `TaskRuntimeExampleTests.testDirectorChildCancellationAcknowledgesExactTerminalSession` and existing dirty `TaskDispatcherIntegrationTests.testCancelledTaskDoesNotRetryOrCreateLegacyIncident` for ordinary task cancellation/fence and stable retry/incident counts. Run the separate accepted cancellation-host suite too. |
| Replay | Retain `TaskDispatcherIntegrationTests.testCLIRerunConsumesOnePendingRequestAndReplayDoesNotDuplicate`; reopen store and compare attempts, sessions, pending requests, ledger/accounting, not only CLI text. |

All proposed names must be implemented or replaced by an explicit reviewed
mapping to equivalent existing tests; never report a zero-selection pass.

### A1 exact serial repair and proof sequence

Steps 2, 3 and 7 describe invariants already partly implemented in the preserved
dirty tree. Fresh-read and test them first; change production only when a named
A1 test demonstrates a remaining defect. Do not reimplement passing repairs.
The paired retry/non-retry tests already exist; complete their first-hook
assertions while preserving all existing assertions and policies.

1. Fresh-read all nine preserved dirty files and current attempt-1 plus historical failed logs. Perform the exact seven-method/two-helper split above first; do not redo completed repairs. Preserve
   the existing atomic repair in `RuntimePublication.swift`/`RuntimeStore.swift`:
   command-node nonzero adapter execution is `adapterFailure`, not nil. Use the
   harness terminal observation seam and reopen SQLite/WorkStore to prove the
   first canonical failed snapshot, outcome and durable evidence agree. Preserve
   source-compatible optional classification, advisory routing, required gates,
   task-free failures and cancellation precedence. Do not redo or revert the
   dirty repair, weaken the terminal fence or classify unrelated failures.
2. In `TaskDispatch.swift` terminal reconciliation, supply a stable attempt-budget
   observation only for retry-eligible reconciled failed work when no admission
   capacity remains. In `TaskGuardCoordinator.swift`, keep observation identity
   and violation counts consistent and persist that causal evidence before the
   shared decision applier stops the task. Do not bypass the coordinator with
   direct task-state writes. A running or completed last admitted attempt must
   not receive this exhaustion observation. Preserve all existing hard-stop
   resource/convergence rules. In the same coordinator, select the configured
   director child ahead of automatic failure retry when its failed-attempt
   threshold is met and capacity remains. Never recurse from a director child,
   override cancellation or hard stops, or allow failed judged work to be accepted.
3. In `TaskDispatch.swift`, before current completion evaluation, reconcile only
   a proven historical synthetic gate-absence finding. Inspect prior canonical
   gate lineage, exact generated finding ID and `stepExecutionId == "missing"`;
   require a real accepted required gate for the same gate/step in the latest
   completed work attempt. Use existing store operations to persist resolution
   with the new gate evidence as cause. Retain all old immutable evidence. Never
   clear by ID prefix, clear substantive findings, or resolve absence from a
   failed/director attempt, mismatched, missing, rejected or needs-work gate.
   Reopening/replay must preserve resolution without duplicate evidence or
   reopening it from stale projection. If existing APIs cannot support the
   accepted behavior, report exact evidence and request a bounded ownership
   amendment before editing any read-only owner.
4. Extend tests in newly owned `TaskDispatcherIntegrationTests+GuardPolicy.swift` and
   `TaskRuntimeExampleTests.swift` before treating the repair as complete:
   retain the two named retry tests, actual distinct sessions, pending request
   consumption, failed-at-limit, last-admitted success, refused replay and row
   counts. Retain `testRetryDisabledAdapterFailureWaitsWithoutPendingRequest` and add
   `testUnclassifiedFailureDoesNotAutomaticallyRetry`; drive actual failures
   through existing fixtures, not terminal-success seeds. Extend `testLastAdmittedRecoveryAttemptCanSucceed` as the reviewed equivalent of
   `testHistoricalMissingGateResolvesOnlyAfterMatchingAcceptedGate`, and add
   `testCurrentMissingOrRejectedGateAndSubstantiveFindingsStillBlock` to cover
   matching/mismatched lineage, missing/rejected/needs-work gates, similar-ID
   substantive high/mid findings, required human acceptance, durable resolution
   cause and reopened replay. Retain
   `testConfiguredDirectorChildRunsOrdinarilyAndCannotAcceptFailedWork` and add
   `testDirectorEscalationRequiresConfigurationThresholdAndCapacity` for absent
   authorization, below threshold, exhausted capacity and no director recursion.
   Proposed names may use parameterized subcases; record the final exact mapping.
5. In the newly owned `TaskCancellationIntegrationTests.swift`, change
   `testTerminalFirstOrdinaryFailureSurvivesLateSIGINTAndExternalRequest` to set
   `rerunOnAdapterFailure=false` on the seeded task before dispatch. Keep failure
   exit, reconciled state, waiting, no cancellation record and zero cancel
   decisions for both external and SIGINT branches; assert `adapterFailure` at
   the terminal hook, outcome and reopened snapshot. Add
   `testTerminalFirstRetryableFailurePreservesOnePendingRequestAfterLateCancellation`
   with retry enabled: identical immutable terminal failure and exactly one
   ordinary policy pending request, with no extra/suppressed retry from the late
   signal/request. Retain cancellation-first and selected-host assertions.
   Never change the non-retry expectation to scheduled just to match the failed
   log. Run policy-focused and canonical-regression commands below; retain any
   failures and repair within ownership before proceeding.
6. Move and extend the two existing live tests in `TaskDispatcherIntegrationTests+GuardPolicy.swift`.
   `testTaskInactivityPersistsViolationAndStopsExactAttempt` covers a backend
   with no heartbeat and a backend that stops after progress; observe it running
   through actual dispatch, then durable violation/decision and exact-session
   acknowledgment before replacement. `testTaskProgressPreventsInactivityAction`
   emits progress more frequently than the timeout, with a timeout below one
   second, and proves normal completion without false violation/cancellation.
   Use controlled execution/clock synchronization, not synthetic terminal seeds.
7. Extend the 100 ms observer in `TaskRunCancellation.swift` to read the exact
   running canonical session at `store.rootDirectory`. Canonical backend-event
   writes are unthrottled; the CLI projection is unsuitable. Use
   `TaskGuardSnapshotAdapter`/`TaskGuardCoordinator`; in the latter file, make
   `createdAt` the no-event baseline, otherwise use `lastBackendEventAt`.
   Polling does not reset progress. Missing, stale or failed reads authorize no
   interruption. Recheck progress, task version and reservation identity before
   applying; reload after conflicts or terminal completion rather than forcing
   cancellation. Persist immutable evidence and the shared policy decision first.
8. Reuse stable attempt/step observation identities and original payloads on
   replay; never rewrite immutable idle durations/timestamps. Warnings produce
   evidence without cancellation. Recovery/stop uses the existing cancellation
   record, interruption, join, selected-host stop proof and terminal acknowledgment.
   No replacement may launch before acknowledgment. In `TaskDispatch.swift`,
   retain the causal live violation at terminal reconciliation without a duplicate
   decision. Cover warning/repeated observation, progress/terminal races,
   cancellation precedence and reopened replay in the same owned fixtures.
9. Run V0, canonical-regression, cancellation-host and the complete V1 on the
   stable before-removal tree. Capture positive counts for all four V1 suites,
   named row assertions, complete logs, exit 0 and source hashes. The historical
   60-test failure remains preserved; no test disabling/deletion is permitted.
   If any assertion, suite or source identity is missing, A1 remains incomplete
   and A2 cannot start. Repairs invalidate affected receipts.

### Evidence, drift and command contract

Allocate the next unused numbered attempt before any A0/A1 evidence writes:

```bash
a1_attempt=2
while test -e "tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-$a1_attempt"; do
  a1_attempt=$((a1_attempt + 1))
done
export a1_evidence_dir="tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-$a1_attempt"
mkdir -p "$a1_evidence_dir/before-removal" "$a1_evidence_dir/intents" "$a1_evidence_dir/reviews"
```

For each command below, redirect stdout/stderr to a distinct full `.log`, save
`$?` immediately to its paired `.exit`, and record timestamps and the exact
expanded command in the receipt. Use `before-removal/v1.log` for full V1,
`v0.log`, `discovery.log`, `size.log`, `policy.log`, `canonical.log`,
`cancellation-host.log`, `races.log` and `swiftlint-strict.log` for the other gates.
Each coverage table row/subcase references its relevant log and named method.
No later command may overwrite the prior command's terminal exit.

On final source before gates, and again after gates (change `before` to `after`),
produce the complete sorted inventory/hash manifest; comparison detects new or
removed files as well as content changes:

```bash
python3 - "$a1_evidence_dir/source-before.sha256" <<'MANIFEST'
from pathlib import Path
import hashlib, sys
paths = sorted([p for root in ('Sources', 'Tests', 'examples')
                for p in Path(root).rglob('*') if p.is_file()]
               + [Path('Package.swift'), Path('Package.resolved')])
Path(sys.argv[1]).write_text(''.join(
    hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p) + '\n' for p in paths))
MANIFEST
shasum -a 256 -c "$a1_evidence_dir/source-before.sha256"
cmp "$a1_evidence_dir/source-before.sha256" "$a1_evidence_dir/source-after.sha256"
```

Run `cmp` only after generating `source-after.sha256` after verification; both
checks require exit 0. Record `git rev-parse HEAD` with both manifests. Generate
the current strict-lint input from surviving reviewed A1 Swift paths that differ
from the preserved checkpoint, including its pre-existing dirty Swift paths and
the new extension. The explicit manifest below avoids omission of the new file:

```bash
python3 - "$a1_evidence_dir/changed-swift-files.nul" <<'LINT'
import json, pathlib, subprocess, sys
m = json.loads(pathlib.Path('impl-plans/active/work-runtime-p1-7a-resume-comm000006-37c80ecd-dispatch.json').read_text())
changed = set(subprocess.check_output(['git', 'diff', '--name-only', '8b263ab07e22bb48a390489f395a7a4ea6a5d58b'], text=True).splitlines())
changed.add('Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift')
paths = [p for p in m['plans'][0]['writePaths'] if p.endswith('.swift') and p in changed and pathlib.Path(p).is_file()]
assert 'Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift' in paths
pathlib.Path(sys.argv[1]).write_bytes(b''.join(p.encode() + b'\0' for p in paths))
LINT
xargs -0 swiftlint lint --strict --quiet --no-cache < "$a1_evidence_dir/changed-swift-files.nul"
```


Evidence root: `tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-<n>/`.
Preserve occupied attempt-1; choose the next unused attempt (at least attempt-2) and use `before-removal/`,
`after-removal/`, `intents/` and `reviews/` subdirectories. Preserve historical
attempt-3 under the prior root. Before each edit, fresh-read the exact file,
save its preimage (or absent marker), SHA-256 and intended hunk/rationale. Recheck
preimage hash immediately before writing; on drift stop that edit, reread and
reconcile serially. Save postimage/hash. No overwrite of another owner's work.
After joining, compare the manifest to actual changed paths and repair serially.
Only one process may mutate shared build output; read-only investigations can
run concurrently, but no concurrent builds, tests, lint generation or Git.

Each command receipt includes exact command/environment/cwd, start/end, complete
log path, terminal exit, source HEAD plus SHA-256 manifest of Sources/Tests/
examples/Package.swift/Package.resolved (including additions/deletions), and
positive counts for each selected suite. Record NUL-delimited surviving changed
Swift paths for V6. Source manifests must match before/after verification.
Never use `&`, nohup, daemonization or detached work; poll yielded handles to exit.
Redirect foreground output to the named full log; record the actual command exit,
not a pipe/tee exit. Missing summary, truncation, skipped-only or zero-test runs
are incomplete, never PASS. Any necessary environment adaptation is recorded
alongside the original failure; do not silently substitute commands.

Commands below retain historical attempt-1 examples; substitute the next unused
attempt (at least attempt-2) before executing any command that writes evidence. `<key>.log` and
`<key>.exit` live under the attempt directory (V1 separately under before-removal
and after-removal). V0 compiles/typechecks; V1 proves the deletion matrix and
existing four-suite behavior; V2–V4 preserve accepted store/guard/capability
contracts in deferred A3. V5 groups and broad certify deferred removal effects;
they are not current A1 completion gates.
V6 has no strict diagnostics; V7 baseline/final records all diagnostics and no
new owned lint defect. V8 is only repository example validation/mock execution,
not provenance discovery; assert documented two-node accepted repair and one-node
`kind=accept` director outputs. Catalog tests retain observed selection checks.
V9 exit 0 requires match-by-match rejection-test/retained/historical classification,
exit 1 means no matches, >1 is an error. Diff checks require exit 0. Cached diff
runs only at the serial checkpoint/finalization gate.

**Split discovery, size, live races and retained design commands — current A1**

```bash
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch list
wc -l Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests.testTaskInactivityPersistsViolationAndStopsExactAttempt|TaskDispatcherIntegrationTests.testTaskProgressPreventsInactivityAction|TaskDispatcherIntegrationTests.testTaskInactivityWarningAndReplayPreserveSingleObservation|TaskDispatcherIntegrationTests.testTaskInactivityProgressTerminalAndCancellationRacesPreservePrecedence'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests.testFailedTaskRetriesWithinBudgetAndStopsAtLimit|TaskDispatcherIntegrationTests.testLastAdmittedRecoveryAttemptCanSucceed|TaskRuntimeExampleTests.testConfiguredDirectorChildRunsOrdinarilyAndCannotAcceptFailedWork|TaskCancellationIntegrationTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RuntimeStoreTests|RuntimePublicationTests|DeterministicWorkflowRunnerTests|TaskCancellationIntegrationTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

Discovery must list each moved/added method once under the original XCTest suite;
the original must be <1,000 lines and the new file ≤1,000. Live execution must select all four methods and
record both inactivity variants and all warning/race subcases. Focused and full
suite logs must map every A1 row above, not merely show a positive aggregate.
V0, policy-focused, canonical-regression, cancellation-host, full V1, focused
live races, discovery, size, V6 strict changed-file lint and source identity are
mandatory for current A1. V7 captures the baseline/comparison already prescribed
by A0. Removal-specific V2–V5, V8–V9, catalog/Monja and serial broad gates are
deferred to A2/A3; they do not block the A1-only implementation handoff.
Use a fresh NUL lint manifest including the new split file; do not modify the
preserved attempt-1 lint manifest or logs. Different scratch paths require the
same recorded final source hashes; no stale binary evidence is accepted.

**V0**

```bash
swift build --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch
```

**V1**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**retry-focused — diagnostic only, never a substitute for V1**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests.testFailedTaskRetriesWithinBudgetAndStopsAtLimit|TaskDispatcherIntegrationTests.testLastAdmittedRecoveryAttemptCanSucceed'
```

**policy-focused — all new positive/negative cases, before full V1**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'
```

Require positive counts and every A1 step 4–5 case, not only the four historically
failing methods. Retain complete output and the exact method-name mapping.

**canonical-regression — before removal and final source**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'RuntimeStoreTests|RuntimePublicationTests|DeterministicWorkflowRunnerTests|TaskCancellationIntegrationTests'
```

Require positive actual-suite counts, advisory/failure behavior and the existing
canonical terminal/cancellation arbitration assertions. Only the newly owned
TaskCancellationIntegrationTests.swift may change as specified in A1; other
regression files remain read-only. Required new first-write
classification assertions belong to both named terminal-first methods in
`Tests/RielaCLITests/TaskCancellationIntegrationTests.swift`, as mapped above.

**V2-actual-suites — mandatory supplement**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'
```

Planning self-check found historical filter/file-name mismatches:
`WorkStoreCancellationTests.swift` extends `WorkStoreReservationTests`, and
`BudgetAdmissionStoreTests.swift` declares `BudgetAdmissionDecisionApplierStoreTests`.
Keep the requested V2 command as an explicit receipt, but require this supplemental
command and positive actual-suite counts. Separately enumerate executed test
identities from the cancellation extension to prove cancellation coverage;
never claim either nonexistent suite executed. No suite rename is required.

**V3**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
```

**V4**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V5a**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
```

**V5b**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
```

**retained**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'WorkflowCommandTests|WorkflowRunHelpTests|CommandParsingTests|SpecialistSupervisorCommandTests|SpecialistSupervisorBoundaryTests|SpecialistSupervisorRecoveryTests|EventLiveServeTests|RoutineCommandTests|RoutineAddonTests|RoutineStoreTests|RoutineGraphQLTests|EventRoutineBindingTests|RoutineAddonCatalogTests|LoopStartPromoteCommandTests|DefaultLoopGuardRecoveryTests'
```

**cancellation-host**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

**catalog**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'RielaExampleParityTests'
```

**retained-consumers — after A2**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'SurfaceParityCLITests'
(cd examples/monja-agent-collaboration && bun run typecheck)
(cd examples/monja-agent-collaboration && bun run test)
(cd examples/monja-project-task-orchestrator && bun run typecheck)
(cd examples/monja-project-task-orchestrator && bun run test)
rg -n -- '--no-auto-improve|--auto-improve|examples/auto-improve/|examples/supervised-mock-retry/|examples/default-superviser/' examples/catalog/chat-persona-and-agent-trio.md examples/monja-project-task-orchestrator/executor.ts examples/monja-agent-collaboration/riela.ts examples/monja-agent-collaboration/verify-workflow.ts
```

Require the real `SurfaceParityCLITests.testOptionUniverseContainsRealFlagsAndRejectsRetiredOnes`
assertions and positive Monja test counts. Typechecks must exit 0; missing local
dependencies are an explicit verification gap, not permission to regenerate
lockfiles. Review the three argument-array diffs to prove only the obsolete
argument changed, and verify replacement catalog links exist. For this targeted
reference audit require no remaining obsolete invocation/link (rg exit 1 means
no matches); retained historical context needs explicit classification. Tests
must not execute external live services as an unrecorded substitute for mocks.

**remote**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'WorkflowCommandTests.testWorkflowRunUsesGraphQLEndpointTransport|WorkflowCommandTests.testWorkflowRunEndpointUsesRielaAuthEnvironment|WorkflowCommandTests.testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus'
```

**standalone-gate**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --filter 'TaskRuntimeExampleTests.testStandaloneNonAcceptedRepairGateFailsAndRetainsEvidence|WorkflowCommandLivePersistenceTests.testWorkflowRunPersistsRejectedRequiredLoopGateForFailedRunInspection'
```

**broad**

```bash
swift test --scratch-path tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch --no-parallel
```

**V6**

```bash
xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-1/changed-swift-files.nul
```

**V7**

```bash
swiftlint lint --quiet --no-cache
```

**V9**

```bash
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
```

**diff**

```bash
git diff --check
```

**cached-diff**

```bash
git diff --cached --check
```

**V8-task-repair-loop-validate**

```bash
tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
```

**V8-task-repair-loop-mock**

```bash
tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-1/task-repair-loop-store --output json
```

**V8-task-agent-director-validate**

```bash
tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
```

**V8-task-agent-director-mock**

```bash
tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1-7a-resume-comm000006-37c80ecd/plans/p1-dispatch/attempt-1/task-agent-director-store --output json
```

The remote filter uses the actual XCTest class `WorkflowCommandTests` even
though its methods are declared in `WorkflowCommandInspectionTests.swift`.
Record receiving-rejection commands separately from the local Swift selection
when the identified external owner supplies exact test paths and publication
evidence for `packages/rielflow-graphql/src/schema-contract.ts`. Capture external source identity, complete logs and terminal exits for
false/null field presence and ordinary authenticated acceptance; no guessed
local test name or outbound omission satisfies that gate.

Keep `tmp/work-runtime-p1-7b-catalog-20260925-bffa1da-comm000006/plans/p1-dispatch/attempt-2/broad-classification.json`
as the prior baseline: exit 1, 18 assertions, owners Doctor/backend-capability
(7), workflow/host-readiness (8), runner admission (1), temporary registration
(2). Compare exact file/test/assertion identities and causes, never counts alone.
Every fresh failure needs owner/follow-up; new P1-7a failures must be repaired.
Unrelated broad failures remain **FAILED** even if formal review accepts the slice.

### Completion/progress checklist

- [ ] Current Step 5 accepts this A1-only plan; P3 publishes only the three planning paths, then enables A0/A1 dispatch.
- [ ] A0 inventory/receiving-boundary investigation and immutable intents complete.
- [ ] A1 causal policy, paired cancellation, live inactivity/progress, canonical-regression, cancellation-host and full four-suite V1 pass on the same source before deletion.
- [ ] Deferred A2: removal and rejection/preservation; not authorized now.
- [ ] Deferred A3: post-removal final-source receipts.
- [ ] Deferred A4: full-removal formal review; separate current A1-only review is required.
- [ ] Deferred A5: full-removal finalization; separate current A1-only documentation/finalization is required.

Each progress entry records A-task status, touched paths, source identity,
commands/full logs/exits/counts, findings and ownership, review decisions and
next dependency. Do not mark P1-7a complete before A5; parent P1 stays open.
Step 3 `comm-000004` accepted this design; Step 5 `comm-000006` accepted the A1-only plan without findings.
Step 4 completion means a review-ready plan/manifest, not completed A0–A5 or a
passing implementation gate. Current Step 6 completion requires A0/A1 and every
current A1 evidence gate; formal reviews and scoped finalization follow through
the workflow and must not cause Step 6 to self-block. Future implementation must satisfy the full A1
matrix before deletion and published external evidence before A2/A3 acceptance.
Future A4/A5 remain downstream; no implementation or progress edits occur here.

Independent read-only consumer inventory, test-coverage analysis and failure
classification may be delegated within a ready wave, with evidence under `tmp/`.
Only the integration owner writes coupled source/tests and the progress file;
serialize builds/tests/lint sharing scratch output. Join investigation results,
recheck hashes and repair drift serially before advancing the task DAG.

---

## Historical contracts and receipts (retain for traceability)

# Work Runtime P1-7b: task-backed replacement examples

## Current executable contract — P1-7b only (2026-09-25)

**Current authority: reviewed catalog amendment.** Issue “Finish P1-7b after
integration review found missing example-catalog coverage”; intake `comm-000002`.
Step 3 `comm-000004` (`step3-design-review-attempt-1-exec-4`) accepted
`design-docs/specs/design-work-runtime-consolidation.md` §17.9 with no findings.
Preserve checkpoint `bffa1da4ab161892ecec54784439e6148860f302`, all eight dirty
implementation/progress files listed in §17.9 and unrelated session work.
No GitHub number/URL, codex-agent reference or Cursor behavior mapping applies.
Step 5 review and amendment checkpoint/push are pending; this author claims
planning only. The earlier task-gate correction is retained WIP, not new work.

### Catalog ownership repair and pre-dispatch gate

Prior Astra `comm-000018` and `comm-000027` rejected the catalog omission and
misclassification; the latter reports `blocked_on_unchanged_plan_ownership`.
Finding `p1-7b-example-parity-misclassified` remains open until repaired and
verified. Prior Sol acceptance does not override it.

Add only these two new paths to the existing serial owner's write set:

- `Tests/RielaCLITests/RielaExampleCatalog.swift`: add `task-agent-director` and
  `task-repair-loop` once each, preserving existing catalog entries/order.
- `Tests/RielaCLITests/RielaExampleParityTests.swift`: adjust only affected
  expected mock counts to observed selections/results. Preserve every assertion,
  exclusion and execution/output check. Do not dynamically derive expectations
  from the same actual result, skip bundles or weaken equality checks.

Before B0, Step 5 must accept this plan and the aligned manifest
`impl-plans/active/work-runtime-p1-7b-catalog-20260925-bffa1da-comm000006-dispatch.json`.
Checkpoint and non-force push exactly that manifest, this plan and
`design-docs/specs/design-work-runtime-consolidation.md`. Keep all eight dirty
implementation/progress files outside this planning commit. Record the actual
commit/push hashes and exact file receipt; dispatch only after successful push.
No implementation or unchanged reconciliation retry precedes this gate.

### Retained accepted finalization amendment

The proposal is
`tmp/work-runtime-p1-7b-20260925-comm000008-59f45c1a/plans/p1-dispatch/attempt-2/bounded-amendment-request.json`.
V1 `logs/before-removal-final.log` in the same directory demonstrates
`terminalSnapshotConflict`: a rejected required gate leaves a completed
canonical task session, then CLI finalization rewrites it as failed. SQLite
correctly rejects the rewrite. The prior `plan_amendment_review` found no
production write authorization at that time; the prior accepted amendment authorized this exact-file remedy.

- Additional production ownership is limited to
  `Sources/RielaCLI/WorkflowRunCommand.swift`, under the existing serial owner.
  Preserve the implemented actual reservation presence from `run` to `RunFinalizeContext`
  at both plain and auto-improve construction sites; guard only the call to
  `applyRequiredLoopGateFailureIfNeeded` so it runs for standalone executions.
  Do not use authored inputs or task-context metadata to infer reservation.
- Retain evidence projection/summary, persistence and notification/rendering
  order. A rejected task gate must retain its completed canonical session,
  rejected gate/findings and causal evidence for existing deterministic
  recovery; it must not become task success. Do not override genuine runner
  failure/cancellation, clear findings or weaken terminal arbitration.
  Standalone required-gate failure status/exit and inspection remain unchanged.
- No changes to SQLite, dispatcher/director policy, CLI/schema/public APIs,
  abstractions or unrelated failures. Existing test/bundle paths remain as
  previously authorized; this continuation adds no production file.
  Reuse the standalone regression read-only; its file is not a new write path.
- Preserve the complete existing recovery fixture and its ordinary dispatch
  assertions. Historical amendment-time V1 executed 56 tests with four failed assertions, including intermittent
  second-attempt/replay recovery behavior. The terminal correction is not proof
  of resolving those findings. If they persist, B2/B3 remain blocked; record
  exact evidence and seek another bounded review for any out-of-scope repair.
  Never manually address findings, seed terminal success or delete assertions.

Before B3 acceptance, run these exact tests separately on the final source,
with the explicit Xcode toolchain and architecture:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskRuntimeExampleTests.testRejectedGateRecoveryConsumesPendingRequestAndAcceptsSecondAttempt
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter WorkflowCommandLivePersistenceTests.testWorkflowRunPersistsRejectedRequiredLoopGateForFailedRunInspection
```

Record complete `task-recovery.log` and `standalone-rejected-gate.log` under a
fresh numbered attempt directory, exact command/toolchain, source hashes,
positive counts (at least one executed test each), zero failures and final exit
0. Missing/zero selections cannot pass. The first test must prove completed
first session, retained rejection, no premature acceptance, causal pending
recovery for `verification`, distinct second attempt/session with accepted
gate and succeeded task, consumed request and unchanged ledger on replay.
The second must prove failure exit/status and rejected evidence in canonical
and artifact stores. Renew build, V1 four-suite, V11, affected suites, mocks,
strict lint including the production file, diff and serial broad checks below;
no mutating tests overlap edits. Capture complete logs, terminal exits and
positive per-suite counts against identical source. Prior broad evidence is
FAILED and includes the owned catalog defect; classify all fresh failures by exact
test/assertion/cause/source/owner. Resolve new/slice failures; unrelated ones
remain FAILED with follow-up and formal slice-only review disposition. Do not
report broad PASS without a complete passing run. Retain B4, formal test-integrity,
single adversarial, Astra combined-tree, exact-file commit and non-force push
gates; P1-7b, P1-7a and parent P1 remain open. No unresolved user decision.

**Executable scope.** Only this current section and its first JSON block
schedule this continuation. Everything after “Historical P1-6d contract” is
retained history, including older authority, task DAGs, allowlists and removal
gates. Prior review references there do not replace current runtime decisions.
Status: design accepted; catalog ownership plan review/checkpoint and repair pending.
Preserve the checkpoint above and ancestor P1-6d commit
`59f45c1a126d451fbe2eaf775306785d53b518d2` on `feat/remaining-impl-plans`.

### Intent, context, boundaries and ownership

Complete the existing two example bundles and prove their task behavior through
real WorkStore, TaskDispatch, WorkflowRunCommand and decision application.
Standalone mocks supplement real task tests. Both bundles and the existing example
test methods already exist; preserve them and repair only proven defects instead of rebuilding
accepted P1-6d. TaskExampleHarness lives in TaskDispatcherIntegrationTests.swift.
The old broad run failed 19 assertions, one belonging to these examples;
“historical non-slice” for P1-6d is not an exemption for P1-7b.

Retain all legacy examples and P1-7a implementation. No deletion, new CLI/schema,
recursive director, new orchestration abstraction, unrelated failure repair,
Monja work, broad formatting, lockfile regeneration or global plan archiving.
No workflow/package provenance rediscovery. No reset, stash, revert, force push, broad staging,
main merge, private branch, worktree or concurrent Git operation. Shared state
and source edits are serial. Retain the previously authorized
`Sources/RielaCLI/WorkflowRunCommand.swift` correction; any further
production path needs a separately reviewed exact-path amendment.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "examples/task-repair-loop/workflow.json",
    "examples/task-repair-loop/nodes/node-repair.json",
    "examples/task-repair-loop/nodes/node-verify.json",
    "examples/task-repair-loop/prompts/repair.md",
    "examples/task-repair-loop/prompts/verify.md",
    "examples/task-repair-loop/mock-scenario.json",
    "examples/task-repair-loop/README.md",
    "examples/task-repair-loop/EXPECTED_RESULTS.md",
    "examples/task-agent-director/workflow.json",
    "examples/task-agent-director/nodes/node-director.json",
    "examples/task-agent-director/prompts/director.md",
    "examples/task-agent-director/mock-scenario.json",
    "examples/task-agent-director/README.md",
    "examples/task-agent-director/EXPECTED_RESULTS.md",
    "Tests/RielaCLITests/TaskRuntimeExampleTests.swift",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/README.md",
    "impl-plans/REMAINING-WORK-HANDOVER.md"
  ]
}
```

Paths are candidates, not mandatory edits. One owner covers this coupled test/
bundle scope and writes only `impl-plans/progress/p1-dispatch.md` as its progress
log. Shared documentation is reserved for serial finalization. No independent
implementation plan justifies splitting the shared fixture contract. Read-only
evidence inspection can overlap only when no command mutates the source/build.
Use independent read-only subagents for assertion inventory, failure-log
classification and evidence audit wherever safely separable. They return
findings to the serial owner and never edit coupled files, run concurrent Swift
commands or substitute advisory findings for the formal downstream reviews.

### Dependency-ready waves and precise deliverables

| Task / dependency | Exact work and acceptance evidence |
| --- | --- |
| B0 / accepted and pushed amendment checkpoint | Read §17.9, current plan/manifest, preserved WIP and prior integration receipts. Record source hashes, status, exact owners and seven-case assertion inventory. Confirm both catalog omissions and count-selection logic read-only; prior final5 evidence is historical unless identity remains valid. |
| B1 / B0 | Reconcile and preserve existing bundle, production correction and seven lifecycle cases against their receipts. Retain existing README/EXPECTED_RESULTS behavior distinctions. Do not reimplement completed work or edit the shared harness without a demonstrated material defect within existing ownership. |
| B2 / B1 | Under one serial owner add both names in RielaExampleCatalog.swift and update only affected expected mock counts in RielaExampleParityTests.swift based on observed execution. Keep all assertions and existing exclusions. Deliver exact diff and named test-to-requirement mapping; retain the production correction and standalone regression unchanged unless a material in-scope repair is proven. |
| B3 / B2 | Serial join against immutable intents; run build, catalog validation and catalog mock tests, both exact regressions, TaskRuntimeExampleTests, V1 before-removal, affected suites, V8, V11, strict lint, diff and serial broad tests below. Record positive counts, observed mock counts, complete logs/final exits/source identity. Classify every failure by exact identity/cause/owner/follow-up; resolve all P1-7b failures and renew invalidated evidence. |
| B4 / B3 plus formal reviews | After formal test-integrity, single adversarial and Astra combined-tree acceptance with no material P1-7b defect, refresh directly affected shared docs and progress. Prepare exact reviewed file allowlist, then downstream commit/non-force push. Leave P1-7a, parent P1 and unrelated broad follow-ups open. |

Task DAG: B0 → B1 → B2 → B3 → formal test-integrity/single adversarial
review → Astra combined-tree acceptance → B4 → final commit → non-force push.
Use native Riela sequencing; no nested shell orchestration or implementation
fanout is needed. B3 implementation evidence can complete before later review
steps; B4 and publication cannot be claimed early.

After Step 5 acceptance and successful exact-file amendment checkpoint/push,
hand the single plan to native Riela dispatch. Reconcile prior work, then perform
the new catalog/count repair and fresh evidence; do not repeat unchanged Step 6
receipts. Any checkpoint push failure stops dispatch. Formal implementation
reviews precede B4 and the final exact-file implementation commit/non-force push.
Step 4 itself does not commit, push, implement or run behavioral tests.

### Invariants and executable test intent

1. **Acceptance:** seed through existing WorkStore APIs, execute repair/verify
   through task dispatch, assert exact reserved attempt/session, accepted required
   gate, verification/acceptance evidence, causal accept and succeeded task.
2. **Gate recovery:** deterministic first response rejects `verification` with
   remaining attempt budget. Assert the task cannot succeed and the persisted
   recover decision/pending request names that gate. Change only the controlled
   mock response to passing; ordinary task dispatch must consume that request,
   run the recovery and reconcile a distinct bounded attempt/session to success.
   Assert durable evidence, consumed request and stable counts on repeat dispatch.
   Never seed the expected recovered terminal state or call only the evaluator.
3. **Guard stop:** retain a deterministic convergence violation, persisted guard
   evidence and `.stop` reference to that evidence. Assert failed task and the
   accepted terminal CLI result; repeat dispatch creates no new work. The current
   gate-visit fixture is not proof of repeated-finding behavior; narrow docs to
   actual coverage rather than adding an unrequested guard mechanism.
4. **Capacity wait:** use capacity zero, assert waiting/capacity and absent response
   IDs, plus unchanged attempts, canonical sessions and leases in the store.
   Use existing read APIs or isolated fixture database observations, no product API.
5. **Allowed director:** retain ordinary linked-child execution and successful
   acceptance of durably satisfied judged work. Child-only success must not accept
   failed work. Preserve version, causality, budget, human and completion checks.
6. **Once-only accounting:** reuse the existing nonzero seven-token child case
   where suitable; assert exact task/judged/child/session linkage and durable cost
   entries. Reopen the store, repeat ordinary dispatch and assert no duplicate
   attempt, decision or charge and unchanged judged evidence/outcome.
7. **Invalid output:** drive malformed/forbidden recommendation through the real
   child runner and application path; assert durable human-wait escalation with
   evidence. Reopen/repeat dispatch and assert no extra child/charge/recursion.
   Preserve existing failed-child and admission-budget coverage.

Do not weaken assertions, skip failing cases, use direct terminal-state writes
for transitions under test, or substitute workflow output strings for ledger
observations. Preserve accepted cancellation, selected-host, task-free workflow,
specialist/event/loop/routine behavior. All fixtures clean up owned sessions.
Follow applicable Swift checks on actual Swift edits. This amendment does not
authorize extraction or another production file, including for file-length
cleanup. If a required change cannot fit the one-file scope, record the exact
conflict and obtain a separate bounded amendment before any additional write.
Do not expand this repair into a refactor.

### Edit integrity and progress evidence

Before every edit fresh-read the file; store immutable numbered preimage,
SHA-256 (or absent sentinel), requirement, owner and intended hunks under
`tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-N/intents/`. Recheck the hash
immediately before writing. On drift, stop that write, reread and create a new
intent; never restore stale bytes. Record post-hash and exact diff. Reconcile
all edits serially before checks and review. Preserve unrelated WIP and index.

For every command record exact invocation, start/end, complete stdout/stderr log,
terminal exit, source manifest hash and positive per-suite test counts in
`verification-evidence.json` under that attempt. Manifest membership includes
Sources, Tests, Package.swift, Package.resolved and all catalog example trees, including
new files; compare SHA-256 and membership before/after runs. A moving source
invalidates the affected receipt. Separate B0 baseline from final-source logs.
Update progress with task status, requirement→test mapping, commands/logs/counts,
failure classifications, review IDs/decisions and remaining work, never intent
as completed evidence. Preserve required evidence; delete disposable scratch.

### Exact verification commands and evidence

Run from repository root, foreground only; poll every yielded handle to exit.
Create an immutable numbered attempt directory before redirecting command logs.
Do not pipe away exit statuses. The following commands use the existing build
root; execute serially on stable source. No command in this list ran at Step 4.

```bash
mkdir -p tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskRuntimeExampleTests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests|WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|AgentDirectorStoreTests|CompletionEvaluatorTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/repair-store --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/director-store --output json
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel
git diff --check
git diff --cached --check
```

Assign complete logs respectively: `build.log`, `examples-tests.log`,
`before-removal/focused-tests.log`, `affected-store-tests.log`,
`selected-host-tests.log`, `repair-validate.log`, `repair-mock.log`,
`director-validate.log`, `director-mock.log`, `broad.log`, `diff.log`,
`cached-diff.log`. Create nested log directories first. On retry use attempt-N
and matching fresh session-store roots, retaining all earlier logs/exits.
V8 operates only on these repository examples, never the executing workflow.
Compare mock business outputs to EXPECTED_RESULTS, not just exit status.

Run the catalog commands separately after B2; each must execute at least one
test, exit 0 and retain existing assertions. Save `catalog-validation.log` and
`catalog-mocks.log`, recording observed total and node-runtime mock counts and
proof both replacement bundles executed:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI
```

Run both exact recovery/standalone commands above separately with their named
logs. Prior final5 does not replace these renewed gates. Catalog edits invalidate
catalog/mock and broad receipts. The changed Swift lint manifest includes the
retained WorkflowRunCommand.swift and TaskRuntimeExampleTests.swift changes plus
both newly owned catalog/parity paths, and any other surviving authorized Swift
change. Do not limit lint to just this continuation's edits.

Before Swift edits and after final changes capture repository lint diagnostics;
compare attributable new findings without fixing unrelated baseline issues:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/changed-swift-files.nul
```

Construct the NUL manifest from exact surviving changed/new Swift paths in intent
records, excluding deleted paths; include untracked additions. Use
`swiftlint-baseline.log`, `swiftlint-final.log`, `swiftlint-changed.log`; strict
touched-file lint must exit 0. Only skip strict lint for a recorded empty Swift
write set. Swift build is the typecheck gate. No web changes or browser E2E.
If bundle workflow/prompt edits affect a checked-in package digest, refresh only
that owning digest under a recorded exact-path amendment; documentation-only
edits do not trigger a digest refresh. Do not inspect user registries.

All V1 suites and seven behavior rows require positive execution counts and
passing assertions. V11 preserves selected-host regression coverage. Missing
suites, zero tests, unavailable tools, timeouts, incomplete logs or listener
denial are failed/blocked evidence, never behavioral passes. Record any justified
toolchain/cache adjustment with its exact command and full log; do not omit a
required gate. The broad command is fresh and serial on final source. Classify
each failure by test/assertion, cause, source identity and ownership, comparing
prior failure identities only as historical context. The catalog assertion is
P1-7b-owned even if present in older P1-6d runs. Resolve every new or
P1-7b-owned failure. Unrelated failures remain **FAILED**, with explicit owner/
follow-up and formal slice-only review disposition; no unrelated repair.

For the final stable source snapshot, generate the membership and checksum
receipts with these commands (substitute the current immutable attempt number).
Before/after each verification run regenerate `current-files.txt`, compare it
with `source-files.txt`, then run the checksum check. Log each exit; never
regenerate the baseline checksums to hide drift.

```bash
rg --files Sources Tests examples Package.swift Package.resolved | LC_ALL=C sort > tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/source-files.txt
while IFS= read -r source_path; do shasum -a 256 "$source_path" || exit; done < tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/source-files.txt > tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/source.sha256
rg --files Sources Tests examples Package.swift Package.resolved | LC_ALL=C sort > tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/current-files.txt
cmp tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/source-files.txt tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/current-files.txt
shasum -a 256 -c tmp/work-runtime-p1/p1-dispatch/p1-7b/attempt-1/source.sha256
```

Enable shell `pipefail` for the membership pipelines so a failed file inventory
cannot appear successful merely because sorting succeeded.

### Completion gates

- [ ] Step 5 acceptance and exact design/plan/manifest checkpoint/non-force push.
- [ ] B0 inventory/baseline and exact ownership recorded.
- [ ] B1 minimal bundles and truthful README/EXPECTED_RESULTS agree.
- [ ] B2 both catalog entries and observed expected mock counts corrected;
  catalog validation/mock tests and both exact amendment regressions pass; all
  seven rows proven at real task boundaries; retained tests preserved.
- [ ] B3 final-source build, V1 before-removal, affected focused/V11, V8, strict
  lint, diff and serial broad evidence complete; new/slice failures resolved.
- [ ] Formal test-integrity, single adversarial and Astra combined-tree reviews
  record no material P1-7b defect; repairs invalidate and renew affected checks.
- [ ] B4 shared docs and progress reflect accepted evidence; P1-7a/parent P1 and
  unresolved broad follow-ups remain open. Exact-path commit and non-force push
  have matching published hash and reviewed file evidence.

No user decision is unresolved. Author self-check confirms §17.9 traceability,
the one-plan DAG, bounded writes, real-boundary tests, evidence requirements and
separate downstream gates. Step 4 claims planning only, not implementation or
formal Step 5 acceptance.

## Historical P1-6d contract

## Current executable contract — P1-6d only

Mode `issue-resolution`; issue “Complete Work Runtime P1-6d after Step 6
finalization-boundary repair”, effective workflowInput,
`comm-000001`; no GitHub number/URL or codex-agent reference input.
Step 3 accepted `design-docs/specs/design-work-runtime-consolidation.md` §17.8
through `comm-000004`, `step3-design-review-attempt-1-exec-4`, execution
`codex-design-and-implement-review-loop-session-1`, with no findings.
Accepted Step 3 design checkpoint SHA-256:
`9a20702d522e2a0007a5168714ea799e3709aeaa2939815b1621589cddff4e99`.
Status (2026-09-25): D0–D4 implementation and source-matched verification were
accepted by formal independent test-integrity, single adversarial and Astra
combined-tree review. D5 documentation was refreshed before exact-file
commit and non-force push, which remain pending. Evidence is under
`tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/`. The broad gate remains
**FAILED** with 19 classified historical non-slice assertions; P1-7b, P1-7a
and parent P1 remain open.

Only this section and its first JSON block schedule this invocation. Everything
below “Historical P1-6c contract” is retained history, including older current
contract headings, JSON blocks and broader verification/removal requirements.

### Intent, context and non-goals

Assess retained P1-6d work and repair only concrete material deficiencies,
without rebuilding accepted P1-6a/b/c. Current HEAD and accepted plan checkpoint
are `79eea8114b7d407e3fb7ed18faf5de5d86bce1ab` on
`feat/remaining-impl-plans`. Preserve all tracked/untracked source, tests and
documentation, including other sessions' work. The old clean d3f78df baseline
is historical. Step 3 accepted the current §17.8 update with no findings.
The child must execute through the ordinary runner and shared store, judge the
original work, and consume attempt/cost budgets once. Its successful status
cannot substitute for work completion. Forward existing planner capability inputs.

P1-7b task-backed replacement examples, then P1-7a legacy removal, parent P1 and
unrelated broad failures remain open. No recursive director, second task store,
replacement planner/discovery system, speculative abstraction or unrelated repair.
No workflow provenance rediscovery. No worktrees, private branches, resets,
force push, broad staging, concurrent Git writes, main merge or Monja changes.
No Cursor behavior mapping or intentional reference divergence applies.

### Scheduling and ownership

One plan and one serial implementation owner cover coupled store/model/CLI
changes. Paths are authorized candidates, not a requirement to edit every file.
Existing Core planner DTO is reused read-only. Necessary responsibility-based
extractions have explicit candidate names below; record their exact intent before
creation. Do not use this allowance for unrelated cleanup.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaWork/AgentDirector.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/WorkModels.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/WorkStore+Director.swift",
    "Sources/RielaWork/AgentDirectorModels.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskDispatch+Director.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Tests/RielaWorkTests/AgentDirectorTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/DecisionApplierCausalityStoreTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift",
    "Tests/RielaWorkTests/AgentDirectorStoreTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+Director.swift",
    "Tests/RielaCLITests/TaskRuntimeExampleTests.swift",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/README.md",
    "impl-plans/REMAINING-WORK-HANDOVER.md"
  ]
}
```

Shared documentation is reserved for serial reconciliation/finalization. No
lockfile, global formatting or plan archiving is needed. Independent agents may
investigate source, review test integrity and inspect completed verification
evidence read-only. Do not overlap SwiftPM runs or source writes. Formal
test-integrity, single adversarial and Astra combined-tree reviews remain
independent runtime steps; author/delegated advice cannot replace their decisions.

### Ordered tasks and file-level deliverables

The D0–D4 requirements below are assessment criteria for retained work, not an
instruction to recreate it. First map current source/tests and complete receipts
to every row. A satisfied requirement needs an evidence reference, not a new edit.
Only a demonstrated material defect or missing material verification triggers
repair and affected reruns. Report concrete deficiencies with severity and paths.


1. **D0 — baseline and seam reconciliation.** Read §17.8, the retained P1-6d
   checklist and source/test paths above. Capture current source membership/hashes,
   Git status and repository lint before any Swift edit. Inspect
   `Sources/RielaCore/WorkflowRequirements.swift` for
   `WorkflowPlanningCapabilityContext.workflowVariables()` and the exact
   `hostCapabilityContext` key. Confirm existing transaction, replay, budget,
   reservation and terminal reconciliation helpers before extending them.
   Deliver an immutable baseline and path intents; no predecessor repair work.
2. **D1 — durable round reservation (after D0).** In WorkModels/AgentDirectorModels
   define the smallest typed linkage for task ID, judged non-director attempt ID,
   child attempt ID and exact child session ID. In WorkStore+Reservation and,
   if useful, WorkStore+Director, persist that linkage atomically with ordinary
   `.director` reservation. Enforce one round per judged attempt, current version,
   reconciled judged work, no live competing attempt and existing admission
   budgets. Repeated admission resolves the durable round rather than creating
   another child. Adapt WorkStore+Schema only if storage shape requires it;
   preserve old rows/identities and migration policy. Rollback must leave no child,
   linkage, session, lease or attempt charge. Child terminal reconciliation uses
   its exact session and existing once-only usage accounting. Add fresh-store,
   reopen, duplicate/replay and injected transaction rollback assertions in
   WorkStoreReservationTests, WorkStoreTests and AgentDirectorStoreTests as needed.
3. **D2 — shared application (after D1).** Extend WorkStore+Decisions' shared
   application boundary with a narrow linked-child exception to latest-attempt
   checks. Validate same task, stored linkage, producer child session, reconciled
   successful child, original reconciled work, current task version and absence
   of newer/unrelated attempts. Reconstruct accept completion using original
   work gates, verification, acceptance and applicable blocking findings. Preserve
   `requiresHumanAccept`, causal-evidence scope and ordinary latest-attempt checks.
   Keep rerun/recover target, pending-request and budget validation. AgentDirector
   may emit allowed accept only once these protections exist; reject extra fields,
   invalid types and forbidden kinds. Identical decision replay returns its stored
   application; conflicting identity reuse rejects. Add real store acceptance
   tests in DecisionApplierStoreTests/DecisionApplierCausalityStoreTests and typed
   validator tests in AgentDirectorTests. Retain judged outcome/evidence unchanged.
4. **D3 — ordinary child execution and planner inputs (after D2).** Extend
   TaskGuardCoordinator and TaskDispatch (optionally TaskDispatch+Director) so only
   configured deterministic escalation selects one child after work reconciliation.
   Use the child workflow's ordinary resolution, admission token, placement and
   runner session; do not recursively call the director path for its completion.
   Construct `AgentDirectorTaskView` from the reconciled judged work and durable
   store records, then serialize and deliver it through the ordinary child
   workflow input variables. Include `task`, `judgedAttempt`, durable `completion`,
   `guardViolations`, `openFindings`, `evidenceSummary` and `remainingAttempts`.
   Retain original work identity/outcome across child reservation and execution;
   never substitute the newest director attempt or its success into this view.
   Remaining attempts must reflect the child admission charge when delivered,
   so the child sees the actual budget available for any proposed next work.
   Keep this judged context alongside the existing `hostCapabilityContext`
   planner input, without replacing either input or unrelated workflow variables.
   Extend TaskDispatcher and WorkflowRunCommand+TaskReservation only where needed
   to carry this ordinary child admission. Reuse SupervisionPersistence only if
   necessary for the existing persistence path; add no legacy supervisor behavior.
   Persist invalid/forbidden output, child failure, missing linkage and admission
   denial as escalation requiring a human. On stale versions preserve newer state;
   apply any escalation through current-version validation. Persistence failure
   is an error, not successful escalation. Replay/restart consults durable linkage
   and reservation state, preserving uncertainty fences and cancellation rules.
   Evaluate successful last-admitted work before trying another admission.
   Forward the selected finite host snapshot and reachable requirements through
   existing `hostCapabilityContext` variables; preserve other input variables and
   ensure callers cannot replace admission's authoritative snapshot. Keep selected
   backend/host through actual execution, without local fallback or dry-run writes.
5. **D4 — runner matrix and verification (after D3).** In
   TaskDispatcherIntegrationTests and optional +Director extension, run real
   shared-store ordinary-runner fixtures proving the matrix below. Strengthen
   one fixture to capture the actual child node's received workflow inputs and
   decode its judged TaskView: assert exact task/judged-attempt IDs and outcome,
   durable completion, nonempty guard violations/open findings/evidence with
   matching identities and payloads, and remaining attempts after child admission.
   Assert these values match the original reconciled work/store records, not
   the director attempt, and that `hostCapabilityContext` is also delivered.
   This must exercise dispatch and ordinary runner delivery, not DTO construction
   or serialization alone. Strengthen
   TaskRuntimeExampleTests only to prove this slice's child path; do not implement
   P1-7 replacement bundles/removal. Reconcile all final changes against intents,
   repair serially, validate or renew the evidence below, and hand off to formal
   independent review. Obtaining those downstream decisions is not a D4 task.
6. **D5 — accepted completion record (after D4 and formal reviews).** Refresh
   progress, this plan, design, README and shared indexes only where behavior/status
   changed. Keep P1-7b/P1-7a/parent P1 and broad follow-ups open. Produce exact file
   allowlist and evidence for downstream commit/non-force push; do not stage or
   publish implementation from a worker. Planning approval alone is not completion.

Task DAG: D0 → D1 → D2 → D3 → D4 → formal test-integrity/single adversarial
review → Astra combined-tree acceptance → D5 → exact-file commit → non-force
push. No separate implementation plan is
independent enough to justify concurrent writers.

### Invariants and required test matrix

| Case | Required observation at real store/runner boundary |
| --- | --- |
| Allowed accept | Configured child completes; decision targets judged work, producer is exact child session; all original gates/verification/findings pass. |
| Child-only success | Missing judged gates/acceptance or failed verification still prevents accept; blocking findings also prevent accept. |
| Human/version/linkage | Human-required accept, stale expected version, newer work, unrelated intervening attempt, missing/foreign linkage or wrong child session rejects without overwriting newer state. |
| Invalid child | Failed child, forbidden kind, malformed/extra fields persist escalation; no director recursion. |
| Budget boundary | Denied child admission creates no child/charge and requires human; successful last-admitted work can finish; rerun/recover cannot exceed remaining budget. |
| Durable lifecycle | Fresh/reopened store has exact task/work/child/session relation; rollback leaves no partial state; repeated dispatch/terminal reconciliation/decision replay charges attempts and cost once. |
| Evidence isolation | Compare judged outcome and evidence identities/payloads before child, after completion and after replay; child evidence stays scoped to child. |
| Judged TaskView delivery | Actual child node receives task and judged-attempt identity/outcome, durable completion, guard violations, open findings, evidence identities/payloads and post-admission remaining budget matching reconciled work/store records; hostCapabilityContext remains present. |
| Planner and placement | Observe hostCapabilityContext in actual workflow input; selected backend and host execute the child and report into its reserved session. |
| Compatibility | Dry-run leaves store/files invariant; P1-6a selected root/callee delivery and P1-6c cancellation/fencing continue passing. |

Validator-only tests and recommendation JSON alone cannot satisfy the matrix.
Use existing deterministic fixtures and injected failure points; no sleeps as
proof of lifecycle ordering. Each fixture owns and stops workers before exit.

### Edit safety, checkpoint and progress

Reuse accepted checkpoint `79eea8114b7d407e3fb7ed18faf5de5d86bce1ab` for
this serial continuation; do not restart implementation from a clean tree.
Step 4 does not stage, commit or self-approve its plan revision. After Step 5
acceptance, any required refreshed planning checkpoint belongs to the runtime's
serial checkpoint stage before native fanout, with only exact accepted design/
plan paths. Never include retained implementation/progress changes merely to
clean the worktree. Preserve all predecessor commits and WIP. Final implementation
commit and non-force push require downstream review and documentation gates.

Before every edit, freshly read each target and save immutable preimage, SHA-256,
intended hunks and task ID under `tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-N/`.
Check the pre-hash immediately before writing; stop and reconcile unexpected drift
without overwriting it. Save post-hash and actual diff. New files record absence
as preimage. After joining read-only work, the serial owner compares intents to
the actual combined tree and repairs missing/overwritten hunks before final-source
checks. Keep touched non-generated Swift files at most 1000 lines by cohesive
responsibility extraction, with exact new paths recorded in ownership evidence.

Only the owner updates `impl-plans/progress/p1-dispatch.md`; append D0–D5 status,
paths, command/log/hash/count/exit receipts, review decisions and open risks.
No completion box advances on stale receipts or incomplete logs. All throwaway
files stay under repository `tmp/`. Retain verification evidence for review.

### Exact verification commands and evidence

Run from repository root, foreground only. Use immutable attempt directories under
`tmp/work-runtime-p1/p1-dispatch/p1-6d/` for complete stdout/stderr logs and a JSON
manifest containing exact command, toolchain, start/end, exit status, per-suite
test counts, log SHA-256 and before/after source manifest hashes/membership.
Record every failed/retried command separately. Zero tests, missing named suites,
timeouts and incomplete terminal summaries are not passing. Poll every yielded
handle to exit. No overlapping SwiftPM processes or source changes during checks.

Before deciding to rerun, verify retained evidence with:

```bash
git status --short
git rev-parse HEAD
shasum -a 256 -c tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/source-final9.sha256
shasum -a 256 tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/broad-final4.log
cat tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/broad-final4.exit
cat tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/final7-focused-exits.txt
cat tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/broad4-classification.json
```

The 964-file Swift manifest must match hashes AND current Swift file membership;
check Package.swift/Package.resolved and other relevant fixture/toolchain changes
against retained command evidence separately. The manifest alone does not prove
all dependencies unchanged. Expected broad log SHA-256 is
`b5f07276c78ac3481e29bf353074e6f12fde0cb29c068011a775660bcfa5baa6`, exit 1,
2,666 tests, 19 assertions. Verify all 19 identities against historical evidence;
classification is input to independent review, never a passing broad result.
Retain build-final9.log, swiftlint-final9.log, changed-swift-files-final2.nul,
final7-focused-{1..7}.log and their exact command/exit receipts.

Map suite coverage explicitly: retained focused selection 4 names
WorkStoreCancellationTests and BudgetAdmissionStoreTests, which are filenames,
not standalone suite names. Do not claim that filter ran the budget suite.
The complete broad-final4.log separately reports
BudgetAdmissionDecisionApplierStoreTests 5/5, TaskDryRunReadOnlyTests 6/6 and
TaskCancellationIntegrationTests 17/17 passing. Record these as individual suite
evidence inside a FAILED aggregate, subject to independent integrity acceptance.
If a required focused receipt is still missing, run only the corresponding
explicit filter below. Reuse valid build/lint/test receipts; do not rerun the
broad gate merely for documentation edits or refreshed workflow execution.

Execute invalidated or missing checks below with Xcode's explicit toolchain.
Each numbered test filter
must execute all its named suites with positive counts. Additional test suites
introduced by a justified extraction must be added to the matching gate.

```bash
# V0: compile/typecheck; build.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
# Director/store matrix; director-store.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'AgentDirectorTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|WorkStoreReservationTests|WorkStoreTests'
# V1: ordinary runner and dry-run; focused.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskDryRunReadOnlyTests'
# V2: admission, budgets and cancellation; reservation.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'
# V3: guard/shared decision regression; lifecycle.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
# V4: planner/capability compatibility; capability.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
# V11 plus accepted cancellation regression; selected-host.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests'
# V5: serial broad regression, after focused gates; broad.log
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
# V6: exact surviving changed/new Swift paths from intent evidence; lint-changed.log
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
# V7: run before Swift edits and after; lint-baseline.log / lint-repository.log
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
# Diff checks; diff-check.log / cached-diff-check.log
git diff --check
git diff --cached --check
```

Capture baseline first despite its listing below test commands. If
checking cancellation coverage, `WorkStoreCancellationTests.swift` extends
`WorkStoreReservationTests`; its filename is not a separate XCTest suite.
`BudgetAdmissionStoreTests.swift` declares `BudgetAdmissionDecisionApplierStoreTests`.
AgentDirectorStoreTests already exists. Its retained positive-count result in
focused selection 2 may be reused; otherwise run the exact command
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AgentDirectorStoreTests`
and require positive counts in `director-store-extra.log`. Repeat affected checks
after any repair; avoid redundant broad runs on unchanged source. Environment
failures retain failed/blocked status; documented writable module-cache/scratch
fallbacks may be used under repository tmp with their exact command recorded.
Listener denial requires source-matched listener-capable-host evidence, not a
product failure diagnosis or a waived test. No web changes: browser E2E is not
required. Historical V8–V10 replacement/removal/package checks are not scheduled.

### Completion and review gates

**Step 6 implementation completion:** D0–D4 matrix is satisfied on the retained
or repaired source; build, required behavioral suites, strict touched-file lint
and diff checks have complete valid receipts. A completed failed broad run may
be submitted with exact historical non-slice classification for independent
slice-only disposition. New/unclassified failures or material implementation/
verification gaps keep Step 6 incomplete. Pending formal review, D5, commit or
push alone must not set implementationIncomplete. Emit the precise pending gates
and evidence references rather than claiming final slice acceptance.

**Final workflow completion:** formal test-integrity, single adversarial and
Astra combined-tree reviewers explicitly accept the slice with no material
high/mid finding, D5 documents the accepted result and remaining failures, and
exact accepted files are committed and non-force pushed. D5 reviews README.md,
this design/plan, progress and shared indexes; update only changed behavior/status.
Review `.codex/skills/riela-impl-workflow/SKILL.md` for consistency; the unchanged
workflow contract needs no edit. Shared documentation remains serial. Record
commit hash, exact file allowlist and push result; no parent-plan archival.


All matrix cases, build and strict touched-file lint must pass on the reviewed
source; classify repository lint baseline without unrelated cleanup. Broad tests
must run serially with complete evidence. The historical P1-6c 2,059-test/19-assertion
failure remains FAILED, and its focused receipts cannot certify P1-6d. Classify
every current broad failure against exact test identities and source evidence;
do not waive the broad gate or call it green. Preserve the earlier intermittent
live-progress timing failure, even if its current case passes. If only historical
non-slice failures remain, report them for explicit independent slice acceptance
while leaving the broad gate and parent P1 open; new/unclassified failures block
acceptance. Formal test-integrity, single adversarial and Astra combined-tree
reviews must find no material P1-6d defect. Documentation and exact-file commit/
non-force push follow acceptance only; no whole-plan archiving or parent closure.

Author check: tasks map to accepted §17.8; one-plan DAG and exact path ownership
avoid concurrent coupled writes; tests distinguish child evidence from judged
work and cover rollback/replay. Step 5 `comm-000006` identified missing explicit
judged TaskView delivery and runner assertions (mid); D3, D4 and the matrix now
specify all fields and actual child input observation, preserving planner inputs.
No unresolved user decision remains. Implementation tests are downstream, not
claimed by this plan; renewed Step 5 acceptance is pending.

**P1-6d Step 6 continuation 2 status (2026-09-24):** D1/D2 linkage and shared
acceptance are implemented with real-store tests. D3 ordinary child execution,
judged TaskView and `hostCapabilityContext` delivery, and fail-closed escalation
are partially implemented and tested. D4 remains open: an interrupted child
between reservation and terminal snapshot cannot safely reclaim its original
launch token or resume the same attempt/session; read-only adversarial review
classified this as material. Exact child cost replay and the full runner matrix
also need proof. Current final-source focused V1/V2/V3/V4/V11 selections pass,
but the serial broad run on earlier continuation source was interrupted during
an unrelated parity test and cannot certify the slice. D5, formal independent
reviews, documentation acceptance, exact-file commit and non-force push remain
pending. Keep P1-7b, P1-7a, parent P1 and broad follow-ups open.
Read-only test-integrity review also leaves selected-host execution, exact
child cost/reopened dispatch replay, full nonempty judged TaskView assertions,
isolated wrong-session rejection, and persisted escalation/repeat dispatch open.

**P1-6d Step 6 continuation 3 status (2026-09-24):** D1–D4 source and
behavioral tests now cover a bounded ordinary director child, durable judged
linkage, exact prelaunch recovery, uncertain-launch human fencing, judged-work
acceptance and refusal, nonrecursive escalation, selected remote worker input,
and non-loop child token/wall-clock accounting through reopen and replay.
Transactional shared-store admission now rejects an agent rerun/recover after
the child exhausts durable wall-clock time. Seven final focused selections pass
55/55, 81/81, 43/43, 30/30, 80/80, 55/55 and 55/55; final build and exact
18-file strict SwiftLint pass. The complete source-matched serial broad gate
ran 2,666 tests, exited 1 with 19 failures matching the exact historical
non-slice identities; the broad gate remains **FAILED**. Read-only Codex
test-integrity (`final_integrity3`), adversarial (`final_adversarial3`) and Astra
combined-tree (`astra_combined3`) reviews accept the repaired tree with no
remaining material high/mid P1-6d finding. Evidence, exact logs/hashes and
per-edit intentions are under `tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/`.
Formal workflow acceptance, D5 documentation/publication and the separate
P1-7b, P1-7a, parent P1 and broad follow-ups remain open; no staging, commit
or push occurred in Step 6.

## Historical P1-6c contract

# Work Runtime P1-6c: selected-host late-cancellation regression repair

**Mode / issue:** `issue-resolution`; Work Runtime P1-6c, no GitHub issue supplied.
**Status:** Step 3 accepted for implementation planning with no findings via
`comm-000004`, `step3-design-review-attempt-1-exec-4`, execution
`codex-design-and-implement-review-loop-session-1`. Step 5 accepted; Step 6
repair and source-matched verification complete for independent review.
**Accepted design:** `design-docs/specs/design-work-runtime-consolidation.md`,
“Selected-host regression repair amendment”, “Ordering diagnosis and bounded
repair decision”, and preserved P1-6c arbitration contract. SHA-256:
`6eee525c2ae72de3b896cdbce0c9b5b137df270b4cb984517ff60bf2ca8f5ca6`.
**Roles:** Single Step 2 design author; Step 3 independent design reviewer;
single Step 4 plan author; serial implementation owner; independent test-integrity
reviewer; single adversarial reviewer; Astra exact combined-tree reviewer.
These codex-agent references are workflow roles, not reference behavior. Cursor
CLI mapping and intentional divergences are not applicable.

## Current executable contract

Only this contract and its first JSON block schedule current work. All content
below “Historical preserved contracts” is retained verbatim as history, including
its obsolete scheduling metadata and evidence-readiness statements.

### Intent, context, scope and invariants

Repair the actual terminal/cancellation contract or its faulty deterministic
injection, without weakening assertions. Preserve checkpoint `ce70301`, helper
merge `b06295d`, accepted design/plan history and all pre-existing tracked and
untracked WIP on `feat/remaining-impl-plans`. No resets, force pushes, broad
staging, private branches, worktrees, concurrent Git writes or unrelated repairs.
Runner-resolved provenance and effective workflowInput are authoritative; registry
rediscovery is not work. No new schema, transport, scheduler, framework or adapter.
P1-6d, P1-7a/b, parent P1, non-slice failures, main integration and release are out
of scope. Do not reopen the merged subprocess helper fix.

Intake source manifest:
`tmp/work-runtime-p1-6c-after-helper-review-20260924-9fbcc7126181/final-source-after-retry.sha256`
(SHA-256 `dc6cec7251a8607b20b65ccaddb775606352b7556556209e6985bf1328409cd6`).
Host failure log: `tmp/work-runtime-p1-6c-final-host/selected-host.log`
(SHA-256 `4dc832737ba4ace589f4bcf26ea0aa76d141a7cdb92a4673b3f28d6343a857b2`),
1 test, 3 assertions, operator-reported exit 1. The before-terminal check saw a
terminal session, `adapterFailure` replaced expected `cancelled`, and cancellation
record unwrap failed. Historical 136/136 and 2057/19 logs cannot accept this source.

Keep shared SQLite transaction arbitration: request-first blocks ordinary terminal
commit; terminal-first rejects late cancellation without mutating the winner.
Do not convert `adapterFailure` to cancellation or overwrite an already terminal
snapshot. Request commits before interruption. Exact task/attempt/session identity,
selected placement without fallback, owned worker stop proof, atomic acknowledgment
and fence release, stable replay and once-only accounting remain mandatory. Transport
acceptance, lost heartbeat and lease expiry are not stop proof. Uncertain stop or
failed persistence remains fenced. Preserve real EntryPoint SIGINT coverage and
both trigger/race-order cases. Test hooks unset must preserve production behavior.

### Scheduling and path ownership

One plan covers the entire requested batch. All coupled source edits have one
serial owner. The candidate paths below are conditional repair scope, not a demand
to edit each file. Other preserved WIP remains unchanged and enters combined review;
its presence does not authorize unrelated changes.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "taskIds": [
    "P1-6c-baseline",
    "P1-6c-store",
    "P1-6c-runner",
    "P1-6c-tests",
    "P1-6c-verify",
    "P1-6c-integrity",
    "P1-6c-adversarial",
    "P1-6c-reconcile",
    "P1-6c-astra",
    "P1-6c-finalize"
  ],
  "taskDependencies": {
    "P1-6c-baseline": [],
    "P1-6c-store": [
      "P1-6c-baseline"
    ],
    "P1-6c-runner": [
      "P1-6c-store"
    ],
    "P1-6c-tests": [
      "P1-6c-runner"
    ],
    "P1-6c-verify": [
      "P1-6c-tests"
    ],
    "P1-6c-integrity": [
      "P1-6c-verify"
    ],
    "P1-6c-adversarial": [
      "P1-6c-verify"
    ],
    "P1-6c-reconcile": [
      "P1-6c-integrity",
      "P1-6c-adversarial"
    ],
    "P1-6c-astra": [
      "P1-6c-reconcile"
    ],
    "P1-6c-finalize": [
      "P1-6c-astra"
    ]
  },
  "acceptedPrerequisites": {
    "P1-6a": "2f10916a14501af68fd7e7f63cb91f244a343f8c",
    "P1-6b": "7d8fc121a4f4469de7a40495282b53c9d813b8d4"
  },
  "progressLogPath": "impl-plans/progress/p1-dispatch.md",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6c/selected-host-repair/",
  "dependencyMode": "single-plan-serial-repair-with-independent-read-only-review"
}
```

### Tasks, dependencies and exact deliverables

1. **P1-6c-baseline**: Before source edits, read the complete failed log and check
   the intake manifest/digests. Record HEAD/status, staged paths (initially empty),
   every preserved WIP path and preimage hash. Preserve source drift for diagnosis;
   never reset. Deliver `baseline.json` and requirement-to-test matrix. Identify
   the exact writer of `adapterFailure` by tracing the reserved session through
   initial terminal candidate, injected error, subsequent live/final saves,
   execution/observer join, initial cancellation observation, request insertion
   and joined persistence. Record canonical status, request presence and selected
   job status at each boundary. Use existing seams or minimal scoped test-only
   instrumentation, not sleeps or synthetic terminal rows. Deliver
   `ordering-diagnosis.json` naming writer/call path and evidence, and distinguish
   fixture timing from any demonstrated request-first arbitration defect.
2. **P1-6c-store**, after baseline: Inspect
   `Sources/RielaWork/WorkStore+Decisions.swift`, `WorkStore+Reservation.swift` and
   `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`. Repair only a
   demonstrated bypass of transaction-scoped exact-session arbitration; otherwise
   record no change. Keep decision replay before current-state validation,
   terminal-first rollback and proof-required joined-persistence behavior.
   Add a targeted regression in `Tests/RielaWorkTests/WorkStoreCancellationTests.swift`
   or `DecisionApplierStoreTests.swift` only if this seam changes. Deliver exact
   finding-to-change mapping and evidence for unchanged/changed paths.
3. **P1-6c-runner**, after store: Serially repair the diagnosed seam in
   `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`,
   `WorkflowRunCommand.swift`, `TaskRunCancellation.swift` or `TaskDispatch.swift`.
   Audit alternate canonical writers in `CLIWorkflowSessionStore.swift`,
   `WorkflowRunLivePersistence.swift` and
   `WorkflowRunCommand+SupervisionPersistence.swift`; edit only if demonstrated
   bypass requires it. The current one-shot throwing hook prevents one write,
   not later error/final writes. Provide minimal deterministic fixture control of
   those writes without bypassing the production transaction guard; retain
   persistence-failure regression coverage. Preserve owned/joined execution and
   proof retry. Deliver a boundary trace demonstrating the intended sequence,
   with unchanged unset-hook behavior. No general hook framework or new public CLI.
4. **P1-6c-tests**, after runner: Update
   `Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift` and
   `TaskCancellationIntegrationTests.swift`. Keep the named test
   `testLateSelectedHostCancellationAfterObservationRetriesWithStopProof` and all
   existing assertions. Establish these events explicitly in order: selected
   shell builtin `true` job finishes and execution joins; canonical session is nonterminal
   and request absent; initial cancellation observation sees no request; separate
   store connection commits exact cancellation; joined persistence rejects lack
   of selected-host proof; owner obtains matching completed-job proof and retries;
   dispatch acknowledges canonical cancelled result. Assert entry into the proof
   retry, not only final state. Keep succeeded remote-job assertion, exact cancelled
   failure kind, cancellation record, reconciled attempt and cancelled task.
   Preserve separate running-worker leader/child stop checks and uncertain-proof
   fencing. Retain terminal-first success and ordinary-failure preservation,
   request-first local/remote behavior, both SIGINT/external triggers, replay and
   once-only accounting. Deliver updated requirement-to-test matrix and exact
   assertion/event evidence. If production persistence changed, run existing
   live-persistence regressions and add only a missing material regression there.
5. **P1-6c-verify**, after tests: One build/test owner freezes repaired source and
   runs the commands below in foreground, selected host test first after build,
   then store/focused/compatibility and serial aggregate on the same source.
   Preserve full logs, counts, exits, toolchain/env and before/after manifests.
   Independently classify all aggregate failures against the historical inventory;
   no P1-6c or unclassified material failure may advance. Missing capable-host
   execution produces a precise blocked handoff; sandbox listener denial never
   substitutes. Historical green counts do not waive any fresh test gate.
6. **P1-6c-integrity** and **P1-6c-adversarial**, after verify: Independent read-only
   reviewers may run in parallel. Integrity verifies actual ordering, test selection,
   assertions, proof retry, process stop and exact-source evidence. The single
   adversarial reviewer assesses only material correctness/spec/regression risks
   and coverage, including all preserved WIP. Each writes separate
   `reviews/<role>/` artifacts with exact tree hashes, commands, evidence, findings
   and accept/reject decision. No implementation edits or concurrent SwiftPM runs.
7. **P1-6c-reconcile**, after both reviews: Serial owner joins hashes and intent
   snapshots, checks overwritten/drifted bytes and repairs every high/mid finding.
   Any source/test repair renews manifests, selected/focused/aggregate verification
   and affected independent reviews before proceeding. Deliver reconciled exact
   combined-tree manifest and closed finding ledger; do not hide non-slice failures.
8. **P1-6c-astra**, after reconciliation: Astra independently reviews exact combined
   source/tests/docs and evidence, including preserved WIP. Accept only with no
   material P1-6c defect or verification gap. Deliver explicit decision and hashes.
9. **P1-6c-finalize**, after Astra acceptance: Serial owner updates the P1-6c section
   of `design-docs/specs/design-work-runtime-consolidation.md`, this active plan,
   `impl-plans/progress/p1-dispatch.md` and affected `README.md` wording only if
   needed. Distinguish slice completion from open P1-6d, P1-7a/b, parent P1 and the
   failed broad gate. Obtain Astra reaffirmation on final documentation/tree.
   Workflow finalization exact-file commits then non-force pushes; retain matching
   commit/push hashes and actual file allowlist. No source changes after acceptance
   without renewed gates. Do not archive the active parent plan.

### Checkpoint, drift and progress contract

Step 4 writes only this plan. After Step 5 accepts, runtime serial checkpointing
commits exactly the accepted design and plan before native implementation/review
fanout; it preserves source/progress WIP. This planning checkpoint is distinct
from the acceptance-gated implementation commit/push. Do not checkpoint in Step 4.

Before each edit fresh-read the exact path, save preimage bytes/SHA-256, requirement
and owner under an immutable `intents/<unique-id>/` directory in the evidence root.
Compare current bytes to preimage immediately before writing; drift stops edits
for serial reconciliation. Save postimage/hash (or original absence for a new
file). At joins compare actual bytes to all intent snapshots and review manifests.
Shared indexes, lockfile generation, broad formatting and global archiving belong
to serial reconciliation/finalization and are not requested by this slice.
Only the serial owner updates `impl-plans/progress/p1-dispatch.md`; reviewers write
their own evidence/progress artifacts. Record task/communication IDs, completion
state, paths/hashes, commands, positive counts, exits, findings and next action.
No review or completion checkbox advances on missing or unfinished evidence.

### Evidence-producing verification commands

Use fresh `tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001/` (increment
attempt number if it exists). Never overwrite prior evidence. Capture each command's
entire stdout/stderr to a named log and record actual terminal exit, exact argv,
start/end source hashes, toolchain/environment and XCTest counts in
`verification.json`. Do not pipe commands in a way that loses their exit status.
Poll yielded handles until terminal exit. No detached/background shell jobs.

Baseline commands (logs: `head.log`, `status.log`, `intake-digests.log`,
`intake-source-check.log`, `intake-host-log.txt`):

```bash
git rev-parse HEAD
git status --short
shasum -a 256 tmp/work-runtime-p1-6c-after-helper-review-20260924-9fbcc7126181/final-source-after-retry.sha256 tmp/work-runtime-p1-6c-final-host/selected-host.log
shasum -a 256 -c tmp/work-runtime-p1-6c-after-helper-review-20260924-9fbcc7126181/final-source-after-retry.sha256
cat tmp/work-runtime-p1-6c-final-host/selected-host.log
```

Expect 973 matched intake entries and the digests above, or diagnose drift before
editing. Intake test exit 1 comes from the authoritative operator receipt; `cat`
exit 0 is not a test pass. For repaired source, generate a new manifest once:

```bash
python3 -c 'import hashlib,pathlib,subprocess; paths=sorted(set(filter(None,subprocess.check_output(["git","ls-files","--cached","--others","--exclude-standard","-z","Sources","Tests","Package.swift","Package.resolved"]).decode().split("\0")))); assert paths; out=pathlib.Path("tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001"); out.mkdir(parents=True,exist_ok=True); (out/"membership.nul").write_bytes("\0".join(paths).encode()+b"\0"); (out/"final-source.sha256").write_text("".join(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()+"  "+p+"\n" for p in paths))'
```

Before and after tests run both membership and hash checks; do not regenerate the
baseline to conceal drift. Log these as `membership-before/after.log` and
`source-before/after.log`; record manifest SHA-256 in the receipt:

```bash
python3 -c 'import pathlib,subprocess; saved=pathlib.Path("tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001/membership.nul").read_bytes().split(b"\0")[:-1]; current=sorted(set(filter(None,subprocess.check_output(["git","ls-files","--cached","--others","--exclude-standard","-z","Sources","Tests","Package.swift","Package.resolved"]).split(b"\0")))); assert saved==current and len(saved)==len(set(saved)); print("membership matched",len(saved))'
shasum -a 256 -c tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001/final-source.sha256
shasum -a 256 tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001/final-source.sha256
```

Include every changed Swift file (preserved WIP and untracked files included) in
an explicit reviewed NUL-separated `changed-swift-files.nul`; reject missing or
empty entries. Hash the combined review tree separately, including exact candidate
commit allowlist and docs/progress, since the source manifest excludes docs.

Commands below produce `build.log`, `selected-host.log`, `store-decisions.log`,
`focused.log`, `compatibility.log`, `aggregate.log`, `swiftlint.log`, `diff-check.log`
and `cached-diff-check.log`, respectively. Build is compile/typecheck verification.
Swift edits follow the repository Swift skill, including strict lint and meaningful
responsibility-based splitting for edited Swift files over 1,000 lines; no unrelated
cleanup. No web/UI changes are planned, so browser/UI verification is inapplicable.

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests/testLateSelectedHostCancellationAfterObservationRetriesWithStopProof'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionDecisionApplierStoreTests|DecisionApplierStoreTests|TaskCommandParsingTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests|DistributedProcessCancellationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|WorkflowCommandLivePersistenceTests|WorkflowCommandLivePersistenceEventTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests|SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'
xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/selected-host-repair/attempt-001/changed-swift-files.nul
git diff --check
git diff --cached --check
```

Selected regression, store, focused and compatibility gates require positive
per-requested-suite counts and exit 0, with exact new regression names in logs.
Build/lint/diff/hash checks require exit 0 but have no test count. Aggregate must
finish with complete counts and exit; compare every failure to inventory
`tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json`.
Do not demand historical counts after adding tests. Historical non-slice owners:
IDs 1–7 doctor/backend-capability, 8 P1-7b examples, 14–21 workflow-command/host
readiness, 22 runner admission, 23–24 temporary workflow/host requirements. Keep
IDs 9–13 repaired catalog/projection coverage. Independently justify classification
using assertion identity, source history and changed dependencies; unknown/material
P1-6c failures block acceptance. Broad gate remains FAILED until an actual passing
aggregate; classification alone is not a green gate. Do not repair unrelated failures.

### Completion and self-check expectations

Plan readiness requires valid metadata/DAG, accepted-design mapping, concrete
file/task ownership and evidence commands. Implementation completion additionally
requires diagnosed writer, repaired deterministic ordering and any proven product
fault, unchanged assertions, source-matched capable-host gates, explicit acceptance
from integrity/adversarial/Astra reviewers, final docs/tree reaffirmation and matching
exact-file commit/non-force push receipts. Missing host evidence means incomplete
implementation, not missing plan work. No open user decision; diagnosis determines
fixture versus product repair. No Step 5 feedback supplied; Step 3 has no findings.

Step 4 self-check evidence is under `tmp/p1-6c-plan-repair/`: metadata/path/DAG and
accepted-design hash checks, verbatim historical preservation, pre/post hashes,
source manifest check and whitespace check. These are planning checks, not new
Swift test execution or implementation acceptance.

### Step 6 implementation checkpoint — 2026-09-24

The diagnostic trace in `tmp/work-runtime-p1-6c-repair-0a3605e9eafe/p1-dispatch/attempt-001/`
identified `FailClosedSQLiteWorkflowRuntimeStore.markSessionFailed` as the first
`adapterFailure` canonical writer after the throwing hook was consumed. Live CLI
persistence also attempted that terminal candidate. The selected worker's `/bin/true`
failed with exit 127 because the capable macOS host has no such path. The fixture
now uses the POSIX shell builtin `true`, defers its canonical terminal writes
without failing the worker, fences live/final CLI projection for that test seam,
and asserts one proof-required retry. Production behavior with the hook unset and
shared SQLite arbitration remain unchanged. No store transaction repair was needed.

Final source manifest `tmp/work-runtime-p1-6c-repair-0a3605e9eafe/p1-dispatch/attempt-003/final-source.sha256`
has 973 entries and SHA-256
`7883cb40b4c4678588a79071dada6044bec3c38ad2c7cd099183a630eb955ddb`.
The source-matched build exited 0; selected-host 1/1, store 56/56, affected focused
104/104 and compatibility 28/28 exited 0. Strict selected-file SwiftLint and
diff checks exited 0. Complete logs and terminal exits are recorded in
`attempt-003/verification.json`. The serial aggregate exited 1 after 2,059 tests
and 19 assertion failures; all 19 test identities exactly match historical
non-slice inventory IDs 1–8 and 14–24. The broad gate remains **FAILED**.

Step 6 read-only test-integrity and adversarial Codex agents recommended acceptance
with no material P1-6c finding on the repaired source. Formal workflow test-integrity,
single adversarial and Astra exact combined-tree decisions remain pending, followed
by completion documentation, exact-file commit and non-force push. P1-6d, P1-7a/b
and parent P1 remain open. This checkpoint does not mark those downstream gates
or the broad aggregate complete.

## Historical preserved contracts

# Work Runtime P1: P1-6c post-helper final review

**Status:** Step 3 accepted the revised design for planning, without findings,
`comm-000004`, `step3-design-review-attempt-1-exec-4`. Repaired implementation WIP is preserved. A bounded Step 6 selected-host stop-proof timing repair has local build, test and lint evidence; source-matched capable-host focused and aggregate verification, formal test-integrity/adversarial and Astra exact combined-tree acceptance remain pending. Broad aggregate remains FAILED.
**Workflow mode:** `issue-resolution`.
**Issue:** Work Runtime P1-6c — Review and finalize late-cancellation repair
on final capable-host source; no GitHub issue URL or number supplied.
**Design:** `design-docs/specs/design-work-runtime-consolidation.md`, P1-6c
bounded amendment: preserved arbitration contract, deterministic regression
matrix, current post-helper capable-host evidence, failure disposition, and
acceptance/rollout boundary.
**Design SHA-256:** `ada1f845a100bb7cfad5b3468c601add5ee0889478fa3f64849aef2b279a063f`.
**Codex-agent references:** Step 2 author continuing prior `/root/design_author`;
this Step 4 author owns the whole plan. One serial implementation owner;
independent test-integrity and adversarial reviewers; Astra exact combined-tree
reviewer. Implementation review decisions are pending. References denote roles,
not Cursor behavior; no adapter or reference-repository divergence applies.

## Current executable contract — evidence review and bounded material repair

Only this section and its first JSON block schedule current work. Everything
under “Historical preserved plan” is preserved context, not executable scope.

### Intent, context and non-goals

Preserve every checkpoint, helper merge
`b06295d5c3fbc42528d0382014ded0e9118dfa88`, all tracked/untracked WIP and branch
`feat/remaining-impl-plans`. The shared-SQLite request-first/terminal-first
repair and deterministic regressions are already implemented as WIP. The helper
wait deadlock was separately fixed and merged; do not reimplement either change
without a material finding. Review the exact post-helper source against
`tmp/work-runtime-p1-6c-after-helper-acceptance/host-evidence.json`: 973-entry
manifest, focused 136/136 exit 0, aggregate 2057 tests / 19 assertions / 7 unexpected
exit 1. Step 2 verified hashes, membership and assertion identities; Step 3
accepted the design only. Formal independent acceptance is still required.
The prior high race finding and mid real-SIGINT coverage finding require explicit
closure against current code/tests, not automatic carry-forward acceptance.

Non-goals: P1-6d, P1-7a/b, parent P1 completion; unrelated baseline repairs;
new stores, schemas, schedulers, generalized frameworks; direct decision-row
mutation or hidden cleanup after success; broad formatting, package edits,
main merge or release. Protect Monja and other worktrees. No reset, force push,
broad staging, private branches, worktrees or concurrent Git operations.
Runner-resolved provenance and effective workflowInput are authoritative;
registry rediscovery/repair is not a task.

### Scheduler metadata and ownership

One coupled contract uses stable planId `p1-dispatch`, with no plan dependencies.
All candidate writes are serial-owned; preserving a WIP path does not authorize
unrelated edits. Core/Server transport and catalog paths are preservation-only
unless a material P1-6c review finding requires a bounded repair. Shared indexes,
lockfiles, formatting and archiving are reserved for serial finalization and
are not requested. No new independent implementation plan is warranted.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift"
  ],
  "taskIds": [
    "P1-6c-baseline",
    "P1-6c-store",
    "P1-6c-runner",
    "P1-6c-tests",
    "P1-6c-verify",
    "P1-6c-integrity",
    "P1-6c-adversarial",
    "P1-6c-reconcile",
    "P1-6c-astra",
    "P1-6c-finalize"
  ],
  "taskDependencies": {
    "P1-6c-baseline": [],
    "P1-6c-store": [
      "P1-6c-baseline"
    ],
    "P1-6c-runner": [
      "P1-6c-store"
    ],
    "P1-6c-tests": [
      "P1-6c-runner"
    ],
    "P1-6c-verify": [
      "P1-6c-tests"
    ],
    "P1-6c-integrity": [
      "P1-6c-verify"
    ],
    "P1-6c-adversarial": [
      "P1-6c-verify"
    ],
    "P1-6c-reconcile": [
      "P1-6c-integrity",
      "P1-6c-adversarial"
    ],
    "P1-6c-astra": [
      "P1-6c-reconcile"
    ],
    "P1-6c-finalize": [
      "P1-6c-astra"
    ]
  },
  "acceptedPrerequisites": {
    "P1-6a": "2f10916a14501af68fd7e7f63cb91f244a343f8c",
    "P1-6b": "7d8fc121a4f4469de7a40495282b53c9d813b8d4"
  },
  "progressLogPath": "impl-plans/progress/p1-dispatch.md",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6c/after-helper-review/",
  "dependencyMode": "single-plan-serial-repair-with-independent-read-only-review"
}
```

### Ordered tasks, exact deliverables and acceptance

1. **P1-6c-baseline:** Fresh-read accepted design, this contract, current host receipt and
   both complete logs. Record HEAD, status, all WIP paths and hashes; retain immutable inputs
   under the evidence directory. Map current insertion and canonical writer call
   paths, including both snapshot save overloads and live/final/supervision
   persistence. Deliver a requirement-to-boundary/test matrix, frozen combined-tree
   manifest and baseline state receipt. Check current source against the supplied
   manifest before further work; any drift requires diagnosis, not a reset.
   Do not rerun or relabel excluded logs as current-source evidence.
2. **P1-6c-store**, after baseline: Audit existing WIP first; edit only for a
   documented material violation of the following contract. In
   `Sources/RielaWork/WorkStore+Decisions.swift` and
   `Sources/RielaWork/WorkStore+Reservation.swift`, read the exact reserved
   canonical session in the write transaction deciding cancellation insertion.
   Preserve accepted decision replay before new-request validation, identity,
   version and causal checks. Ordinary terminal-first returns a distinguishable
   already-terminal rejection with no decision/application/request/version
   mutation. Cover the lower-level cancellation primitive as well as applier.
   In `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` and
   `Sources/RielaCLI/CLIWorkflowSessionStore.swift`, guard every task-backed
   canonical terminal write in the same transaction as snapshot persistence;
   roll back CLI record/message writes with the rejected snapshot. Request-first
   prevents ordinary terminal commit; stale live saves cannot overwrite a
   terminal winner. Reuse transaction-scoped APIs and existing tables, respect
   module dependency direction, and leave plain workflows unchanged. Add only
   the minimal shared error outcome in `Sources/RielaWork/WorkStore.swift` if
   needed to distinguish terminal-first from version conflict. Audit the existing
   arbitration errors in `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift`
   and the forwarding/terminal barrier in
   `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`; preserve their
   current API and behavior unless a concrete defect requires repair. Deliver atomic
   store/persistence behavior, not a read-then-write check across transactions.
3. **P1-6c-runner**, after store: Audit the existing winner handling and
   owned shutdown; record evidence without edits if correct. In
   `Sources/RielaCLI/TaskRunCancellation.swift`, `TaskDispatch.swift` and
   `TaskCommands.swift`, consume the winner. External `task decide --cancel`
   reports explicit rejection after terminal-first. Late SIGINT joins observation
   and proceeds with canonical ordinary reconciliation, preserving run success
   or failure and exit result; do not retry as a version conflict or retarget a
   newer attempt. In `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift`,
   `WorkflowRunCommand+SupervisionPersistence.swift` and the task-reservation seam,
   handle request-first ordinary-save rejection by returning to owned shutdown:
   interrupt/join local or selected-host work, then persist exact cancelled
   snapshot/outcome and acknowledge. A rejected save is not stop proof. Keep
   persistence awaited; a live-save diagnostic must not swallow arbitration and
   allow a success result to escape. Preserve EntryPoint's real signal route.
   Deliver no pending cancellation against ordinary success, no fabricated
   acknowledgment, and no hidden terminal-success cleanup.
4. **P1-6c-tests**, after runner: Map existing tests to every required assertion
   and identify material gaps before adding tests. Only for such a gap, extend
   `Tests/RielaWorkTests/WorkStoreCancellationTests.swift` and
   `DecisionApplierStoreTests.swift` for both commit orderings across independent
   SQLite connections, both insertion APIs, rollback and accepted replay.
   Extend `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` and its
   `+Fixtures.swift` for the four cases below at production boundaries. Retain
   `testTaskRunSubprocessSIGINTCommitsAndAcknowledgesCancellation`. Use existing
   fixture seams or minimal internal test barriers; no public CLI test switches.
   Add persistence-overload/stale-save regression in the listed live persistence
   tests if not covered by the integration cases. Deliver exact test-name mapping,
   deterministic barrier events and assertions; no sleep-based ordering proof.
5. **P1-6c-verify**, after tests: Inspect the supplied complete post-helper
   logs, SHA-256 digests, manifest membership and all 19 assertion identities
   using the evidence commands below. Record reported host exits separately
   from this node's inspection exits. Assess source-matched earlier build, lint,
   V0/V1/V2/V11, decisions, live and compatibility receipts against changed
   dependencies, including helper merge b06295d; do not assume the 136-test filter
   covers every obligation. Record exact original commands from retained run
   receipts, logs and source relevance. If a command cannot be recovered, record
   that gap explicitly and have the independent reviewers decide its materiality.
   Current complete host evidence is available: do not demand a fresh host run
   merely because this sandbox cannot run listeners. If source/tests change or
   a material verification gap is found, generate a fresh manifest and rerun
   affected checks on a capable host where required. Do not reuse unchanged
   counts or old manifests to certify repaired bytes. Deliver per-requirement
   evidence and per-assertion disposition with explicit follow-up ownership.
6. **P1-6c-integrity** and **P1-6c-adversarial**, after verification: Independent
   read-only reviewers may work concurrently on frozen bytes. Integrity checks
   actual assertions, production boundaries, complete logs, counts, manifests,
   stop proof and all failure dispositions. Adversarial checks both orderings,
   alternate writers, independent-process races, replay, stale saves and fence
   invariants. Each returns explicit accept/reject, reviewed manifest, severities,
   exact paths/test names/commands/logs/exits and remaining gaps. Prior acceptance
   or advisory inspection does not count as renewed review.
7. **P1-6c-reconcile**, after both reviews: Join, compare all hashes, serially
   repair material high/mid findings only, rerun affected gates and obtain renewed
   independent reviews for changed bytes. Each repair starts a new evidence
   attempt; never patch reviewed snapshots. Prepare proposed final file allowlist
   and documentation disposition without claiming acceptance.
8. **P1-6c-astra**, after reconciliation: Astra independently accepts or rejects
   the exact combined tree, including preserved WIP and documentation. Require
   no unresolved material P1-6c defect or coverage gap. Classification of unrelated
   failures is not a green aggregate or permission to hide them.
9. **P1-6c-finalize**, after Astra acceptance: Serially update affected README
   wording, design and `impl-plans/progress/p1-dispatch.md` with slice-only status,
   commands and evidence. Keep later slices and failed broad gate open. Obtain
   Astra reaffirmation on the exact final documentation/source tree, then let
   workflow finalization exact-file commit and non-force push with matching
   commit/push receipts. Any substantive source change returns to verification
   and reviews. Do not archive this still-active parent plan.

### Required race assertions and preserved invariants

| Trigger / ordering | Required assertions |
| --- | --- |
| SIGINT / request-first | Durable stable decision before interruption; owned stop; exact reserved cancelled snapshot and outcome; acknowledgment then fence release; no ordinary success; once-only evidence/accounting after replay. |
| External cancel / request-first | Separate command/connection commits before terminal save; same stop/proof/acknowledgment chain and stable accepted replay. |
| SIGINT / terminal-first | Barrier after terminal commit before reconciliation, including the observer-join/final-signal-commit window; preserve canonical success (and ordinary failure); no pending request or decision/application/version mutation; reconcile once and replay unchanged. |
| External cancel / terminal-first | Explicit already-terminal rejection; preserve terminal result, fence until ordinary reconciliation, unchanged application/version and no cancellation insertion; repeated request remains rejected. |

Inspect both live and final saves; assertion of a manually fabricated snapshot
covers only store behavior. Keep launch-token/version/causality validation,
selected-host placement without local fallback, delayed/lost stop-proof fencing,
prelaunch cancellation, exact cancellation acknowledgment, one replacement and
once-only accounting. Transport acceptance, lease expiry and heartbeat loss
are not stop proof. Failed persistence keeps a visible fenced error/pending state.
Historical contradictory records fail closed; no retroactive cleanup is added.

### Checkpoint, drift detection and progress

Step 4 edits the plan only; Step 5 must accept it before the runtime's serial
checkpoint commits exactly the accepted design and plan, ahead of implementation
fanout. Preserve unstaged source/progress WIP. This documentation checkpoint is
not implementation acceptance or authorization to commit implementation.

Before every edit, fresh-read its path and record requirement, owner, preimage
and SHA-256 in an immutable `intents/<unique-edit-id>/` directory beneath the
evidence directory. Immediately before writing, compare current hash to preimage;
drift stops the edit for serial reconciliation. Record postimage/hash or original
nonexistence for a new file. At review join compare all actual bytes with intent
snapshots and review manifests; repair any overwrite serially and renew evidence.
No worker overwrites another's progress: only the serial owner appends
`impl-plans/progress/p1-dispatch.md`; reviewers own separate `reviews/<role>/`
artifacts under tmp. Record task/communication IDs, changes, hashes, exact
commands/environment, complete logs, terminal exits, positive per-suite counts,
review decisions, findings, owners, open gates and next action. Preserve history.

### Verification commands and evidence

Run foreground commands below from repository root; one build/test owner, no
concurrent SwiftPM or Git writes. Evidence root is
`tmp/work-runtime-p1/p1-6c/after-helper-review/`; use a fresh attempt subdirectory
for reruns and never overwrite earlier receipts. Record exact toolchain/env,
argv, start/end source hashes, complete combined stdout/stderr path and actual
terminal exit for each command. Poll yielded sessions through exit; no detached
shell orphans. Build/lint/hash checks have no test count; test gates require a
terminal suite summary and positive counts for every requested suite.

#### Existing-source inspection: execute first

Keep the supplied source manifest and logs immutable. Run and capture:

```bash
shasum -a 256 tmp/work-runtime-p1-6c-late-cancel-host/final-source-after-helper.sha256 tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log tmp/work-runtime-p1-6c-late-cancel-host/aggregate-after-helper.log
shasum -a 256 -c tmp/work-runtime-p1-6c-late-cancel-host/final-source-after-helper.sha256
cat tmp/work-runtime-p1-6c-after-helper-acceptance/host-evidence.json
cat tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log
cat tmp/work-runtime-p1-6c-late-cancel-host/aggregate-after-helper.log
cat tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json
```

Save complete outputs as `digests.log`, `source-check.log`, `host-receipt.json`,
`focused-inspection.log`, `aggregate-inspection.log` and `inventory-inspection.json`
in a fresh evidence attempt, with each inspection exit in `verification.json`.
Expected manifest/focused/aggregate digests, respectively:
`b4609069880f14c0bd4f62053d39b73cd13556078fc688d763643fd243ab0f1c`,
`b6d4dd35c487172f34542e302093e8f5908ffcb1a5da61d5c391ac7c096646e1`,
`bceedcfbe1aaa20653088bdcdf4c37045081a0b546492f72b67dac375ac21ccd`.
Host exits 0/1 come from the receipt; `cat` exit 0 does not make a failed test pass.
The following exact read-only command checks membership, terminal summaries and
assertion identity multisets. Capture its output/exit as `identity-check.log`;
review failure messages, source history and changed dependencies separately.

```bash
python3 - <<'PYVERIFY'
import collections, json, pathlib, re, subprocess
root = pathlib.Path('tmp/work-runtime-p1-6c-late-cancel-host')
manifest = (root / 'final-source-after-helper.sha256').read_text().splitlines()
paths = [line.split('  ', 1)[1] for line in manifest]
membership = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', 'Sources', 'Tests', 'Package.swift', 'Package.resolved']).decode().split('\0')
assert len(paths) == len(set(paths)) == 973
assert set(paths) == set(filter(None, membership))
focused = (root / 'focused-after-helper.log').read_text()
aggregate = (root / 'aggregate-after-helper.log').read_text()
assert 'Executed 136 tests, with 0 failures (0 unexpected)' in focused
assert 'Executed 2057 tests, with 19 failures (7 unexpected)' in aggregate
assert ': error: ' not in focused
inventory = json.loads(pathlib.Path('tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json').read_text())
expected = collections.Counter((r['testSuite'], r['test'], r['assertionSource']) for r in inventory['records'] if r['id'] <= 8 or r['id'] >= 14)
actual = collections.Counter()
for number, line in enumerate(aggregate.splitlines(), 1):
    if ': error: ' not in line:
        continue
    match = re.search(r'(Tests/[^:]+:\d+): error: -\[([^ ]+) ([^\]]+)\]', line)
    assert match, (number, line)
    actual[(match[2].split('.')[-1], match[3], match[1])] += 1
    print(json.dumps({'logLine': number, 'assertion': line}))
assert sum(actual.values()) == 19 and actual == expected
print(json.dumps({'manifestEntries': 973, 'matchedAssertions': 19, 'new': [], 'missing': []}))
PYVERIFY
```

Exclude the interrupted `tmp/work-runtime-p1-6c-late-cancel-host/aggregate.log`,
older sandbox `tmp/work-runtime-p1-6c-late-cancel-20260924-session-1/aggregate-final-3.log`
and pre-repair 99/2049-test logs from current acceptance. Step 2 receipts under
`tmp/p1-6c-step2-after-helper/` are inspection evidence, not formal review decisions.

#### Conditional execution: only material repair or missing evidence

The remaining build/test commands are conditional rerun instructions, not a
requirement to rerun available host checks inside this sandbox. Compilation via
`swift build` supplies Swift typechecking; this slice adds no web/typecheck gate.
Use the exact toolchain/cache environment appropriate to the existing host and
record it; do not silently substitute an unrecorded command. Start with
`repair-attempt-001` below and increment for each later repair, retaining all
prior evidence. Obtain source-matched capable-host aggregate evidence after a
material source/test repair; unchanged receipts cannot certify that new source.

Create `final-source.sha256` from the sorted unique output of the membership
command below: SHA-256 of every existing tracked/untracked Sources/Tests file
and Package.swift/Package.resolved. Retain the NUL membership list, reject missing
or duplicate entries, compare fresh membership and all hashes before and after
host runs. Also hash the exact combined review tree including docs/progress and
proposed commit allowlist; source-only test manifests do not identify that tree.
The exact manifest-generation command is:

```bash
python3 -c 'import hashlib,pathlib,subprocess; paths=sorted(set(filter(None,subprocess.check_output(["git","ls-files","--cached","--others","--exclude-standard","-z","Sources","Tests","Package.swift","Package.resolved"]).decode().split("\0")))); assert paths; out=pathlib.Path("tmp/work-runtime-p1/p1-6c/after-helper-review/repair-attempt-001"); out.mkdir(parents=True,exist_ok=True); (out/"membership.nul").write_bytes("\0".join(paths).encode()+b"\0"); (out/"final-source.sha256").write_text("".join(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()+"  "+p+"\n" for p in paths))'
```

Run generation once per frozen attempt; before/after checks compare newly listed
membership with the saved list and run `shasum -c`, never regenerate the baseline
to conceal drift. The combined-tree review manifest additionally includes every
candidate commit file and its SHA-256, with exact allowlist membership checked.

Create `changed-swift-files.nul` from the exact owned changed Swift allowlist,
including preserved WIP and untracked Swift files; reject empty/missing paths.
No dependency/lockfile regeneration is requested.

```bash
git rev-parse HEAD
git status --short
git ls-files --cached --others --exclude-standard -z Sources Tests Package.swift Package.resolved
shasum -a 256 -c tmp/work-runtime-p1/p1-6c/after-helper-review/repair-attempt-001/final-source.sha256
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionDecisionApplierStoreTests|DecisionApplierStoreTests|TaskCommandParsingTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests|DistributedProcessCancellationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|WorkflowCommandLivePersistenceTests|WorkflowCommandLivePersistenceEventTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests|SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'
xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/after-helper-review/repair-attempt-001/changed-swift-files.nul
shasum -a 256 -c tmp/work-runtime-p1/p1-6c/after-helper-review/repair-attempt-001/final-source.sha256
git diff --check
git diff --cached --check
```

Log names in command order: `head.log`, `status.log`, `membership.nul`,
`source-before.log`, `build.log`, `store-decisions.log`, `focused.log`,
`compatibility.log`, `aggregate.log`, `swiftlint.log`, `source-after.log`,
`diff-check.log`, `cached-diff-check.log`; terminal receipts go in
`verification.json`. Membership generation and manifest construction also record
exit status and manifest digest. The focused gate includes real SIGINT and
selected-host tests, V1/V11 and live persistence; store gate covers V2 and decisions;
compatibility preserves P1-6b results/dry-run and catalog/projection semantics.
New deterministic cases must appear by exact test name in passing logs.

Listener-denied sandbox runs are environmental failures, not code failures or
passes. Do not repeat the broad listener-dependent aggregate there; obtain its
source-matched capable-host run. If a new capable-host run is required by changed bytes or a material gap,
its unavailability leaves that check open and publication blocked; it does not
invalidate the supplied unchanged-source host receipts. Record any build-cache/toolchain failure verbatim;
a supported fallback must retain its exact command and cannot erase failed runs.

Current host logs are `tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log`
(136/136, reported exit 0) and `aggregate-after-helper.log` (2057 tests, 19 assertions,
7 unexpected, reported exit 1). Compare assertion
(test name, source path/line) multisets against IDs 1–8 and 14–24 in
`tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json`.
Record every new, missing or shifted assertion and evidence for its disposition;
do not demand historical counts after adding tests. Owners remain: IDs 1–7 CLI
doctor/backend-capability; 8 P1-7b examples; 14–21 workflow-command/host-readiness;
22 runner admission; 23–24 temporary workflow/host-requirements. IDs 9–13 are
historically repaired catalog/projection assertions. Unknown relevance or a
material P1-6c failure blocks slice acceptance. No unrelated repair or weakened
assertion is authorized. Broad aggregate remains FAILED until it actually passes;
independently accepted non-slice failures never become a green gate.

### Completion and author self-check

Plan readiness requires valid DAG/paths and traceability to the accepted design.
Implementation completion separately requires both race orders for both triggers,
all preserved stop/acknowledgment/replay/fence invariants, source-matched complete
evidence, independent integrity/adversarial and Astra acceptance with no high/mid
P1-6c defect, accurate final docs/progress, exact-file commit and matching non-force
push receipt. A material rejection or unavailable required new verification is an explicit
incomplete outcome; no new host run is required solely for unchanged evidence.
P1-6d, P1-7a/b and parent P1 remain open; this plan stays active.

Step 3 supplied no findings; no Step 5 revision feedback was supplied. Step 4
checks metadata, DAG, path existence, accepted design hash, historical-tail
preservation and whitespace; logs live in `tmp/p1-6c-step4-after-helper/`.
This author check makes no claim of passing Swift tests or implementation review.

---

## Historical preserved plan — not executable in this invocation

The following prior plan text and WIP history are preserved. Its statuses,
commands, metadata and checkbox states do not supersede the current contract.

# Work Runtime P1: P1-6c durable decisions and live cancellation

**Status**: Historical design/plan checkpoint `0a74a070670a5cb73f6cd18e035adf61732a0b07` retained. Step 3 accepted the host-evidence/classification refresh; runtime dispatch is at Step 6 implementation. P1-6c implementation and publication remain incomplete.
**Workflow mode**: issue-resolution
**Issue reference**: Work Runtime P1-6c; no GitHub issue URL or number supplied.
**Accepted design**: `design-docs/specs/design-work-runtime-consolidation.md` §17.2 and §17.5 “P1-6c bounded amendment (2026-09-24)”.
**Design SHA256**: `f1ea157a0547fc3df77be2c1c510654539f4368e373be47d3e062098fc0cf9a0`.
**Review decision**: Step 3 accepted the host-evidence/classification design with no findings, `comm-000004`, `step3-design-review-attempt-1-exec-4`. This Step 6 dispatch has no Step 5 communication ID in its input; independent implementation and combined-tree acceptance remain pending.
**Codex-agent references**: `gpt-6-astra` single design/plan author and final integration reviewer; `gpt-6-sol` implementation, serial reconciliation, independent test-integrity and adversarial review. Execution `codex-design-and-implement-review-loop-session-1`.
**Updated**: 2026-09-24

**Current Step 6 handoff**: Host receipt and original source manifest were rechecked before the five-file catalog/projection repair. The 24 original broad assertions are classified in `tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json`; five direct P1 assertions are repaired, and the catalog/parity/projection focused gate passes 17/17 with a writable repository-`tmp/` HOME. The original capable-host broad gate remains failed at 24/2,048. Final-source selected-host and affected capable-host aggregate acceptance, independent reviews, docs acceptance, exact-file commit and push remain open. P1-6d, P1-7a/b and parent P1 remain active.

The prior host's cancellation/worker dependencies are unchanged, but its manifest differs in five Swift files and cannot count as an exact final-source pass. Pre-P1 capable-host logs and a final-source focused run now establish the eight workflow-command assertion failures predate P1-6c; exact causes for six historical assertions remain unspecified and are a separate workflow-command follow-up. With writable `tmp/` HOME, the final-source sandbox broad aggregate reached terminal exit 1 after 2,048 tests and 240 failures (90 unexpected), including listener denials. Its complete log is `tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/aggregate-home-final-source.log`; source recheck after the run exited 0. This broad gate is failed, not slice acceptance.

This is the only current executable contract in this file. The historical
P1-6b and parent material below is reference-only and does not authorize work.
Preserve P1-6b publication `7d8fc121a4f4469de7a40495282b53c9d813b8d4` and receipt
baseline `ae7cafe7577fda5037dee105e894804c88626f43`. P1-6d, P1-7a/b and parent P1
remain active. One implementation owner is necessary because store, runner,
signal and selected-host acknowledgment form one coupled safety contract;
there is no independent implementation plan to fan out.
The accepted design/plan checkpoint is
`0a74a070670a5cb73f6cd18e035adf61732a0b07`; the current implementation baseline
is intake HEAD `30601aa89485436440728bf417b0156ea477f25d` plus all 20
intake WIP files (17 modified tracked and three untracked), as enumerated in
`comm-000002`. Preserve the accepted Step 2 design update as well. The five-file
checkpoint is historical, not the current preservation allowlist. Step 3
accepted the refreshed design via `comm-000004`; no Step 5 revision feedback
is supplied. Prior read-only agents `failure_matrix_audit` and
`remote_evidence_audit` supply history, not final review acceptance.


The runner-resolved immutable user-scope workflow package and effective
workflow input are authoritative. No registry or package rediscovery belongs
to this node. Within this run, at most two productive incomplete Step 6
continuations may retain this accepted design/plan without reopening them.
Each requires concrete new changes, plan-progress evidence and passing
behavioral tests. Repeated evidence, external blockers, missing material
verification or a third consecutive incomplete attempt ends with an accurate
handoff; incomplete implementation never enters review or finalization.

### Current continuation and historical progress

Current status follows accepted Step 3 `comm-000004`, execution
`step3-design-review-attempt-1-exec-4`. The complete receipt
`tmp/work-runtime-p1-6c-host-failure/evidence.json` records capable-host
selected-live 1/1, V11 plus live 55/55 and V1 plus cancellation 50/50, all exit 0.
The fixture proves one policy start and one human cancel with causal evidence
and unchanged replay history. The prior two-row failure is resolved by this
source-matched evidence; do not rebuild the implemented cancellation seams or
repeat obsolete listener diagnosis. The manifest SHA-256 is
`6d3ef8ee373d32a7ed1deac12a969a5366b71117c9019031869a3759debf5e96`;
Step 3 independently matched its 962 entries. Evidence verification remains an
explicit task; these results alone do not accept P1-6c.

The complete `tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log`
is failed: 2,048 tests, 24 assertions (7 unexpected), exit 1. Assertion counts:
Doctor 7, surface parity 4, projection 1, example parity 1, workflow commands 8,
temporary workflow registration 2 and runner admission 1. The separate
`capable-host-projection-current.log` is failed: 2 tests, 1 assertion, exit 1.
Classify every assertion, repair only demonstrated slice defects, rerun affected
final-source gates and obtain independent disposition of remaining unrelated
failures. Earlier continuation observations below are historical, not current
missing-feature claims or substitutes for these receipts.

The owner audited the accepted store, runner, signal and selected-host seams.
`WorkStore+Reservation.swift` now exposes an exact task/attempt/session scoped
read of a durable cancellation request and its acknowledgment state. The
reopened-store regression in `WorkStoreCancellationTests.swift` passes, along
with the selected 23-case reservation/cancellation suite and strict two-file
SwiftLint. Complete logs and source hashes are under
`tmp/work-runtime-p1-6c-2c7cf9334b26/`.

The live request observer, prelaunch cancelled snapshot, task-backed Ctrl-C,
selected-host worker-stop proof, dispatch acknowledgment route and full matrix
remain open. This seam does not establish P1-6c completion or authorize a
fence release. The completion criteria below remain unchecked pending those
paths, final-source V1/V2/V11 and aggregate evidence, and independent reviews.

Continuation `nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`
added a fail-closed exact cancellation check in `TaskDispatch.swift` before
terminal evidence projection and generic reconciliation. An unacknowledged
request remains fenced; an already acknowledged request is accepted only when
the durable attempt outcome matches the reserved terminal snapshot, then its
evidence projection can replay without reapplying the transition. This is an
intermediate guard, not the live acknowledgment route: the run-owned observer,
worker-stop proof, cancellation-safe terminal persistence and exact first
acknowledgment remain open. Read-only Codex audits `audit_dispatch`,
`audit_runner` and `audit_store` identified these coupled gaps. The build and
selected V2/decisions suites passed with plan-local module caches; V1 selected
41 tests and failed 16 listener-dependent assertions because this host denies
local network listeners. Complete logs and exits are under
`tmp/work-runtime-p1/p1-6c/continuation/`. No completion criterion advances.

This Step 6 continuation added `TaskRunCancellation.swift` to poll exact durable
requests during the owned run and join observation on exit. A separate-process
decision now interrupts local execution, and `TaskDispatch.swift` acknowledges
only its exact cancelled terminal snapshot after the local runner returns. The
selected-host worker now records a durable lease-bound stop receipt after its
executor joins; the controller rejects foreign or stale receipts. Dispatch still
holds selected-host cancellation pending because it does not yet consume that
receipt as end-to-end proof. Prelaunch cancelled persistence and task-backed
Ctrl-C remain open. The controller retains a cancelled claimed job until its
stop receipt is durable, including under zero terminal-retention configuration;
receipt replay survives archival and reopen. The final-source safe filter
passed 92/92 and strict
changed-file SwiftLint passed; the real process test could not start a local
listener on this sandbox host. Evidence and per-edit intents are under
`tmp/work-runtime-p1/p1-6c/continuation-2/`. No independent review or P1-6c
completion is claimed.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Finalization.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Finalization.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6c-audit",
    "P1-6c-decision-diagnosis",
    "P1-6c-decision-repair",
    "P1-6c-evidence",
    "P1-6c-catalog-projection",
    "P1-6c-store",
    "P1-6c-remote",
    "P1-6c-live",
    "P1-6c-regressions",
    "P1-6c-integrity",
    "P1-6c-adversarial",
    "P1-6c-reconcile",
    "P1-6c-integration",
    "P1-6c-finalize"
  ],
  "taskDependencies": {
    "P1-6c-audit": [],
    "P1-6c-store": [
      "P1-6c-catalog-projection"
    ],
    "P1-6c-remote": [
      "P1-6c-store"
    ],
    "P1-6c-live": [
      "P1-6c-remote"
    ],
    "P1-6c-regressions": [
      "P1-6c-live",
      "P1-6c-evidence"
    ],
    "P1-6c-integrity": [
      "P1-6c-regressions"
    ],
    "P1-6c-adversarial": [
      "P1-6c-regressions"
    ],
    "P1-6c-reconcile": [
      "P1-6c-integrity",
      "P1-6c-adversarial"
    ],
    "P1-6c-integration": [
      "P1-6c-reconcile"
    ],
    "P1-6c-finalize": [
      "P1-6c-integration"
    ],
    "P1-6c-evidence": [
      "P1-6c-audit"
    ],
    "P1-6c-decision-diagnosis": [
      "P1-6c-audit"
    ],
    "P1-6c-decision-repair": [
      "P1-6c-decision-diagnosis"
    ],
    "P1-6c-catalog-projection": [
      "P1-6c-evidence",
      "P1-6c-decision-repair"
    ]
  },
  "dependencyMode": "single-plan-ordered-internal-gates",
  "acceptedPrerequisites": {
    "P1-6a": "2f10916a14501af68fd7e7f63cb91f244a343f8c",
    "P1-6b": "7d8fc121a4f4469de7a40495282b53c9d813b8d4"
  },
  "verificationCommands": [
    "shasum -a 256 -c tmp/work-runtime-p1-6c-decision-20260924-c07910f-comm000006/continuation-2/source-test.sha256",
    "rg -n 'Test Case .* failed \\(| error: ' tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log",
    "swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'",
    "swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'DoctorCommandTests|RielaExampleParityTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests|WorkflowRunnerAdmissionTests'",
    "git log -n 12 --format=oneline -- Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaWork/CompletionEvaluator.swift Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "git diff 30601aa89485436440728bf417b0156ea477f25d -- Sources Tests",
    "CLANG_MODULE_CACHE_PATH=tmp/work-runtime-p1/p1-6c/module-cache SWIFTPM_MODULECACHE_OVERRIDE=tmp/work-runtime-p1/p1-6c/module-cache swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests|DecisionApplierStoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskProjectionProofTests",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/changed-swift-files.nul",
    "git diff --check",
    "git diff --cached --check"
  ],
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6c/"
}
```

## Current P1-6c executable contract

### Intent, boundaries and invariants

Complete P1-6c using verified host evidence, repair confirmed catalog/projection
defects and classify the failed aggregate while preserving accepted behavior. Complete actual task
cancellation, not just request storage: human cancel/reject,
guard stop/replacement and Ctrl-C must commit the shared decision before
interrupting the exact local or selected-host execution. Reuse the WorkStore
applier, reservation fence, workflow persistence and authenticated worker path.
Requests from another CLI process must reach the running owner without output
or heartbeat dependence. The runtime-supplied workflow input and provenance
are authoritative; registry rediscovery is not a task.

Non-goals: director execution, legacy auto-improve removal, later examples,
new decision storage or scheduler, new dependencies, generalized signaling or
persistence frameworks, broad formatting, unrelated baseline repair, main merge,
release, worktrees or private branches. Preserve Monja and unrelated work.
Codex references map to agent roles, not product behavior; no Cursor adapter or
reference-repository comparison is required.

Invariant sequence: durable request -> interruption -> proven owned execution
stop -> exact reserved cancelled snapshot -> atomic store acknowledgment ->
optional one-time replacement reservation. Generic reconcile, caller outcomes,
HTTP cancellation acceptance, expired leases and missing heartbeats cannot
substitute for any boundary. Pre-authorization cancellation prevents launch;
authorized uncertainty remains fenced. Matching success or non-cancelled failure
cannot acknowledge cancellation and must remain an explicit fenced conflict.
No stale token, duplicated evidence/usage, replacement or decision application is
permitted. A task may contain distinct legitimate decisions; one cancellation
intent must not be mistaken for a universal one-row task history.

### Ownership and evidence safety

Step 5 acceptance precedes the workflow's serial exact-file design/plan checkpoint
commit, which must occur before native implementation/review fanout. Step 4
itself does not commit an unreviewed plan. Record checkpoint hash and changed
file list; retain baseline and accepted P1-6b evidence separately. Checkpoint
only the accepted design and plan documents; do not stage the preserved partial
Swift implementation or its progress log as completed implementation. Preserve
all 20 intake WIP files through checkpointing and later edits; the existing plan WIP
is retained within this revised plan, not reverted to the old committed version.

All writePaths are exclusive to the single implementation owner; listed files
are candidates, not a requirement to edit every file. Shared docs, README,
indexes, lockfile generation and finalization are serial-only. Do not change a
lockfile or index unless necessary and explicitly recorded by reconciliation.
No concurrent Git operations. Reviewers are read-only and write evidence only
under their own `tmp/work-runtime-p1/p1-6c/reviews/<role>/` directory.
Read-only log/source investigation may run in parallel with the owner. Serialize
Swift build/test commands using the shared scratch path and freeze source while
capturing accepted runs; never attribute a run across concurrent source edits.

Before each edit, fresh-read the file, hash its current bytes and save an
immutable preimage plus intended change, requirement and owner under
`tmp/work-runtime-p1/p1-6c/intents/<unique-edit-id>/`. Recheck the pre-hash just
before writing; drift means stop that edit and reconcile, never overwrite.
Record postimage/hash immediately. For new files record nonexistence first.
At the review join compare current files to owner/reviewer manifests and all
accepted intents; serially restore missing behavior, then rerun affected checks
and reviews against repaired hashes. Never reset unrelated changes.

Only this plan's owner appends `impl-plans/progress/p1-dispatch.md`, recording
workflow/communication IDs, task IDs, exact edited paths, hashes, complete log
paths, exit codes, counts, review decisions, blockers and next work. Preserve
historical entries and P1-6b hashes. Do not mark parent/later slices complete.

### Tasks, file-level deliverables and dependencies

- [x] **P1-6c-audit**: Accepted seam audit is complete. Fresh-read only files
  being edited and reconcile current hashes with the terminal handoff;
  do not restart a broad audit. `/root` remains the sole source/test editor.
- [x] **P1-6c-decision-diagnosis** after audit: Reconcile the supplied receipt
  against each complete host log and the unchanged manifest. Fresh-read
  `TaskCancellationIntegrationTests.swift` and `+Fixtures.swift`; map exact
  policy-start/human-cancel IDs, kinds, producer, task/attempt, causal evidence,
  reserved session and application/replay assertions to the passing selected-live
  test. Record this mapping and source-match exit/count under this attempt's
  evidence directory. Reuse valid evidence; only an actual inconsistency requires
  new diagnostics. Never infer causality merely from a row count or producer.
- [x] **P1-6c-decision-repair** after diagnosis: Record the evidence-supported
  no-new-repair decision for the now-passing fixture, unless diagnosis exposes
  an actual contradiction. If one exists, only the serial owner may repair the
  demonstrated fixture/producer seam in the already listed CLI/Work files and
  rerun selected-live. Preserve exact identity, cancellation, process-stop,
  proof, lease, outcome, replay and accounting assertions. No direct decision-row
  mutation, unexplained filtering or bare count substitution.
- [x] **P1-6c-evidence** after audit: Independent read-only investigation may run
  alongside receipt reconciliation. Write `reviews/evidence/failures.json` under
  this attempt's evidence root with exactly 24 assertion records, each containing
  suite/test, original log line, expected/actual, source and dependency history,
  focused reproduction command/log/exit/count, relevance and disposition.
  Multiple assertions in one test retain separate records. Reconcile the seven
  suite-group counts above and explicitly retain the seven unexpected failures.
  Use the history, diff and classification commands below; trace fixtures and
  affected production dependencies, not just whether a test file changed.
  Classify as slice defect, evidenced baseline/unrelated, environment, or unknown;
  unknown blocks acceptance. This task delivers the initial classification and
  pre-repair reproduction; regressions updates the same records with final-source
  results before calling an earlier failure resolved. Baseline claims need concrete historical semantics or
  reproduction evidence; do not reset this shared tree or create worktrees.
  Read-only `git show <commit>:<path>` may inspect the identified history.
  Each unresolved unrelated failure gets an explicit follow-up owner (parent P1
  maintainer or the evidenced later slice), affected paths and reproduction.
  The implementation owner records proposed slice-only disposition in progress;
  independent reviewers must accept it. Classification never makes aggregate green.
- [x] **P1-6c-catalog-projection** after evidence and decision-repair: The serial
  owner confirms catalog schema/parity from `SurfaceCatalog.swift`,
  `SurfaceCatalog+RowSupport.swift`, `SurfaceCatalog+RowsCLI.swift`, registered
  `TaskCommands.swift` and existing catalog/parity tests. Add only missing task
  run/decide rows in `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, matching
  actual command capabilities, mutation and audit behavior. Retain full parity
  assertions; extend `Tests/RielaCoreTests/SurfaceCatalogTests.swift` or
  `Tests/RielaCLITests/SurfaceParityCLITests.swift` only if existing coverage cannot
  detect the demonstrated omission. No registration removal to hide a mismatch.
  Verify failed-session semantics in read-only
  `Sources/RielaWork/CompletionEvaluator.swift` and the fixture, then add the
  required `acceptanceNotMet` reason in canonical order to
  `Tests/RielaCLITests/TaskProjectionProofTests.swift`; retain all gate/finding
  reasons and task-state assertions. Do not weaken the evaluator or example.
  Deliver before/after intent hashes, focused failing/passing evidence and the
  exact repair rationale. Run catalog-projection below with positive counts for
  all three suites. Other failures authorize no unrelated edits; a material
  issue beyond listed scope needs a documented scope decision before repair.
- [ ] **P1-6c-store** after catalog-projection: Verify the preserved implementation, repairing
  only demonstrated gaps. In `WorkStore+Decisions.swift` and
  `WorkStore+Reservation.swift`, preserve and consume the existing
  `attemptCancellation(taskId:attemptId:sessionId:)` read and
  `AttemptCancellationRecord`; do not recreate the verified seam. Repair only
  demonstrated transaction/replay gaps. Preserve decision/version validation, request-before-signal ordering,
  authorization/node-start guards and generic-reconcile rejection. Acknowledge
  only canonical exact cancelled snapshots; atomically update attempt, lease,
  task and acknowledgment. Reopen recognizes already committed acknowledgment
  without applying it twice. Keep pending replacement consumption in the existing
  reservation transaction. Extend the three Work test files listed above only
  for demonstrated missing coverage.
- [ ] **P1-6c-remote** after store: Preserve implemented receipts and proof
  consumption; repair only defects exposed by the required live/race tests. In `DistributedNodeExecution.swift`,
  `DistributedJobController.swift`, `DistributedWorkerModels.swift`,
  `DistributedWorkerLoop.swift`, `DistributedWorkerHTTPRouter.swift` and only
  if needed `DistributedWorkerProtocol.swift`, carry proof of worker stop using
  the existing authenticated worker completion route and durable job record.
  Controller cancellation intent/status alone is insufficient. Retain the exact
  job, lease token, worker incarnation and task-session attachment binding;
  acknowledge only after the worker has cancelled and joined its executor/process
  tree. A queued job proven never claimed may establish nonexecution atomically.
  A leased job needs worker acknowledgment, including after lease expiry; expired
  or missing heartbeat alone cannot establish it. Reject foreign/stale worker
  proof and late successful results. Preserve cancelled-job result semantics;
  use a minimal additive optional acknowledgment field if required, with absent
  legacy data meaning unacknowledged. Do not add a parallel transport or store.
  The task-backed caller awaits that proof before canonical cancellation
  persistence; failed/lost transport keeps the attempt fenced. Bound individual
  waits and surface uncertainty without releasing the fence. Preserve plain
  distributed cancellation and worker reuse; reuse Core controller, Server HTTP
  and distributed process regressions, extending only demonstrated coverage gaps.
- [ ] **P1-6c-live** after remote: Verify and complete the preserved connection of `TaskDispatch.swift` and
  `WorkflowRunCommand+TaskReservation.swift` to a run-owned bounded poll of exact
  durable pending requests. Use `TaskRunCancellation.swift` only as a cohesive
  helper for this lifetime, not a general service. Observe before admission and
  throughout running, interrupt once per request while allowing safe retry,
  and cancel/join the observer on every exit. In `TaskCommands.swift` preserve
  exactly-one-action and required identity/version parsing; distinguish request
  acceptance from task completion in existing output (`TaskCommandModels.swift`
  only if necessary). Route guard actions through the same applier. In
  `EntryPoint.swift`/`CLISignalCancellation.swift`, route task-backed Ctrl-C to
  the owner so the stable decision commits before cancelling execution; handle
  signals before reservation and repeated signals without a stale launch or
  duplicate decision. Other command cancellation remains compatible. Do not
  propagate parent cancellation to execution before the durable write finishes.
  In `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` and
  `WorkflowRunCommand+SupervisionPersistence.swift`, preserve reserved identity
  and await cancellation-safe terminal persistence. A prelaunch-cancelled
  reservation records its own cancelled snapshot without launching work.
  `TaskDispatch.swift` checks pending/acknowledged cancellation before generic
  reconciliation or completion/guard evaluation, projects evidence idempotently,
  and reserves a pending replacement once only after acknowledgment. Return
  explicit pending/error for persistence/stop uncertainty, retaining IDs/fence.
  `WorkflowRunCommand.swift` is already 998 lines: keep new cancellation logic
  in the cohesive helper; if the file exceeds 1000, move only existing finalization
  responsibility to `WorkflowRunCommand+Finalization.swift`, preserving access
  boundaries. No broad file splitting is authorized.
- [ ] **P1-6c-regressions** after live and evidence: Verify the preserved matrix below. Keep new live
  tests in `TaskCancellationIntegrationTests.swift` and its fixtures file to
  avoid enlarging the existing integration suite unnecessarily. Extend existing
  selected-host fixtures only where needed. Run all commands below on final
  implementation source, produce a source/test manifest, and record every
  failure honestly. Store-only tests cannot close this gate.

  Preserve the existing end-to-end selected-host test in
  `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` and
  `TaskCancellationIntegrationTests+Fixtures.swift`, including bounded process
  exit polling and Linux zombie handling. Repair only demonstrated gaps. Drive a
  real task reservation/dispatch to the authenticated selected worker, hold a
  real process at a deterministic readiness barrier, and invoke `task decide`
  from a separately owned CLI process against the same store. Assert selected
  host/job/reserved-session linkage and no local fallback. Observe the durable
  request before interruption, delay worker-stop proof to assert the request
  and lease remain fenced, then prove executor/process-tree exit and exact
  cancelled persistence before acknowledgment. Reopen/replay and compare
  decision, terminal evidence, usage and replacement counts. Do not replace
  this with a controller-only test or fabricated cancelled snapshot. The live
  command must select this test and record a positive count on a capable host.

  Match each matrix row to existing test names and final-source evidence first.
  The terminal handoff already records lost-response/reopen and independent
  replacement-contender tests; rerun those rather than duplicate their bodies.
  Extend only proven missing cases: terminal persistence failure before any
  canonical snapshot; lost acknowledgment response after commit (distinct from
  the existing transaction-failure test); lease/heartbeat loss with owned work
  still unproven; and two independent reservation contenders after acknowledged
  replacement, with exactly one request consumption/new session. Use barriers,
  shared-applier decisions and owned teardown; no direct decision-row mutation.
  Existing passing cases need final-source reruns, not duplicate test bodies.

  Historical context only: Step 6 continuation 3 added exact prelaunch cancelled snapshot persistence,
  task-run request-before-signal decision application and selected-host controller
  stop-proof consumption. Focused local and controller tests pass. Keep store,
  remote, live and regression boxes open. Continuation 4 adds passing focused
  acknowledgment-loss, terminal-projection failure, empty-controller proof and
  once-only replacement tests. Real selected-host dispatch, complete race and
  failure matrix, final-source V1/V11 and aggregate acceptance, reviews and
  publication remained pending then; current host evidence supersedes those
  historical listener failures. At this gate require all 24 assertions classified,
  material slice defects repaired and affected gates rerun on final source.
  Unrelated failed broad tests may proceed only as an explicit proposed slice-only
  disposition for independent review; unknown or material failures cannot.
- [ ] **P1-6c-integrity** and **P1-6c-adversarial** after regressions: Independent
  Sol read-only reviews may run concurrently. Integrity verifies test selection,
  positive counts, meaningful ordering/process assertions, final-source hashes,
  actual terminal exits, complete logs and every aggregate disposition. Both
  reviews explicitly accept or reject slice-only treatment of unrelated failures.
  Adversarial review exercises material
  races/failure cases against design; no style-only or speculative scope.
- [ ] **P1-6c-reconcile** after both reviews: Single Sol owner repairs all high/mid
  findings and shared-file drift, preserves accepted changes, reruns affected
  focused/aggregate/lint gates and obtains renewed independent acceptance where
  repairs invalidate review. Refresh design, plan, owner progress and directly
  affected README usage here, before final combined-tree review. Record unresolved
  broad failures and owners separately from P1-6c and active later slices. Shared
  indexes and documentation edits are serial; no unrelated README changes.
- [ ] **P1-6c-integration** after reconciliation: Independent Astra review accepts
  the exact combined tree, evidence and accepted design with no material open
  finding. Any repair repeats affected verification/review before acceptance.
- [ ] **P1-6c-finalize** after integration: Verify the reviewed docs and unchanged
  accepted source tree; any substantive new edit repeats affected review.
  Record exact changed-file allowlist and accepted hashes; workflow finalization
  commits and non-force pushes that exact accepted result to
  `origin/feat/remaining-impl-plans`. Record commit/push receipts. Keep parent
  plan active; do not archive it or close P1-6d/P1-7a/b. No main merge or release.

### Required regression matrix

| Requirement | Files and observable proof |
| --- | --- |
| Selected-host decision identities | Existing CLI fixture: record every reservation/acknowledgment/replay decision ID, kind and causality; exactly one human cancel, stable complete history/application and accounting on replay; explain both observed rows and pass capable-host rerun. |
| CLI validation/replay | `TaskCommandParsingTests.swift`, `TaskCommandMutationTests.swift`, `DecisionApplierStoreTests.swift`: absent/conflicting actions, blank principal/ID/reason, negative/missing version, step without rerun, valid actions; rejected inputs leave rows/version unchanged; identical replay returns original result; conflicting replay/stale new decision rejects. |
| Prelaunch and authorization race | Work reservation/cancellation tests plus `TaskCancellationIntegrationTests.swift`: deterministic barriers before authorization and node start; no worker/process launch if request wins; exact reserved cancellation snapshot; authorized uncertainty stays fenced. |
| Live local and separate-process decisions | Preserved CLI live tests: real owned command/process blocked at a deterministic fixture barrier, request from another store connection/process using CLI decision path, durable row observed before signal, process exit observed before acknowledgment, IDs match reservation. Cover cancel, reject, guard stop and replacement. |
| Ctrl-C | Preserved CLI live tests drive the actual EntryPoint signal path in an owned subprocess; prove durable request before interruption, repeated signals stable, pre-reservation signal does not launch work, ordinary non-task command cancellation unchanged. |
| Live selected host | CLI selected-host fixtures, `DistributedProcessCancellationTests.swift`, `DistributedWorkerHTTPTests.swift`, `DistributedJobControllerTests.swift`: authenticated chosen worker actually runs/stops, exact session/job linkage, no local fallback, no acknowledgment merely on HTTP acceptance, delayed worker-stop proof holds fence, stale lease/incarnation proof rejected. |
| Persistence and acknowledgment loss | Work and CLI live tests inject failure at terminal persistence and after snapshot/before acknowledgment; reopen store and reconcile exact snapshot; after committed acknowledgment simulate lost response and prove no duplicate transition, evidence, usage or replacement. |
| Negative terminal evidence | Wrong session, created/nonterminal snapshot, success and non-cancelled failure cannot release pending fence; generic reconcile blocked. No rewriting an unrelated outcome as cancellation. |
| Replacement and failure uncertainty | Pause between acknowledgment and reservation, reopen/replay twice, assert one consumed request/new session, no stale token launch or duplicate accounting; lease expiry, missing heartbeat, transport loss and inaccessible runner retain fence. |

Use deterministic readiness/barrier signals and bounded deadlines, not timing-only
sleep assertions. Every process/worker/server fixture is owned and awaited in
teardown even after failure. Capture live execution counts and exact session IDs;
mock DTOs or fabricated snapshots establish only store-level invariants.

### Verification commands and required evidence

Run commands in the foreground. Record each exact argv/environment, complete log,
terminal exit code, selected suites/counts and before/after source/test SHA256
under `tmp/work-runtime-p1/p1-6c/`; retain/poll any tool session to terminal exit.
If a named log already exists, use a new attempt subdirectory and record its
actual path; never overwrite prior evidence. Hash the complete source/test
manifest, including new files, not merely the two previously verified store files.
Do not use detached shell jobs. A logging wrapper under that directory must
propagate the child exit status, never just tee's status. Planning checks do not
substitute for these implementation gates.

**selected-live** — log `tmp/work-runtime-p1/p1-6c/<attempt>/selected-live.log`

```bash
CLANG_MODULE_CACHE_PATH=tmp/work-runtime-p1/p1-6c/module-cache SWIFTPM_MODULECACHE_OVERRIDE=tmp/work-runtime-p1/p1-6c/module-cache swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof
```

This retained planned command selects the same test as the passing host receipt;
it is not a claim about the operator's exact argv. Recover actual argv/environment
from `evidence.json` and its logs (the supplied host prefix has no scratch-path
flag). Reuse matching capable-host evidence only with explicit dependency/source
justification. Any changed cancellation or worker dependency requires a new host
run; never treat listener refusal as a behavioral failure or passing coverage.

**source-match, failure inventory and history** — complete logs under the new
attempt directory (`source-match.log`, `failure-inventory.log`, `history.log`,
`source-diff.log` respectively):

```bash
shasum -a 256 -c tmp/work-runtime-p1-6c-decision-20260924-c07910f-comm000006/continuation-2/source-test.sha256
rg -n 'Test Case .* failed \(| error: ' tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log
git log -n 12 --format=oneline -- Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaWork/CompletionEvaluator.swift Tests/RielaCLITests/TaskProjectionProofTests.swift
git diff 30601aa89485436440728bf417b0156ea477f25d -- Sources Tests
```

The original manifest is immutable baseline evidence: do not overwrite it after
repairs. Produce a new sorted manifest of every tracked/untracked `Sources/` and
`Tests/` file, `Package.swift`, `Package.resolved` when present and the HEAD ID;
record SHA-256 for each path and the manifest, then check it before/after every
accepted run. Compare its path set too, so newly added files are not omitted.
Record the diff from the host manifest and gate dependency relevance when reusing
historical evidence; unchanged cancellation sources alone do not prove unchanged
build inputs. A mismatching old manifest after authorized repairs is expected,
not permission to claim the old run used final source.

**catalog-projection** — log `<attempt>/catalog-projection.log`:

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'
```

Must pass all three suites with positive counts, preserving full catalog parity
and failed-session completion requirements.

**classification** — log `<attempt>/classification.log`:

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'DoctorCommandTests|RielaExampleParityTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests|WorkflowRunnerAdmissionTests'
```

Capture all selected suite counts and each failed assertion. This can remain
failed for evidenced unrelated defects; it cannot silently skip tests or serve
as passing P1-6c evidence. History command paths above cover proposed repairs;
repeat `git log -n 12 --format=oneline -- <exact-affected-paths>` and
`git show <identified-commit>:<exact-path>` for every other failure's fixture and
production dependency, recording resolved commands/commits in its record.

**V0** — log `tmp/work-runtime-p1/p1-6c/V0.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**V1** — log `tmp/work-runtime-p1/p1-6c/V1.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'
```

**V2** — log `tmp/work-runtime-p1/p1-6c/V2.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'
```

**V11** — log `tmp/work-runtime-p1/p1-6c/V11.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof'
```

**decisions** — log `tmp/work-runtime-p1/p1-6c/decisions.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests|DecisionApplierStoreTests'
```

**live** — log `tmp/work-runtime-p1/p1-6c/live.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests'
```

**compatibility** — log `tmp/work-runtime-p1/p1-6c/compatibility.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

**projection classification** — log `tmp/work-runtime-p1/p1-6c/projection.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskProjectionProofTests
```

This focused reproduction classifies the observed `acceptanceNotMet` mismatch;
it does not replace the affected aggregate or justify weakening its assertion.

**aggregate** — log `tmp/work-runtime-p1/p1-6c/aggregate.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'
```

**lint** — log `tmp/work-runtime-p1/p1-6c/lint.log`

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/changed-swift-files.nul
```

**diff** — log `tmp/work-runtime-p1/p1-6c/diff.log`

```bash
git diff --check
```

**staged-diff** — log `tmp/work-runtime-p1/p1-6c/staged-diff.log`

```bash
git diff --cached --check
```

V0 is compile/typecheck. V1 proves task behavior; V2 covers reservation,
cancellation and budgets; V11 covers selected-host/controller/HTTP behavior.
The decisions and live commands explicitly select suites omitted by V1/V2/V11.
Compatibility protects accepted read-only dry-run and result behavior. Aggregate
covers affected CLI, Work, Core and Server targets including plain workflows.
Require positive counts for every named suite; absence is a failure. Add exact
filters for any extra suite introduced by a necessary seam before claiming
coverage. No web/UI changed, so browser/AppKit checks are not required.

Before lint generate `changed-swift-files.nul` from the exact task-owned changed
Swift allowlist, including new untracked Swift files; validate every path exists
and reject an empty list. Do not select only `git diff` tracked files or include
unrelated changes. Record that list in the evidence manifest. Strict changed-file
SwiftLint must pass; retain repository baseline exceptions separately.

If the exact scratch command fails due to module-cache permissions, record its
failure and retry with absolute repo-local `CLANG_MODULE_CACHE_PATH` and
`SWIFTPM_MODULECACHE_OVERRIDE` under the evidence directory, recording full env.
If listeners cannot run, retain the failed log and identify the exact bounded
environment cause. Run the same filters on a capable host against matching full
source/test manifests before and after execution; record the actual host argv,
environment, logs and exits. Do not treat P1-6b host evidence or a reduced filter
as P1-6c acceptance. Unavailable host evidence remains an explicit verification
gap. No blanket test skipping or unrelated baseline repair. Packaged workflow,
prompt, script and skill files are outside this plan, so package digest refresh
is unnecessary unless a
subsequently accepted edit actually changes a packaged workflow/prompt/skill.

### Completion criteria

Both live-test decisions retain verified ID, kind and causal evidence; any
new justified production or expectation correction passes an affected capable-host rerun
without weakening replay/accounting assertions. All matrix behaviors have
passing final-source evidence, or bounded environment
failures are recorded alongside passing source-matched capable-host evidence.
Catalog/projection gates pass. All 24 original assertions and any new failures
have explicit evidence-backed dispositions; no unknown or material slice failure
remains. Broad failures stay failed with follow-up ownership, and unrelated
residuals require independent slice-only acceptance.
Strict lint and compile pass; independent integrity/adversarial/Astra decisions
accept the exact tree without high/mid findings. Documentation accurately reports
request acceptance versus terminal acknowledgment. Progress records review/log/
hash evidence and exact committed/pushed files. Only then mark P1-6c complete;
P1-6d, P1-7a/b and parent P1 remain open. Do not reuse the historical P1-6b task
checkboxes, hash comparison or host receipt as new-slice completion evidence.

**Current status:** Source-matched capable-host cancellation selections pass;
catalog/projection repairs, complete assertion classification, final-source
affected gates, reviews and publication are pending. No implementation task is
marked complete solely by this planning refresh.

### Current planning author self-check

Step 3 `comm-000004` accepted the host-evidence/classification design with empty
findings/feedback. Step 5 has not reviewed these revised plan bytes. One plan
`p1-dispatch` retains `dependsOn: []`; its internal DAG orders receipt checks and
classification, serial conditional repair, preserved seam verification, final
gates, independent reviews, serial reconciliation/docs and Astra acceptance
before publication. No user decision, new architecture or branch is introduced.

Run `python3 tmp/p1-6c-step4-host-refresh/self-check.py`; complete log:
`tmp/p1-6c-step4-host-refresh/self-check.log`. It checks design hash, metadata/DAG,
write paths, task and command coverage, preservation of every other tracked and
untracked input file, unchanged index and whitespace. Planning checks do not
claim Swift, lint, implementation-review or publication acceptance.

---

## Historical P1-6b completed contract

### Intent, context, and non-goals

Independently review and conditionally finalize the existing task-run result and
allocation-free dry-run WIP on `feat/remaining-impl-plans`, planning checkpoint
`788d45a44f1da19ea2a85f311ace19a8eec31202`, retaining accepted P1-6a dispatch.
The eight Swift changes, unchanged SQLite helper and plan/progress/design edits already exist; preserve
them. Recheck actual status before review; never reset changes. Coding may be
re-dispatched only for an independently proven material defect.
The supplied effective workflow input and runtime provenance are authoritative.
Do not inspect the executing package or scoped registries.

No director, human-decision/cancellation redesign, legacy removal, new examples,
new schema, general persistence framework, new dependency, broad formatting,
main merge, worktree creation or unrelated baseline repair is authorized.
P1-6c/d, P1-7a/b and parent P1 remain open. Existing examples are regression
fixtures only. Preserve other sessions/worktrees, including Monja tenant-sharding-d48.
Codex references are workflow identities; no Cursor adapter or source-parity task applies.

### Ownership, dependencies, and safe edits

`dependsOn: []` means no newly scheduled external plan; P1-6a is an accepted
prerequisite at the commit above, not work to rerun or reopen. The metadata DAG
orders evidence audit → result/read-only reviews → combined verification →
conditional finalization. Native Riela owns dependency-ready review waves;
this node creates no implementation fanout.
All listed paths are exclusively owned by this single implementation owner;
reviewers inspect without edits. The write set is a ceiling, not a demand to
change every file. All code/test edits are conditional on an independently proven material defect.
The two focused test files already exist and are included in host evidence. No other path is implicitly writable: a needed
path expansion requires a concrete finding, exact path and bounded plan/review
amendment before editing, not a blanket new abstraction or unrelated repair.

Current reviewed repair: the live zero-byte-WAL immutable amendment was
withdrawn. `Sources/RielaSQLite/SQLiteDatabase.swift` has no diff and must retain
its baseline behavior. Confirm canonical first-match store selection, private
preview copies, rejection of nonempty WAL, and original main/WAL/SHM byte and
inventory comparisons after copying and before ready/wait output. Confirm
live WorkStore/TaskDispatcher reads retain their prior SQLite mode. Read the
original test-integrity, adversarial and Astra reports under
`tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/`; record each actual
artifact path, reviewer identity, final hashes, findings and decision. Progress
summaries alone are not independent acceptance. If an original decision cannot
be substantiated, report that specific evidence gap and obtain the required
independent review; do not infer a code defect or rerun passing tests by default.

Before each edit, fresh-read the file and capture SHA256 plus an immutable
intent snapshot under `tmp/work-runtime-p1/p1-6b/attempt-N/` recording intended
hunks and accepted requirement. Record post-edit hashes. Compare predecessor
hashes at every handoff; preserve unexpected changes, invalidate affected
verification, and reconcile serially instead of restoring whole files. No
concurrent Git operations or private implementation branches. Before native implementation/review fanout, Step 5 must accept this plan
and the serial checkpoint gate must commit the accepted design and plan with
an exact documentation-only allowlist, preserving all existing Swift and
progress WIP. This author node does not commit or preempt Step 5. No coding
fanout is requested: the default work is evidence confirmation. Any conditional
material repair follows accepted plan/checkpoint gates. Final implementation
commit/push remain downstream of independent acceptance. Reconcile checkpoint
publication serially before final commit so native push gates do not receive
an unexpected stack of unpublished commits.

Workers append only to `impl-plans/progress/p1-dispatch.md`. Shared indexes,
lockfile generation, formatting and global archiving are reserved for serial
finalization and are unnecessary for this slice. Never archive this parent plan.
If native join supplies change evidence, the serial integration owner compares
all intended hunks and hashes and repairs overwritten accepted behavior before
independent combined-tree review.

### Tasks and exact deliverables

All boxes below are current evidence-confirmation/finalization gates, not
instructions to redo prior coding or discard prior reviews. Result/read-only
review tasks first confirm the existing independent decisions on final hashes;
new review is required only where evidence is missing or a material concern remains. Historical completed implementation remains recorded in progress.

- [x] **P1-6b-audit** (wave 1, single owner): Fresh-read accepted §17.5, the nine
  Swift files in `writePaths`, both exact manifests and complete host log.
  Recompute nine hashes, inventory current diff/untracked files and record
  source identity plus the host command/exit 0/198 tests. Preserve the earlier
  sandbox aggregate as failed, exit 1, including 24 listener/dependent failures.
  Deliver an evidence inventory and review inputs in repository-root `tmp/`.
- [x] **P1-6b-results** (wave 2, independent test-integrity review, read-only):
  Inspect `Sources/RielaCLI/TaskDispatch.swift`,
  `Tests/RielaCLITests/TaskCommandParsingTests.swift`,
  `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`, and
  `Tests/RielaCLITests/TaskRunResultTests.swift`. Trace text/JSON placement,
  ready/wait without allocation, typed reasons, nonzero failure exits,
  pre-admission failure envelopes and exact durable reserved attempt/session
  IDs after admitted errors. Inspect read-only fixtures and snapshots in
  `Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift` for real APIs, complete
  row values and nonmutating observation. Deliver findings with severity,
  paths, concrete evidence and an explicit private-copy repair accept/reject
  decision; no edits or inferred pass from row counts alone.
- [x] **P1-6b-readonly** (wave 2, independent adversarial review, read-only):
  Trace `Sources/RielaCLI/TaskDispatch.swift`,
  `Sources/RielaCLI/HostCapabilityResolver.swift`,
  `Sources/RielaWork/TaskDispatcher.swift`, `Sources/RielaWork/WorkStore.swift`
  and `Sources/RielaSQLite/SQLiteDatabase.swift`. Verify no writable fallback,
  initialization, migration, checkpoint, quarantine, profile persistence,
  reservation, pending-request consumption or launch on preview. Assess
  absent/corrupt/incompatible stores, profiles and sidecars; byte/inventory and
  row-value invariance includes `work_hosts`. Corrupt undecodable data requires
  diagnostic and byte invariance, with row comparison explicitly inapplicable.
  Assess zero-byte/absent WAL handling, rejection of nonempty WAL before either
  store opens, shared-reader compatibility and concurrent-writer races. Deliver
  a separate explicit private-copy repair accept/reject decision and material
  findings supported by evidence, not hypothetical hardening requests.
- [x] **P1-6b-verification** (wave 3, serial join and independent Astra
  combined-tree integration review): Join both reports and recheck all hashes.
  Astra explicitly decides the private-copy repair and combined result/placement/
  reservation contract against accepted §17.5 and P1-6a regression evidence.
  All three reviews must have no unresolved material correctness, data-loss,
  security or verification defect. Only an independently demonstrated defect
  authorizes a serial repair: record finding, exact affected paths, pre/post
  hashes and intent; change the smallest required behavior/test in the allowlist,
  rerun affected compile/tests/lint below, then repeat affected independent
  reviews on the repaired tree. If another path is necessary, obtain a bounded
  plan/review amendment first. Preserve unexpected drift and reconcile serially.
  Unchanged bytes reuse completed host gates; never rerun solely because this
  is a new workflow. Deliver final hash manifest and all three review decisions.
- [x] **P1-6b-finalization** (wave 4, downstream serial workflow gates): After
  acceptance, align §17.5 and P1-6b plan/progress evidence. The README Work
  Runtime section lacked the accepted read-only preview and result contract;
  include its bounded Step 8 amendment in publication.
  Append commands, terminal exits, positive suite counts, complete logs, hashes,
  retained-code attribution and independent decisions to
  `impl-plans/progress/p1-dispatch.md`. Step 9 explicitly records P1-6c/d,
  P1-7a/b and parent P1 open and retains this active plan. Emit the exact reviewed
  file allowlist (the eight changed Swift files plus README and directly affected
  design/plan/progress; exclude reverted `SQLiteDatabase.swift` and already
  committed checkpoint-only docs from a later commit).
  Native commit/push gates publish only accepted files, non-force to
  `origin/feat/remaining-impl-plans`, verifying matching accepted commit/push
  evidence. No broad staging, tmp files, force push, main merge or unrelated
  worktree changes. No workflow/prompt/script/skill change or digest refresh.

### Invariants and acceptance matrix

| Accepted requirement | Passing evidence |
| --- | --- |
| CLI parsing and typed text/JSON | Valid and invalid parsing; shared option precedence; text placement; typed diagnostics; correct nonzero failure exits |
| Exact identity and wait reason | Output IDs equal reserved durable rows on successful and failed admitted runs; ready/wait allocate nothing; wait reason matches dispatcher |
| Read-only dry-run | Same resolution/prospective placement, all byte/inventory/row-value checks unchanged across the matrix above; no misleading stale WAL read |
| P1-6a preserved | Final-source reservation and selected-worker/callee execution regression gates pass |
| Bounded publication | Independent test-integrity/adversarial/Astra integration acceptance, including the private-copy repair, without unresolved material finding, exact file allowlist, matching committed/pushed hash; later slices open |

A preview is not a launch promise: real admission still rechecks dependency,
version, budget and capacity races. Do not add a second direct-mutation path or
weaken authentication, placement pinning, reservation tokens or uncertainty fences.

### Exact verification and evidence

All commands run in the foreground from repository root. Capture full stdout
and stderr, exact argv/environment, start/end timestamps, terminal exit code,
per-suite positive test counts and final relevant source SHA256 inventory in
`tmp/work-runtime-p1/p1-6b/attempt-N/verification-evidence.json`. Use immutable
numbered attempts, the log names below and the existing shared scratch path;
never run SwiftPM gates concurrently against it. Poll every yielded session
through terminal exit. Incomplete logs, timeouts and zero/absent selected suites
are failed/blocked checks, never passes. Reuse only evidence matching final
relevant sources and fixtures; unrelated documentation edits alone do not
invalidate Swift tests. The recorded host pass is reused evidence, not a fresh run by this plan author.
The commands below are conditional rerun gates; do not execute them all by
default on unchanged source bytes. The host aggregate in metadata includes
`SQLiteDatabaseTests`, both focused files, V1/V2/V4/V11 and parsing; use its
exact command for a full affected aggregate rerun on a listener-capable host.
A listener-denied run remains failed; retain its complete log and exit.

**Always-run source identity — hash-check.log**

Run this command before reviews and again before finalization. Capture its full
output and exit; any mismatch invalidates affected evidence and requires drift
reconciliation before acceptance. A documentation-only change does not invalidate
these nine Swift hashes.

```bash
python3 - <<'HASHCHECK'
import hashlib, json
from pathlib import Path
host = json.loads(Path("tmp/work-runtime-p1-6b-host-final/evidence.json").read_text())
prior = json.loads(Path("tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/plans/p1-dispatch/attempt-1/verification-evidence-final-source-v2.json").read_text())
assert len(host["sourceHashes"]) == 9
for path, expected in host["sourceHashes"].items():
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    print(path, actual, flush=True)
    assert actual == expected == prior["sourceHashes"][path], path
print("PASS: 9/9 hashes match both manifests")
HASHCHECK
git diff --check
git diff --cached --check
```

Record each command's own exit code, not only the last shell command. Inspect
`tmp/work-runtime-p1-6b-host-final/aggregate.log` and the prior manifest's complete
logs; record the host aggregate's exact metadata command, exit 0, 198/198 and
per-suite counts separately from the failed sandbox run. The hash comparison
alone is not behavioral acceptance. Repaired bytes require a new manifest;
never overwrite the original evidence or claim old hashes match new code.

**V0 compile/typecheck — build.log**

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**Parsing — parsing-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests'
```

**V1 focused behavior — focused-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation regression — reservation-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V4 capabilities/profile regression — capability-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V11 selected-host regression — selected-host-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

V1 retains each named suite, including existing task examples; it does not
certify later slices. Require positive counts for each selected suite. V2 proves
reservation/cancellation/budget compatibility. V4 proves placement and profile
read compatibility. V11 proves real selected-host and exact-session behavior.
The two focused test files are already present. If their evidence is invalidated,
run their gate and require a
positive count for each created suite (adjust the filter to the created names
and record exact argv; never report a missing suite as passing):

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

If store evidence is invalidated, also run:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreTests|TaskCommandTests|SQLiteDatabaseTests'
```

Before lint, build `tmp/work-runtime-p1/p1-6b/changed-swift-files.nul` from the
reviewed exact changed/new Swift paths relative to the accepted implementation
baseline; include newly created files, exclude unrelated changes, record the
list in evidence and require it nonempty. Never invoke xargs with an empty list.
**Strict changed-file lint — swiftlint.log**:

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6b/changed-swift-files.nul
git diff --check
git diff --cached --check
```

Capture diff checks as `diff-check.log` and `cached-diff-check.log` respectively;
the cached check is repeated by finalization after accepted staging. Inspect
changed Swift file sizes and keep files within the skill's 1000-line rule using
the named focused test files, without broad unrelated extraction. Build/tests
must compile touched modules. Broaden only for a concrete shared-path risk or
new failure; record exact additional command and reason. Pre-existing failures
remain failures: require an explicit independent bounded disposition, never
suppress them, count a failed gate as passing or repair unrelated baseline work.

### Completion and progress state

| Item | Current slice state |
| --- | --- |
| P1-6a | Accepted prerequisite at 2f10916; preserve |
| P1-6b | Nine final Swift hashes match both manifests; host aggregate passed 198/198, including listener-backed selected-host/HTTP cases. Independent test-integrity, adversarial and Astra combined-tree reviews accepted with no material finding. Commit `7d8fc12` was non-force pushed; the resumed workflow completed. |
| P1-6c/d, P1-7a/b | Deferred/open |
| Parent P1 | Open; no global certification or archiving |

No unresolved user decision or design defect was identified. Progress entries
must distinguish source inspection, actual verification and independent
acceptance; record exact retained files, concrete repairs, hash drift and
invalidated/reused evidence. Design/plan acceptance is not implementation
acceptance. Finalization requires all scoped acceptance rows and reviewer
findings resolved, matching final-source evidence and exact accepted publication.

Current final-source follow-up (2026-09-24): Step 3 accepted §17.5 via
`comm-000004`, with no findings. All nine current hashes match the final host
and Step 6 v2 manifests. The host complete log confirms 198/198, recorded exit
0; prior safe suites are 169/169 and 15/15, and strict changed-file SwiftLint
records exit 0. Preserve their exact commands/log paths from the manifests.
The sandbox aggregate remains failed, exit 1 with 24 failures. The preserved
Step 6 runtime payload records the original test-integrity and adversarial
acceptances and Astra's source acceptance with verification withheld. Its
verbatim reviewer transcripts are unavailable; fresh read-only test-integrity,
read-only behavior, and Astra combined-tree reviews accepted the same nine-hash
tree with no material finding. The host 198/198 closes the recorded verification
condition. Serial commit/push evidence remains pending; no user decision is required.

### Historical evidence chronology (superseded by current follow-up)

Operator-host follow-up after Step 6 terminal (2026-09-24): the nine Swift
source/test hashes in `tmp/work-runtime-p1-6b-host/evidence.json` match Step 6's
`verification-evidence-exact.json` before and after the host run. Using the
already resolved SwiftPM scratch path, the full P1-6b selected aggregate,
including listener-backed `TaskDispatcherIntegrationTests` and
`DistributedWorkerHTTPTests`, passed 194/194 with exit 0. The complete command,
log and exit are in `tmp/work-runtime-p1-6b-host/evidence.json` and
`aggregate.log`; `git diff --check` passed. This replaces the sandbox-only V11
verification gap for these unchanged source bytes, but it is not independent
review or publication acceptance. The SQLite shared-path amendment, remaining
P1 slices and parent P1 still require their own decisions.

Step 6 review continuation (2026-09-24): independent test-integrity and
adversarial reviews rejected the live zero-byte-WAL immutable amendment after
identifying a concurrent-writer race. `SQLiteDatabase.swift` is restored to
the checkpoint bytes. Preview now resolves stores in canonical first-match
order using private database copies, rejects nonempty WAL, and checks original
main/WAL/SHM bytes before returning ready or waiting. Live WorkStore and
TaskDispatcher reads retain their baseline SQLite mode; only private copies
use immutable reads. New tests cover an intervening writer, first-match scope,
and text/JSON admitted failure identities. Test-integrity, adversarial, and
Astra combined-tree source reviews accept this repair with no remaining
material code finding. Current-source safe suites passed 169/169 and 15/15;
strict selected-file SwiftLint passed. The final-source sandbox aggregate ran
198 tests and failed with 16 listener denials and eight dependent expectation
failures (exit 1). The prior
host 194/194 pass has six mismatched Swift hashes and cannot certify the
repair. Final-source listener-capable aggregate, publication review, exact
commit and non-force push remain pending. Complete logs and hashes are under
`tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/plans/p1-dispatch/attempt-1/`.

## Historical parent-plan reference — not executable in this invocation

The following pre-P1-6b parent narrative is retained to preserve later work and
historical evidence. Its former scope, unchecked P1-6a status, predecessor
inventories and broad gates are superseded for this invocation by the current
contract above. Do not schedule, certify, update indexes for, or execute its
later tasks as part of P1-6b. Historical metadata is available in Git at
`2f10916a14501af68fd7e7f63cb91f244a343f8c` under this same plan path.

## Intent, authority and repository context

Complete every unchecked P1-6a–d and P1-7a–b requirement by reconciling retained
implementation, including necessary reservation, guard, capability and shared
applier repairs. Accepted design §17.7 governs this single plan; older six-plan
scheduler metadata is historical. The complete effective implementation input
is this file alone. `dependsOn: []` means no external scheduler predecessors;
it does not waive the internal prerequisite gates below. Supporting reservation,
guard/director, capability and finalization plans supply reference detail only;
do not launch or implement them as additional work packages.

Inspected HEAD is `f46ff788d522b6e53631862253fdcbcf17adfb1a` on
`feat/remaining-impl-plans`, also the deliberate base branch; supplied upstream
is `origin/feat/remaining-impl-plans`. Preserve the intake’s 93 retained files
(49 tracked, 44 untracked, zero staged) and the accepted Step 2 design edit.
Step 4 therefore starts with 50 tracked changes and 44 untracked files; its
plan edit adds one tracked change. The older 50/44 inventory predates the
f46ff788 checkpoint; reconcile exact paths/hunks rather than using counts
as ownership evidence. These include
dispatch, capability and example code. The CLI still rejects
`.director` dispatch in `Sources/RielaCLI/TaskDispatch.swift`; the retained
`AgentDirector.validate` escalates all accept output. Reconcile these concrete
P1-6d gaps; do not replace retained code wholesale or certify it from inventory.
Step 4 edits only this plan and preserves all prior source/design/progress work.

Runtime provenance is authoritative. Effective input requires the immutable
user-scope workflow package and supplies no minimum or exact version.
No contradiction exists; do not inspect, repair or validate registries or the
executing package from this node. No worktrees, private branches, concurrent
Git mutations, or changes to other directories/sessions. Preserve all unrelated
work and Monja tenant-sharding-d48. Commit/push of accepted P1 and necessary
documentation are authorized; finalization remains gated below.

Non-goals: P2–P7, loop-engineering, agent-node-output-contract, workflow defect
detection, Tauri, Note, gateway SDK, Monja implementations, task serve, new task-create CLI, remote
authentication, planner frameworks, compatibility/migration for removed
auto-improve state, recursive director repair, proposals, specialist classifiers,
optional hardening, style-only changes, broad cleanup or formatting. Preserve
accepted workflow-defect documents. Record external dependencies rather than
absorbing them. The supplied local Codex reference root
`../../codex-agent` is absent in accepted design evidence. Agent references are
execution provenance, not parity claims. Cursor-specific invocation/auth/probe/
heartbeat behavior stays in existing adapters; no cross-backend equivalence.

## Internal dependency gates and ownership

One implementation integration owner executes this plan. The DAG in metadata
orders tasks within this package; it is not a list of missing external plans.

| Wave | Tasks | Deliverable / gate |
| --- | --- | --- |
| 0 | P1-AUDIT | Fresh retained-diff attribution, source hashes, lint baseline, existing interface inventory; run canonical sandbox regression without editing workflow/package artifacts. |
| 1 | P1-PREREQ-R | Verify/repair only reservation primitives needed by §17.2: atomic rollback, dependency/version race, unique exact session, single-use digest token, uncertain launch fence, pending request consumption and durable cancellation acknowledgment. V2 and relevant store tests pass. |
| 2 | P1-PREREQ-L | Verify/repair §17.2–17.3 guard, deterministic ordering, causality, replay, store completion and budget enforcement. V3 passes against accepted reservation hashes. |
| 2 | P1-PREREQ-C | Verify/repair §17.4 reachable requirements, bounded probes, declarations, freshness, placement and host/planner inputs. V4 passes against accepted reservation hashes. |
| 3 | P1-6a, then P1-6b/c | Wire real exact-session dispatch, preview and human decisions; prerequisite checks must already pass. |
| 4 | P1-6d | Bounded child execution and authoritative judged-work acceptance; focused store, director and CLI integration checks pass. |
| 5 | P1-7b, then P1-7a | Task-backed examples and before-removal replacement evidence, then legacy removal and after-removal evidence. |
| 6 | P1-FINAL | Serial join/repair, aggregate tests/lint, author self-review, single adversarial implementation review, combined-tree review, docs/index reconciliation and final publication handoff. |

Independent investigation of lifecycle and capabilities may run in parallel
only after reservation interfaces are stable. Implementation overlap in schema,
store, CLI and tests is serialized, even within the same wave. P1-6b/c may use
parallel read-only investigations; the integration owner writes their shared
files. Child investigators return evidence to this plan's owner, who alone
appends `impl-plans/progress/p1-dispatch.md`. Do not edit another worker's log.
No additional executable plan files are created for tightly coupled repairs.

Each prerequisite handoff records source hashes, concrete interface signatures,
owner, exact passing command/log/final exit, positive suite counts and review
status. Inspect current code before deciding repair is needed. Unchanged code
can pass with fresh behavioral evidence; never invent changes or accepted IDs.
Failure blocks dependent tasks, while independent investigation may continue.
The canonical sandbox check concerns checked-in real payloads only; a failure
outside accepted P1 scope is reported as a dependency with command/log/exit,
not repaired through package rediscovery or unrelated workflow implementation.

After Step 5 accepts, the serial workflow checkpoint gate commits exactly the
accepted design and this plan before any native implementation/review fanout.
It preserves the existing index and excludes retained source, tests, progress
and scratch. Push that checkpoint before final git-push so exactly one
unpublished final commit remains. Record the checkpoint hash and publication
evidence; do not leave checkpoint commits stacked below an unpublished final
commit. This Step 4 neither commits nor certifies implementation. Later
final commit/push contains only accepted P1 implementation and necessary docs.

## Edit integrity and evidence ownership

Before EVERY edit, including deletion and retry, fresh-read the file and
contract; record pre-edit SHA-256 (or absent sentinel), original bytes, exact
paths, accepted requirement and intended behavior under immutable numbered
`tmp/work-runtime-p1/p1-dispatch/intents/` directories. Recheck hash immediately
before writing. On drift, stop, reread and create a new intent; never overwrite
from stale buffers. Record post-hash, exact diff and preserved behaviors.
After join, compare semantic changes to intents, repair serially and rerun
invalidated gates. Hashing alone cannot eliminate races; runtime change evidence
and independent combined-tree review remain required if work fans out.

Materialize exact paths from metadata globs before edits; metadata is a scope
ceiling, not permission to modify unrelated hunks. Necessary helper extractions
require exact-path ownership and accepted-requirement evidence first. Keep
builds/source verification stable: serialize commands against a stable source
snapshot and compare relevant source hashes before/after each run. A source
change during testing invalidates certification. Lockfile changes, all shared
indexes, final commit allowlist and any archiving are serial-only. No broad
formatting; no global archive or unrelated lockfile update is needed here.

## Prerequisite file-level repair map

The exact paths below belong to this plan's serial integration owner only for
necessary P1-6/7 prerequisite repair. Prefer proving retained code correct.

### P1-PREREQ-R

Atomic attempt/session/lease/decision placement commit, rollback, launch token, pending request and cancellation fencing. Preserve schema generation policy and P0 reads; use task-owned scratch stores, never reset user databases.

Exact repair/test paths:

- `Package.swift`
- `Sources/RielaWork/WorkModels.swift`
- `Sources/RielaWork/WorkStore.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaWork/WorkStore+Reservation.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Tests/RielaWorkTests/WorkStoreTests.swift`
- `Tests/RielaWorkTests/WorkStoreReservationTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`

### P1-PREREQ-L

Persist complete guard batch before action; stable priority/tie order, exact equality boundaries, last-admitted-attempt completion, budget admission, scoped causality, original replay and store-reconstructed completion. Human acceptance waives only requiresHumanAccept.

Exact repair/test paths:

- `Sources/RielaWork/WorkGuard.swift`
- `Sources/RielaWork/TaskGuardCoordinator.swift`
- `Sources/RielaWork/DeterministicDirector.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/CompletionEvaluator.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`
- `Sources/RielaWork/WorkDecision.swift`
- `Sources/RielaWork/WorkEvidence.swift`
- `Tests/RielaWorkTests/WorkGuardTests.swift`
- `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
- `Tests/RielaWorkTests/DeterministicDirectorTests.swift`
- `Tests/RielaWorkTests/DecisionApplierTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Tests/RielaWorkTests/CompletionEvaluatorTests.swift`

### P1-PREREQ-C

One reachable/called-node requirement set and merged finite-freshness snapshot; disable wins, explicit unprobed enable stays unverified, failed refresh is not stale success, pin never falls back, declared capacity/liveness and required executables/environment are enforced. Host/profile reads stay nonmutating for dry-run.

Exact repair/test paths:

- `Sources/RielaCore/BackendCapability.swift`
- `Sources/RielaCore/WorkflowBackendPolicy.swift`
- `Sources/RielaCore/WorkflowRequirements.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowNodeValidation.swift`
- `Sources/RielaCore/WorkflowValidationHelpers.swift`
- `Sources/RielaCore/DistributedWorkerModels.swift`
- `Sources/RielaAdapters/BackendCapabilityProbe.swift`
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`
- `Sources/RielaWork/BackendCapabilityPlacement.swift`
- `Sources/RielaWork/WorkStore+Hosts.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaCLI/DoctorCommand.swift`
- `Sources/RielaCLI/DistributedWorkerCommand.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`
- `Sources/RielaCLI/HostCapabilityResolver.swift`
- `Sources/RielaServer/DistributedWorkerProtocol.swift`
- `Sources/RielaServer/DistributedWorkerHTTPRouter.swift`
- `Sources/RielaServer/DistributedWorkerHTTPClient.swift`
- `Tests/RielaWorkTests/BackendCapabilityPlacementTests.swift`
- `Tests/RielaCLITests/DoctorBackendCapabilityTests.swift`
- `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`
- `Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift`
- `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`
- `Tests/RielaAdaptersTests/BackendCapabilityProbeTests.swift`
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`
- `Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift`
- `Tests/RielaAppSupportTests/HostCapabilityConfigurationTests.swift`

Additional retained integration paths are `Sources/RielaCLI/WorkflowValidationOptions.swift`,
`WorkflowCalleeResolution.swift`, `ServeHTTPCommand.swift` (all RielaCLI),
`Sources/RielaCore/WorkflowValidation.swift`, `DistributedJobController.swift`
(RielaCore), `Sources/RielaServer/DistributedControllerHost.swift`,
`DistributedWorkerLoop.swift` (RielaServer), and
`Sources/RielaApp/EntryPoint+DistributedController.swift`. Verify only capability
snapshot registration/forwarding and selected host/backend execution in those
paths; no UI redesign or distributed subsystem redesign. Required matching
regressions include `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`.
Add retained `WorkStoreCancellationTests`, `BudgetAdmissionStoreTests` and
`DecisionApplierCausalityStoreTests` under `Tests/RielaWorkTests` to prerequisite
gates so aggregate filters cannot hide these new regressions.

## Intended changes and acceptance (§17.2–17.5)

- [ ] **P1-6a** Compose TaskDispatcher with canonical stored plan/definition and
  runtime store resolution. Resolve selected entry, dependencies and placement
  before reservation. Missing plan/entry/dependency or invalid policy errors;
  unmet dependencies/capacity records its wait without attempt/session/lease.
  Atomically reserve and authorize, then run EXACT reserved session ID through
  the existing runner. Project terminal evidence before guard/completion and
  apply decisions through the shared applier. Refresh real dispatch placement
  once before reservation and use the chosen per-node backend/host in execution.
- [ ] **P1-6b** Ship task run <task-id> [--dry-run] with attempt/session IDs or
  wait reason. Dry-run follows identical resolution but opens state read-only:
  no create, migration, generation reset, checkpoint, host-cache, task, attempt,
  session, decision, lease or evidence writes. Missing/incompatible stores are
  diagnostics; fresh probes remain in memory. Prove byte AND row equivalence
  including work_hosts, SQLite sidecars and host profile configuration; an
  absent store stays absent and corrupt profile config is not quarantined.
- [ ] **P1-6c** task decide requires exactly one --accept, --reject <reason>,
  --rerun [step], --cancel plus --principal, --expected-version, --decision-id.
  Human principal is audit identity under existing local access, not new remote
  authentication. Validate action combinations and stable replay; call the
  applier, never direct row mutation. Ctrl-C uses this same durable cancellation
  path; terminal acknowledgment precedes fence release. Cover interruption
  during authorization, running, acknowledgment and pending rerun consumption.
  Existing authenticated remote manager paths keep their protections.
- [ ] **P1-6d** Wire one bounded optional agent-director child through ordinary
  workflow execution. Reconcile work attempt before entry: .director reservation;
  retain judged work TaskView, record child session/cost/attempt exactly once.
  Validate allowed P1 decision kinds and apply through the same causal/version/
  completion/budget checks. Invalid/forbidden/failed/budget-blocked output records
  evidence and needs human decision. No recursive director repair, replan,
  proposals or specialist classifier. Finish planner-variable host snapshot
  wiring through dispatcher workflow input variables using capability contracts.
- [ ] **P1-7a** FIRST establish replacement dispatcher behavioral tests for
  auto-improve inactivity, bounded retry, gate/failure recovery, cancellation
  and replay. Record passing exit/log before deleting the old implementation.
  THEN remove WorkflowRunCommand+AutoImprove.swift, WorkflowAutoImprovePolicy,
  WorkflowMutationMode, SupervisedScenarioNodeAdapter, supervision state/result,
  remote input.autoImprove/input.nestedSuperviser and removed flags. Discover
  exact references with rg; changes outside scoped files are serialized and
  assigned to this integration owner before edit. Preserve specialist/event
  supervisor dispatch, existing loop/routine behavior and plain workflow runs.
- [ ] **P1-7b** Replace examples/auto-improve, examples/default-superviser and
  examples/supervised-mock-retry with examples/task-repair-loop and
  examples/task-agent-director, each with mock-scenario.json and
  EXPECTED_RESULTS.md. TaskRuntimeExampleTests must drive real task lifecycle
  using deterministic fixtures: acceptance, gate recovery, guard stop, capacity
  wait; allowed director output, child accounting and invalid-output escalation.
  Workflow-only mock runs supplement these tests; they do not prove dispatch.

Deliverables: dispatcher/CLI composition, bounded director child, both example
bundles, removal of obsolete implementation and equivalent regressions. Keep
CLI addition and auto-improve removal in the same delivery cut; no publication
between them. Test real reserved-session execution, dependency/version races,
guard persistence failure, cancellation acknowledgment loss, replay crashes,
last-attempt completion, dry-run effects, and task-free plain workflow run.

## File-level implementation map and preserved invariants

Every row is limited to the accepted requirement named. New file names below
identify retained code or intended repair destinations; fresh-read actual APIs. Fresh-read existing
neighbors and accepted predecessor signatures before implementation; reuse
existing functions and avoid a generic framework. Extra helpers are allowed
only for necessary responsibility splits, with an exact-path serial assignment
and intent record first. The JSON writePaths list never authorizes unrelated
changes to a matched file. Prerequisite repair paths are assigned above; ownership transfers remain serial.

| Task / files | Intended change / required evidence |
| --- | --- |
| P1-6a: retained `Sources/RielaWork/TaskDispatcher.swift`; retained `Sources/RielaCLI/TaskDispatch.swift`; existing `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` in Sources/RielaCLI | Work coordinates accepted requirement/placement/reservation/decision contracts; CLI resolves canonical definition/store and bridges to existing runner using the reserved session ID and per-node host/backend. Project terminal evidence before completion/guard evaluation. Reuse runner execution; no RielaCore import of RielaWork. TaskDispatcherTests and TaskDispatcherIntegrationTests prove exact reserved ID, version/dependency races, wait without attempt/session/lease, stale launch rejection and projection-before-decision. |
| P1-6b/c: `Sources/RielaCLI/TaskCommands.swift`, `TaskCommandModels.swift`, `RielaCommand.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, retained `TaskDispatch.swift` | Add run/dry-run/decide parsing, typed result DTOs and text/JSON output. Preserve show/list and store-root precedence. Dry-run must select read-only dependency APIs before any loader that initializes/migrates/quarantines. Decide validates exactly one action, principal, expected version and stable ID. Route Ctrl-C through durable applier/runner cancellation, including pending-launch and acknowledgment windows. No second direct-mutation path. TaskCommandMutationTests and TaskCommandParsingTests assert parsing, replay and filesystem/row invariance. |
| P1-6a/c/d shared serial handoff: `Sources/RielaWork/WorkStore+Decisions.swift`, `TaskGuardCoordinator.swift`; `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`, `WorkGuardDispatcherTests.swift` | Consume and regression-test the accepted lifecycle implementation of scoped causality, reconstructed completion, original replay, atomic pending requests and live cancellation fencing. Only add narrowly necessary real-runner coordination after ownership transfer; complete lifecycle prerequisite repairs before dispatch integration. Coordinator must preserve complete guard-batch persistence before decisions. If durable outcome storage needs schema/model changes, assign the existing store/schema files to the serial integration owner and use existing storage; do not invent parallel storage. Add negative/rollback/crash/replay tests, not CLI-only checks. |
| P1-6d: retained `Sources/RielaWork/AgentDirector.swift`; `TaskDispatcher.swift`, `Sources/RielaCLI/TaskDispatch.swift` | One ordinary child workflow only when configured escalation needs it. Reconcile judged work before .director reservation; retain its TaskView; charge child attempt/session/cost once and use the same applier. Forward the accepted capability snapshot through planner workflow variables; no new planner. TaskDispatcherTests/TaskDispatcherIntegrationTests prove host input and selected backend delivery, last-admitted-attempt completion, invalid/forbidden/failed/budget-blocked child escalation and no recursion. Deterministic ordering is certified in P1-PREREQ-L. |
| P1-7a: `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` (delete after barrier), `RielaCommand.swift`, `ParsedWorkflowOptions.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, `WorkflowCommands.swift`, `WorkflowRunCommand.swift`, `ProductionNodeAdapter.swift`, `RielaCLIApplication.swift` | Remove actual policy/mutation types in RielaCommand, flags, option plumbing, execution branch, remote serialization and scenario wrapper. SupervisedScenarioNodeAdapter actually lives in RielaCLIApplication.swift (not an Adapters file). Reject removed autoImprove/nestedSuperviser remote fields rather than ignoring or forwarding them. Keep normal run, mock scenario and authenticated remote paths intact. Rewrite legacy tests as rejection/preservation regressions only after replacement coverage passes. |
| P1-7a conditional retained call sites: `Sources/RielaCLI/SessionCommands.swift`, `SessionCommandModels.swift`, `RielaCommand+SessionParsing.swift`, `LoopCommands.swift`; `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Remove only obsolete supervision plumbing/result fields tied to the deleted workflow path. Preserve loop/routine and specialist/event behavior and their stores; do not delete symbols merely for containing supervisor. Inspect callers/consumers before removal; contradictory retained behavior is a dependency blocker, not permission to redesign another plan. A newly discovered remote decoder outside listed paths requires exact serial ownership assignment before its narrow removed-input rejection edit and tests. |
| P1-7a regressions: `Tests/RielaCLITests/CommandParsingTests.swift`, `WorkflowCommandAutoImproveTests.swift`, `WorkflowCommandInspectionTests.swift`, `WorkflowCommandPackageLifecycleTests.swift`, `RielaExampleParityTests.swift`, `WorkflowRunHelpTests.swift` | Preserve equivalent scenarios in the four new dispatcher suites before deleting old tests. Assert removed flags/remote fields fail, plain runs create no task, help and package examples match; keep specialist supervisor, events, routines and loops green in V5. |
| P1-7b: `examples/task-repair-loop/` and `examples/task-agent-director/` each with `workflow.json`, required referenced `nodes/` and `prompts/`, `mock-scenario.json`, `EXPECTED_RESULTS.md`, `README.md`; `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` | Minimal deterministic bundles; tests create task fixtures through existing store APIs then drive actual task run/decision lifecycle with mock node execution, not merely workflow run or string assertions. Document acceptance, gate recovery, guard stop, capacity wait, bounded child output/accounting/escalation. Remove only the three legacy directories after V1 before-removal passes. No new task-create CLI. |

The four required suites are exactly
`Tests/RielaWorkTests/TaskDispatcherTests.swift`,
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` and
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift`. Integration tests use
real reservation/store/runner paths and deterministic injected node/probe/clock
boundaries; test doubles must not bypass the contract under test.

Invariant checklist for tests and independent review:

- Reservation atomically binds task version/dependencies, attempt, unique
  session, lease, placement and decision. Token is single-use and digest-only;
  no relaunch on uncertain authorization, lease expiry or heartbeat loss.
- Dry-run changes neither bytes nor rows across main DB, WAL/SHM, work_hosts,
  runtime/host cache and host-profile files; absent stores stay absent; corrupt
  profile input is neither rewritten nor quarantined. Compare inventories and
  content before/after with connections closed; include missing/incompatible state.
- Store causality cannot reference missing, foreign or stale attempt evidence.
  Latest-work verification/gates (with only the persisted bounded-child exception below) and applicable blocking findings govern
  acceptance; human accept waives only requiresHumanAccept. Identical replay
  returns original outcome even after later task changes; conflicting payload
  or fresh stale-version decisions fail without side effects.
- Guard batch persistence failure prevents all dependent action. Replay does
  not duplicate evidence or cumulative tokens. Gate visits use > limit; other
  used limits use >=; attempt budget limits the next admission and allows the
  last admitted attempt to finish. SDK heartbeat exemptions are preserved.
- Cancellation is durable before runner cancellation; fence release follows
  durable terminal acknowledgment. Test interruption before authorization,
  while running, during acknowledgment and during pending-request consumption.
- Placement consumes the dependency's one fresh merged snapshot. No pin
  fallback, implicit authentication, invented capacity, unreachable-node
  requirement or stale success after failed refresh. Chosen per-node backend/
  host and planner snapshot reach execution; capability validation is not a token.


## Resumption execution detail from accepted §17.7

These tasks complete the retained implementation; they do not restart it or
certify existing checkmarks. Step 3 accepted this revision with empty findings
and feedback; no Step 5 revision request was delivered. Preserve the prior
attempt evidence in `impl-plans/progress/p1-dispatch.md`, including attempt 3
from `nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`
and its logs under `tmp/p1-dispatch-step6-attempt3/`. The second workflow run
ended at `implementation-blocked-output`; neither its findings nor partial
passing suites certify the implementation or exhaust the remaining paths.
Use new numbered evidence directories; never overwrite prior logs.

Retained source now resolves reachable workflow/add-on requirements and sums
wall-clock durations from exact durable attempt sessions. Preserve these changes
and reverify them rather than reimplementing from the older gap inventory.
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` already supplies
`agentSandbox: .readOnly` in the previously failing callee fixture. V1 must
rerun that case and the cumulative wall-clock case on final source; a historical
passing rerun is not final acceptance.

### P1-AUDIT and P1-PREREQ-L: data flow beyond the reported gaps

Fresh-read `Sources/RielaCLI/TaskDispatch.swift`,
`Sources/RielaWork/TaskGuardCoordinator.swift`, `WorkGuard.swift`,
`DeterministicDirector.swift`, `WorkEvidence.swift` and `WorkStore+Decisions.swift`
(the last five under RielaWork). Trace cumulative wall-clock, token accounting,
repeated findings, gate visits and live heartbeat input from actual attempts
into guard evaluation. Inventory every unchecked criterion, its current test
and missing behavior. Reconcile the progress log's older claims against source.
Repair only broken accepted contracts. Extend `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
and `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` to prove cumulative
multi-attempt budgets, repeated findings, stable simultaneous-violation order,
inactivity and successful completion of the last admitted attempt. No new
attempt may evade budget through human, agent or warning paths. V1/V3 must
exercise these cases; helper-only guard tests cannot certify dispatch input.
For repeated findings, use the existing fingerprint identity across real task
attempts; assert the configured equality threshold persists the violation and
applies the ordered decision, while replay neither duplicates evidence nor
counts the same observation again. For inactivity, drive a configured
heartbeat-capable backend through the live runner with a deterministic clock;
assert threshold-triggered cancellation is durably acknowledged before any
replacement admission. Include below-threshold and SDK-exemption cases, and
assert heartbeat loss alone cannot release the one-live-attempt fence. Route
signals through existing runner/guard seams; do not add a monitoring service.


### P1-6a: called workflow and selected-host delivery

1. In `Sources/RielaCLI/TaskDispatch.swift`, use existing
   `WorkflowCalleeResolution.swift` to supply reachable called bundles to
   `Sources/RielaCore/WorkflowRequirements.swift`, including add-on/environment
   requirements. Resolve from the actual entry; preserve returns/joins and
   workflow/step/node provenance, exclude reused prefixes/unreachable nodes,
   visit cycles once and diagnose unresolved executable targets before reserve.
2. In `Sources/RielaCLI/HostCapabilityResolver.swift` and TaskDispatch, replace
   the local-only/no-workers composition with the existing configured topology.
   Preserve explicit worker/group assignments and one fresh merged evaluation.
   Use `Sources/RielaWork/BackendCapabilityPlacement.swift` and existing host
   storage; no new capability registry. Waits create no attempt/session/lease.
3. In `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift`,
   `WorkflowRunCommand.swift` and `WorkflowCalleeResolution.swift`, carry chosen
   host/backend/model into root and callee execution rather than rejecting all
   nonlocal/callee choices or filtering them out. Reuse configured distributed
   execution and existing authentication. Retain exact reserved session identity
   and single-use launch admission; deliver the snapshot through planner inputs.
4. Inspect and narrowly repair the existing distributed paths already listed:
   `Sources/RielaCore/DistributedJobController.swift`,
   `Sources/RielaServer/DistributedWorkerProtocol.swift`,
   `DistributedWorkerHTTPClient.swift`, `DistributedWorkerHTTPRouter.swift`,
   `DistributedWorkerLoop.swift` and `DistributedControllerHost.swift` (Server).
   Record an exact serial ownership intent before any additional seam is edited.
   Worker loss after admission cannot authorize local fallback or duplicate
   launch; preserve uncertainty fencing and durable session evidence.
5. Extend `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`,
   `WorkflowHostCapabilityTests.swift` (CLI),
   `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`,
   `DistributedJobControllerTests.swift` (Core), and
   `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Use deterministic
   owned worker fixtures through the actual handoff/worker completion path.
   Observe which worker executed, selected backend/model and exact reserved
   session evidence. Cover callee-only requirements, cycle/return/join/reused
   prefix, explicit assignments, missing target, unavailable capacity and
   post-admission worker loss. DTO-only placement assertions are insufficient.
   V1/V4/V11 pass before P1-6a closes; V5 certifies preserved distributed behavior.

### P1-6c: durable request to live execution to acknowledgment

In `Sources/RielaCLI/TaskCommands.swift`, `TaskDispatch.swift`,
`WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` and
`WorkflowRunCommand+SupervisionPersistence.swift`, connect the shared durable
cancellation request to the active runner and existing selected-host cancellation
path. Reuse `Sources/RielaWork/WorkStore+Decisions.swift` and
`WorkStore+Reservation.swift`; do not add another decision store or bypass them.
Human cancel/reject, guard stop/replacement and Ctrl-C persist before signalling.
Pending cancellation takes the acknowledgment path, never generic reconcile.
Require the exact cancelled terminal snapshot before fence release and task
terminal state; consume any replacement request once after acknowledgment.
Pre-launch cancel forbids authorization. Lost acknowledgment, write failure,
lease expiry or heartbeat loss retains the fence until explicit reconciliation.

Extend `Tests/RielaWorkTests/WorkStoreCancellationTests.swift`,
`WorkStoreReservationTests.swift`, `DecisionApplierStoreTests.swift` (Work),
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`TaskDispatcherIntegrationTests.swift` (CLI), and
`Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Exercise real running
cancellation locally and on the selected worker, authorization races, terminal
persistence failure, acknowledgment loss, reopen/replay and pending replacement
consumption. Assert no premature terminal task, stale launch or duplicate
accounting. V1/V2/V11 must pass; store-only acknowledgment tests are insufficient.

**P1-6c late-cancellation arbitration addendum (2026-09-24):** The shared
runtime SQLite commit is the arbitration point between a new cancellation
decision/request and the exact reserved session's ordinary terminal snapshot.
`WorkStore+Decisions.swift` and `WorkStore+Reservation.swift` reject a new
request when that snapshot is already terminal; both snapshot save overloads
in `SQLiteWorkflowRuntimePersistenceStore.swift` reject ordinary terminal
persistence while cancellation is pending. After request-first interruption
and owned observer join, `TaskRunCancellation.swift` persists the exact
cancelled terminal before acknowledgment. Stale live saves cannot replace a
terminal winner. Replay of an accepted decision remains available before
new-request validation. Production-boundary CLI tests and independent SQLite
connections must cover SIGINT/external request in both orderings, ordinary
success/failure, rollback, replay, exact acknowledgment and fencing.

Implementation and local deterministic tests are in progress. Completion still
requires a final-source manifest, build, affected tests, strict selected-file
SwiftLint, listener-capable focused evidence, serial aggregate classification,
independent test-integrity/adversarial and Astra acceptance, then documentation
finalization and exact-file publication. The historical 99/99 focused and
2,049/19 aggregate receipts predate this repair; the aggregate remains FAILED
with its 19 owned non-slice assertions. P1-6d, P1-7a/b and parent P1 remain open.

### P1-7b/P1-7a and final evidence investigation

Complete task-backed gate recovery and real bounded director child cases in
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift` and both example bundles.
The retained recommendation-only director test is not child lifecycle evidence.
Use the P1-6d linked-work cases below and prove exactly-once accounting on replay.
Record each scenario, test name and observed persisted outcome against
`EXPECTED_RESULTS.md`. Run V1 before any legacy deletion; only then perform
P1-7a and run V1 again. Preserve unrelated supervisor/event/loop/routine paths.

Investigate prior broad failures and the truncated XCTest aggregate as test
execution issues. For a truncated aggregate, retain the whole log and final
process exit, reproduce the last unfinished suite in the foreground, identify
premature process termination or harness behavior, then rerun the affected full
gate. A targeted success does not replace V5. Supply fixture-owned paths under
this worktree's tmp for tests requiring writable runtime state; do not inspect
or repair the executing workflow's scoped registry. Never weaken assertions,
skip required suites or classify incomplete zero exits as passing. Compare
unchanged-baseline failures without broadening product scope; record any
unresolved gate explicitly. Final acceptance requires complete passing evidence.

## P1-6d judged-work acceptance and child execution

Apply accepted §17.7 in `Sources/RielaWork/AgentDirector.swift`,
`WorkStore+Decisions.swift`, `WorkStore+Reservation.swift`, `WorkModels.swift`,
`WorkStore+Schema.swift`, `TaskGuardCoordinator.swift` (all RielaWork), and
`Sources/RielaCLI/TaskDispatch.swift`, `WorkflowRunCommand+TaskReservation.swift`
and `WorkflowRunCommand+SupervisionPersistence.swift` (RielaCLI), as required.
Reuse existing reservation/evidence persistence, not a second task store.

1. Replace the explicit director-dispatch rejection with one ordinary bounded
   child run after work reconciliation. Persist its relation to the judged work
   at child reservation in the same store transaction, using the existing
   durable record model or the smallest required typed extension. Record both
   attempt identities, child session and task identity; caller TaskView alone
   is not authority. Schema/model edits, if necessary, are serialized and
   covered by fresh/reopened store and rollback tests under existing policy.
2. Keep work TaskView stable across child execution, charge child attempt/cost
   once, and validate successful child output against configured allowed P1
   kinds. Invalid/forbidden/failed/budget-blocked output persists escalation and
   requires a human; never recursively invoke the director.
3. At shared application, validate persisted linkage, producer child session,
   same task, current version and child terminal state. Only that linked child
   may intervene after judged work; reject newer work or foreign/stale linkage.
   Reconstruct completion from the judged work's durable gates, verification,
   acceptance criteria and applicable blocking findings. Child success alone
   cannot accept work. Preserve latest-attempt enforcement for unrelated paths.
4. Remove the validator's unconditional accept escalation only once shared
   application can enforce those rules. Agent acceptance cannot waive human
   acceptance. Replays return the original result; neither replay nor child
   completion duplicates accounting or changes judged work evidence.
5. Extend `Tests/RielaWorkTests/AgentDirectorTests.swift`,
   `DecisionApplierStoreTests.swift`, `DecisionApplierCausalityStoreTests.swift`,
   `WorkStoreReservationTests.swift` and, for any storage-shape change,
   `WorkStoreTests.swift`; extend CLI `TaskDispatcherIntegrationTests.swift`
   and `TaskRuntimeExampleTests.swift`. Prove a valid allowed accept, child-only
   success rejection, newer-work rejection, foreign/missing linkage rejection,
   requiresHumanAccept rejection, current-version conflict, restart/replay,
   exact child session/cost/attempt accounting, and nonrecursive escalation.
   Test real shared store and runner paths; validator-only assertions do not
   establish this contract. Include passing last-admitted work and budget-blocked
   child admission independently.

## Common lint and validation contract

swift build is the Swift compile/typecheck gate. Swift edits follow the local
Swift skill: keep touched code responsibility-based, avoid speculative
abstraction, and split touched non-generated files over 1000 lines by actual
responsibility without unrelated cleanup. Include necessary extracted paths in
serial ownership records. Do not weaken tests or lint to accept retained WIP.

Before any implementation edit, the integration owner captures repository lint
baseline; the integration owner records that immutable log/hash. After edits,
materialize exact existing changed/new Swift paths from its intent records in
`tmp/work-runtime-p1/<planId>/changed-swift-files.nul`; do not rely on git diff
alone because it omits untracked files and predecessor commits. The plan ID below is fixed for this package.
The metadata above contains the exact p1-dispatch commands.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

Skip xargs only for an explicitly empty Swift write set; strict touched-file
lint gates acceptance. Repository-wide output is a recorded baseline check:
fail new diagnostics attributable to this work, report existing unrelated ones,
and do not broaden edits to clear them. If a tool is unavailable, record a
blocked gate and environment error, not success. Run required focused tests,
then the broader V5 gate once on the joined tree; repeat only after
new changes/failures. No web code is planned, so browser E2E is not a P1 gate.

## Verification contract

All commands run in the foreground from repository root. Create
`tmp/work-runtime-p1/p1-dispatch/` first. Capture full stdout/stderr, command,
start/end, final exit status, and positive executed test count in
`verification-evidence.json` there and in the progress log. Poll yielded handles
through terminal exit. Timeouts, incomplete logs, absent suites and zero tests
are failures/blocked checks, never passes. Log basenames below are mandatory;
use immutable numbered attempt subdirectories on retries and distinct
`before-removal/` and `after-removal/` directories for V1. Build caches remain
`tmp/work-runtime-p1/build/p1-dispatch`. Never use shell orphaning or detached
processes. No implementation commands below have run during Step 4; these are downstream requirements.

### Commands and evidence

**V0 compile/typecheck**, log `build.log`:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**V1 required focused behavior**, log `focused-tests.log`. Run once before any
legacy deletion and again on the final removal tree. All four named suites
must exist and execute positive counts; an aggregate count alone cannot hide
an absent suite. It establishes every P1-6/7 acceptance row above, including
real task-backed examples and dry-run file/row comparisons.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation readiness/regression**, log `reservation-tests.log`. Require
atomic rollback, duplicate IDs, concurrent independent connections, stale
version/dependency, token replay, uncertainty fence, pending request consumption
and durable cancellation tests from the stable P1-PREREQ-R revision.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V3 lifecycle readiness and shared-applier regression**, log
`lifecycle-tests.log`. Require positive counts for each suite and behavioral
proof of the shared file map and invariant checklist, stable simultaneous
violation ordering, gate recovery budget and latest-attempt completion.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
```

**V4 capability readiness**, log `capability-tests.log`. These suites/interfaces
are certified by this plan’s P1-PREREQ-C gate, not a separate scheduled plan. Require
selected-entry/called-workflow resolution, deterministic placement, finite
freshness and failed-refresh handling, host declarations, read-only profile
loading, probe redaction and planner snapshot contract; every suite must run.
Absent suites make readiness blocked even if the test command exits 0.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V5 joined-tree regression**, logs `work-cli-core-tests.log` and
`adapter-server-graphql-tests.log`. Work/CLI/Core are mandatory for the planned
shared changes, retaining P0 read/projection/store, plain runner, parser/help,
loop/routine/specialist/events, surface catalog and remote forwarding behavior.
Both commands are required for the retained capability/profile and planned
shared runtime changes. Do not
weaken unrelated failing tests: classify baseline versus caused failures and
report blocked verification explicitly.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
```

**V6 strict touched-file lint**, log `swiftlint-changed.log`. The NUL manifest
contains all surviving new/modified Swift paths from intent/change evidence,
including untracked files, with no deleted paths. Require no strict diagnostics.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
```

**V7 repository lint baseline/comparison**, logs `swiftlint-baseline.log` before
edits and `swiftlint-repository.log` after. Record each exit and compare full
diagnostics; do not fix unrelated baseline issues or call unavailable lint a pass.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

**V8 bundle validation/supplemental workflow mocks**, logs respectively
`repair-validate.log`, `repair-mock.log`, `director-validate.log`,
`director-mock.log`. All four exit 0; compare results with each bundle's
EXPECTED_RESULTS.md. These checks do not replace V1's actual task lifecycle.
Only run on the newly built executable after V0. No real credentials required.

```bash
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-agent-director --output json
```

**V9 removal inventory and diff**, logs `legacy-reference-audit.log`,
`git-diff-check.log`, `git-diff-cached-check.log`. For rg, exit 1 means no
matches, 0 requires classification of every retained match (rejection tests,
historical docs or unrelated specialist/event behavior), and >1 is an error.
Never delete all supervisor-name matches. Diff checks require exit 0; cached
check runs at the serial plan/final commit gate after the exact allowlist is staged.

```bash
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
git diff --check
git diff --cached --check
```

**V10 canonical payload prerequisite**, log `sandbox-tests.log`. Require positive
executed counts and real checked-in payload checks. Do not inspect the executing
workflow package or registries, and do not expand this plan into workflow repairs.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter ImplementationWorkflowSandboxTests
```

**V11 selected-host execution and cancellation**, log `selected-host-tests.log`.
Require positive counts for each suite and the P1-6a/c integration cases above:
actual worker execution with root/callee choice delivery, exact reserved session,
worker loss fencing and live cancellation/acknowledgment. In-memory transport
fixtures may control scheduling, but cannot bypass the worker execution and
shared store boundaries under test. Every fixture stops before the test exits.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

At the P1-PREREQ-L gate, V3 certifies the existing lifecycle requirements;
record bounded-director cases as pending P1-6d, never passing by omission.
After P1-6d and at final acceptance, V3 must also prove reopened-store
judged-work linkage and all P1-6d cases above. For V5 the AppSupport suite is required because host declarations touch
profile/daemon loading. SurfaceCatalog, help, doctor and plain workflow behavior
must remain covered by positive suites; classify unrelated baseline failures,
never suppress them or report the affected gate passing. V2 also needs positive
counts for cancellation and budget suites; V3 for causality and agent-director.

## P1-FINAL documentation, review and publication

- [ ] Serially reconcile source against immutable intents and prerequisite
  handoffs; run affected checks after repairs, then V0–V11 on the final stable
  tree. No unresolved material high/mid finding or incomplete required evidence.
- [ ] Perform author self-review, independent test-integrity review and the workflow's single adversarial
  implementation review, followed by required combined-tree acceptance. Review
  material behavior/data-loss/security/regression/test gaps, not style nits or
  speculative abstraction. Record actual review IDs, decisions and findings.
- [ ] Refresh `README.md`, affected example READMEs/EXPECTED_RESULTS, and P1
  status in `design-docs/specs/design-work-runtime-consolidation.md`. Update
  `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, `SurfaceCatalog+Rows.swift`,
  `SurfaceCatalog+RowSupport.swift`, `Sources/RielaCLI/CLISurfaceEnumeration.swift`
  and `Tests/RielaCoreTests/SurfaceCatalogTests.swift` only where task CLI/removal
  requires it. Task GraphQL/UI counterparts stay explicitly deferred.
- [ ] Reconcile this plan, `impl-plans/README.md`, `impl-plans/PROGRESS.json`,
  `impl-plans/progress/plans-index.json`, `meta.json`, `phases.json` and
  `plans/work-runtime-p1-dispatcher-guard-director.json` under that progress
  directory only where the existing index format requires it. Preserve all
  non-P1 entries and other plans' unchecked status unless their acceptance is
  explicitly evidenced; do not claim completion of separate work packages.
- [ ] Append this session's status/evidence only to
  `impl-plans/progress/p1-dispatch.md`: task state, exact changed paths/hashes,
  retained-hunk attribution, interface ownership, commands/start/end/final exits,
  complete log paths, positive per-suite counts, review findings/decisions,
  invalidated evidence and deferred/external dependencies. No checkboxes close
  on source inspection, planning acceptance or historical logs alone.
- [ ] Audit applicable repository-owned `riela-package.json` manifests only
  for modified workflow/prompt/script/skill artifacts; refresh actual owning
  digests with established tooling and record exact paths serially before edit.
  Do not invent a manifest, modify an immutable installation or inspect scoped
  registries. Review `.codex/skills/riela-impl-workflow/SKILL.md` for directly
  affected documentation; update only a necessary P1 contract with explicit
  owner/path and digest audit, not unrelated workflow material. No skill edit
  is necessary merely because this plan was authored.
- [ ] Lockfile generation is conditional on a necessary dependency change;
  do not opportunistically update `Package.resolved`. No archiving is necessary
  before execution completes. Exclude tmp evidence from staging.
- [ ] Prepare the exact accepted P1 file/hunk allowlist; retain unrelated hunks
  even in shared files. The authorized workflow finalization gate commits and
  pushes non-force to `origin` / `feat/remaining-impl-plans`, verifies the final
  accepted hash remotely and records matching commit/push evidence. Freshly
  check publication readiness at that gate; missing upstream is not a design
  blocker. Do not fabricate tracking state, change other worktrees or integrate
  a base branch. No broad `git add` and no concurrent Git operations.

Shared-file documentation changes invalidate affected test/lint gates; rerun
those gates before the final allowlist is accepted. Existing untracked files
must be included in evidence and strict lint, not omitted by git diff. If
commit tooling can stage only whole files, unrelated mixed hunks require an
isolated accepted-content preparation that preserves the worktree/index; do
not silently include them. Actual inability to publish is reported with its
concrete failed command/log/exit, not claimed as success.

## Planning author check and remaining gates

Step 3 accepted §17.7 in the runtime-delivered review with no findings. Step 5
plan acceptance, implementation, behavioral tests, lint, adversarial review,
documentation completion and final commit/push remain downstream. No Swift
build/test/lint result is claimed in Step 4. No unresolved user decision or
known design defect remains. The current concrete director integration gap is
an implementation task, not a reason to reopen accepted design.

Author check: `python3 tmp/work-runtime-p1/step4-f46ff788/self-check.py`.
Complete logs/final exits and source-preservation evidence are recorded in
`tmp/work-runtime-p1/step4-f46ff788/verification-evidence.json`.
This plan's source inspections are not behavioral acceptance. The author
checks the single-plan DAG, exact scope, file-level tasks, accepted §17.7 mapping,
evidence commands, review/finalization gates and preservation of all prior work.
