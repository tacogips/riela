# wh-16 GraphQL provider progress

Plan: `impl-plans/active/wh-16-graphql-provider.md`
Mode: `issue-resolution`
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.
Branch: `feat/work-handover-and-takeover`; plan DAG dependencies: none (`dependsOn: []`; `acceptedPlanIds: []`).
Plan: `wh-16-graphql-provider`; fanout branch: `wh-16-graphql-provider`; Riela codex-agent: `step6-implement`, workflow execution `nested-v1-6ba6e2b9560f4b00f822179b2200b43a165faa623a2e0f8f926f5b7773dc32fc`.

## Implementation

- Implemented `TaskHandoverGraphQLProvider` in `Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`; it locates stores, exposes the seven handover operations, validates traits and required placement, reserves via `TaskDispatcher`, issues the lease credential, and delegates remote reports to `TaskDispatch.reconcileExternalTerminal`.
- Wired the GraphQL document executor into `Sources/RielaCLI/ServeWebHost.swift`, `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift`, and `Sources/RielaCLI/RielaLibrary.swift`; serve enforces manager bearer authorization. Added provider tests for fields, authorization, takeover, heartbeat, completed report, suspended report, and replay.
- Forwarded remote host IDs through `Sources/RielaWork/TaskDispatcher.swift`. R31 rotates the one-use launch-token digest to a random lease credential digest in both attempt and lease records; takeover returns the credential, and launch-token replay remains rejected. No schema column or generation change was made; `Sources/RielaWork` contains no `consumed:` digest.
- Session 12 fixed completed report reconciliation. `WorkStore.reservationDecision(attemptId:)` first resolves the consumed pending reservation's decision and falls back to the latest decision naming a plain-reserved attempt. `TaskDispatch+Handover.swift` now uses this API and retains the existing `reconcileTerminal` path. Added pending takeover, plain reservation, and unknown attempt coverage.
- The completed provider test asserts `taskState == succeeded` and `decisionKind == accept`, then verifies sequential report replay throws `unauthorized` without changing task state or decision count. The predecessor fixture now persists the failed/stalled session snapshot referenced by its attempt and packet.
- Session 13 implements R32: `WorkStore.claimLeaseForReport(attemptId:token:now:)` rotates the lease and attempt launch digests to an unreturned random digest in one transaction. A losing or replayed claim returns `false` without writes; the lease row, fence, expiry and heartbeat remain available for recovery. `reportAttempt` decodes and validates the snapshot and deliverables before claiming, then reconciles only after a successful claim. It no longer calls `verifyLeaseToken`; `heartbeatAttempt` still does.
- Added `WorkStoreLeaseTests` coverage for successful claim, re-claim, wrong and missing lease, unchanged state on failed claims, two-store concurrent claims, and expiry recovery after claim. Added `testConcurrentReportsWithSameCredentialReconcileExactlyOnce`: one report succeeds with `succeeded`/`accept`, one is unauthorized, and exactly one accept decision is recorded. The existing sequential replay and suspended-report cases remain green.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-s11.log'`: exit 0; build complete; log `tmp/work-handover/wh-16-graphql-provider/build-s11.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreReservationTests|TaskDispatcherTests|WorkStoreTakeoverTests|DecisionApplierStoreTests|WorkStoreCancellationTests" > tmp/work-handover/wh-16-graphql-provider/work-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/work-s11.log'`: exit 0; 81 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/work-s11.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-s11.log'`: exit 0; 43 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/focused-s11.log`.
- The first session-12 focused attempt is preserved at `tmp/work-handover/wh-16-graphql-provider/focused-s11-attempt1.log` (exit 1, 43 tests, 1 fixture failure: missing `session-predecessor` runtime snapshot). The fixture was repaired, and the rerun above passed all 43 tests.
- Selected-file strict SwiftLint used the NUL manifest `tmp/work-handover/wh-16-graphql-provider/session-12/changed-swift-files.nul`; command `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-16-graphql-provider/session-12/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log'`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/diff-check.log`.
- `rg -n 'consumed:' Sources/RielaWork` check: no matches; exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/consumed-digest-check.log`.
- Per-edit preimages, hashes, and intentions are under `tmp/work-handover/wh-16-graphql-provider/session-12/`.

## Blocked completion (resolved)

- The R31 completion blocker was that the lease credential returned to a remote successor did not authenticate against a publicly derivable `consumed:` digest. Authorization now mints a random credential and stores only its digest in both the attempt and lease records; replaying the one-use launch token is rejected. Resolved with session-11 evidence: `build-s11.log` exit 0, `work-s11.log` 81 tests/0 failures, `focused-s11.log` 43 tests/0 failures, and `consumed-digest-r31.log` exit 0. The session-12 rerun also records the no-match check at `session-12/consumed-digest-check.log`.

## Resolved findings

- Resolved medium finding: concurrent `reportAttempt` calls previously could both verify a credential before reconciliation deleted the lease row. The R32 compare-and-swap claim and concurrent regressions above close this race; see `work-s13.log`, `focused-s13.log`, and `concurrent-s13.log` below. No open findings remain for wh-16.

## Completion criteria

- [x] All seven fields are executable through serve, the local document command, and the library; manager-session authorization is enforced in serve.
- [x] Provider, GraphQL, serve, work-store, dispatcher, lease-credential, reservation-decision, completed/suspended report, and sequential replay tests pass in the session-12 gates.
- [x] R31 uses only a random lease credential digest; the launch token is rejected after authorization; no `consumed:` digest remains in `Sources/RielaWork`.
- [x] `reservationDecision(attemptId:)` resolves pending takeover and plain reservations, returns nil for an unknown attempt, and completed remote report reconciles to `succeeded` with `accept`.
- [x] Concurrent `reportAttempt` with one credential reconciles exactly once; the loser gets unauthorized (design §14 Report claim, §21 R32).

## Session-13 R32 verification (Step 6 execution)

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-s13.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-s13.log'`: exit 0; build complete; log `tmp/work-handover/wh-16-graphql-provider/build-s13.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreReservationTests|TaskDispatcherTests|WorkStoreTakeoverTests|DecisionApplierStoreTests|WorkStoreCancellationTests" > tmp/work-handover/wh-16-graphql-provider/work-s13.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/work-s13.log'`: exit 0; 83 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/work-s13.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-s13.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-s13.log'`: exit 0; 44 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/focused-s13.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests/testConcurrentReportsWithSameCredentialReconcileExactlyOnce" > tmp/work-handover/wh-16-graphql-provider/concurrent-s13.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/concurrent-s13.log'`: exit 0; 1 test, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/concurrent-s13.log`.
- Exact changed-Swift strict lint used NUL manifest `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/changed-swift-files.nul`; `xargs -0 swiftlint lint --strict --quiet --no-cache`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/swiftlint.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/diff-check.log`. The `consumed:` search returned no matches (exit 0; `attempt-session-14/consumed-digest-check.log`); the provider has exactly one `verifyLeaseToken` reference, in `heartbeatAttempt` (exit 0; `attempt-session-14/heartbeat-token-check.log`).
- Preserved the first work test attempt (exit 1, 83 tests, one fractional-date assertion precision mismatch) at `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/work-s13-attempt1.log`; the whole-second fixture correction passed all 83 tests. Preserved the first focused attempt (exit 1, 44 tests, one task-version expectation that omitted the normal running-to-verifying transition) at `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/focused-s13-attempt1.log`; the corrected single-report version assertion passed all 44 tests.
- Per-edit preimages, hashes and intended hunks are under `tmp/work-handover/wh-16-graphql-provider/attempt-session-14/`.

Formal test-integrity, adversarial and serial integration reviews, review-owned documentation/index updates, and Git staging/commit/push remain downstream workflow steps. No Git state changes were made in this implementation step.
