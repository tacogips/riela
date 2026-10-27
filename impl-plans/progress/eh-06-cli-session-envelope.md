# eh-06-cli-session-envelope progress

## Status

Implementation and focused verification are complete. No commit, push,
rebase, or reset was performed. Worktree branch: `feat/efficient-history`.

## Changes

- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
  - Added the scalar `CLIWorkflowSessionEnvelope` with
    `sessionStorage: "canonical"` and the generated-column session stub.
  - CLI saves now write an envelope and canonical runtime snapshot in one
    transaction, including the former CLI-only `save(_:)` path.
  - Added the foreign definition pin pre-call before local transactions in
    both in-database save overloads and the CLI-only save path.
  - Reads and `loadAll` resolve envelopes against the canonical snapshot in
    one SQLite read transaction; `list` loads only the canonical session
    header and does not assemble execution rows.
  - Legacy full rows remain readable. Added
    `legacyFullRecordIds(limit:)` and `convertLegacyRecord(sessionId:)`, with
    canonical snapshot status taking precedence during conversion.
  - Execution identity observation uses runtime execution rows for envelopes
    and the existing JSON path for legacy rows. Missing canonical snapshots
    are skipped and warned through the existing decode-resilience path.
  - The eh-02 `writableRuntimeStoreDefault` options line is unchanged.
- `Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift`
  - Added `testSaveStoresSmallEnvelopeAndLoadsCanonicalSession`,
    `testLegacyRecordLoadsAndConvertsToCanonicalEnvelope`,
    `testLegacyConversionUsesCanonicalSnapshotStatus`,
    `testMissingCanonicalSnapshotIsUnreadableAndListKeepsOtherRows`,
    `testExecutionIdentityObservationReadsEnvelopeAndLegacyRows`,
    `testForeignPinLockDoesNotStartLocalTransaction`, and
    `testForeignPinFailureLeavesLocalRowsAbsentAndRetrySucceeds`.
- `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`
  - Existing raw legacy/corruption fixtures and assertions remain unchanged;
    they continue to exercise legacy decode and malformed-row resilience.

## Out-of-scope edits

- `Sources/RielaCore/WorkflowDefinitionPins.swift`: this task changed only the
  enum and `recordForeignPinIfNeeded` visibility because `RielaCLI` cannot
  call the internal `RielaCore` symbol required by the accepted plan. The
  recorded whole-file hashes also include other shared-worktree changes and
  do not establish authorship for them.
- `Sources/RielaCLI/CLIWorkflowSessionResolution.swift`: added the error
  description for `canonicalSnapshotMissing(sessionId:)` because adding the
  accepted enum case made this existing exhaustive switch fail compilation.
  Before hash: `8f6efe2027d218e54f6f0028fbada07a2546af11253bbf5f20e2cbe982bb50e4`;
  after hash: `25b8bc25943152618d13d5ed38aeeb71c6d41306ba0272b59500d402388a142b`.

- Named files added during review repair outside the plan's original
  `writePaths`: `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
  (F3's header-only API) and `Sources/RielaCLI/SessionCommandModels.swift`
  (F1's summary count projection). `CLIWorkflowSessionResolution.swift`
  remains the original compiler-exhaustiveness change described above. These
  edits are directly named by the review repairs; no other additional source
  paths were edited for eh-06.

## Verification

All commands ran under an arm64 zsh shell. Logs are under
`tmp/efficient-history/eh-06-cli-session-envelope/`.

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Final build completed. Log: `build-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "CLIWorkflowSessionEnvelopeTests\|CLIWorkflowSessionStoreResilienceTests\|SessionReconcileCommandTests\|WorkflowCommandLivePersistence\|SessionRecoveryHydrationScopeTests\|RuntimeStoreFirstOpenerAutoVacuumTests\|PrivateWorkflowTests"'` | 0 | 67 tests, 0 failures; all selected suites executed. Log: `test-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/CLIWorkflowSessionStore.swift Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift'` | 0 | Strict lint passed for plan-owned Swift files. Log: `swiftlint-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCLI/CLIWorkflowSessionResolution.swift'` | 0 | Strict lint passed for minimal out-of-scope Swift edits. Log: `swiftlint-outs-of-scope-final.log`. |
| `git diff --check` | 0 | No whitespace errors. Log: `diff-check-final.log`. |

