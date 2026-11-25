# bots-03-activity-core implementation progress

Design acceptance: `comm-000004`. Plan acceptance: `comm-000008`.
Dispatch admitted `bots-01-contracts` as the accepted prerequisite for this plan.
Branch: `feat/bots-overview`. Checkpoint: `666108c9f32fe3f926d5c1448ab8f2063c4f714a`.

## Implemented

- `Sources/RielaCore/BotActivity/ActivityReducer.swift` projects typed adapter updates and produces idempotent terminal events. It derives all times from its inputs.
- `Sources/RielaCore/BotActivity/ActivityJournal.swift` allocates sequences and commits bounded event payloads, retention, and activity state in one SQLite transaction. User answers and reconciliation honor the recorder's persisted per-session retention and payload limits.
- `Sources/RielaCore/BotActivity/ActivityStore.swift` provides snapshot-consistent replay, cursor polling with authorization checks, state and pending request reads, retention deletion, and orphan settlement.
- `Sources/RielaCore/BotActivity/ActivityRequests.swift` and the recorder permission extension persist requests, enforce first-answer semantics and deadlines, and publish the resolution with the status transition. Cancellation cleanup awaits an uncancelled task because opening a SQLite writer honors cancellation.
- `Sources/RielaCore/BotActivity/SQLiteWorkflowActivityRecorder.swift` and its text extension coalesce chunks, flush ahead of structural events, finalize streamed messages, and clear an execution's open activity on settlement.
- The agent, stdio, add-on, and supervised add-on callers each use `settlingActivity`. Supervised retries share the execution's activity until the supervisor completes, and each attempt uses its own permission deadline.
- `Tests/RielaCoreTests/BotActivity/` covers reducer semantics, journal replay and retention, permissions, polling, runner settlement, and the recorder-free runner outcome.

## Per-edit hashes

The complete before/after SHA-256 pairs and exact intended hunks are in
`tmp/bots-overview/bots-03-activity-core/edit-intentions.md` and
`tmp/bots-overview/bots-03-activity-core/tests-edit-intentions.md`.
`tmp/bots-overview/bots-03-activity-core/scope.log` records the comparison of
all 17 Swift paths with the native pre-node snapshot and the final per-edit hashes.
The snapshot is
`tmp/riela-fanout/68A31AD1-C959-4C01-8C17-8D92D36E7A1B/4C23F682-3243-4891-913F-9E88BA26DBD7.json`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "ActivityReducerTests|ActivityRecorderTests|ActivityPermissionTests|ActivitySettlementRunnerTests|ActivityWaitTests|DeterministicWorkflowRunnerTests"'` exited 0. Complete log: `tmp/bots-overview/bots-03-activity-core/test.log`. Executed 66 tests with 0 failures. Suite counts were reducer 6, recorder 6, permissions 8, runner settlement 6, wait 3, and existing runner 37.
- Strict selected-file SwiftLint exited 0. The arm64 invocation runs `xargs -0 swiftlint lint --strict --quiet --no-cache` on the 17 paths in `tmp/bots-overview/bots-03-activity-core/changed-swift.nul`. Complete log: `tmp/bots-overview/bots-03-activity-core/swiftlint.log`.
- `grep -rn "settlingActivity" Sources/RielaCore` exited 0 and printed the helper and four call sites. Complete log: `tmp/bots-overview/bots-03-activity-core/settling-activity-final.log`.
- `grep -rn "Date()" Sources/RielaCore/BotActivity/ActivityReducer.swift` exited 1 with no matches. The no-match check exited 0 and logged to `tmp/bots-overview/bots-03-activity-core/reducer-no-clock.log`.
- Scoped `git diff --check` exited 0. Complete log: `tmp/bots-overview/bots-03-activity-core/diff-check-final.log`. The existing `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` matched the checkpoint.
- The 17 Swift file hashes matched before and after tests and matched the final working tree. Evidence: `tmp/bots-overview/bots-03-activity-core/test-source-before.sha256`, `tmp/bots-overview/bots-03-activity-core/test-source-after.sha256`, and `tmp/bots-overview/bots-03-activity-core/final-source-check.log`.

## Deviations

- Tool projection trimming evicts terminal calls first. If an execution has more than 200 simultaneously open calls, the projection keeps all open calls so terminal settlement can close them. The event journal still enforces its retention bound.
- When the last text was already delivered, settlement appends an empty final message delta carrying the same retained message ID. This preserves the replay cursor and the last message line.
- The Swift test runs used the moving shared tree. Earlier attempts encountered plan-local compile errors, a shared SwiftPM build database lock, and a sibling edit to `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` during compilation. The complete attempt logs remain under the plan evidence directory.

## Open items

Formal test-integrity, adversarial, and serial integration review are pending. All implementation-phase checks in the assigned plan passed.

## Redispatch verification

- A whole ACP message now carries `replace: true` on its activity event so replay and live consumers can replace text already delivered for the same message ID. Later chunks in the same buffer retain that flag. The regression checks the replacement payload, the current state and the next replay cursor after a tool event flushed the earlier text.
- All 19 files in the redispatch snapshot matched before editing. Intentions and before/after hashes are in `tmp/bots-overview/bots-03-activity-core/`, alongside `redispatch-snapshot.log`. All 17 Swift hashes matched before and after the final test and matched the working tree.
- The exact arm64 Swift test filter above exited 0 on the shared tree. `tmp/bots-overview/bots-03-activity-core/redispatch-test-final.log` records 67 tests and zero failures. Counts were reducer 6, recorder 7, permissions 8, runner settlement 6, wait 3, and existing runner 37. The first redispatch run reported 67 passing tests but its shell wrapper failed to capture the exit status. Its log remains in `tmp/bots-overview/bots-03-activity-core/redispatch-test.log`.
- Exact-file strict SwiftLint exited 0 in `tmp/bots-overview/bots-03-activity-core/redispatch-swiftlint-final.log`. The settlement grep found one helper and four callers in `tmp/bots-overview/bots-03-activity-core/redispatch-settlement-sites-final.log`. The runner regression suite matched the checkpoint.
- The standalone `grep -rn 'Date()' Sources/RielaCore/BotActivity/ActivityReducer.swift` exited 1 with an empty `tmp/bots-overview/bots-03-activity-core/redispatch-clock-guard-final.log`. Record this as the expected no-match source guard. The previous compound command placed the shell `test` builtin immediately after the `.swift` path on a new line, which matched the workflow gate's behavioral test pattern.
