# Pre-release review fixes

Branch: `fix/pre-release`, based on `431fd816`. No commit, push, rebase, or reset.

## Review A: persistence and performance

### A1 — share execution reuse across runtime-store copies

- Root cause: each persistence-store value owned a separate execution cache, so the canonical writer and live projection invalidated each other's witness and repeatedly rewrote all execution rows.
- Fix: all copies use the process-wide `RuntimeExecutionReuse.shared` cache. The existing cache key includes database path and session id, and the committed witness check still rejects stale or rolled-back entries.
- Regression: `SQLiteRuntimeExecutionRowsTests.testStoreCopiesShareIncrementalExecutionReuse` alternates eight growing-session saves across two store copies and bounds each later write to the incremental statement count.

### A2 — protect edited manager-journal history and remove unedited history rows

- Root cause: retention only recognized `memory_evolution.version > 1`, while schema-v7 edits live in `memory_history_heads` and `memory_history_versions`; deleting only the entry/evolution rows left history content orphaned.
- Fix: both scan-time and transaction-time protection checks recognize history-head revisions above one. Cleanup removes matching history version/head rows in the same transaction as an unedited entry deletion.
- Regression: `TerminalRetentionTests.testEditedManagerJournalHistoryProtectsSessionAndUneditedHistoryIsDeleted` confirms the edited session is protected and verifies the unedited entry and all associated history rows are removed, with no orphans.

### A3 — serialize migrations across concurrent first opens

- Root cause: the migration chain selected steps from a generation read before the transactions; queued openers could execute a step after another opener had already advanced the schema.
- Fix: each migration transaction re-reads `user_version` and skips unless it still equals the step's source generation. Runtime opens already hold the branch's shared `DistributedStoreLock` at `.riela/runtime-schema.lock`; runtime, CLI session, and Work Runtime schema paths use it. SQLite's transaction remains the cross-process guard for the step itself.
- Regression: `SQLiteSchemaMigratorTests.testConcurrentGenerationNineOpenersApplyEachMigrationOnce` releases eight generation-9 openers through a barrier and counts exactly one execution of each migration step; all finish at generation 11.

### A4 — remove statement-accounting work from unobserved connections

- Root cause: statement text copying/search and counter locking ran on every SQLite statement even when no observer read the metrics.
- Fix/evidence: this was already corrected on the pre-release branch: statement accounting is disabled by default, and only measured persistence connections opt in. The existing `SQLiteDatabaseTests` accounting tests assert no accounting calls while disabled and preserve catalog/full-scan counts while enabled.

### A5 — avoid repeated schema setup on saves

- Root cause (re-review): the old cache trusted only path and `schema_version`, and cache hits bypassed schema-generation and JSONB compatibility checks. A replaced database at the same path could inherit a stale cache entry.
- Fix: runtime and CLI schema setup caches now include canonical database path, device, inode, `schema_version`, and `user_version`. Cache hits still validate JSONB and compatible generation; a `no such table` write invalidates the runtime cache. CLI schema preparation is deduplicated across `openDatabase` and its callers. Runtime and CLI read-only opens bypass the initialization lock for established databases; only missing or empty databases take it to wait for first creation.
- Regressions: `SQLiteRuntimeExecutionRowsTests.testCachedSchemaRejectsDatabaseMigratedByNewerBuild` changes the stamped generation after a cached save and confirms the old process rejects the next write; `testSchemaCacheDetectsRecreatedDatabaseAtSamePath` recreates the same path with the same schema counter and confirms setup restores missing runtime tables. Existing repeated-save suites cover prepared-store reuse.

### A6 — use lock-respecting reads for DELETE-journal stores

- Root cause: immutable opens ignore SQLite's reader/writer locks and can observe inconsistent live DELETE-journal memory/cache files.
- Fix: doctor uses strict ordinary read-only opens for memory, cache, and KV stores; compact dry runs and invocation reconciliation use ordinary reads for memory/cache data. Cold WAL fallback remains only on runtime/session stores, where SQLite WAL databases without sidecars cannot be opened as ordinary read-only on this platform.
- Regression: `StorageDoctorCommandTests.testDoctorMemoryReadsStayConsistentWithConcurrentDeleteJournalWriter` performs 50 doctor reads while a DELETE-journal writer commits 80 fixed-row updates; every report observes one row. Existing cold-WAL session read test also passes.

### A7 — limit and throttle run-end reclamation

