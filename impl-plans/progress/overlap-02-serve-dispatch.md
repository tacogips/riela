# overlap-02-serve-dispatch progress

## Plan status

- [x] Dependency `overlap-01-contracts` admitted by `acceptedPlanIds`.
- [x] Read accepted dispatch plan and design §§3, 4.3, 6.1–6.8, 7, 8, 11, 14.
- [x] Added injected serve clock, workflow trigger-default resolver, and session-start observer seam.
- [x] Added per-binding tracked cron dispatcher, policy outcomes, receipts, cancellation settlement/timeout, drain and shutdown cancellation.
- [x] Switched polling from `dueTick` to ascending bounded `dueTicks`; concurrent policy submits every due tick and other policies submit only latest with coalesced count.
- [x] Serialized serve-record read-modify-write and persisted startup `overlapPolicies`.
- [x] Updated cron tests and added deterministic skip, queue, cancellation, timeout, supersede, shutdown, due tick, non-blocking serve, and real-runner cancellation tests.
- [x] Add direct coverage for concurrent caps.
- [x] Add direct coverage for startup workflow/default resolution and unresolved-workflow fallback; binding precedence is exercised by the binding-policy dispatcher tests.
- [x] Add direct coverage for invalid binding policy failing closed and writing a failed serve record.
- [x] Add direct coverage that concurrent submits all due ticks without coalescing and skip records `coalescedTickCount` on the latest fire.
- [x] Add direct coverage that a queued routine is re-checked before deferred start and skipped after becoming disabled.
- [x] OVL02-TI-01: shutdown discards queued and pending fires with `overlap-shutdown-discarded:binding`; a cooperative active run is cancelled and no deferred fire starts.
- [x] OVL02-TI-02: routine accounting covers concurrent successes, skipped fires, failed runs and a cancelled run followed by a successful superseding run.
- [x] Shutdown timeout continuation is installed before its timer task; timer scheduling is independent of the dispatcher actor executor.

## Changed-file hashes

| Path | Pre-edit SHA-256 | Final SHA-256 |
|---|---|---|
| `Sources/RielaCLI/EventServeClock.swift` | new | `3aff872937b28c2a82f6a828d23c5ad4745092735e533034c574bebbdb3f1f46` |
| `Sources/RielaCLI/EventCronOverlapDispatcher.swift` | new | `046ed18d22204c651bbefd064bb9bce4c408906ee5667d59e2483bec5ffac892` |
| `Sources/RielaCLI/EventLiveServe.swift` | `c55f75a58fbcddfb77722a1f28b4f6832cbfdc66b7687924658fc3061f203dcb` | `6222967efdf5c174931e3869fbef06136c88d4f7582d71f5ac7b0acc5e28b612` |
| `Sources/RielaCLI/EventLiveServe+Cron.swift` | `87191301f30d6d4a93405e058c96c6b3cdef048f669b932a91b2de488d2e4ee4` | `23966730c231568360321898b3437c27870df92ee38527d44f58c1d1b785cb97` |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | `d5a75d7c8d4a706018673a7bf8b4fc31db0e310167a67daf9f950ad60a9019c8` | `2659e5cf341dab382e1052db6e5ac64bb3237f3d2401f2655fdbf9a8bf0bec68` |
| `Tests/RielaCLITests/EventCronOverlapTests.swift` | new | `642aaa0a91e045be254ae094d47fcb16d15e17b8f1c5cc33ea3d2b3923b4b0d0` |
| `Tests/RielaCLITests/EventLiveServeCronTests.swift` | `0b6cb694a1539af03acf9d3f13e67b5aedbede32d1294ec3942cb6759cf1f7ed` | `d7250c4d0a174416c353c61885bf44d09076fedf548f41813676dbe6f42620c5` |

## Limit-path changes

All seven source-specific `--limit` exits (webhooky, cron, file-change, Telegram, Discord, Slack and Matrix) now drain the dispatcher before reporting completion. The loop-final exit also drains. Signal/error exits call `shutdownCancelling()` from an unstructured task before rethrowing.

