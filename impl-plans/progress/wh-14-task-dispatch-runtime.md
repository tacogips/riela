# wh-14 Task dispatch runtime progress

Workflow mode: issue-resolution. Plan: `wh-14-task-dispatch-runtime` (`impl-plans/active/wh-14-task-dispatch-runtime.md`). No GitHub issue was supplied; tracking references are `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`. Accepted dependency: `wh-10-host-traits` (runtime `acceptedPlanIds`).

Codex agent reference: `step6-implement`, workflow execution `nested-v1-1dd3c0eb0e9a2d357a79a2f84f362ec64c05e850aa9458e7fcca0ab86a80290b`.

## Implemented in this attempt

- Added the guarded `WorkStore.updateAttemptIsolation` update and the pinned `TaskHandoverRuntime` facade for answer, takeover, request, orphan, expiry reconciliation, adoption, and packet listing.
- Added direct suspended-session sealing and notification, TaskDispatch `suspended`/`handoverId` fields, presence-aware placement, takeover accepted-history import with answer variables/message, and the external-terminal reconciliation seam.
- Added repository branch setup/materialization, attempt isolation recording, owner-fence checked checkpoint/publish and orphan deliverable reporting, step-boundary checkpoints, non-immediate boundary requests, lease heartbeat fencing, and typed wait-signal handover capture. The `everyMs` checkpoint timer and director `.handover` observer capture are not implemented.
- Added `riela/handover-request@1`, registration/dispatch, and `HandoverRequestAddonTests`.

## Acceptance evidence and remaining work

- Handover request add-on: `HandoverRequestAddonTests.testHandoverRequestRequiresTaskContext`, `testHandoverRequestReturnsValidatedEnvelope`, and `testHandoverRequestRequiresResumeStep` pass.
- Required handover signal mapping (signals 1–5): not established by plan-owned dispatch/lease/repository tests. Direct suspension and request add-on behavior have focused evidence only; no `TaskHandoverDispatchTests`, `TaskHandoverLeaseTests`, or `TaskHandoverRepositoryTests` files exist yet.
- Remaining implementation: add takeover/answer/seal and repository behavior tests; prove heartbeat extension, revived-owner `leaseLost`, orphan expiry/reconcile, and adoption; wire director `.handover` observer capture and `everyMs` checkpoint timer; complete progress evidence mapping for acceptance signals 1–5. External terminal reconciliation and answer/takeover/repository behavior also lack dedicated behavioral proof.

## Verification

- Final-source `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/build-final-source.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/build-final-source.log'`: exit 0.
- Final-source `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/focused-final-source.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/focused-final-source.log'`: exit 0; 3 tests, 0 failures (only the present add-on suite matched).
- Final-source `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/regression-final-source.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/regression-final-source.log'`: exit 0; 84 tests, 0 failures.
- Exact changed-file SwiftLint used `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/changed-swift-files.nul`; `swiftlint lint --strict --quiet --no-cache` exit 0, full log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/swiftlint-final-source.log`.
- `git diff --check`: exit 0, full log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/diff-check-final-source.log`.
- Earlier focused attempt `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/focused.log` exited 1 with 1 fixture failure; corrected `options: []` and rerun passes as recorded above.
- Build retries and their historical outcomes are preserved under `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement/build-rerun-*.log`; the initial build log `tmp/work-handover/wh-14-task-dispatch-runtime/build.log` exited 1 before its import correction.

Plan status: implementation incomplete; no review approval claimed. Acceptance checkboxes remain unchecked until missing behavior, observer wiring, tests, and evidence mappings pass. Earlier failed build/lint attempts remain in their original `step6-implement/*` logs; the source-matched build, focused, regression, lint, and diff-check evidence above supersedes the resolved failures only.

## Continuation implementation update (2026-10-01)

Codex agent reference: `step6-implement`, workflow execution `nested-v1-e5487b6137864c935c9bbf1244eb318ceada90ada2924d4f19339bbb4ef1e3f8`; workflow mode `issue-resolution`; plan `wh-14-task-dispatch-runtime`. Issue reference: no GitHub issue supplied; design and umbrella tracking references remain `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`.

