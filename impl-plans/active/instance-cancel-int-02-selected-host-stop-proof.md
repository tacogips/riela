# instance-cancel-int-02: Selected-host stop-proof fixture vs. documented 5 s cancellation grace

**planId**: instance-cancel-int-02-selected-host-stop-proof
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-cancel.md §8.2 (D3), C8, §7; docs/app-instance-control.md Cancel section; design-docs/user-qa/qa-instance-cancel-post-merge.md item 1
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-int-02-selected-host-stop-proof.md
**Evidence root**: tmp/instance-cancel-integration/int-02/

## Intent and context

`TaskCancellationIntegrationTests.testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof`
fails on the merged branch with "Worker did not reach its delayed stop
receipt". Here is the verified hypothesis:

- The fixture (`Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift`,
  `assertSelectedHostCancellation`) runs a leader and a child that both do
  `trap '' TERM`.
- It waits at most **4 s** (`let proofDeadline = Date().addingTimeInterval(4)`)
  for the worker executor to throw after Task cancellation.
- The branch's C8 change (`Sources/RielaAdapters/LocalProcess.swift`,
  `cancellationGrace: TimeInterval = 5` and `cancellationHardBound = 5`)
  deliberately waits a 5 s SIGTERM grace before SIGKILL. Before C8 the wait
  was 1 s. The grace is documented user-facing behavior.
- Main's merge did not change `Sources/RielaAdapters`, `Sources/RielaWork`
  or `Sources/RielaServer`.

The design keeps the 5 s grace and corrects only the fixture's wait bound.
**This plan must confirm the hypothesis before it edits anything.**

## Non-goals

- Do NOT edit `Sources/RielaAdapters/LocalProcess.swift`,
  `LocalProcessTree.swift`, or any `Sources/**` file. If the confirmation
  shows a real defect (the executor never throws, or the processes survive
  past grace + hard bound), stop and report a blocker. Do not fix it here.
- Do NOT change, remove or loosen any `XCTAssert*` in the fixture, including
  the message string "Worker did not reach its delayed stop receipt".
- Do not change `readyDeadline`, the late-boundary path, or
  `assertSelectedHostProcessesStopped` unless the confirmation proves they
  depend on the grace. In that case, record the evidence first.

## Step 1: confirm (mandatory, before any edit)

All evidence goes under `tmp/instance-cancel-integration/int-02/`.

1. Static evidence (read-only git):
   - `git diff --stat 293527c8 8ab7f848 -- Sources/RielaAdapters Sources/RielaWork Sources/RielaServer > static-main-diff.txt`
     must be empty.
   - `git diff 4841a578 8ab7f848 -- Sources/RielaAdapters/LocalProcess.swift > c8-diff.txt`
     must show `cancellationGrace: TimeInterval = 5`.
2. Historical run at `293527c8`. Do not use worktrees and do not check out
   any commit. Export the tree read-only:
   `mkdir -p tmp/instance-cancel-integration/int-02/at-293527c8 && git archive 293527c8 | tar -x -C tmp/instance-cancel-integration/int-02/at-293527c8`
   then
   `/usr/bin/arch -arm64 /bin/zsh -lc "cd tmp/instance-cancel-integration/int-02/at-293527c8 && swift test --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof" > tmp/instance-cancel-integration/int-02/at-293527c8.log 2>&1; echo $? > tmp/instance-cancel-integration/int-02/at-293527c8.exit`.
   Expected: non-zero, with the same "delayed stop receipt" failure. If it
   passes, the hypothesis is wrong: stop and report.
3. Current-tree run, unmodified:
   `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof" > tmp/instance-cancel-integration/int-02/head-before.log 2>&1; echo $? > tmp/instance-cancel-integration/int-02/head-before.exit`.
   Expected: non-zero, with the same message.
4. Remove `tmp/instance-cancel-integration/int-02/at-293527c8/` after the
   run (it is large). Keep the logs.

## Step 2: file-level change

### Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift

- Replace the literal `4` in `proofDeadline` with a named bound derived from
  the documented LocalProcess cancellation defaults. For example, a
  `private let selectedHostStopReceiptBound: TimeInterval = 5 + 5 + 4`
  (grace + hard bound + scheduling margin, at least 12 s), with a one-line
  comment citing C8 and the 5 s documented grace. If
  `FoundationLocalProcessRunner`'s defaults are reachable through
  `@testable import RielaAdapters`, you may reference them instead. Do not
  add new public API to do so.