## Verification

| Gate | Command | Exit | Tests | Failures | Log |
|---|---|---:|---:|---:|---|
| V1 | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v1-build-final.log` |
| V2 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServeCronTests"'` | 0 | 18 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v2-overlap-final.log` |
| V3 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventLiveServeTests|EventLiveServeFileChangeTests|EventLiveServeWebhookyTests|EventLiveServeSlackTests|EventLiveServeMatrixTests|EventLiveServeIsolationTests|EventReadOnlyPolicyTests|WorkflowCommandLivePersistenceEventTests"'` | 0 | 59 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v3-regression-final.log` |
| V4 | `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v4-lint-final.log` |
| V1 continuation 1 | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v1-continuation1-final-build-2.log` |
| V2 continuation 1 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServeCronTests"'` | 0 | 22 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v2-continuation1-final-overlap-2.log` |
| V3 continuation 1 | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventLiveServeTests|EventLiveServeFileChangeTests|EventLiveServeWebhookyTests|EventLiveServeSlackTests|EventLiveServeMatrixTests|EventLiveServeIsolationTests|EventReadOnlyPolicyTests|WorkflowCommandLivePersistenceEventTests"'` | 0 | 59 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v3-continuation1-final-regression-2.log` |
| V4 continuation 1 | exact changed-file `swiftlint lint --strict --quiet --no-cache` through `changed-swift-files.nul` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v4-continuation1-final-lint-2.log` |
| V5 continuation 1 | `git diff --check` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v5-continuation1-final-diff-check-2.log` |

The final continuation V2 log includes 14 `EventCronOverlapTests` and eight `EventLiveServeCronTests`. It covers binding-over-workflow startup precedence, workflow/default resolution, unresolved-workflow diagnostics, invalid-policy fail-closed behavior, concurrent per-tick dispatch, latest-tick coalescing count, and deferred routine re-check. It also covers serve non-blocking dispatch, concurrent caps, real-runner cancellation with the runtime-owned session id and no live child PID, plus timeout, supersede and shutdown-with-unsettled-run behavior. All 22 tests pass.

## Test-integrity repairs (continuation 2)

- OVL02-TI-01: `testShutdownDiscardsQueuedFireAndCancelsRunningRun` asserts the queued receipt is `discarded` with `overlap-shutdown-discarded:binding`, the cooperative running receipt is `cancelled`, no queued fire starts (`requestCount == 1`), and the running list is empty. `testShutdownDiscardsPendingAfterCancelAndInvalidatesSettleTimeout` asserts the pending receipt remains discarded after the manual clock advances and no deferred run starts.
- OVL02-TI-02: `testRoutineAccountingCountsOnlySuccessfulRuns` asserts two concurrent completions count as two; a skipped fire adds no count; a failed run adds no count and has a failed receipt; and a cancelled run adds no count while its superseding success adds one.
- The pending-shutdown test exposed a timeout scheduling race. `shutdownCancelling()` now stores its continuation before scheduling the timeout and runs that timeout independently of the dispatcher actor. The focused shutdown and routine tests pass.
- Final-source V1 build passed. V2 ran 25 tests with zero failures. V3 ran 59 regression tests with zero failures. V4 strict changed-file SwiftLint and V5 `git diff --check` passed. Final logs: `v1-ti-repair-final-6.log`, `v2-ti-repair-overlap-final-4.log`, `v3-ti-repair-regression-final-4.log`, `v4-ti-repair-lint-final-4.log`, and `v5-ti-repair-diff-check-final-6.log` under the plan evidence directory.
- Pending-fire discard and stale settle-token behavior pass with cooperative cancellation; the existing cancellation-ignoring shutdown test independently verifies the 30-second bound. The additional cancellation-ignoring pending-fire test variant could not stably register both manual-clock sleepers under bounded `Task.yield` waits and was stopped (exit 130); its incomplete attempt is retained as `debug-shutdown-pending-detached.log`. The earlier interrupted focused run is retained as `v2-ti-repair-overlap.log` and exited 130. The final V2 log above is source-matched after the repair.