- Root cause: run-end cleanup scanned every resolved user/project/explicit store regardless of which store the run used or whether the automatic retention pass was eligible.
- Fix: maintenance selects only the store used by a resolved workflow run, only if that store's automatic retention pass completed. It skips runs whose store cannot be identified, requires at least 128 free pages, uses busy timeout 0, and vacuums at most 128 pages per run.
- Changed expectation: the old `testAutomaticHookVacuumRunsWithoutRetentionConfig` required vacuuming an explicit store even when automatic retention was unconfigured. Renamed it to `testAutomaticHookSkipsMaintenanceWithoutCompletedRetentionPass` and now asserts the freelist stays unchanged; this reflects the finding that maintenance must honor the existing automatic policy and run stamp.
- Regression/evidence: `RunEndStorageMaintenanceTests` covers bounded reclamation, busy-writer skipping, and no reclamation without a completed pass.

### A-low — memory update CPU and hash formatting

- Root cause: external history heads compressed a value that was discarded, and retention reconstructed/re-encoded every kept version even when no rows were dropped. SHA-256 hex formatting used locale-aware `String(format:)` per byte on persistence hot paths.
- Fix: external heads skip compression; retention returns immediately when no versions are removed; runtime and memory SHA-256 rendering now use a lowercase hex lookup table.
- Evidence: `VersionedHistoryTests`, `MemoryHistoryRetentionTests`, and `JSONCanonicalTests` passed with unchanged digest/history behavior.

## Review B: runtime and CLI

### B1 — preserve Codex sessions inherited by reuse steps

- Root cause: preset expansion considered only the current step's reuse policy, so a producer inherited by a later reuse step received `--ephemeral`.
- Fix: a producer omits `--ephemeral` when any workflow step has an effective reuse policy inheriting from that producer id.
- Regression: `AgentToolPolicyResolutionTests.testPresetProducerInheritedByReuseConsumerDoesNotUseEphemeralSession` checks the inherited producer omits the flag and an independent preset step retains it.

### B2 — honor explicit KV/memory roots and deduplicate warnings

- Root cause: the validator treated every KV/memory addon as cwd-local even when its `kvRoot`/`memoryRoot` was supplied in addon config or inputs; CLI validation concatenated duplicate diagnostics.
- Fix: warn only when both root sources are absent/blank, and filter production diagnostics already present in bundle diagnostics.
- Regressions: `HandoverContractsTests` covers config and templated input roots for KV and memory; `WorkflowValidateGatewayContextTests.testValidatePrintsSharedCwdLocalWarningOnlyOnce` asserts one warning.

### B3 — correct cron window documentation

- Root cause: README described the schedule-derived prior occurrence as the previous dispatched tick and claimed skipped/coalesced/downtime ticks were covered.
- Fix: document that `previousScheduledAt` is schedule-derived, skipped/coalesced/downtime intervals can be missed, catch-up is bounded to one hour, and consumers needing complete coverage must track their own last-successful boundary. No new payload field was added because dispatch history is binding-scoped and requires durable state.
- Evidence: existing `EventLiveServeCronTests` passed; the change is documentation-only.

### B4 — reject `--file` with either diff version selector

- Root cause: the comma-separated condition required both `--from` and `--to` instead of either selector.
- Fix: validate `--file` against the disjunction of `--from` and `--to`.
- Regression: `WorkflowDefinitionCommandTests.testDiffRejectsFileWithEitherVersionSelectorAndAcceptsLeadingDashValues` checks both forms.

### B5 — accept leading-dash option values

- Root cause (re-review): consuming every unknown `--...` token as a space-separated value let a missing reason swallow safety flags such as `--dryrun`, `--dry_run`, or `--help`. Swift Argument Parser also rejects leading-dash passthrough tokens in separate-token form.
- Fix: restored the strict space-separated value rule; tokens beginning with `--` are accepted only with `--option=<value>`. Help and docs describe equals syntax for values beginning with `-`.
- Regressions: the existing leading-dash parser case now requires `--reason --x` to throw and retains `--reason=--x`; new tests reject prune/purge missing reasons before flags and run `update-prompt` end to end with `--text=--- yaml --reason=--- x` through `RielaCLIApplication`.

## Opus re-review repairs