### Changes in this continuation

- `Sources/RielaCLI/TaskRunCancellation.swift`: captures director `.handover` before cancelling, leaves the terminal session unsaved for sealing, and checks the `everyMs` timer during observation.
- `Sources/RielaCLI/TaskDispatch+Handover.swift`: acknowledges only matching pending director handover cancellations before saving the stalled snapshot; serializes step/timer checkpoint requests and enforces presence traits for backend-free workflows.
- `Sources/RielaCLI/TaskHandoverSupport.swift` and `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift`: add the per-attempt serialized checkpoint queue and pass its closure/isolation through execution context. Timer commits use `Riela-Checkpoint: <attemptId>/timer-<n>`.
- `Sources/RielaWork/WorkStore+Isolation.swift`: adds a transaction-guarded acknowledgement for the exact matching `.handover` decision without reconciling the attempt.
- `Tests/RielaCLITests/TaskHandoverDispatchTests.swift`: `testPresenceTakeoverRequiresTraitsWithoutBackendRequirements` proves no-trait refusal reason `host-traits-unavailable: userReachable`, trait admission, and no reservation in either placement preview.
- `Tests/RielaCLITests/TaskHandoverRepositoryTests.swift`: `testTimerCheckpointsAreSerializedAndUseUniqueTrailers` proves unique timer trailers and maximum concurrent workspace checkpoints of one.

Acceptance signal mapping 1–5 is still incomplete. Signal 1 has existing add-on unit coverage (`HandoverRequestAddonTests.testHandoverRequestReturnsValidatedEnvelope`) plus new placement/timer unit coverage, but no end-to-end seal test. Signals 2–5 do not yet have their planned dispatch/answer, repository, lease/fence/orphan/reconcile/adoption behavioral test names. In particular, the director `.handover` predecessor cancellation/re-reservation resume checklist is implemented but still needs an end-to-end regression test. No completion box is checked.

### Verification for this continuation

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/build-final.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/build-final.log; exit $code'`: exit 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/focused-final.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/focused-final.log; exit $code'`: exit 0; 5 tests, 0 failures. The `TaskHandoverLeaseTests` class is not yet present, so its filter contributed no cases.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/regression-final.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/regression-final.log; exit $code'`: exit 0; 84 tests, 0 failures.
- Changed-file SwiftLint: manifest `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/changed-swift-files.nul`; `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`: exit 0, log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/swiftlint-final.log`.
- `git diff --check`: exit 0, log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/diff-check-final.log`.
- Earlier attempts retained: `build.log` exited 1 on the obsolete helper reference; `focused-tests.log` exited 1 on a test initializer argument order. The source-matched build and focused rerun above resolved these. `build-rerun-01.log` and `focused-tests-rerun-01.log` also pass after those corrections.

Implementation remains incomplete; continue this plan with the outstanding tests and acceptance signal mappings above. No formal review approval is claimed.

### Final continuation verification update

Added `Tests/RielaCLITests/TaskHandoverLeaseTests.swift`; `TaskHandoverLeaseTests.testHeartbeatExtendsLeaseDuringLongRunningAttempt` passes and proves the observer extends a short lease during a slow node. The current focused run is therefore 6 tests / 0 failures, including that test, `TaskHandoverDispatchTests.testPresenceTakeoverRequiresTraitsWithoutBackendRequirements`, `TaskHandoverRepositoryTests.testTimerCheckpointsAreSerializedAndUseUniqueTrailers`, and all three `HandoverRequestAddonTests` cases. This is partial signal evidence only; acceptance signals 1–5 are not fully mapped.

Final-source evidence after the lease test addition:

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/build-final-after-lease.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/build-final-after-lease.log; exit $code'`: exit 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/focused-with-lease.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/focused-with-lease.log; exit $code'`: exit 0; 6 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/regression-final-after-lease.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/regression-final-after-lease.log; exit $code'`: exit 0; 84 tests, 0 failures.
- Exact changed-file SwiftLint manifest now contains the five changed source files and three added test files; selected-file `swiftlint lint --strict --quiet --no-cache` exit 0, full log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/swiftlint-final-after-lease.log`.
- `git diff --check`: exit 0, log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-2/diff-check-after-progress.log`.

