# wh-16 GraphQL provider progress

Plan: `impl-plans/active/wh-16-graphql-provider.md`  
Mode: issue-resolution  
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.  
Branch: `feat/work-handover-and-takeover`; accepted dependency: `wh-15-task-commands` (present in the dispatch item's `acceptedPlanIds`).  
Codex agent: `step6-implement` in workflow execution `nested-v1-0590ffcc92ce6eaee8cc6da598248460cac06e5ef6cb35c2f3ad7155cde1c7f2`; native branch `wh-16-graphql-provider`.

## Implementation

- Added `TaskHandoverGraphQLProvider` in `Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`. It resolves stores through `TaskCommandRunner.storeRoots`, returns digest-verified packet and awaiting-handover records, rejects unknown `HostTrait` and sink/backend values, requests handovers and answers, checks required presence traits, reserves takeover attempts through `TaskDispatcher`, forwards the remote host ID, authorizes launch, heartbeats leases, and delegates reported terminal state to `TaskDispatch.reconcileExternalTerminal`.
- Wired `TaskHandoverGraphQLDocumentExecutor` into `ServeWebHost`, the local GraphQL document chain, and `RielaLibrary.executeGraphQLDocument`.
- Added a serve manager bearer check before `ServeWebRegistryExecutor` marks requests locally trusted. It reuses `WorkflowExecutionAuthorizationWrapper` for the same bearer comparison and local-trust decision used by workflow execution.
- Added a remote host ID forwarding parameter to `TaskDispatcher.reserve` and regression `TaskDispatcherTests.testReservationForwardsSelectedHostIdToLease`.
- Added provider, trait-filtering, answer/request, takeover, heartbeat, and serve auth coverage in `Tests/RielaCLITests/TaskHandoverGraphQLProviderTests.swift`.
- R31: added `AuthorizedAttemptLaunch` and random lease credential issuance in `WorkStore.authorizeAttemptLaunchIssuingLeaseCredential`; the transaction replaces both stored digests and retains launch-token replay fencing. `authorizeAttemptLaunch` keeps its existing signature. `TaskDispatcher.authorizeIssuingLeaseCredential` is used by takeover and its returned credential is `heartbeatToken`.
- Added reservation, lease, and dispatcher regressions proving digest rotation, launch-token replay rejection, credential verification, and node start. Added provider report tests for completed and suspended outcomes; suspension passes and the completed case exposes the blocker below.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-retry2.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-retry2.log'`: exit 0; `Build complete! (6.61s)`; log `tmp/work-handover/wh-16-graphql-provider/build-retry2.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-retry3.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-retry3.log'`: exit 1; 41 tests, 1 failure. Existing GraphQL, workflow-execution, and ServeWeb suites passed (37 tests); provider packet/trait, answer/request, and serve auth tests passed. `testTakeoverValidatesTraitsReservesOnRemoteHostAndHeartbeatsLease` fails when the returned launch token is used for heartbeat; log `tmp/work-handover/wh-16-graphql-provider/focused-retry3.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter TaskDispatcherTests > tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log'`: exit 0; 9 tests, 0 failures; log `tmp/work-handover/wh-16-graphql-provider/dispatcher-tests.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-16-graphql-provider/final-evidence/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-16-graphql-provider/swiftlint.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/swiftlint.log'`: exit 0; selected-file strict SwiftLint passed; manifest `tmp/work-handover/wh-16-graphql-provider/final-evidence/changed-swift-files.nul`; log `tmp/work-handover/wh-16-graphql-provider/swiftlint.log`.
- `git diff --check`: exit 0; log `tmp/work-handover/wh-16-graphql-provider/diff-check.log`.
- Earlier attempts are retained: `build.log` exit 1 and `build-retry.log` exit 1 were compile errors corrected before `build-retry2.log`; `focused-initial.log` exit 1 and `focused-retry.log` exit 1 were test compilation errors corrected before the current-source behavioral run.
- R31 build: `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-r31.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-r31.log'` exit 0; log `build-r31.log`.
- R31 work-store/dispatcher tests: `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreReservationTests|TaskDispatcherTests|WorkStoreTakeoverTests|DecisionApplierStoreTests|WorkStoreCancellationTests" > tmp/work-handover/wh-16-graphql-provider/work-r31-retry.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/work-r31-retry.log'` exit 0; 79 tests, 0 failures.
- R31 focused provider/GraphQL/serve tests: `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-r31-retry.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-r31-retry.log'` exit 1; 43 tests, 1 failure. Completed reporting reaches `TaskDispatch.reconcileExternalTerminal` but that seam throws `reported task attempt has no recorded decision`; the suspended report test and existing suites pass. This failure is not classified as baseline; log `focused-r31-retry.log`.
- Selected changed-file SwiftLint: `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="$PWD/tmp/work-handover/wh-16-graphql-provider/attempt-20261001-r31/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-16-graphql-provider/swiftlint-r31.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/swiftlint-r31.log'` exit 0; log `swiftlint-r31.log`.
- `git diff --check` exit 0; log `diff-check-r31.log`.
- `/bin/zsh -c '! grep -rn "consumed:" Sources/RielaWork'` exit 0 with no matches; log `consumed-digest-r31.log`.

## Remaining completion issue

R31 is resolved in this plan: launch authorization now mints a random lease credential, stores only its digest in both required records, rejects launch-token replay, and `takeoverTask` returns that credential. The `Sources/RielaWork` search for `consumed:` is empty.

Completed `reportAttempt` remains unverified as an accepted task transition. Its new provider test calls the required `TaskDispatch.reconcileExternalTerminal` entry and receives `reported task attempt has no recorded decision` from `Sources/RielaCLI/TaskDispatch+Handover.swift:462`; the suspended report test passes and seals a new packet. That file is outside wh-16 `writePaths`, and the plan expressly delegates report reconciliation to the wh-14 entry. Do not claim the completed-report acceptance criterion until the owner of that seam reconciles this behavior.

Resume criterion: the serial integration owner assigns or resolves the `TaskDispatch+Handover.swift` ownership seam; rerun the focused GraphQL/ServeWeb filter and confirm completed reports record an accept decision and suspended reports seal a handover.

## Completion criteria

- [x] Provider and all three executor chains are implemented; serve manager bearer enforcement is covered by `testServeRequiresManagerBearerForTaskHandoverFields`.
- [x] All seven fields pass through the provider; takeover heartbeat accepts the rotated lease credential.
- [ ] `reportAttempt` completed reconciliation remains unresolved at the wh-14 `TaskDispatch+Handover.swift` seam; suspended reconciliation passes.
- [ ] `TaskHandoverGraphQLProviderTests` passes in full; current focused result is 43 tests with 1 completed-report reconciliation failure.

Formal test-integrity, adversarial review, serial integration review, review-owned docs/index updates, staging, commit, and push remain downstream steps. No Git state changes were made by this implementation node. The existing wh-15 modifications in `Tests/RielaCLITests/TaskHandoverCommandTests.swift` and `impl-plans/progress/wh-15-task-commands.md` were preserved.
