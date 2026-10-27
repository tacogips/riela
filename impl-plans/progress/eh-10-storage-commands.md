# eh-10-storage-commands progress

## Status

Completed. `riela doctor storage` is read-only, and `riela storage compact` reports dry-run work and applies resumable conversion, reconciliation, configured pruning, definition pin backfill, and manual reclamation.

## Changes

- `StorageRoots.swift`: provides `StorageClientAction` and ArgumentParser-backed `ParsedStorageCommandArguments`, including every contract option and command-specific flag validation.
- `StorageDoctorCommand.swift`: opens files with strict read-only mode; reports dbstat table sizes with estimated-column fallback, memory history/current bytes and legacy/version/orphan attachment metrics, session legacy/abandoned/prune protection metrics, definition history metrics, per-file text/JSON output, and prune/free-page estimates. Auto scope includes project and user session and memory roots.
- `StorageCompactCommand.swift`: preserves dry-run estimates, scans memory/cache/KV roots, converts memory/runtime/CLI/nested legacy rows in bounded batches, takes non-blocking session locks, reconciles abandoned invocations, backfills definition pins and applies the configured window, runs retention before bounded manual reclamation, and sets `workRemaining` for batches, busy locks, retention failures, or remaining incremental free pages. Compact JSON includes the retention target report or `{ "state": "notConfigured" }`.
- `RielaCommand.swift`, `RielaClientCommandRouter.swift`, and `RielaCLIApplication.swift`: route `doctor storage` and `storage compact`; help/catalog ownership remains with eh-11.
- `StorageDoctorCommandTests.swift`: parser help flags, read-only hash/mtime preservation, text blocks, and a legacy 20-version memory report with amplification and legacy counts.
- `StorageCompactCommandTests.swift`: dry-run immutability/estimates, bounded memory and runtime/CLI/nested conversions and convergence, definition pin insertion, held-lock skip, abandoned nested marking, configured and unconfigured retention, reclamation shrink, low-space exact byte warning and `VACUUM INTO` alternative.

## Out-of-scope edits

- `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift`: one-line compatibility repair required by eh-10 definition pin backfill. The query referenced nonexistent `cli_workflow_sessions.created_at`; it now uses the original session `createdAt` from `record_json`, falling back to the table's `updated_at`. The end-to-end compact conversion test reached this path and failed before the repair.
- `Sources/RielaCLI/RetentionSQLiteReclaimer.swift` and `Tests/RielaCLITests/RetentionReclamationTests.swift` were already changed by the prior partial eh-10 attempt and are preserved. They add a bounded manual incremental-vacuum page budget and its regression test, required for large stores that cannot pass the full-VACUUM free-space guard.

## Edit identities

Current SHA-256 values for eh-10 source/test files:

- `StorageDoctorCommand.swift`: `86348151a203be40dd6194ad87f7d270883170960f75e28cbed483511f8174df`
- `StorageCompactCommand.swift`: `5017ef72496b78a75fb4d6c8995bb3163a5b80227a7322d846f2ca0a03b2381e`
- `StorageRoots.swift`: `ac2486b597039273c58b6a98f5f12dcc1ae23e8d71884206f06a5439a776d3eb`
- `RielaCommand.swift`: `c254fec1cbf3364333972a780c99733a2e96f392d9658ba15b92fca1d1f3f9b5`
- `RielaClientCommandRouter.swift`: `f105d30de9d4fb076bfc3122829515f6f1d845b55484a21e4fc59730f3e331ab`
- `RielaCLIApplication.swift`: `0032a3ebde1d96eab468295614b150ec183a40ba2563c22de6d5ebe2f9f317cf`
- `StorageDoctorCommandTests.swift`: `ab6899d09c6f751d58d9fa34b941e643b1b413c468a51998fbde27c8a7a85`
- `StorageCompactCommandTests.swift`: `96f9a394f24ea4415c9ee0cbd5d4e172e35489f55f0cf6d126509ae4ae8c76b5`
- Out-of-scope pin backfill query repair, `WorkflowDefinitionHistorySchema.swift`: `5196350c9da33f999af7a868fda688e7659b40c3e5bd941e153fb6ed51860b1d`
- Preserved reclaimer/test edits: `RetentionSQLiteReclaimer.swift` `1f755f66dca87423ef6bda0788bedb211a2c701d107b87e2d115815343a3a3de`; `RetentionReclamationTests.swift` `b2012d8be2a50e09ec014bb7d5511e9d40f78cde06ee030e16fd1c0fada97ed9`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build'` — exit 0; `Build complete! (5.35s)`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "StorageDoctorCommandTests|StorageCompactCommandTests|DoctorCommandTests|DoctorBackendCapabilityTests|GarbageCollectionCommandTests"'` — exit 0; 32 tests executed, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageCompactCommand.swift Sources/RielaCLI/StorageRoots.swift Sources/RielaCLI/RielaCommand.swift Sources/RielaCLI/RielaClientCommandRouter.swift Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/RetentionSQLiteReclaimer.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift Tests/RielaCLITests/StorageCompactCommandTests.swift Tests/RielaCLITests/RetentionReclamationTests.swift` — exit 0.
- `git diff --check` — exit 0.

## Deviations and open risks

- Surface parity and help text remain eh-11-owned as specified by the plan.