An earlier test rebuild was blocked by the in-progress eh-07 test fixture at
`SessionAbandonedInvocationTests.swift:54`; after that concurrent edit was
corrected, the exact eh-06 filter above rebuilt and passed. Initial test
failures from intermediate implementation attempts are preserved in their
logs (`test-2.log`, `test-3.log`, and `envelope-tests.log`); final verification
is green.

## Remaining checks

- [x] Exact focused filter passes with every listed suite executed.
- [x] Strict SwiftLint over the three plan-owned Swift files passes.
- [x] Strict lint for the two minimal out-of-scope Swift edits.
- [x] `git diff --check` passes.
- [x] Confirmed API and call-order greps, including the unchanged
  `writableRuntimeStoreDefault` line.
- [x] Recorded final post-edit hashes and close-out risks.

## Final edit hashes

| Path | Before | After |
|---|---|---|
| `Sources/RielaCLI/CLIWorkflowSessionStore.swift` | `9e70f8f6ea2c6fcbbe44ffb2ce5da068be7c4a70b44c331a599c08322716a2f5` | `130de7af521ae56f9ff80b4b632c81b1d0e03d73f20bf025b23ce425a41b55b5` |
| `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift` | `ce468969af6bf76f4989c89ff4bcd729db7039892ca3ef1932dcb374194f06f4` | `ce468969af6bf76f4989c89ff4bcd729db7039892ca3ef1932dcb374194f06f4` |
| `Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift` | New file | `a8c21ba7268e42776c81099cd6e140843b87f687082bf1b186de60bf78cd8922` |

## Open risks / deviations

- The accepted lock test described a short-busy-timeout throw. The runtime
  store opens its foreign database with cancellable `waitForLocks`; the test
  cancels the blocked save after 150 ms, proves neither local row was written,
  then releases the lock and retries successfully. A rejecting-trigger test
  also proves the same rollback and retry behavior for a foreign pin error.
- `WorkflowDefinitionPins` public visibility is a minimal API exposure needed
  for the planned CLI-to-Core call and is listed above as an out-of-scope edit.
- `ProductionNodeAdapter+WorkflowImprovementAddon.swift` is owned by the
  concurrent eh-09 plan and was left untouched. Its current prior-run lookup
  calls `list` and then builds improvement evidence from `session.executions`;
  eh-06 now intentionally returns header-only sessions from `list`. eh-09's
  caller should load the selected prior session by ID before building that
  evidence. The eh-09 repair owns that integration point.

## Independent review repair (2026-10-27)

- **F1:** `list` now attaches a SQL-derived `executionCount` summary while
  leaving canonical execution payloads unloaded. `SessionDiscoveryRow` uses
  that summary. The count excludes imported executions and supports both
  execution rows and inline canonical snapshots.
- **F2:** the eh-09 caller remains untouched as requested; eh-09 owns its
  load-by-id correction.
- **F3:** added `SQLiteWorkflowRuntimePersistenceStore.loadSessionHeader`,
  which applies SQLite `json_remove` before decoding and uses the shared
  `RuntimeSnapshotDates` decoder. Added an inline-snapshot list regression.
- **F4:** load, list, loadAll and conversion select the JSON storage marker
  with `json_type`; legacy detection no longer parses the whole record with
  `JSONSerialization`.
- **F5:** list status filtering uses canonical `session_status` when present,
  and falls back to the legacy generated stub status only when no canonical
  row exists. Added a runtime-only status update regression.
- **F6:** CLI-only save now loads an existing snapshot in its transaction and
  replaces only `session`, preserving messages and other runtime metadata.
  Added a message preservation regression.
