# Merge PR #181: definition retention

## Merge state

- Fetched `origin` and merged `origin/feat/definition-retention` with `git merge --no-ff --no-commit`.
- Merge resolution is staged and intentionally uncommitted. No commit, push, rebase, reset or history rewrite was performed.
- PR #181's prune and purge commands, audit behavior, config alias and documentation are retained. Retention now uses the existing shared `VersionedHistory` engine and its guarded delete path.

## Conflict resolutions

| Conflicted file | Resolution |
| --- | --- |
| `Sources/RielaCLI/WorkflowDefinitionArguments.swift` | Combined `--history-retention` and `--expected-revision` with PR #181's `--keep`, `--all-workflows`, `--dry-run` and `--yes`. Kept `undo`/`redo` parsing and operation-specific validation. Moved prune/purge validation into a helper to keep SwiftLint complexity within the project limit. |
| `Sources/RielaCore/WorkflowDefinitionStore.swift` | Kept the existing shared-history store, migration, pin handling and undo/redo paths. Added `prune`/`purgeHistory` audit operations and the retention error. The PR's standalone blob-table deletion implementation was not retained. Internal store access needed by the retention adapter is exposed only within the module. |
| `Sources/RielaCore/WorkflowDefinitionStoreSchema.swift` | Kept `WorkflowDefinitionHistorySchema.create`. This preserves the shared engine schema and its retention guard row; the PR's duplicate table creation and trigger drop/recreate helper were discarded. |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` | Kept the existing undo/redo service methods and added thin prune/purge delegates to the shared store API. |
| `Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift` | Preserved the existing history, undo/redo, diff and configuration coverage; added prune/purge command coverage and reconciled surface enumeration with the existing undo/redo commands. |
| `Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` (add/add) | Kept all existing eh-04 retention, migration and pin tests, then added explicit prune/purge engine coverage for recent-head and live-pin protection, audit cleanup and redo-branch purge. |

The incoming `WorkflowDefinitionStore+Retention.swift` was rewritten as an adapter over `VersionedHistoryStore`. Prune calls engine retention with protected pins; purge asks the engine to retain exactly protected versions and remove the redo branch as well. Both paths remove definition metadata through `WorkflowDefinitionHistorySchema.deleteDroppedVersionsAndOrphanAudit` and `withGuardedDelete`; neither path drops/recreates triggers.

## Other merge reconciliations

- `retention.definitions.keepVersions` is resolved as an alias of `workflowDefinitions.historyRetention`, with CLI flag > project config > user config > default 10. Conflicting values in the same config file produce a validation error. `riela gc` and per-write automatic retention both use the shared engine; unset retention is 10 generations.
- Added exact-retention support to `VersionedHistoryStore` for purge while keeping shared survivor reconstruction, guarded deletion and blob GC. Automatic retention continues to preserve its redo branch; purge removes an unprotected redo branch.
- Added missing surface catalog/router entries for the merged `storage compact` command and existing memory undo/redo commands. Added workflow definition undo/redo to the typed subcommand enum so catalog and parser enumeration agree.
- Reconciled README, workflow store guide, design spec and skill text with 10-generation default retention, the alias, 24-hour former-head grace and shared-engine deletion.
- The older CLI-session migration query now falls back to an empty timestamp when legacy rows lack `updated_at`; pin payload timestamps remain preferred.

## Changed test assertions and reasons

- `testDefinitionCLIEnumeratesAllOperationsAndRejectsBadGrammar` now enumerates 12 commands: the existing eight definition operations, existing `undo`/`redo`, and PR #181's `prune`/`purge-history`. The old count of eight did not include the catalog's existing undo/redo rows or the two incoming commands.
- The CLI prune preview for versions created during the test now expects zero removed versions and no prune audit. Recent former heads inside the 24-hour grace period, the current head and the last file import are protected. Purge still produces one `purgeHistory` audit while retaining those protected versions.
- The explicit retention CLI test now creates its candidate versions with an old injected timestamp. This lets the test verify deletion beyond the 24-hour grace window instead of expecting recently-written versions to be pruned.
- The new shared-engine test expects an active pinned generation and last file import to survive prune. Before purge it moves the head back and advances the test clock past 24 hours; purge then drops the unprotected redo generation while preserving the pin, file import and current head.
- Added assertions that the two config keys reject differing values and that manual GC with no definition override uses the default 10 generations. These pin the alias validation and the no-unlimited-default requirement.

## Verification

All commands below used Xcode's arm64 Swift toolchain.

| Command | Result |
| --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | Passed. `Build complete! (5.76s)`. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowDefinition.*|VersionedHistoryConformanceTests|RielaRetention.*|SurfaceCatalog.*|SurfaceParity.*|AutomaticRetention|TerminalRetentionPolicy.*|SQLiteRuntimeSchemaMigration.*' > tmp/merge-pr-181/focused-tests.log 2>&1` | Passed: 213 tests executed, 1 skipped, 0 failures (130.063 seconds). The filter covered the requested workflow definition, engine conformance, retention, surface parity/catalog, automatic retention, terminal retention and runtime schema migration suites. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryStore.swift Sources/RielaCLI/CLISurfaceEnumeration.swift Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/WorkflowDefinitionArguments.swift Sources/RielaCLI/WorkflowDefinitionCommand.swift Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift Sources/RielaCore/RielaRetentionConfiguration.swift Sources/RielaCore/SurfaceCatalog+Rows.swift Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionStore+Retention.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCLITests/RielaRetentionServiceTests.swift Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` | Passed: 19 files linted, 0 violations, 0 serious. |

