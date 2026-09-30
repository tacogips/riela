# wh-15 task commands progress

Plan: `impl-plans/active/wh-15-task-commands.md`  
Mode: issue-resolution  
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.  
Branch: `feat/work-handover-and-takeover`; accepted dependency: `wh-14-task-dispatch-runtime`.

## Implemented

- Added `task handover`, `task takeover`, `task answer`, `task handovers`, and `task reconcile` routing and handlers. Parsers validate required arguments, exact answer payload cardinality, closed `HostTrait` and sink values, and the reconcile flag.
- Takeover avoids a second reservation when answer already created one; validates packet sink/file digest and requires task ID plus digest to match the latest store packet. `--clone-into` clones only an explicit repository deliverable remote or accepts the matching existing origin.
- Added `session handover` parser/handler; it calls runtime adoption and returns exit code 5 with `{sessionId, taskId, handoverId}`.
- Added `task show` handover rows, lease summary without lease token data, and latest session suspend record in JSON and appended text output.

## CLI acceptance test mapping

`Tests/RielaCLITests/TaskHandoverCommandTests.swift`:

- Signal 1 (`task show` handover fields): `testShowIncludesHandoverLeaseAndSuspendFields`; `testHandoversReturnsEmptyListForTaskWithoutHandover` covers list route/rendering, but packet-present CLI rendering remains unverified.
- Signal 2 (`task answer` and takeover continuation): parser and command paths implemented; no positive answer/takeover CLI test completed in this plan attempt.
- Signal 4 (`--force-orphan`): `testForceOrphanFlagReachesOrphanFenceRuntime`.
- Signal 5 (traits parsing): `testTakeoverRejectsUnknownTraitByName`.
- Strict parsing and routing: `testTaskCommandRoutingIncludesHandoverSurface`, `testAnswerRequiresExactlyOnePayloadFlag`, `testReconcileRequiresExpiredLeasesFlag`, `testImmediateHandoverWithoutRunningAttemptFails`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-15-task-commands/step6-implement/build-retry-2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/build-retry-2.log'`: exit 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskCommandTests|TaskCommandParsingTests|TaskCommandMutationTests|SessionObservabilityCommandTests" > tmp/work-handover/wh-15-task-commands/step6-implement/focused-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/focused-final.log'`: exit 1 before tests ran. Compilation is blocked by the concurrent, out-of-scope `Tests/RielaCLITests/TaskHandoverExampleTests.swift:133` call passing `beforeExecution:` to `TaskDispatch.run` (no such argument in current API); its following `.failure` diagnostic is a cascade. This file is outside wh-15 `writePaths` and cannot be changed here.
- Earlier build compile failures were fixed in wh-15 source; see `build.log` (exit 1) and `build-retry-1.log` (exit 1). Current source build passed in `build-retry-2.log`.

## Remaining

- Re-run the focused command after the owner of `Tests/RielaCLITests/TaskHandoverExampleTests.swift` repairs its call against the current TaskDispatch API; then address any wh-15 failures.
- Add/complete positive CLI coverage for packet-present show, answer scheduling followed by takeover completion, valid presence traits, packet tamper refusal/valid packet use, reconcile dry-run JSON, and session adoption. The new test file currently cannot compile with the shared target due to the blocker above.
- Run strict SwiftLint and `git diff --check` after final source stabilization.

Plan done criteria remain unchecked until all assigned command behavior and required focused tests have passing evidence.

Final gates on the current source tree:

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-15-task-commands/step6-implement/build-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/build-final.log'`: exit 0 (`Build complete!`).
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskCommandTests|TaskCommandParsingTests|TaskCommandMutationTests|SessionObservabilityCommandTests" > tmp/work-handover/wh-15-task-commands/step6-implement/focused-final-2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/step6-implement/focused-final-2.log'`: exit 1 at test-target compilation; `TaskHandoverCommandTests.swift` itself compiled, then the build failed in `Tests/RielaCLITests/TaskHandoverExampleTests.swift:133` (`beforeExecution` is not a `TaskDispatch.run` argument). No tests executed; no test count is available.
- `arch -arm64 /bin/zsh -lc '... xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-15-task-commands/step6-implement/changed-swift-files.nul ...'`: exit 0, exact changed-file manifest at `tmp/work-handover/wh-15-task-commands/step6-implement/changed-swift-files.nul`; final log `swiftlint-retry-2.log`. Earlier lint failures are preserved as `swiftlint.log` and `swiftlint-retry-1.log`.
- `git diff --check`: exit 0, `tmp/work-handover/wh-15-task-commands/step6-implement/diff-check.log`.

The test target blocker is outside this plan's writePaths. No test file outside wh-15 scope was modified. Resume when the `TaskHandoverExampleTests.swift` owner repairs the mismatched call; rerun the focused suite and finish the positive CLI integration coverage listed under Remaining.