- **F7:** strict reads preserve `canonicalSnapshotMissing`; the test now
  asserts that specific error. The identity regression now places exec-90 in
  the envelope and exec-2 in the legacy row, so only the envelope can satisfy
  the high-water assertion. Added ordinary-save legacy conversion coverage.
- **F8:** only `public` visibility for `WorkflowDefinitionPins` and
  `recordForeignPinIfNeeded` is claimed as eh-06 work. The `localRoot`,
  `createdAt`, `normalizedStoreRoot`, and `canonicalDate` changes in that file
  were already present in the shared worktree and were not edited in this
  repair. Their originating plan was not independently established, so no
  provenance was attributed to eh-06 for those changes.
- Added `WorkflowCommandSessionDiscoveryTests` to the plan verification
  filter.
- Updated design §5 to document header-only list decoding, SQL execution
  counts, inline legacy handling and canonical-status filtering (the review's
  requested design-doc record for the list contract).
- Assertion audit: no pre-existing assertions in the tracked resilience or
  discovery test files were weakened by eh-06. The resilience file is
  unchanged, and the discovery suite retains its execution-count assertion.

### Changed assertions and reasons

| Test assertion | Change | Reason |
|---|---|---|
| `testMissingCanonicalSnapshotIsUnreadableAndListKeepsOtherRows` | Assert `loadStrictReadOnly` throws `.canonicalSnapshotMissing(sessionId:)` instead of `.notFound` | The strict path now preserves the actionable missing-canonical error required by F7. |
| `testMissingCanonicalSnapshotIsUnreadableAndListKeepsOtherRows` | Expect no warning after the strict load | The strict call returns the preserved error directly; list remains the operation that emits the skipped-row warning. |
| `testExecutionIdentityObservationReadsEnvelopeAndLegacyRows` | Move the highest identity (`exec-90`) from legacy JSON into the envelope; legacy now holds `exec-2` | Ensures the assertion can pass only when the envelope identity branch works. |
| `WorkflowCommandSessionDiscoveryTests` latest execution count assertion | Retained and now covered by the verification filter | Confirms the unchanged CLI discovery count behavior after F1. |

### Repair verification

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "CLIWorkflowSessionEnvelopeTests\|CLIWorkflowSessionStoreResilienceTests\|SessionReconcileCommandTests\|WorkflowCommandLivePersistence\|SessionRecoveryHydrationScopeTests\|RuntimeStoreFirstOpenerAutoVacuumTests\|PrivateWorkflowTests\|WorkflowCommandSessionDiscoveryTests"'` | 0 | 78 tests, 0 failures; every selected suite ran. Log: `tmp/efficient-history/eh-06-cli-session-envelope/repair-test-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/CLIWorkflowSessionStore.swift Sources/RielaCLI/SessionCommandModels.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift Tests/RielaCLITests/WorkflowCommandSessionDiscoveryTests.swift'` | 0 | Strict lint passed. Log: `tmp/efficient-history/eh-06-cli-session-envelope/repair-swiftlint.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCLI/CLIWorkflowSessionResolution.swift'` | 0 | Strict lint passed for the previously recorded boundary changes. Log: `tmp/efficient-history/eh-06-cli-session-envelope/repair-swiftlint-outs-of-scope.log`. |
| `git diff --check` | 0 | No whitespace errors. |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build completed after waiting for the concurrent eh-07 SwiftPM process using the shared `.build` directory. Log: `tmp/efficient-history/eh-06-cli-session-envelope/repair-build-final.log`. |

The concurrent eh-07 test process completed with 3 failures among 98 tests,
in `SessionAbandonedInvocationTests.swift:58` and
`TerminalRetentionTests.swift:136,551`. Those files are outside eh-06 and were
not edited here; see `tmp/efficient-history/eh-07-abandoned-and-retention/repair-test.log`.
The concurrent eh-09 implementation remains responsible for F2's prior-run
load-by-id fix; `ProductionNodeAdapter+WorkflowImprovementAddon.swift` was not
edited in this repair.

## Independent review repair: N1–N4 and list query follow-up (2026-10-27)

