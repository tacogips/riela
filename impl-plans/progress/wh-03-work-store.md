# wh-03-work-store progress

Plan: `impl-plans/active/wh-03-work-store.md`  
Dependency: `wh-01-contracts` is accepted in the dispatch runtime (`acceptedPlanIds`).  
Implementation branch: `feat/work-handover-and-takeover`  
Issue reference: no GitHub issue supplied; umbrella tracking is in `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.

## Implementation

- Added takeover reservation validation for the pending request, digest-verified packet, same-task predecessor, resume step, one-time successor attachment, and takeover lineage.
- Reservation now records host, heartbeat, expiry and monotonic fence in the lease and task; ordinary entries wait while the latest handover is unattached.
- Added lease loading, heartbeat, token verification and ordered expiry queries.
- Added atomic orphan fencing with `leaseLost` reconciliation and evidence, answer validation/replay and answer-backed takeover reservation, and operator takeover requests.
- Added idempotent live-attempt handover requests and decision transition rules; late reconciles of fence-superseded attempts are ignored.
- Added focused tests for lease lifecycle, answer and takeover reservations, orphan fencing, preview waits and handover request lifecycle.

## Verification

Final-source evidence after the takeover-helper responsibility split (SHA-256 identity: `tmp/work-handover/wh-03-work-store/final-source-sha256-split.txt`):

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-03-work-store/build-final-split.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-03-work-store/build-final-split.log'` — exit 0, build complete.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreTakeoverTests|WorkStoreHandoverRequestTests|WorkStoreReservationTests|WorkStoreCancellationTests|DecisionApplier|TaskDispatcherTests|BudgetAdmissionStoreTests" > tmp/work-handover/wh-03-work-store/focused-final-split.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-03-work-store/focused-final-split.log'` — exit 0; 77 tests, 0 failures.
- Selected-file strict SwiftLint used the NUL manifest `tmp/work-handover/wh-03-work-store/changed-swift-files.nul` — exit 0, log `tmp/work-handover/wh-03-work-store/swiftlint-final-split.log`.
- `git diff --check` — exit 0, log `tmp/work-handover/wh-03-work-store/diff-check-final-split.log`.
- The reservation source was 973 lines at the initial snapshot and is 997 lines after moving takeover-specific helpers into `WorkStore+Takeover.swift`.

Prior attempts retained:

- `build.log` exit 1: first implementation compile identified missing import, helper visibility and conditional syntax; repaired, then build passed.
- `focused-attempt-01.log` exit 1: a concurrent wh-04-owned untracked `Tests/RielaWorkTests/HandoverPacketBuilderTests.swift` failed compilation; not modified by wh-03. The subsequent focused retry compiled the shared tree.
- `focused-retry-01.log` exit 1: 76 tests ran; three assertions in the new orphan-fence case exposed a missing late-reconcile early return and an incorrect expected fence. Both were corrected and the current-source run passed 77/77.
- Initial `swiftlint.log` exit 1: reservation complexity/line-length and conditional-parenthesis findings; refactored without disabling rules, then strict selected-file lint passed.

## Completion criteria

- [x] Every pinned store API is implemented and tested; reservation and takeover fence invariants are covered by the focused suite.
- [x] Existing Work store reservation and cancellation tests pass in the 77-test focused suite.
- [x] Progress log includes final-source verification evidence and earlier failed attempts.

Formal test-integrity, adversarial and serial integration review remain downstream workflow steps; this plan's implementation verification is complete.

## Step 6 test-integrity self-repair

- Gap: the plan's Tests section requires "a second takeover for the same handover is refused"; no test covered it.
- Added `WorkStoreTakeoverTests.testSecondTakeoverForSameHandoverIsRefused` (test-only; no source change). It reserves a presence takeover, then asserts a second `requestTakeover` throws, a second direct takeover reservation for handover-1 throws, `work_handovers.successor_attempt_id` still equals the first successor, and no `attempt-second` attempt exists.
- Verification: `tmp/work-handover/wh-03-work-store/step6-review/focused.log` — exit 0, 78 tests, 0 failures (includes the new test). Strict SwiftLint on the test file: `step6-review/swiftlint.log` — exit 0.
- Earlier attempts (`focused-attempt1.log`, `focused-attempt2.log`, exit 1) failed only because of a concurrently edited wh-04 `HandoverPacketBuilderTests.swift`; the later run compiled the fixed tree.

## Step 7 adversarial review self-repairs

- Finding 1 (mid): a live `.handover` decision inserted a cancellation that could not be persisted or acknowledged. Fixed in `Sources/RielaWork/WorkStore+Reservation.swift`: `requiresCancellationAcknowledgment` now includes `.handover`, and `acknowledgeAttemptCancellation` maps `.handover` to `task.state = .failed` like `.stop`.
- Finding 2 (mid): `requestTakeover` could resurrect a terminal task. Fixed in `Sources/RielaWork/WorkStore+Takeover.swift`: terminal task states are refused before any handover lookup.
- New tests in `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift`: `testLiveHandoverDecisionCancellationPersistsAndAcknowledges`, `testRequestTakeoverRefusesTerminalTask`.
- Verification: `tmp/work-handover/wh-03-work-store/step7-review/focused-repair.log`, exit=0, 80 tests, 0 failures.
