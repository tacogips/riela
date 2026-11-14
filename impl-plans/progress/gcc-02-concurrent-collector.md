# gcc-02-concurrent-collector progress

## Implementation summary

Implemented full Gmail mailbox listing and concurrent per-thread reads in the assigned files. `maxThreads` now sets the in-flight thread-read limit, clamped to 16. Listing remains sequential at 50 items per request until the provider completes or a real early-stop reason occurs. One `GmailCollectionRequestLimiter` instance governs the scan profile (or the coordinator's counted prefetched profile), every listing request, and all thread metadata/full-thread/body requests. The parent accepts worker outcomes in queue order and owns all checkpoint/output mutations.

The collector maps deadline, output-budget and listing-limit stops to explicit failure stages. A refusal before an item's first granted request leaves it pending; a refusal after a request is deferred. Cancellation propagates. Scope identity and the pending checkpoint shape are unchanged.

## Per-file changes and hashes

| File | Change | Pre SHA-256 | Post SHA-256 |
|---|---|---|---|
| `Sources/RielaCLI/GmailCollection.swift` | Sendable clock/wait/fetch; shared limiter; complete page listing; bounded concurrent workers; ordered acceptance and explicit stop stages. | `7a85b9450226337af50d253729d3bbbe1339d72f51a7ca485dc09f0946a0c602` | `a79b8b62345e606adae77e1a3bdb4eaa0f05b56ff42d20b5b65042dc60185596` |
| `Sources/RielaCLI/GmailCollectionCoordinator.swift` | Sendable fetch, prefetched profile passed into scan and counted by limiter. Existing state-machine complexity rule suppression is documented; coordinator behavior is otherwise unchanged. | `f95ba8c9adf07f96dd2030a82e6c46fe56325c38a651afee8efa5022a0c46ffb` | `6e0ec8c1cc8e4fef413dca41658172fca7e1468e6d447a8b6d90bbb208c0fb7f` |
| `Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift` | Nested provider fetch marked `@Sendable`. | `029f8323dce48e2f2b04ee030fabd7c4c7c498384adedb80b048849d029fbff2` | `2b284a00836dcf301978003454585b51a059dd1907be4862dc3e561f06df941a` |
| `Tests/RielaCLITests/GmailCollectionTests.swift` | Sendable static fixtures/lock box; resume/rotation/deadline tests rewritten; six required behavioral tests added. | `0917222831e2b51f8ac516a2a99285e79b107e180df397f60134e95abd3834d4` | `d6b92abd213ba19b61f470875c2ccb8c5b09b954560fc879477be47e7db1dfa9` |

Protected files stayed byte-identical. `guard-pre.sha256` equals `guard-post.sha256`; `guard-diff.log` is empty. Protected paths: `Sources/RielaCLI/GmailMessageBodyCollection.swift`, `Sources/RielaCLI/GmailCollectionRetryBacklog.swift`, `Sources/RielaCLI/GmailCollectionRequestLimiter.swift`, and `design-docs/specs/design-native-source-collection.md`.

## Rewritten and added tests

Rewritten existing tests and preserved guarantees:

- `testSmallRunResumesExactListingCursorAndKeepsPreScanMailboxVersion`: deadline after first listing page, exact resume cursor, both threads accepted in order, prior mailbox version preserved.
- `testFailedItemCannotMonopolizeOneItemRuns`, `testAllFailedItemsReceiveFairRetryTurnsAtOneItemBudget`: failed IDs rotate behind fresh work under one-read deadlines.
- `testDeadlineContinuationDoesNotReadAlreadyCompletedThreadsAgain`: accepted work is not re-read; before-start refusal remains pending.
- `testBudgetStopsBeforeAnotherProviderCallAndCancellationPropagates`: real deadline stage and cancellation propagation.
- `testBodyBudgetRetainsAcceptedPrefixAndDoesNotAcknowledgeOversizedItem`: output-budget stage carries `threadId` and oversized item remains unacknowledged.
- `testPoisonBacklogDoesNotBlockFreshMailAndPreservesExactOldCursor`, `testLongRunningScanKeepsDiscoveryFloorAndScopesSurviveBodyIntentSwitch`, `testDrainingOldCursorCannotRemoveAlreadyAcquiredFreshThreadVersions`, `testRequestedBodyFoundByFreshScanRemainsKnownWhenOldCursorDrains`: old cursor throws only on the specified first-turn continuation; exact cursor, discovery floor, old/fresh versions, body intent and backlog behavior remain covered.
- `testPermanentPoisonDoesNotAccumulateOneScanPerFreshProfile`: lock-box conversion only; 35 fresh reads and one backlog remain asserted.

Added tests:

- `testOneRunListsEveryPageAtPageSizeFiftyWithOneThreadConcurrency`.
- `testThreadReadConcurrencyIsBoundedAndResultsStayInListingOrder`.
- `testThreadReadConcurrencyClampsAtSixteen`.
- `testRequestStartsShareOneLimiterAcrossWorkers`.
- `testListingLimitRecordsListingLimitStage`.
- `testCoordinatorPrefetchedProfileKeepsRequestCount`.

Scope-hash goldens `29b73447...` and `c4ee206a...` remain unchanged and pass.

## Verification

| Command | Exit | Tests run | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/gmail-collect-concurrency/gcc-02/build.log 2>&1'` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/build.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter GmailCollection > tmp/gmail-collect-concurrency/gcc-02/test-gmail.log 2>&1'` | 0 | 36 | 0 | `tmp/gmail-collect-concurrency/gcc-02/test-gmail.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter RielaCLITests > tmp/gmail-collect-concurrency/gcc-02/test-rielacli.log 2>&1'` | 1 | 2265 | 6 | `tmp/gmail-collect-concurrency/gcc-02/test-rielacli.log` |
| `if [ -s tmp/gmail-collect-concurrency/gcc-02/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/gmail-collect-concurrency/gcc-02/changed-swift-files.nul; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/swiftlint.log` (empty) |
| `shasum -a 256 Sources/RielaCLI/GmailMessageBodyCollection.swift Sources/RielaCLI/GmailCollectionRetryBacklog.swift Sources/RielaCLI/GmailCollectionRequestLimiter.swift design-docs/specs/design-native-source-collection.md > tmp/gmail-collect-concurrency/gcc-02/guard-post.sha256 && diff tmp/gmail-collect-concurrency/gcc-02/guard-pre.sha256 tmp/gmail-collect-concurrency/gcc-02/guard-post.sha256` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/guard-diff.log` (empty) |

The full CLI aggregate had no Gmail failures. Its six failures were confined to three unowned `StorageCompactCommandTests` tests: `testApplyConvertsLegacyRuntimeAndCLISessionRows` (2 assertions), `testApplySweepsOrphanMemoryHistoryAndReportsCount` (1 assertion), and `testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged` (3 assertions). Each was rerun alone. The first passed alone (log `rerun-StorageCompactCommandTests-testApplyConvertsLegacyRuntimeAndCLISessionRows.log`); the latter two failed again in unchanged `StorageCompactCommandTests.swift` behavior (logs `rerun-StorageCompactCommandTests-testApplySweepsOrphanMemoryHistoryAndReportsCount.log` and `rerun-StorageCompactCommandTests-testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged.log`). These paths and implementation code are outside gcc-02 `writePaths`.

Final invariants checked: `GmailCollection.swift` has no exact `"budget"` stage, `options.maximum` appears only in `min(options.maximum, 16)`, `GmailCollectionCoordinator.swift` has no `usedProfile`, and the adapter contains `@Sendable func fetch`. No issue tracker reference was supplied (`issueReference: none`). Formal review and integration acceptance remain downstream workflow work.

Additional final verification detail:

| Command | Exit | Tests run | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter StorageCompactCommandTests/testApplyConvertsLegacyRuntimeAndCLISessionRows > tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testApplyConvertsLegacyRuntimeAndCLISessionRows.log 2>&1'` | 0 | 1 | 0 | `tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testApplyConvertsLegacyRuntimeAndCLISessionRows.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter StorageCompactCommandTests/testApplySweepsOrphanMemoryHistoryAndReportsCount > tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testApplySweepsOrphanMemoryHistoryAndReportsCount.log 2>&1'` | 1 | 1 | 1 | `tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testApplySweepsOrphanMemoryHistoryAndReportsCount.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter StorageCompactCommandTests/testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged > tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged.log 2>&1'` | 1 | 1 | 1 | `tmp/gmail-collect-concurrency/gcc-02/rerun-StorageCompactCommandTests-testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged.log` |
| `if [ -s tmp/gmail-collect-concurrency/gcc-02/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/gmail-collect-concurrency/gcc-02/changed-swift-files.nul; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/swiftlint.log` (empty) |
| `if ! rg -n '"budget"' Sources/RielaCLI/GmailCollection.swift && [ "$(rg -n 'options\\.maximum' Sources/RielaCLI/GmailCollection.swift | wc -l | tr -d ' ')" = 1 ] && rg -Fq 'min(options.maximum, 16)' Sources/RielaCLI/GmailCollection.swift && ! rg -n usedProfile Sources/RielaCLI/GmailCollectionCoordinator.swift && rg -Fq '@Sendable func fetch' Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift; then printf '%s\\n' 'All gcc-02 grep invariants passed.'; else printf '%s\\n' 'gcc-02 grep invariant failed.'; exit 1; fi` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/invariants.log` |
| `git diff --check > tmp/gmail-collect-concurrency/gcc-02/diff-check.log 2>&1` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-02/diff-check.log` (empty) |

The first aggregate-only `testApplyConvertsLegacyRuntimeAndCLISessionRows` failure passed its isolated rerun. The other two failures reproduce in isolated reruns. Both test file and related StorageCompact implementation paths are unmodified and outside gcc-02 `writePaths`; no StorageCompact test was changed to force a pass.

## Superseded implementation attempts

These runs are retained for audit and are not current-source passing evidence:

- Initial SwiftLint runs reported collector/coordinator complexity and catch-layout diagnostics (`swiftlint-initial.log`, `swiftlint-after-extract.log`, `swiftlint-after-refactor.log`). The collector listing/profile/ordered-accept logic was extracted and catch formatting corrected; final changed-file lint is the empty `swiftlint.log`, exit 0.
- `test-gmail-initial.log` failed while compiling the first fixture/test rewrite. `test-gmail-compile.log` recorded fixture typing errors. Those compile issues were corrected; the final-source `test-gmail.log` compiles and passes 36 tests with 0 failures.
- `test-gmail-next.log` ran the then-current 36 tests and reported 7 assertion failures in the first deadline/resume revisions. The test turn maps and assertions were corrected; a targeted rerun passed, followed by the final-source full GmailCollection run (36/0).