- **N1 (High):** `encodedHeaderJSON` now stores `_rielaNewExecutionCount` from `WorkflowSession.newExecutionCount` in each canonical header. `list` reads this scalar before considering older-header fallbacks, so new snapshot rows no longer join or inspect execution payload blobs. The list query is factored into `listSQL` so the regression measures VM steps on the exact SQL used by `list`; the test compares equivalent four-execution sessions with 20-byte and 250-KB response payloads. Imported rows are explicitly excluded by the stored count and a dedicated test.
- **N2 (Medium):** the list SQL builder checks table presence. Without `workflow_runtime_snapshots`, it filters on the stub status and counts legacy inline executions. With snapshots but without generation-11 execution/payload tables, it counts inline executions only and does not prepare references to absent tables. A read-only legacy-row test drops the generation-11 tables from the fixture and verifies the row and count.
- **N3 (Low):** `save(_:)` rejects records carrying `executionCount` with `sqliteFailed("cannot save header-only session summary: …")`. A regression confirms a list-derived summary cannot erase canonical execution rows.
- **N4 (Low):** non-strict `load` warns and maps a missing canonical snapshot to `notFound`, allowing hydration to continue and skip it. Strict reads continue to surface `canonicalSnapshotMissing`. Added direct-load warning and hydration-skip coverage. Design §5 documents both behaviors.
- **Minor list consolidation:** `listSQL` joins the snapshot row once and uses the joined `session_json` for status and count projections, avoiding repeated scalar snapshot lookups.
- Prior F1–F8 dispositions and their tests remain as recorded above. No changes were made to `WorkflowCommandSessionDiscoveryTests` or `CLIWorkflowSessionStoreResilienceTests`; their existing count and resilience assertions remain intact.

### Changed assertions and reasons

No pre-existing assertions were changed or weakened in this repair. The following assertions were added:

| Regression test | New assertion | Reason |
|---|---|---|
| `testListCountExcludesImportedExecutions` | A three-execution session with one imported execution lists count 2 | Pins the list count contract while ensuring imports do not inflate the count. |
| `testListCountWorkDoesNotReadLargeExecutionPayloads` | VM steps from the exact `listSQL` query for 250-KB payloads are at most five above the 20-byte fixture | Ensures list query work does not grow with payload byte size. |
| `testReadOnlyListSupportsGenerationTenRuntimeTables` | A read-only list on a legacy fixture without generation-11 tables returns its row and count 3 | Catches references to tables absent before migration. |
| `testSavingListSummaryThrowsAndPreservesCanonicalExecutions` | Saving a list result throws and all three execution rows remain | Prevents header-only API results from deleting canonical executions. |
| `testHydrationSkipsMissingCanonicalSnapshotWithWarning` | Non-strict load emits the skipped-row warning and hydration leaves the missing session unseeded | Records the resilience behavior selected for N4. |

### Scope and verification

- Cross-plan edit: `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` adds the execution-count scalar to the canonical header. This is the Core write-path adjustment explicitly named by N1; the bounded-write suite was included to retain eh-05 coverage.
- `design-docs/specs/design-efficient-history-and-storage.md` records the count field, older-store fallback, generation-10 table handling, and N4 read behavior. No other out-of-scope paths were edited for this repair. Concurrent memory, eh-07, and eh-09 files were left untouched.
- `git diff --check` passed (exit 0).

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "CLIWorkflowSessionEnvelopeTests|CLIWorkflowSessionStoreResilienceTests|SessionReconcileCommandTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|RuntimeStoreFirstOpenerAutoVacuumTests|PrivateWorkflowTests|WorkflowCommandSessionDiscoveryTests|RuntimePersistenceBoundedWriteTests"'` | 0 | 87 tests, 0 failures across 10 suites; all selected suites ran. Log: `tmp/efficient-history/eh-06-cli-session-envelope/review-repair-test-final.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/CLIWorkflowSessionStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift'` | 0 | Strict lint passed. Log: `tmp/efficient-history/eh-06-cli-session-envelope/review-repair-swiftlint-final.log`. |
| `git diff --check` | 0 | No whitespace errors. |
