# Pre-release known fixes

Branch: `fix/pre-release`, based at `234504cb`. This work is uncommitted.

## Root causes and fixes

### Six failures present on main

1. `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession` had an outdated diagnostic expectation. Commit `1eb0f5f2` added `prompt-too-large` to the supported retryable failure kinds and to the command guidance. Updated the assertion to the current retry guidance; runtime behavior was already intentional.
2. `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip` expected decoding an unknown persisted status to throw. Commit `7f087cc4` deliberately made unknown status strings decode as `.failed`; `impl-plans/progress/issue-sweep-2-20261024-27a-cancelled-status.md` records that compatibility rule. Updated the test to assert `.failed`.
3. `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal` exposed a compatibility gap from the first-class cancelled status change in `7f087cc4`: the observability terminal check only considered the new status enum, although legacy/transitional records can still have `.running` plus `failureKind == .cancelled`. The service now treats that failure kind as terminal, matching its compatibility handling elsewhere.
4. `WorkflowCommandTests.testCancellationWithoutAutoImprovePersistsTerminalFailure` expected `.failed` after a user cancellation. Commit `7f087cc4` deliberately persists first-class `.cancelled` session and step status; the cancellation progress document records the status and handover behavior. Updated the stale test expectation to `.cancelled`.
5. `WorkflowHostCapabilityTests.testIssue116BuiltinsResolveWithoutExternalExecutable` used incomplete Gmail and X gateway fixtures. Strict request validation was introduced by `868faf01`; read operations need a `queryTemplate` or `operation`. Added valid legacy query templates to the fixtures while keeping the no-external-executable resolver assertion.
6. `ServeWebHostTests.testBrowserExecutionUsesProfileStoreAndGatesSummaryReads` was added by `9da1ffd7` with a fixture that edited a workflow after its first service-mode use, then expected the changed file to be used. The definition store and session pinning already existed (`6337aa24`); `docs/workflow-definition-store.md` and `design-docs/specs/design-workflow-definition-store.md` define first-use seeding and pinning: later file edits are ignored until import/update. The test now starts a separate barrier workflow with its barrier present before first use. Its profile-switch and summary-gating checks remain intact.

### Flaky tests and shared SQLite startup race

- `SpecialistServiceResponsivenessTests.testBarrierHeldServiceChildSurvivesExclusionKillAndRestartWithoutRelaunch` could spend the full 180-second test timeout rebuilding the `riela` executable for each subprocess. The test support now builds/resolves the executable once per XCTest process and reuses that path. The isolated case passed in 15.427s; in the final focused run the specialist suite passed 11 tests.
- Concurrent fresh CLI runs shared `runtime-message-log.sqlite`, but the runtime store, CLI session store, Work Runtime, specialist store, and standalone message log had independent open/schema paths. Those paths could concurrently run `PRAGMA auto_vacuum = INCREMENTAL` or `PRAGMA journal_mode=WAL`; stress runs captured SQLite code 10 (`disk I/O error`) at those setup statements. Added the shared `RuntimeDatabaseAccess` schema lock, with an in-process recursive mutex plus `flock`, around the shared DB opens and initial schema setup in all five paths. Standard read opens also wait for initialization. Lock-setup failures retain the SQLite error contract and database path.
- Expanded `WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds` to 20 rounds of three simultaneous runs (60 CLI runs total), checking distinct IDs and persisted session rows each round.

### Validation warning and SQLite accounting overhead

- `WorkflowValidation` now emits the local KV handover warning only if a `riela/kv-*` node has no usable `kvRoot` (missing, non-string or blank). Explicit absolute and templated roots suppress it; local-memory warnings retain their previous behavior. Tests cover implicit, absolute and templated roots.
- SQLite statement accounting is disabled by default per connection. The disabled path does not call `recordStatementWork`; opted-in connections use ASCII-insensitive catalog matching and report catalog full-scan steps separately. `SQLiteWorkflowRuntimePersistenceStore` and bounded-write samples opt in only for measurements. Added a repeated-query test asserting zero accounting calls when disabled and a catalog-scan accounting test.

## Verification

Commands below ran in the repository root with Xcode's arm64 Swift toolchain. The common environment was:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
```

- Focused command:

  ```sh
  swift test --filter 'DeterministicWorkflowRunnerFailureStateTests|HandoverContractsTests|SessionObservabilityTests|WorkflowCommandAutoImproveTests|WorkflowHostCapabilityTests|ServeWebHostTests|SpecialistServiceResponsivenessTests|WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds|RuntimePersistenceBoundedWriteTests|SQLiteDatabaseTests|SQLiteWorkflowMessageLogTests'
  ```

  Result: 90 tests, 0 failures (47.944s). This included five of the six corrected failures, the 20-round concurrent stress test, the specialist suite, bounded-write tests, and both SQLite accounting tests. The cancellation case ran separately as below and was also covered in the full suite.

- CLI cancellation regression:

  ```sh
  swift test --scratch-path tmp/prerelease/build --filter 'WorkflowCommandTests.testCancellationWithoutAutoImprovePersistsTerminalFailure'
  ```

  Result: 1 test, 0 failures (0.945s).

- Concurrent stress alone:

  ```sh
  swift test --filter 'WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds'
  ```

  Result: 1 XCTest, 0 failures (3.850s); 20 rounds, 60 simultaneous-run invocations.

- Full suite, final run:

  ```sh
  swift test --scratch-path tmp/prerelease/build
  ```

  Result: 4,367 tests, 39 skipped, 0 failures (974.196s). Final full-suite failure list: none.

- Strict SwiftLint on the 31 changed Swift files: 0 violations. `git diff --check`: clean. A repository-wide `swiftlint lint --strict` reports 43 existing violations outside the changed files.

The first exploratory full run found one test-contract regression when an invalid runtime-root ancestor caused lock-directory creation to throw before SQLite could report its database path; that contract was fixed and its focused test passed. Subsequent stress evidence found the uncoordinated Work Runtime and CLI session-store opens; those were brought under the shared lock before the final 90-test focused run and the final full suite above.
