# wh-15 task commands progress

Plan: `impl-plans/active/wh-15-task-commands.md`  
Mode: issue-resolution  
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.  
Branch: `feat/work-handover-and-takeover`; dependency admission: `dependsOn: []`.

## Implementation

- Completed the assigned CLI surface: `task handover|takeover|answer|handovers|reconcile`, `task show` handover/lease/suspend fields, and `session handover` adoption. Existing wh-15 production implementation at the accepted checkpoint was retained.
- Added hermetic CLI integration tests within `TaskHandoverCommandTests.swift`. Test workflows and session stores are isolated under unique directories in repository-root `tmp/work-handover/wh-15-task-commands/tests/`. The session-handover tests are hermetic because each fixture project is its own git repository (one commit, a local bare remote as `origin`). Before adoption the test asserts the fixture's `rev-parse --show-toplevel` equals the fixture, and after adoption `assertAdoptedIsolation` asserts that the recorded attempt isolation path equals the fixture and that the branch starts with `riela/task/`. A `GIT_CEILING_DIRECTORIES` value passed to `RielaCLIApplication.run(environment:)` does not reach git, because `TaskHandoverRuntime` builds git's environment from `ProcessInfo`, so the tests do not rely on it. The other CLI tests (envelope run, answer/takeover, presence) use non-repository fixture directories. Their tasks have no repository context, so the dispatch runs no git.
- Coverage proves answer payload and host-trait validation; packet tamper rejection before attempt mutation; valid packet-file takeover; answer scheduling and one A→B successor; packet-present `task show`/`task handovers`; presence wait without `userReachable` and completion with it; reconcile dry-run JSON without writes; session adoption and `--task` attachment.
- The CLI represents host-trait unavailability as exit success with `status=waiting` and a `host-traits-unavailable` placement failure. The test asserts this observed contract and then verifies retry with `--traits userReachable` completes.

## CLI acceptance test mapping

`Tests/RielaCLITests/TaskHandoverCommandTests.swift`:

- Signal 1 (`task show` packet and digest; `task handovers` packet row): `testEnvelopeRunAppearsInTaskShowAndHandovers`; empty state remains covered by `testShowIncludesHandoverLeaseAndSuspendFields` and `testHandoversReturnsEmptyListForTaskWithoutHandover`.
- Signal 2 (answer then takeover continuation): `testAnswerOptionSchedulesTakeoverAndRejectsTamperedPacket` verifies `--option staging` schedules the task, tampered packet refusal leaves attempt count unchanged, valid packet succeeds, and exactly one successor links predecessor A to B.
- Signal 4 (`--force-orphan`): `testForceOrphanFlagReachesOrphanFenceRuntime`.
- Signal 5 (presence traits): `testPresenceTakeoverRequiresDeclaredUserReachableTrait` verifies waiting without the trait and completion with `--traits userReachable`; strict unknown trait remains covered by `testTakeoverRejectsUnknownTraitByName`.
- Additional command behavior: `testAnswerRequiresExactlyOnePayloadFlag`, answer option/default failures in `testAnswerOptionSchedulesTakeoverAndRejectsTamperedPacket`, `testReconcileRequiresExpiredLeasesFlag`, `testReconcileDryRunReturnsJSONWithoutWritingPackets`, `testSessionHandoverAdoptsSuspendedSessionInHermeticRepository`, `testSessionHandoverCanAttachToExistingTask`, `testImmediateHandoverWithoutRunningAttemptFails`, and `testTaskCommandRoutingIncludesHandoverSurface`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-15-task-commands/step6-implement/build-final-2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/build-final-2.log'`: exit 0; log `tmp/work-handover/wh-15-task-commands/step6-implement/build-final-2.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskCommandTests|TaskCommandParsingTests|TaskCommandMutationTests|SessionObservabilityCommandTests" > tmp/work-handover/wh-15-task-commands/step6-implement/focused-final-2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/focused-final-2.log'`: exit 0; 47 tests, 0 failures; log `tmp/work-handover/wh-15-task-commands/step6-implement/focused-final-2.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-15-task-commands/step6-implement/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`: exit 0; manifest selects only `Tests/RielaCLITests/TaskHandoverCommandTests.swift`; log `tmp/work-handover/wh-15-task-commands/step6-implement/swiftlint-final-2.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-15-task-commands/step6-implement/diff-check-final-2.log`.
- Step6 test-integrity re-verification after the test repair: the focused filter command (same filter as above) exited 0 with 47 tests and 0 failures, log `tmp/work-handover/wh-15-task-commands/step6-test-integrity/reviewer-focused.log`; SwiftLint strict exited 0, log `tmp/work-handover/wh-15-task-commands/step6-test-integrity/reviewer-swiftlint.log`; `git diff --check` exited 0, log `tmp/work-handover/wh-15-task-commands/step6-test-integrity/reviewer-diff-check.log`.
- Earlier verification is retained: `focused-pre-edit.log` (exit 1, 41 tests, 1 stale assertion about failure output), `focused-tests-1.log` (compile caught missing explicit return), and `focused-tests-2.log` (5 assertion failures while adapting to structured CLI errors/date decoding/waiting result). Those issues were corrected and resolved by the final source-matched 47-test run.

## Completion criteria

- [x] Every assigned command and flag is implemented with strict parsing; `task show` additions are present.
- [x] `TaskHandoverCommandTests` and existing command suites pass; acceptance signals 1, 2, 4, and 5 map to test names above.

Formal test-integrity/adversarial review and later review-owned documentation/index updates, exact-file staging, commit, and push remain downstream workflow steps.