Still outstanding before this plan can complete: end-to-end trigger/seal/answer/takeover and imported history checks; director `.handover` no-unacknowledged-cancellation plus follow-up reservation; repository publish/checkpoint trailer/second-clone materialization and fenced-owner proof; lease fence/revived owner `leaseLost`; orphan expiry/force takeover and `reconcileExpired`; `adoptAndSeal`; and acceptance signal 1–5 test mapping. Done criteria remain unchecked. No blocker is external; this is unfinished work owned by wh-14.

## Continuation implementation update 2 (2026-10-01)

Codex agent reference: `step6-implement`, workflow execution `nested-v1-e5487b6137864c935c9bbf1244eb318ceada90ada2924d4f19339bbb4ef1e3f8`; workflow mode `issue-resolution`; plan `wh-14-task-dispatch-runtime`. Issue reference: no GitHub issue supplied; tracking references remain `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`.

### Changes in this continuation

- `Sources/RielaCLI/ProductionNodeAdapter+HandoverRequestAddon.swift`: the strict handover envelope parser now projects only envelope fields from resolved workflow input, so ordinary upstream payload keys do not masquerade as envelope fields; unsupported keys in authored add-on config remain rejected.
- `Sources/RielaCLI/TaskDispatch.swift`: terminal guard evaluation accepts prior `.suspended` sessions, matching the durable handover status and allowing a successor attempt to reconcile after its predecessor was sealed.
- `Sources/RielaCLI/TaskDispatch+Handover.swift`: answer lookup for takeover reads the durable task decisions and matches question id plus handover id; imported history and the delivered answer message are saved in one successor snapshot before execution.
- `Tests/RielaCLITests/TaskHandoverTestSupport.swift` and `TaskHandoverDispatchTests.swift`: added `testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes`, covering digest-sealed packet/task waiting/predecessor reconciliation/no lease, answer takeover, imported accepted history, answer in resume input and delivered message, lineage, and task completion.
- The backend-free presence trait case, heartbeat extension, and serialized timer trailer cases from the previous continuation remain covered by `testPresenceTakeoverRequiresTraitsWithoutBackendRequirements`, `testHeartbeatExtendsLeaseDuringLongRunningAttempt`, and `testTimerCheckpointsAreSerializedAndUseUniqueTrailers`.

### Acceptance mapping and remaining work

- Signal 1 (seal a stable packet and list it): `TaskHandoverDispatchTests.testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes` proves seal/digest/task waiting and reconciled predecessor; CLI task-show listing remains untested in this plan.
- Signal 2 (answer, takeover, resume input and history): the same end-to-end test proves answer injection, imported history, delivered message, lineage, and completion.
- Signal 3 (publish repository branch and continue in a second clone): not proven; repository branch publication, second-clone materialization, and fenced-owner publication tests remain outstanding.
- Signal 4 (presence host traits): `TaskHandoverDispatchTests.testPresenceTakeoverRequiresTraitsWithoutBackendRequirements` proves refusal without `userReachable` and admission with it when backend requirements are empty.
- Signal 5 (remote takeover reporting): owned by downstream wh-16/wh-18; wh-14 provides the local terminal reconciliation seam but remote reporting is not claimed here. The amended director `.handover` cancellation/re-reservation and `everyMs` checkpoint commit end-to-end checks remain outstanding in this plan.
- Other remaining wh-14 tests: immediate/boundary request, wait-signal and inactivity sealing, exactly-once trigger behavior, director cancellation acknowledgement and follow-up reservation, owner fence/revived `leaseLost`, orphan expiry/force takeover, `reconcileExpired`, `adoptAndSeal`, repository publication/checkpoint/materialization, and acceptance signal 1–5 completion evidence. Done criteria remain unchecked; implementation is incomplete and no formal review approval is claimed.

