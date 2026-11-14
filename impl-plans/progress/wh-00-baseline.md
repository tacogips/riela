# wh-00 baseline evidence

Plan: `impl-plans/active/wh-00-baseline.md`  
Design: `design-docs/specs/design-work-handover-and-takeover.md`  
Issue reference: none supplied; work tracked by `impl-plans/active/work-handover-and-takeover.md`.

## Source identity and drift

- Branch: `feat/work-handover-and-takeover`.
- `git rev-parse HEAD`: `56aed1352155c9efbb53a2d8d2b8f5b935ecc1fc` (matches the assigned checkpoint).
- `git diff --stat 01b38f02 -- Sources Tests Package.swift Package.resolved examples Resources`: no output; zero code drift from base commit `01b38f02fb8c126528d5a46aebe737adb429736f`.
- Captured source-drift command output and HEAD: `tmp/work-handover/wh-00/code-drift.txt`, `tmp/work-handover/wh-00/head.txt`.

## Verification baseline

- Build: `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-00/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-00/build.log'` — `exit=0`; log ends with `Build complete! (154.98s)` and `exit=0`.
- Full serial suite: `arch -arm64 /bin/zsh -lc 'swift test > tmp/work-handover/wh-00/full-swift-test.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-00/full-swift-test.log'` — `exit=1`; final XCTest summary: 2759 tests, 2 skipped, 1 failure; Swift Testing summary: 19 tests passed. Combined: 2778 run, 2775 passed, 2 skipped, 1 failed.
- Sorted unique baseline failure list: `tmp/work-handover/wh-00/baseline-failures.txt`.
- Failure: `RielaCLITests.WorkflowCommandCrossWorkflowDispatchTests.testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect` failed when its owned scratch build subprocess exceeded 180.0 seconds (180.042 seconds reported). This is recorded as observed baseline evidence; the log does not establish it as a known flake.

## Plan checklist

- [x] Prove no code drift and record HEAD.
- [x] Capture arm64 build and full serial test logs with final `exit=` lines.
- [x] Record suite counts and sorted unique failure list.

No source or test files were changed. The baseline completed; the one timeout is a classified pre-implementation failure for downstream comparison, not an incomplete baseline capture.
