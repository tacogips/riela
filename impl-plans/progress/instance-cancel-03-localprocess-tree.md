# instance-cancel-03-localprocess-tree progress

Implementation is incomplete and has not passed review. Added process snapshots, descendant tracking, a cancellation driver and initial tree regression tests. These changes require compilation and behavioral verification, plus review of the cancellation/reaping race and PID identity guard.

The required aggregate test includes `LocalProcessForegroundLifetimeTests`, which creates fixtures under `tmp/specialist-supervisor/process-lifetime/`, outside the declared artifact root `tmp/instance-cancel/instance-cancel-03-localprocess-tree/`. The test was not run. Amend the checkpoint to authorize that fixture path or assign its owner a fixture-path change, then run the full prescribed aggregate and pgrep checks. Do not substitute a narrower suite for that gate.

An initial default-path build was interrupted after it began dependency resolution. The isolated build log is `tmp/instance-cancel/instance-cancel-03-localprocess-tree/build.log`; it began before the final source edits, so its result cannot establish final-source success. An earlier strict selected-file lint passed (exit 0, `tmp/instance-cancel/instance-cancel-03-localprocess-tree/lint.log`) before the last source edits and must be rerun on final source. Review, commit and push remain downstream.

Author self-check: the current hard-bound loop signals tracked PIDs repeatedly but signals the owned group only once. The plan requires repeated owned-group SIGKILL until the tracked set clears or the hard bound expires. Correct and verify this before review. The current process-tree test suite also still needs a pre-change regression demonstration and the full prescribed pgrep evidence.

The isolated `swift build --scratch-path tmp/instance-cancel/instance-cancel-03-localprocess-tree/build` completed with exit 0 (`build.log`, `build.exit`). It was started before the final edits and ran on a shared moving tree; rerun against final source after the blocker is resolved.

## 2026-11-11 continuation

The accepted scope amendment authorizes the existing foreground fixture root and shared `.build`. The cancellation driver now repeats the owned-group SIGKILL during escalation. Fixture teardown trims PID files, and the tests assert leader disappearance, the hard elapsed bound, and two seconds of cooperative cleanup. The earlier statements above describe the prior attempt.

Pre-change regression rationale from the stash-free diff: the old cancellation path signalled only the owned group, and the leader-exit observer immediately killed that group. The separate-group child therefore survived, and cooperative cleanup in the owned group could be preempted. The new separate-group and cooperative assertions exercise these failure mechanisms.

Final-source arm64 `swift build` exited 0 (`tmp/instance-cancel/instance-cancel-03-localprocess-tree/build-final.log`). The assigned aggregate `swift test --filter "LocalProcessCancellationTreeTests|LocalProcessForegroundLifetimeTests|LocalProcessAdmissionTests|LocalProcessWallDeadlineTests"` exited 0, 15 tests and zero failures (`test-final.log`). Both `pgrep-before-final.log` and `pgrep-after-final.log` are empty. Strict changed-file SwiftLint exited 0 (`lint-final.log`, `changed-swift.nul`). Evidence files are under `tmp/instance-cancel/instance-cancel-03-localprocess-tree/`; verification ran on the shared working tree. Formal review, serial integration, commit and push remain downstream.

## Adversarial revision IC03-LEADER-GRACE

The grace loop now waits for the WNOWAIT-observed leader exit as well as tracked descendants; the hard-bound escalation and normal-exit, deadline and await-owner paths were not changed. The new childless leader regression failed before the source correction (one test, one missing-marker assertion; `leader-grace-before.log`) and passed afterward. The aggregate ran 16 tests with zero failures, including PID reuse; both `pgrep-before-leader-grace.log` and `pgrep-after-leader-grace.log` are empty. Build, aggregate, plan lint and strict changed-file lint exited 0; logs `build-leader-grace.log`, `test-leader-grace.log`, `lint-leader-grace-plan.log`, `lint-leader-grace.log` and exit files are under the evidence root. Runs used the shared working tree.

Source SHA-256 before → after: `LocalProcess.swift` d95b63aa5f142c3bee3f6e2af5fbe3584961b3a8ba0170b01b9ca61daf687704 → cf51d8d14c8929f61ddcd58b6b41570d694220212182228dca8e1f49479cd7b1; `LocalProcessCancellationTreeTests.swift` ee83c64908f4d2b526fcee94ae601d852e84fac7f5c7f026f44c025adb1e64f8 → 0aa9e28dea560b0b0be3a919a4d21a1b0969ae1d7f6260d20282f45bc49242a3. Full pre/post hashes and edit intentions are in the evidence root. Independent re-review and serial integration remain downstream.