- Keep the loop structure, the `XCTAssertTrue(proofPaused, "Worker did not
  reach its delayed stop receipt")`, and every later assertion.
- Pitfall: the later "after lease and heartbeat" checks use a synthetic
  `now` (`+3_600`). Do not change those. If a lease or heartbeat expiry
  inside the longer real wait breaks a later assertion, stop and report
  with logs. Do not loosen it.

## Step 3: verify

1. `/usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter TaskCancellationIntegrationTests" > tmp/instance-cancel-integration/int-02/after.log 2>&1; echo $? > tmp/instance-cancel-integration/int-02/after.exit`
   Expected: exit 0, 0 failures.
2. Repeat the selected-host test 3 times:
   `for i in 1 2 3; do /usr/bin/arch -arm64 /bin/zsh -lc "swift test --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof" > tmp/instance-cancel-integration/int-02/repeat-$i.log 2>&1; echo $? > tmp/instance-cancel-integration/int-02/repeat-$i.exit; done`
   Expected: all three exit 0.
3. `/usr/bin/arch -arm64 /bin/zsh -lc "swiftlint lint Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift"`
   Expected: no violations.

## Invariants

- C8 behavior and `docs/app-instance-control.md` are unchanged.
- No assertion is removed or weakened. `git diff` of the fixture shows only
  the bound constant/comment change.

## Done criteria (mechanical)

- `static-main-diff.txt` is empty, `at-293527c8.exit` is non-zero,
  `head-before.exit` is non-zero, `after.exit` is 0, and `repeat-{1,2,3}.exit`
  are all 0.
- `git diff -U0 Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift | grep '^-.*XCTAssert'`
  prints nothing.
- The progress log records the pre/post sha256 of the fixture, every
  command, its exit code and its log path.

## Concurrency / drift rules

Before the edit, re-read the file fresh and record its sha256. Re-check the
sha256 immediately before writing. If it changed and you did not change it,
stop and report drift. Touch no other plan's files. Git use is read-only
(`git diff`, `git archive`, `git status`).

## Amendment 2026-11-11 (blocked-wave-scope-or-contract, round 1)

Blocker: Step 1.2 needs a location authorized for build artifacts, to hold
the git-archive export of `293527c8` and its SwiftPM `.build` outputs.

Decision:

- Authorized artifact root, added to this plan's `writePaths` **and**
  `artifactRoots`:
  `tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/archive-293527c8`.
  The runtime records it as a digest/count manifest only, never as content.
  It is not a source path.
- Step 1.2 now runs entirely inside that root. This replaces the earlier
  `tmp/instance-cancel-integration/int-02/at-293527c8` location:
  - `mkdir -p tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/archive-293527c8 && git archive 293527c8 | tar -x -C tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/archive-293527c8`
  - `/usr/bin/arch -arm64 /bin/zsh -lc "cd tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/archive-293527c8 && swift test --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof" > tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/at-293527c8.log 2>&1; echo $? > tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/at-293527c8.exit`

  The build output (`.build`) stays inside the archive root, because SwiftPM
  builds in the package directory. Do not pass `--scratch-path` outside it,
  and do not use the worktree's own `.build` for this run.
- Logs and exit files for every step go directly under
  `tmp/instance-cancel-integration/instance-cancel-int-02-selected-host-stop-proof/`,
  outside the artifact root. They are evidence, not artifacts. All
  `tmp/instance-cancel-integration/int-02/...` paths in this plan map to
  that directory.
- Step 1.4 (removing the export after the run) is kept, and must happen only
  after `at-293527c8.exit` is written. Record the export's `du -sh` before
  removal in the progress log.
- Unchanged: the plan's intent and non-goals, the requirement to confirm
  before editing, the stop-and-report rule, the fixture-only change, every
  assertion, and the verification commands of Steps 1.3 and 3 (with logs
  redirected to the directory above).
- Accepted dependencies, not re-planned: `instance-cancel-int-01-busy-terminal-session`
  and `instance-cancel-int-03-definition-store-generation` (accepted at
  integration review, wave 006).