- **A1 execution reuse lifetime:** the process-wide cache now holds up to 64 sessions instead of 8 and evicts a session at terminal run-end after payload release. Added `SQLiteRuntimeExecutionRowsTests.testTerminalSnapshotEvictsExecutionReuseEntry`; store-copy incremental-write coverage remains in `testStoreCopiesShareIncrementalExecutionReuse`.
- **A2 compact orphan history:** storage compact counts and removes memory history head/version rows whose `memory_entries` row is absent. `StorageCompactCommandTests.testApplySweepsOrphanMemoryHistoryAndReportsCount` inserts a two-row orphan and checks the reported count and deletion.
- **A3 opener barrier:** the generation-nine opener test now waits all openers at a barrier before opening SQLite, so contention begins at the real first-open/migration boundary rather than inside a generation-zero-only probe.
- **Lock reentrancy and first-open admission:** `DistributedStoreLock` instances for a path now share a refcounted descriptor and recursive process lock; a depth counter protected by that lock keeps same-thread nested acquisitions from relocking or unlocking the outer flock. `DistributedStoreLockTests.testNestedAcquisitionOnSamePathIsReentrant` guards against the prior hang. Empty-database read-only admission waits behind first-open setup while established read-only stores avoid the exclusive lock. The concurrent fresh-run regression passed ten consecutive focused runs and passed in the final full suite.
- **B1 node-payload policy:** `WorkflowSessionPolicyTests.testBundleValidationUsesNodePolicyAndStepPolicyPrecedence` now includes a valid `inheritFromStepId` declared on the node payload with no step-level policy and confirms it validates.
- **B2 local roots and diagnostics:** collector local-only deliverables now respect explicit addon roots, while validation warnings identify `workflow.nodes[index]`. The configured-root collector expectation intentionally changed to empty because configured stores are not cwd-local; the unconfigured deterministic ordering case still checks local-only output. The warning deduplication fixture changed its supplied path from `workflow.nodes` to `workflow.nodes[0]` to match the node-specific diagnostic. `AgentNodeOutputContractValidationTests` asserts the node-specific warning path.
- **B3 cron documentation:** the design spec now matches README: skipped/coalesced/downtime ticks can be missed, and coalescing dispatches only the latest pending tick with its own preceding scheduled occurrence.
- **B5 usage envelope:** `WorkflowImprovementApplyOutcome.classify` maps parsed family-level CLI usage output without an `accepted` key to `rejected("cliUsage")`; `WorkflowImprovementNodeTests.testApplyOutcomeClassifiesIdempotentConflictByActor` covers it.
- **Verification (focused):** the final focused suites covered 91 tests with 0 failures. `WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds` passed ten consecutive standalone invocations.
- **Verification (lint):** strict SwiftLint on all touched Swift source and test files — 0 violations across 23 files.
- **Verification (build/full suite/diff):** final `swift build --scratch-path tmp/prerelease/build` passed. Final `swift test --scratch-path tmp/prerelease/build -j 4` passed 4,381 XCTest cases, with 39 skipped and 0 failures, plus 30 Swift Testing cases. `git diff --check` passed.

## Verification

- `swift build --scratch-path tmp/prerelease/build` — passed.
- Focused root suite: `swift test --scratch-path tmp/prerelease/build --filter 'SQLiteRuntimeExecutionRowsTests|TerminalRetentionTests|SQLiteSchemaMigratorTests|AgentToolPolicyResolutionTests|WorkflowDefinitionCommandTests|WorkflowValidateGatewayContextTests|HandoverContractsTests|StorageDoctorCommandTests|StorageCompactCommandTests|RunEndStorageMaintenanceTests|VersionedHistoryTests|JSONCanonicalTests|EventLiveServeCronTests'` — 124 tests, 0 failures.
- Focused memory package suite: `swift test --package-path Packages/RielaMemory --scratch-path tmp/prerelease/memory-build --filter 'VersionedHistoryTests|MemoryHistoryRetentionTests'` — 17 tests, 0 failures.
- Full suite: `swift test --scratch-path tmp/prerelease/build` — passed, 4,223 XCTest cases across 507 suites plus 30 Swift Testing cases, 0 failures (exit status 0).
- Strict SwiftLint: `/usr/bin/xcrun swiftlint lint --strict` on all 29 changed Swift files — 0 violations, 0 serious violations.
- `git diff --check` — passed.

### Final re-review repair run

- `swift build --scratch-path tmp/prerelease/build` — passed after all source changes.
- Focused touched-area suites — 91 tests, 0 failures; the concurrent fresh-run suite passed ten repeated invocations, each covering 20 rounds of three simultaneous runs.
- `swift test --scratch-path tmp/prerelease/build -j 4` — 4,381 XCTest cases, 39 skipped, 0 failures; 30 Swift Testing cases also passed.
- Strict SwiftLint on 23 changed Swift files — 0 violations, 0 serious violations.
- `git diff --check` — passed.
