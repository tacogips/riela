# Progress: ar-06-cli-targets-logs

Workflow mode: `issue-resolution`
Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number)
Codex-agent reference: `/root` (Step 6 implementation)
Plan: `impl-plans/completed/automatic-retention-06-cli-targets-logs.md`

## Scope and implementation

Implemented only the ar-06 write paths: `RetentionTargetResolver` and target DTO; `RetentionTargetLock` and atomic ISO8601 `RetentionRunStamp`; `RetentionLogPruner` with direct-child `lstat`, revalidation of kind/device/inode/size/mtime before `unlink`, bounded planning, warnings and report accounting; public sequential cancellable `RielaRetentionScheduler`; and 20 behavioral tests across the three named suites. Added a cancellable 1 ms scheduler tick after each scheduled pass so an injected sleep that returns synchronously cannot spin and starve stop callers. No service, CLI, events or app wiring was added; those are downstream plans.

Relative explicit session stores are resolved against the project directory (or cwd) using the original input string. Missing roots are skipped without creating them, target symlinks are marked unsafe, and the explicit target is deduplicated against in-scope stores.

## Acceptance status

- Target ordering, deduplication, unsafe-root marking, missing-root behavior, flock admission/release, and stamp freshness behavior: implemented and behaviorally verified.
- Log planner application, protected entries, pre-unlink identity check, unlink bound, and report: implemented and behaviorally verified.
- Scheduler public API, sequential/cancellable loop and immediate-sleep fairness: implemented and behaviorally verified.
- Strict changed-file SwiftLint: exitStatus 0, empty log.
- Focused behavioral suites: exitStatus 0, 20 tests, 0 failures on the stable shared tree. Earlier compile-blocked attempts and pre-fix interrupted runs remain in the evidence directory; they are not current-source failures.

## Verification

| Command | exitStatus | testsRun | failureCount | Log / outcome |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RetentionTargetStateTests|RetentionLogPrunerTests|RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/test-final.log 2>&1'` | 0 | 20 | 0 | Final-source focused suites passed; full log at `tmp/automatic-retention/ar-06-cli-targets-logs/test-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/scheduler-isolated-002.log 2>&1'` | 0 | 4 | 0 | Scheduler suite passed after adding the bounded cancellable tick; full log at `tmp/automatic-retention/ar-06-cli-targets-logs/scheduler-isolated-002.log`. |
| `if [ -s tmp/automatic-retention/ar-06-cli-targets-logs/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-06-cli-targets-logs/changed-swift-files.nul > tmp/automatic-retention/ar-06-cli-targets-logs/swiftlint-verify.log 2>&1; else printf '%s\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | Exact seven-file strict lint gate passed; log at `tmp/automatic-retention/ar-06-cli-targets-logs/swiftlint-verify.log` is empty. |
| `grep -n 'public final class RielaRetentionScheduler' Sources/RielaCLI/RielaRetentionScheduler.swift && grep -n 'static func tryAcquire(stateDirectory: String)' Sources/RielaCLI/RetentionTargetState.swift` | 0 | 0 | 0 | Both required declarations matched. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RetentionTargetStateTests|RetentionLogPrunerTests|RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/test-rerun-004.log 2>&1'` | 130 | 16 | 0 | Pre-fix run built and reached scheduler tests but was interrupted after the immediate-sleep test loop starved progress. It is superseded by `test-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RetentionTargetStateTests|RetentionLogPrunerTests|RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/test-rerun-005.log 2>&1'` | 130 | 16 | 0 | Task.yield-only attempt was interrupted after the scheduler loop still monopolized the test process. It is superseded by the successful isolated and final runs. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/scheduler-isolated-001.log 2>&1'` | 130 | 0 | 0 | Task.yield-only isolated scheduler attempt was interrupted during the busy loop; it is superseded by `scheduler-isolated-002.log`. |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-06-cli-targets-logs/changed-swift-files.nul > tmp/automatic-retention/ar-06-cli-targets-logs/swiftlint-final.log 2>&1'` | 0 | 0 | 0 | Prior exact-file strict lint passed; final-source rerun above also passed. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -frontend -parse Sources/RielaCLI/RetentionTargets.swift Sources/RielaCLI/RetentionTargetState.swift Sources/RielaCLI/RetentionLogPruner.swift Sources/RielaCLI/RielaRetentionScheduler.swift Tests/RielaCLITests/RetentionTargetStateTests.swift Tests/RielaCLITests/RetentionLogPrunerTests.swift Tests/RielaCLITests/RielaRetentionSchedulerTests.swift > tmp/automatic-retention/ar-06-cli-targets-logs/parse.log 2>&1` | 0 | 0 | 0 | `tmp/automatic-retention/ar-06-cli-targets-logs/parse.log`; parser accepted all seven Swift files. |

The initial SwiftLint diagnostic run and two intermediate strict-lint runs failed on style only; corrections are recorded in `tmp/automatic-retention/ar-06-cli-targets-logs/edit-intent-004.md` and `edit-intent-006.md`. The final exact-file strict lint run passes. Compile-blocked attempts are recorded in `test.log` and `test-rerun-001.log` through `test-rerun-003.log` from the earlier moving-tree phase.

## Handoff

No ar-06 implementation blocker remains. Downstream service, trigger and app wiring remains assigned to ar-07, ar-08 and ar-09.

## Final-source SHA-256

- `Sources/RielaCLI/RetentionTargets.swift`: `d65645520d510cacf751c24e6789c1d2424d70a7264be91082f4a8c942d4ebea`
- `Sources/RielaCLI/RetentionTargetState.swift`: `3fda4aaf5b723d03d02ddab645ccb65b4ef82afb3bcbe8397a30867c08d17363`
- `Sources/RielaCLI/RetentionLogPruner.swift`: `6524f26a09d68453599aab3c32b09fe3796671165d52646c5a15856986a8f1e7`
- `Sources/RielaCLI/RielaRetentionScheduler.swift`: `9c3a522f30b5e7caaf38970eeb68f2a767a12d57699d2ed74e6cb9c8565d7719`
- `Tests/RielaCLITests/RetentionTargetStateTests.swift`: `047f051a05a74e46b985e5b19e06fa1b7b6e7cffe79e1aac90c2c113bb95223e`
- `Tests/RielaCLITests/RetentionLogPrunerTests.swift`: `e657dba3903217118a0e4431297cd80f60b1b8fb0dcacd1198d0c38bb535c0e0`
- `Tests/RielaCLITests/RielaRetentionSchedulerTests.swift`: `1cd088af5ac71aaff937466c194dd817402acb938580907ea9e4a2986bc105ab`

## Operator amendment (2026-10-19)

`RielaRetentionSchedulerTests.waitUntil` now polls every 10 ms against a 5 s
wall-clock deadline instead of an iteration budget of 200 x 1 ms, which could
expire under parallel-build load. Added
`testNonSuspendingSleepCannotSpinFasterThanOneTick`, the regression test for the
original hang: an injected sleep that returns synchronously must not busy-spin,
and `stop()` must end the loop at the next tick. The suite passed 5 consecutive
runs (5 tests, 0 failures each).