## Prior attempts retained

- `v1-build-attempt-1.log` and `v1-build-attempt-2.log`: compiler caught actor capture / receipt-id shadowing issues; fixed before final build.
- `v2-overlap-attempt-1.log`: initial cancellation receipt timing assertion failed; added bounded receipt-file wait and corrected the race.
- `v2-real-runner-debug*.log` and `v2-real-runner-attempt-*.log`: fixture defaults/mapping and ISO8601 decoding were corrected; final real-runner test passes in V2.
- `v2-continuation1-overlap.log` and `v2-continuation1-final-overlap.log`: new startup/receipt/routine tests initially exposed test-side diagnostic escaping and ISO8601 receipt decoding assumptions; assertions were corrected to the canonical diagnostic and decoded JSON values. The source-final V2 log passes 22 tests.
- `v4-continuation1-verified-lint.log`: SwiftLint caught a large tuple in the startup test case table; replaced it with named `StartupResolverCase` fields. The final selected-file lint passes in `v4-continuation1-final-lint-2.log`.
- `v4-lint.log` and `v4-lint-final.log` preserve initial lint findings and the clean final strict lint result.

## Concurrent tree note

Other plan workers updated their declared files in this shared working tree. This plan changed only its declared paths: the seven Swift files listed above and this progress record. No generated SDL or Git write operation was used.

## Adversarial repair (OVL02-ADV-01)

- `CronOverlapDispatcher` now has `drainAbandoned`; `abandonDrain()` removes and resumes stored continuations exactly once. `drain()` rechecks both drained and abandoned state before registering and after each resume.
- All seven source-specific `--limit` drains call `drainHonoringCancellation`. The loop-final drain is now inside the existing `do/catch`; the helper abandons the drain on task cancellation, then checks cancellation so the catch invokes `shutdownCancelling()`.
- Added `testDrainHonorsCancellationAndShutdownCancelsRun`, using the helper, `ManualEventServeClock`, and cooperative `BlockingCronRunner`. It verifies cancellation exits drain, shutdown records the run as `cancelled`, and no extra request starts.
- A serve-entry cancellation fixture was attempted with the manual and advancing test clocks. The serve task did not create `serve-record.json` under the bounded-yield readiness checks, so those attempts are retained as failed evidence and were replaced by the direct helper/dispatcher test. This leaves the adversarial request for a serve-entrypoint behavioral test open; source inspection confirms all drain sites use the helper and the final drain is inside the catch scope.

| Gate | Command | Exit | Tests | Failures | Log |
|---|---|---:|---:|---:|---|
| V1 adversarial repair | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v1-adv-repair-final.log` |
| V2 adversarial repair | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServeCronTests"'` | 0 | 26 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v2-adv-repair-overlap-final.log` |
| V3 adversarial repair | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventLiveServeTests|EventLiveServeFileChangeTests|EventLiveServeWebhookyTests|EventLiveServeSlackTests|EventLiveServeMatrixTests|EventLiveServeIsolationTests|EventReadOnlyPolicyTests|WorkflowCommandLivePersistenceEventTests"'` | 0 | 59 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v3-adv-repair-regression-final.log` |
| V4 adversarial repair | `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v4-adv-repair-lint-final.log` |
| V5 adversarial repair | `git diff --check` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v5-adv-repair-diff-check.log` |

