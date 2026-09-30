# wh-13-gc-sweep implementation progress

## Scope and dependency

- Plan: `impl-plans/active/wh-13-gc-sweep.md` (`wh-13-gc-sweep`), issue-resolution mode.
- Accepted predecessor: `wh-01-contracts`, admitted by `fanoutItem.acceptedPlanIds`.
- No GitHub issue was supplied. Umbrella reference: `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.
- Codex agent: GPT-6 implementation agent for fanout branch `wh-13-gc-sweep`; task execution `nested-v1-886707748aba9d4a02eb37a1080b1d9bf5d4cd9058d288c6877a38dfc8ddd9f0`.

## Implementation

- Extended `RielaGarbageCollectionReport` with `handoverFiles` and `handoverRefs` item arrays. Each item reports `removed`, `wouldRemove`, `kept`, or `skipped` with its path.
- File sweep reads `work_tasks(task_id,state)` from the root session store with strict read-only SQLite access and a bounded lock timeout. Missing, locked, unreadable, or incompatible task stores report diagnostics and leave candidate handovers untouched. Terminal or absent tasks are removed; nonterminal tasks are kept. Symlink and non-directory entries are skipped.
- Project local refs are listed with `/usr/bin/env git`, `GIT_TERMINAL_PROMPT=0`, and a 10-second process timeout. The collector verifies repository context, parses exact task/handover ref paths, and deletes only local refs for terminal or absent tasks. It never contacts a remote. Dry-run reports every item decision without deletion.
- Added `Tests/RielaCoreTests/RielaDataGarbageCollectorHandoverTests.swift` for file decisions/dry-run, local ref deletion/preservation and no remote, and missing-database fail-closed behavior.

## Verification history

- Initial build (`tmp/work-handover/wh-13-gc-sweep/build.log`) and focused attempt 1 (`tmp/work-handover/wh-13-gc-sweep/focused.log`) exposed SQLite initializer argument ordering; corrected in source.
- Attempt 2 build (`tmp/work-handover/wh-13-gc-sweep/attempt-06/build.log`) and focus (`tmp/work-handover/wh-13-gc-sweep/attempt-06/focused.log`) exposed the same label order; corrected in source.
- Attempt 3 build (`tmp/work-handover/wh-13-gc-sweep/attempt-08/build.log`) and focus (`tmp/work-handover/wh-13-gc-sweep/attempt-08/focused.log`) exposed a non-exiting guard in dry-run ref deletion; corrected to an `if`.
- Attempt 4 (`tmp/work-handover/wh-13-gc-sweep/attempt-10/build.log`, `attempt-11/focused.log`) passed before the final repository/non-directory guard and lint-only fixes; it is retained as prior evidence, not final-source verification.
- Attempt 5 (`tmp/work-handover/wh-13-gc-sweep/attempt-14/swiftlint.log`) identified a duplicate import and three optional Data-to-String conversions; fixed with no behavior change.
- Attempt 6 (`tmp/work-handover/wh-13-gc-sweep/attempt-19/focused.log`) initially failed during package test compilation because the concurrent wh-12 test file `Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift` used `NSLock.lock/unlock` directly in an async method. The wh-12 owner moved that synchronization into a synchronous helper; no wh-13 files were changed for the issue.
- Final-source build: `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-13-gc-sweep/attempt-19/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-13-gc-sweep/attempt-19/build.log'` passed, exit 0.
- Final-source focused suite: `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaDataGarbageCollector|GarbageCollection" > tmp/work-handover/wh-13-gc-sweep/attempt-20/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-13-gc-sweep/attempt-20/focused.log'` passed, 37 tests, 0 failures, exit 0.
- Final-source exact changed-file SwiftLint (`attempt-19/changed-swift-files.nul`, `attempt-19/swiftlint.log`) passed, exit 0. `git diff --check` (`attempt-19/diff-check.log`) passed, exit 0.
- Source hashes: `Sources/RielaCore/RielaDataGarbageCollector.swift` `9899cb3d5d9bc2ac4f2d541b0299d1f2d29ed9489f176d26d1fcc19d3e969198`; `Tests/RielaCoreTests/RielaDataGarbageCollectorHandoverTests.swift` `51f35db485e51ed191c2ad69772ebefde56ab69b616722a99c7f968c0e718a63` (full manifest: `attempt-19/final-source-sha256.txt`).

## Completion

- [x] File and local-ref sweep implementation and tests are present.
- [x] Final-source build, focused collector tests, changed-file SwiftLint, and `git diff --check` are complete.
- [ ] Downstream test-integrity, adversarial, and serial integration reviews remain pending in their workflow steps.

## Step 6 test-integrity self-repair

- Finding: `RielaDataGarbageCollectorHandoverTests` file-sweep tests (`testHandoverFilesRemoveTerminalAndAbsentTasksAndDryRunReportsEveryDecision`, `testMissingTaskDatabaseLeavesHandoverFilesUntouchedAndReportsDiagnostic`) used `<cwd>/tmp/...` roots inside the enclosing repository worktree with home == project, so `collectHandoverRefs` could resolve the enclosing repo and delete real `refs/riela/handovers/` refs.
- Change (test-only): both tests now run `git init -q` in the temp home right after `makeRoot()`, confining the ref sweep to a throwaway repo with an empty ref namespace; added `handoverRefs == []` assertions (dry-run and real pass in the first test, real pass in the second).
- Verification: focused `swift test --filter "RielaDataGarbageCollector|GarbageCollection"` exit 0 (37 tests, 0 failures); swiftlint --strict on the changed test file exit 0. Evidence under tmp/work-handover/wh-13-gc-sweep/step6-review/.

## Step 7 adversarial self-repair

- Finding (mid): `collectHandoverFiles` swept `<gcRoot>/handovers`, but file-sink packets are written to `<session-store>/handovers` (`<gcRoot>/sessions/handovers`) or the Work Runtime store root's `<gcRoot>/sessions/runtime-records/handovers`, so the sweep never matched real data (tests seeded the wrong directory).
- Change: `Sources/RielaCore/RielaDataGarbageCollector.swift` now sweeps exactly those two directories (no longer `<root>/handovers`), both against `<root>/sessions/runtime-records/runtime-message-log.sqlite`, with unchanged per-directory semantics plus a refusal (diagnostic + `.skipped`) when `sessions` or `sessions/runtime-records` is a symbolic link.
- Tests: `RielaDataGarbageCollectorHandoverTests` seed `sessions/handovers` and additionally `sessions/runtime-records/handovers` (terminal removed / active kept, dry-run and real); missing-database test uses `.riela/sessions/handovers/task-unknown`.
- Verification (logs under `tmp/work-handover/wh-13-gc-sweep/step7-review/repair/`): `build.log` exit=0; `focused.log` exit=0 (37 XCTest executed, 0 failures); `swiftlint.log` exit=0; `diff-check.log` exit=0.
