# ISW2-27b progress: agent-gateway cancellation

## Status

Implementation changes and assigned verification are complete. The refreshed build, focused behavioral suite, strict changed-file SwiftLint, and empty auth-preflight search pass. An earlier focused attempt failed before test discovery while a sibling-owned test file had a compile error; the final rerun passed after that shared-tree error cleared. Integration review and later workflow finalization remain downstream.

## Design and scope

Aligned with `impl-plans/active/issue-sweep-2-20261024-27b-gateway-cancellation.md` and the P2 contract in `design-docs/specs/design-cancellation-and-orphan-session-resilience.md`. Changed only this plan's three Swift paths.

## Changes

- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`: after stream consumption, host task cancellation throws `CancellationError` unless the deadline watchdog expired; cancellation during an `ACPError` also throws `CancellationError` before provider error mapping.
- `Sources/RielaAdapters/AdapterUtilities.swift`: `executeWithRetry` checks `Task.isCancelled` after rethrowing explicit cancellation and before error normalization or retry delay.
- `Tests/RielaAdaptersTests/AgentGatewayCancellationTests.swift`: added five cases for host cancellation, ACP error during host cancellation, retry normalization bypass, deadline timeout, and vendor cancellation with a live host task.

## Completion criteria

- [x] Gateway stream host cancellation escapes as `CancellationError`, while watchdog deadline expiry retains timeout priority in the result path.
- [x] ACP errors while the host task is cancelled escape as `CancellationError`.
- [x] `executeWithRetry` checks host cancellation before normalization and retry logic.
- [x] Five `AgentGatewayCancellationTests` plus `AgentGatewayNodeAdapterTests` and `GatewayTurnLifetimeTests` pass. The final focused command ran 26 Swift Testing cases and 2 XCTest cases (28 total), with zero failures.
- [x] `swift build` and strict SwiftLint on the exact changed Swift paths pass.
- [x] Source auth-preflight grep has no matches; the recorded grep exit 1 means the search was empty.

## Verification records

- Refreshed build: `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27b/step6-final-build.log 2>&1; buildExit=$?; echo exitStatus=$buildExit >> tmp/issue-sweep-2-20261024/isw2-27b/step6-final-build.log; exit $buildExit'`; exitStatus 0; testsRun 0; failureCount 0; log `tmp/issue-sweep-2-20261024/isw2-27b/step6-final-build.log`.
- Focused tests: `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentGatewayCancellationTests|AgentGatewayNodeAdapterTests|GatewayTurnLifetimeTests" > tmp/issue-sweep-2-20261024/isw2-27b/step6-final-focused.log 2>&1; testExit=$?; echo exitStatus=$testExit >> tmp/issue-sweep-2-20261024/isw2-27b/step6-final-focused.log; exit $testExit'`; exitStatus 0; testsRun 28 (26 Swift Testing + 2 XCTest); failureCount 0; log `tmp/issue-sweep-2-20261024/isw2-27b/step6-final-focused.log`.
- Refreshed strict changed-file lint: `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-sweep-2-20261024/isw2-27b/changed-swift-paths.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-27b/changed-swift-paths.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`; exitStatus 0; testsRun 0; failureCount 0; log `tmp/issue-sweep-2-20261024/isw2-27b/step6-final-lint.log`.
- Auth-preflight grep: `grep -rn "authentication is unavailable" Sources > tmp/issue-sweep-2-20261024/isw2-27b/auth-preflight-grep.log 2>&1`; exitStatus 1 (no matches); testsRun 0; failureCount 0; log `tmp/issue-sweep-2-20261024/isw2-27b/auth-preflight-grep.log`.

## Superseded verification attempt

- The earlier focused attempt at `tmp/issue-sweep-2-20261024/isw2-27b/focused.log` exited 1 before test discovery because sibling-owned `Tests/RielaCoreTests/DynamicWorkflowPolicyTests.swift:215` used `Self.defaultBounds()` in a default argument. This is not a current failure: the final focused rerun above passed on the current tree. The #27b worker made no edits to that sibling-owned path.

## Evidence and handoff

- Before/after source hashes: `tmp/issue-sweep-2-20261024/isw2-27b/snapshots/pre-edit-sha256.txt`, `tmp/issue-sweep-2-20261024/isw2-27b/snapshots/post-edit-sha256.txt`, and this continuation's `tmp/issue-sweep-2-20261024/isw2-27b/snapshots/step6-final-post-edit-sha256.txt`.
- Per-edit intent records and immutable fanout pre-node content copies: `tmp/issue-sweep-2-20261024/isw2-27b/snapshots/`.
- An initial build compiled and reached “Build complete” but its wrapper attempted to assign the zsh-reserved variable `status`; that complete superseded log is preserved at `tmp/issue-sweep-2-20261024/isw2-27b/build-wrapper-failure.log`. The final build was rerun with `buildExit` and passed.
- CLI agent authentication preflight text is absent from `Sources`.