- Failed serve-entry attempts are preserved in `v2-adv-repair-overlap.log` (exit 1; 26 tests, 3 failures), `v2-adv-repair-final-overlap.log` (exit 1; 26 tests, 3 failures), `debug-limit-cancel.log` (exit 1; 1 test, 3 failures), `debug-limit-cancel-final.log` (exit 1; 1 test, 3 failures), `debug-limit-cancel-fixed.log` (exit 1; 1 test, 4 failures), `debug-limit-cancel-final-2.log` (exit 1; 1 test, 4 failures), `debug-limit-cancel-autoclock.log` (exit 1; 1 test, 3 failures), `debug-limit-cancel-detached.log` (exit 1; 1 test, 3 failures), `debug-limit-cancel-readiness.log` (exit 1; 1 test, 3 failures), and `debug-limit-cancel-inherited.log` (exit 1; 1 test, 3 failures). The successful final V2 replaces these as current behavioral evidence only for the helper/dispatcher path.
- The current changed-file lint manifest remains nonempty and lists the seven plan-owned Swift files. Final V1-V4 mtimes postdate all three changed Swift files.
- Repair-source SHA-256: `Sources/RielaCLI/EventCronOverlapDispatcher.swift` `af6ede7cc02b7a0d0d41c24f27b8eab7dbad44f0d5ee2f8342727119b84c520f`; `Sources/RielaCLI/EventLiveServe.swift` `bef0ed72ba84833384e197683ecaa5f6c714f384193db3d41ff6aed2f18a18f6`; `Tests/RielaCLITests/EventCronOverlapTests.swift` `c91e25fc543d679d263516ed6fb047954572284d55e30e73154b0f87880a5e54`.

## Adversarial repair continuation: serve-entry drain cancellation

- Replaced helper-only coverage with `testSignalDuringLimitDrainCancelsRunAndReturns`, which starts `DefaultEventLiveServer.serve` with `--limit 1`, waits for the ready serve record and registered manual-clock sleep, advances to a due cron tick, waits until the cooperative runner starts, then cancels the serve task. It asserts the serve throws `CancellationError`, the dispatched receipt is `cancelled`, and `requestCount == 1`.
- The first revised attempt (`v2-adv-serve-entry-attempt-2.log`) exited 1 because the existing 500-yield runner wait cancelled before the async dispatcher task was scheduled. The bounded readiness loop was expanded to 50,000 yields; `v2-adv-serve-entry-attempt-3.log` then passed the serve-entry test (1 test, 0 failures). Both complete logs are retained.
- Final source verification after the test edit: V1 build exit 0; V2 overlap suites ran 26 tests, 0 failures; V3 regression suites ran 59 tests, 0 failures; V4 strict lint of the nonempty seven-file NUL manifest exit 0. Exact commands and logs:

| Gate | Command | Exit | Tests | Failures | Log |
|---|---|---:|---:|---:|---|
| V1 serve-entry repair | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v1-adv-serve-entry-final.log` |
| V2 serve-entry repair | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests|EventLiveServeCronTests"'` | 0 | 26 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v2-adv-serve-entry-overlap-final.log` |
| V3 serve-entry repair | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventLiveServeTests|EventLiveServeFileChangeTests|EventLiveServeWebhookyTests|EventLiveServeSlackTests|EventLiveServeMatrixTests|EventLiveServeIsolationTests|EventReadOnlyPolicyTests|WorkflowCommandLivePersistenceEventTests"'` | 0 | 59 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v3-adv-serve-entry-regression-final.log` |
| V4 serve-entry repair | `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-02-serve-dispatch/v4-adv-serve-entry-lint-final.log` |

- Current repair-source SHA-256: `Sources/RielaCLI/EventCronOverlapDispatcher.swift` `af6ede7cc02b7a0d0d41c24f27b8eab7dbad44f0d5ee2f8342727119b84c520f`; `Sources/RielaCLI/EventLiveServe.swift` `bef0ed72ba84833384e197683ecaa5f6c714f384193db3d41ff6aed2f18a18f6`; `Tests/RielaCLITests/EventCronOverlapTests.swift` `eb8eb777c4797d3f39196dbda7cd3cc0e96d34e95cbb6124ab706bdec6718628`.
- OVL02-ADV-01 completion criteria are now behaviorally covered through the actual `serve` task: cancellation during the `--limit` drain reaches shutdown, terminalizes the run receipt as cancelled, and starts no additional run. The non-cancelled drain and shutdown behavior remain covered by the existing focused suite. All source-specific drains still use the cancellation-aware helper and the final drain remains inside the shutdown `do/catch`.