Earlier verification attempts exposed and fixed the command surface parity gaps, a legacy migration fixture without `updated_at`, and a test fixture that wrote versions inside the 24-hour grace period. The final full focused run above passed after those fixes.

## Reviewer findings resolved

- **H1 — retention settings stay configured.** Added a non-persisting option to the shared `VersionedHistoryStore.applyRetention` API and use it for explicit prune/gc operations. GC honors a workflow's saved `retained_generations` value first, then falls back to the shared config resolver. Restored coverage for an empty prune leaving the stored value `NULL`, prune followed by writes using the default window, and gc preserving a workflow's saved `--history-retention 50`.
- **H2 — one definition-retention resolver.** GC now resolves `workflowDefinitions.historyRetention` and its `retention.definitions.keepVersions` alias through `WorkflowDefinitionHistoryConfiguration.resolve`, with project config ahead of user config and default 10. Target resolution uses the project config for project stores and user config for user stores; a project retention policy for other categories no longer replaces user definition history settings. `0` means keep all for writes and gc. Added coverage for alias-only gc, zero, project-over-user precedence, and category-only project config fallback.
- **M1 — removed blob accounting.** Retention results and audits now take removed version count from the engine's dropped generations and removed bytes from its `freedBytes` return. Restored assertions that prune reports nonzero removed blob count and bytes.
- **M2 — retention audits excluded from overwritten-change lookup.** Restored operation filters on both the origin and result audit rows. Restored the regression using an injected old clock and a force import followed by prune and two updates.
- **M3 — prune audit records survive later retention.** Orphan cleanup now preserves `prune` and `purgeHistory` audit rows. Added a prune-then-write-past-the-window regression asserting the prune record remains in history.
- **M4 — dropped PR #181 behavior and trigger tests restored.** Added invalid-input/no-write and direct guarded-delete checks; purge coverage for protected survivors, one purge audit and unchanged head revision; overwritten-change lookup coverage; and retention config parsing coverage for valid, zero, and unknown definition keys. Added a purge audit `/retention/protected/<versionId>` entry with a 24-hour expiry, and taught the protection query to honor it so former heads stay protected after purge. README and store documentation now state that zero keeps all generations.
- **L1 — exact-retention conformance.** Added a `VersionedHistoryConformanceTests` case covering exact survivors, redo-branch removal, survivor reconstruction, and unchanged `retained_generations`.
- **Migration fixture compatibility.** The CLI pin backfill now checks whether the legacy session table has `updated_at`; it uses the payload timestamp when available and an empty fallback for older schemas without that column.

### Restored and changed tests

- Added retention-store regressions for no-op prune configuration preservation, subsequent default retention, invalid inputs and guarded deletes, purge audit/head behavior, overwritten-change filtering, prune audit survival, purge former-head protection, and nonzero removed blob metrics.
- Added gc regressions for saved per-workflow retention, `workflowDefinitions.historyRetention` alias resolution, project/user precedence, category-only project policy fallback, and zero-as-unlimited behavior.
- Added exact engine conformance and config parsing cases; adjusted the former zero-is-invalid expectation because zero now explicitly means keep all.
- The legacy CLI session migration fixtures now pass with a schema that omits `updated_at`.

### Verification after fixes

All commands used Xcode's arm64 toolchain. Logs were written under the ignored `tmp/merge-pr-181-review/` task directory.

| Exact command | Result |
| --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build > tmp/merge-pr-181-review/build.log 2>&1` | Passed: `Build complete! (21.90s)`. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowDefinition|VersionedHistoryConformanceTests|RielaRetention|SurfaceCatalog|SurfaceParity|AutomaticRetention|TerminalRetentionPolicy|SQLiteRuntimeSchemaMigration|StorageCompactCommandTests|StorageDoctorCommandTests' > tmp/merge-pr-181-review/focused-tests.log 2>&1` | Passed: 250 tests executed, 1 skipped, 0 failures (205.626 seconds). |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --package-path Packages/RielaMemory > tmp/merge-pr-181-review/memory-tests.log 2>&1` | Passed: 113 tests executed, 0 failures (67.294 seconds). |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryStore.swift Sources/RielaCLI/RetentionSQLiteReclaimer.swift Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift Sources/RielaCLI/StorageCompactCommand.swift Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageRoots.swift Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift Sources/RielaCore/RielaRetentionConfiguration.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionStore+Retention.swift Sources/RielaCore/WorkflowDefinitionStore.swift Tests/RielaCLITests/RetentionReclamationTests.swift Tests/RielaCLITests/RielaRetentionServiceTests.swift Tests/RielaCLITests/StorageCompactCommandTests.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift > tmp/merge-pr-181-review/swiftlint.log 2>&1` | Passed: 20 files linted, 0 violations, 0 serious. |