### Final-source verification for this continuation

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/build-final-source.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/build-final-source.log; exit $code'`: exit 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/focused-final-source.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/focused-final-source.log; exit $code'`: exit 0; 7 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/regression-final-source.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/regression-final-source.log; exit $code'`: exit 0; 84 tests, 0 failures.
- Changed-file SwiftLint used `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/changed-swift-files.nul`; `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`: exit 0; complete log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/swiftlint-final-source.log`.
- `git diff --check > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/diff-check-final-source.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/diff-check-final-source.log; exit $code`: exit 0.
- Earlier exploratory E2E runs in this continuation are preserved under the same evidence directory (`dispatch-*.log`); initial failures exposed resolved-input handling, suspended historical reconciliation, fixture output requirements, and answer message assembly. Final-source focused tests pass after those corrections.

### Scope dependency discovered

`TaskHandoverDispatchTests.testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes` confirmed that the answer is durably recorded as a `.answer` decision with matching handover/question ids, but a direct `WorkStore.latestAnswer(handoverId:)` read returned `nil` (`tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/dispatch-answer-db-diagnostic.log`; timestamp-floor retry is preserved in `dispatch-e2e-answer-clock-rerun.log`). The wh-14 dispatch path now selects the latest matching durable decision locally and the E2E answer takeover test passes. `TaskHandoverRuntime.requestTakeover` still delegates to `WorkStore.requestTakeover`, whose canonical answer check calls that `latestAnswer` query; repairing this requires `Sources/RielaWork/WorkStore+Takeover.swift`, outside wh-14 `writePaths`. Do not widen scope implicitly. Resume this seam after approved write-path ownership is assigned or the store query is repaired by its owner, and add a direct `requestTakeover` after-answer regression test.

## Continuation implementation update 3 (2026-10-01)

Codex agent reference: `step6-implement`, workflow execution `nested-v1-7890bac97371b5ea09e8194ea70ca95a36bdf6a3eb0c63de369596dd749bf134`; workflow mode `issue-resolution`; plan `wh-14-task-dispatch-runtime`. Issue reference: no GitHub issue supplied; tracking references remain `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`.

### R25 implementation

- `Sources/RielaWork/WorkStore+Takeover.swift`: `latestAnswer(handoverId:)` now joins answer decisions to the sealed handover, compares `work_decisions.created_at >= work_handovers.created_at` as stored text columns, and filters by the packet's predecessor attempt. Digest, question ID, and handover-reason checks remain enforced.
- `Sources/RielaCLI/TaskDispatch+Handover.swift`: both answer injection paths now use `WorkStore.latestAnswer(handoverId:)`; the private duplicate lookup is removed.
- `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift`: added `testSameSecondAnswerAfterSealAllowsTakeover`, `testLatestAnswerRejectsForeignAttempt`, and `testAnswerBeforeSealDoesNotAllowTakeover`.
- The earlier scope note above is historical: the current runtime dispatch contract assigns `Sources/RielaWork/WorkStore+Takeover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` to wh-14. The direct repair and tests are complete within that assignment.

### Acceptance mapping and remaining work

- Signal 1 (seal one stable packet and list it): `TaskHandoverDispatchTests.testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes` proves seal, digest, waiting task, and reconciled predecessor; task-show listing is downstream CLI surface coverage.
- Signal 2 (answer takeover, resume input, and imported history): `TaskHandoverDispatchTests.testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes`; same-second admission is independently proven by `WorkStoreTakeoverTests.testSameSecondAnswerAfterSealAllowsTakeover`.
- Signal 3 (publish/materialize repository branch): not proven by current wh-14 end-to-end tests; `TaskHandoverRepositoryTests.testTimerCheckpointsAreSerializedAndUseUniqueTrailers` only proves serialized checkpoint coordination and unique timer trailers.
- Signal 4 (presence traits): `TaskHandoverDispatchTests.testPresenceTakeoverRequiresTraitsWithoutBackendRequirements` proves refusal without `userReachable` and admission when declared.
- Signal 5 (remote takeover reporting): remote reporting/controller verification belongs to downstream wh-16/wh-18; wh-14 does not claim that surface. The assigned local director `.handover` cancellation/re-reservation and timer-commit checklist still needs end-to-end tests.
- Remaining plan-owned behavioral coverage: director `.handover` seals once with inactivity and leaves no pending cancellation before takeover reservation; live owner fence/revived `leaseLost`; force-orphan expiry/takeover; `reconcileExpired`; `adoptAndSeal`; real repository branch publication, second-clone materialization, and fenced-owner refusal; actual `everyMs` timer checkpoint commit. Implementation remains incomplete and no formal review approval is claimed.

### Final-source verification for this continuation

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/build.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/build.log; exit $code'`: exit 0; complete log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/build.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/focused.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/focused.log; exit $code'`: exit 0; 7 tests, 0 failures, including `testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/regression.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/regression.log; exit $code'`: exit 0; 84 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreTakeoverTests|WorkStoreHandoverRecordsTests|WorkStoreLeaseTests" > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/workstore.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/workstore.log; exit $code'`: exit 0; 20 tests, 0 failures.
- Changed-file SwiftLint and `git diff --check` are recorded below after this update.
- Changed-file SwiftLint: manifest `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/changed-swift-files.nul` contains the three changed Swift paths. `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/swiftlint.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/swiftlint.log; exit $code'`: exit 0; log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/swiftlint.log`.
- `git diff --check > tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/diff-check.log 2>&1; code=$?; echo "exit=$code" >> tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/diff-check.log; exit $code`: exit 0; log `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-4/diff-check.log`.

## Continuation implementation update 4 (2026-10-01)

Codex agent reference: `step6-implement`, workflow execution `nested-v1-7890bac97371b5ea09e8194ea70ca95a36bdf6a3eb0c63de369596dd749bf134`; workflow mode `issue-resolution`; plan `wh-14-task-dispatch-runtime`. Issue reference remains no GitHub issue supplied; tracking is `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`.

### Resume-checklist test and ownership mismatch

- Added `TaskHandoverDispatchTests.testDirectorInactivityHandoverAcknowledgesCancellationAndAcceptsTakeover` with a stalling scenario adapter. It asserts one inactivity packet, failed(.stalled) predecessor, no unacknowledged cancellation, waiting task, and an accepted follow-up takeover reservation.
- The final fixture-correct test run compiled but failed: dispatch returned an error with `terminalSnapshotConflict` before a packet was sealed. Complete log: `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-5/director-handover-rerun-02.log`; exit=1; 1 test, 1 failure.
- Source inspection shows `TaskRunCancellation.run` skips its joined-cancellation save for a director handover, but the runner's `FailClosedSQLiteWorkflowRuntimeStore.persist` has already committed failed(.cancelled). `TaskDispatch+Handover.sealHandoverIfNeeded` then attempts failed(.stalled); `SQLiteWorkflowRuntimePersistenceStore.validateTaskTerminalWrite` rejects the changed terminal failure as `terminalSnapshotConflict`.
- Repairing the canonical terminal-write lifecycle requires a persistence hook/transition change in `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift` and/or `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`. These are outside wh-14 `writePaths`; `Sources/RielaCLI/WorkflowRunCommand.swift` is shared with only the specific step-boundary/boundary-handover edit authorized. No out-of-scope persistence edit or guard bypass was made.
- Resume criterion: assign an approved owner/write scope for deferring the runner's intermediate cancellation terminal write or for the handover-specific canonical terminal transition. Then rerun this director test and the assigned focused, regression, WorkStore, build, and SwiftLint gates. Existing criteria remain unchecked; no implementation review approval is claimed.

### Failed attempts preserved

- `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-5/director-handover.log`: exit=1; first fixture incorrectly used `sleepDurationMs` for an absent `wait-node`.
- `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-5/director-handover-rerun-01.log`: exit=1 before test execution because the test fixture initially omitted `import RielaAdapters`.
- `tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-5/director-handover-rerun-02.log`: exit=1; fixture compiled and reproduced the unresolved canonical terminal conflict described above.
