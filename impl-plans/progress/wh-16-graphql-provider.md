# wh-16 GraphQL provider progress

Plan: `impl-plans/active/wh-16-graphql-provider.md`  
Mode: issue-resolution  
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.  
Branch: `feat/work-handover-and-takeover`; accepted dependency: `wh-15-task-commands` (present in the dispatch item's `acceptedPlanIds`).  
Codex agent: step6-implement in workflow execution `nested-v1-48b6a1dfffa097cac379cac259c4eb9d5f75172ba5722eacae68bfeb481cc36d`; native branch `wh-16-graphql-provider`.

## Implementation

- Added `TaskHandoverGraphQLProvider` in `Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`. It resolves stores through `TaskCommandRunner.storeRoots`, returns digest-verified packet and awaiting-handover records, rejects unknown `HostTrait` and sink/backend values, requests handovers and answers, checks required presence traits, reserves takeover attempts through `TaskDispatcher`, forwards the remote host ID, authorizes launch, heartbeats leases, and delegates reported terminal state to `TaskDispatch.reconcileExternalTerminal`.
- Wired `TaskHandoverGraphQLDocumentExecutor` into `ServeWebHost`, the local GraphQL document chain, and `RielaLibrary.executeGraphQLDocument`.
- Added a serve manager bearer check before `ServeWebRegistryExecutor` marks requests locally trusted. It reuses `WorkflowExecutionAuthorizationWrapper` for the same bearer comparison and local-trust decision used by workflow execution.
- Added a remote host ID forwarding parameter to `TaskDispatcher.reserve` and regression `TaskDispatcherTests.testReservationForwardsSelectedHostIdToLease`.
- Added provider, trait-filtering, answer/request, takeover, heartbeat, and serve auth coverage in `Tests/RielaCLITests/TaskHandoverGraphQLProviderTests.swift`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-retry2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-retry2.log'`: exit 0; `Build complete! (6.61s)`; log `tmp/work-handover/wh-16-graphql-provider/build-retry2.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-retry3.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-retry3.log'`: exit 1; 41 tests, 1 failure. Existing GraphQL, workflow-execution, and ServeWeb suites passed (37 tests); provider packet/trait, answer/request, and serve auth tests passed. `testTakeoverValidatesTraitsReservesOnRemoteHostAndHeartbeatsLease` fails when the returned launch token is used for heartbeat; log `tmp/work-handover/wh-16-graphql-provider/focused-retry3.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter TaskDispatcherTests > tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log'`: exit 0; 9 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-16-graphql-provider/final-evidence/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-16-graphql-provider/swiftlint.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/swiftlint.log'`: exit 0; selected-file strict SwiftLint passed; manifest `tmp/work-handover/wh-16-graphql-provider/final-evidence/changed-swift-files.nul`; log `tmp/work-handover/wh-16-graphql-provider/swiftlint.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/diff-check.log`.
- Earlier attempts are retained: `build.log` exit 1 and `build-retry.log` exit 1 were compile errors corrected before `build-retry2.log`; `focused-initial.log` exit 1 and `focused-retry.log` exit 1 were test compilation errors corrected before the current-source behavioral run.

## Blocked completion

The takeover heartbeat criterion is blocked by an existing lease-token contract mismatch outside this plan's `writePaths`. `WorkStore.authorizeAttemptLaunch` in `Sources/RielaWork/WorkStore+Reservation.swift` replaces the lease digest with `launchTokenDigest("consumed:<attemptId>:<sessionId>")`; `WorkStore.verifyLeaseToken` in `Sources/RielaWork/WorkStore+Leases.swift` only accepts `launchTokenDigest(token)`. The provider correctly returns the launch token required by the plan, but the focused test proves it is rejected after launch authorization. Heartbeat and `reportAttempt` therefore cannot authenticate with the returned token; the completed and suspended report reconciliation cases remain unverified. No file outside wh-16 `writePaths` was changed.

Resume criterion: assign the lease-token rotation/reuse repair to an accepted plan that owns `Sources/RielaWork/WorkStore+Reservation.swift` and `Sources/RielaWork/WorkStore+Leases.swift`, or explicitly amend wh-16 `writePaths`; then rerun the focused GraphQL/ServeWeb filter and confirm heartbeat, report completion, and report suspension behavior.

## Completion criteria

- [x] Provider and all three executor chains are implemented; serve manager bearer enforcement is covered by `testServeRequiresManagerBearerForTaskHandoverFields`.
- [ ] All seven fields pass through the provider; takeover heartbeat and `reportAttempt` terminal reconciliation remain blocked by the lease-token mismatch above.
- [ ] `TaskHandoverGraphQLProviderTests` passes in full; current focused result is 41 tests with 1 failure.

Formal test-integrity, adversarial review, serial integration review, review-owned docs/index updates, staging, commit, and push remain downstream steps. No Git state changes were made by this implementation node. The existing wh-15 modifications in `Tests/RielaCLITests/TaskHandoverCommandTests.swift` and `impl-plans/progress/wh-15-task-commands.md` were preserved.
