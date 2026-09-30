# wh-16 GraphQL provider progress

Plan: `impl-plans/active/wh-16-graphql-provider.md`
Mode: `issue-resolution`
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.
Branch: `feat/work-handover-and-takeover`; plan DAG dependencies: none (`dependsOn: []`; `acceptedPlanIds: []`).
Plan: `wh-16-graphql-provider`; fanout branch: `wh-16-graphql-provider`; Codex agent: `step6-implement`, workflow execution `nested-v1-3575f80232b28a810bd9821dec778a1558ec9879ab1ae29e5a83ce8f1ebb5230`.

## Implementation

- Implemented `TaskHandoverGraphQLProvider` in `Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`; it locates stores, exposes the seven handover operations, validates traits and required placement, reserves via `TaskDispatcher`, issues the lease credential, and delegates remote reports to `TaskDispatch.reconcileExternalTerminal`.
- Wired the GraphQL document executor into `Sources/RielaCLI/ServeWebHost.swift`, `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift`, and `Sources/RielaCLI/RielaLibrary.swift`; serve enforces manager bearer authorization. Added provider tests for fields, authorization, takeover, heartbeat, completed report, suspended report, and replay.
- Forwarded remote host IDs through `Sources/RielaWork/TaskDispatcher.swift`. R31 rotates the one-use launch-token digest to a random lease credential digest in both attempt and lease records; takeover returns the credential, and launch-token replay remains rejected. No schema column or generation change was made; `Sources/RielaWork` contains no `consumed:` digest.
- Session 12 fixed completed report reconciliation. `WorkStore.reservationDecision(attemptId:)` first resolves the consumed pending reservation's decision and falls back to the latest decision naming a plain-reserved attempt. `TaskDispatch+Handover.swift` now uses this API and retains the existing `reconcileTerminal` path. Added pending takeover, plain reservation, and unknown attempt coverage.
- The completed provider test asserts `taskState == succeeded` and `decisionKind == accept`, then verifies sequential report replay throws `unauthorized` without changing task state or decision count. The predecessor fixture now persists the failed/stalled session snapshot referenced by its attempt and packet.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-s11.log'`: exit 0; build complete; log `tmp/work-handover/wh-16-graphql-provider/build-s11.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreReservationTests|TaskDispatcherTests|WorkStoreTakeoverTests|DecisionApplierStoreTests|WorkStoreCancellationTests" > tmp/work-handover/wh-16-graphql-provider/work-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/work-s11.log'`: exit 0; 81 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/work-s11.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-s11.log'`: exit 0; 43 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/focused-s11.log`.
- The first session-12 focused attempt is preserved at `tmp/work-handover/wh-16-graphql-provider/focused-s11-attempt1.log` (exit 1, 43 tests, 1 fixture failure: missing `session-predecessor` runtime snapshot). The fixture was repaired, and the rerun above passed all 43 tests.
- Selected-file strict SwiftLint used the NUL manifest `tmp/work-handover/wh-16-graphql-provider/session-12/changed-swift-files.nul`; command `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-16-graphql-provider/session-12/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log'`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/swiftlint-arm64.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/diff-check.log`.
- `rg -n 'consumed:' Sources/RielaWork` check: no matches; exit 0; log `tmp/work-handover/wh-16-graphql-provider/session-12/consumed-digest-check.log`.
- Per-edit preimages, hashes, and intentions are under `tmp/work-handover/wh-16-graphql-provider/session-12/`.

## Findings

- `{ "severity": "medium", "finding": "Two concurrent reportAttempt calls can both verify the lease credential before the first reconciliation deletes the lease row.", "coverage": "Sequential replay is tested and rejected; concurrent replay is not serialized or tested in this plan." }`

## Completion criteria

- [x] All seven fields are executable through serve, the local document command, and the library; manager-session authorization is enforced in serve.
- [x] Provider, GraphQL, serve, work-store, dispatcher, lease-credential, reservation-decision, completed/suspended report, and sequential replay tests pass in the session-12 gates.
- [x] R31 uses only a random lease credential digest; the launch token is rejected after authorization; no `consumed:` digest remains in `Sources/RielaWork`.
- [x] `reservationDecision(attemptId:)` resolves pending takeover and plain reservations, returns nil for an unknown attempt, and completed remote report reconciles to `succeeded` with `accept`.

Formal test-integrity, adversarial and serial integration reviews, review-owned documentation/index updates, and Git staging/commit/push remain downstream workflow steps. No Git state changes were made in this implementation step.
