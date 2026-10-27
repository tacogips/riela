# eh-10-storage-commands progress

## Status

Completed the independent Opus review repairs. Doctor handles cleanly closed WAL stores, does not create execution locks during reconciliation, and reports attachment bytes per memory using both current and legacy references. Compact’s batch accounting, failure reporting, lock probing, and optional full-vacuum override are covered by focused regressions.

## Review resolutions

- **Finding 1 — bounded pin backfill:** retained the bounded, rowid-paged backfill from the prior repair; the definition-pin stress regression remains in the focused suite.
- **Finding 2 — conversion failures and tombstones:** per-item failures remain reported and later rows continue. The new one-slot batch regression proves an undecodable first row does not prevent conversion of the next valid row.
- **Finding 3 — incremental reclamation:** retained bounded incremental vacuum behavior and its multi-chunk regression.
- **Finding 4 — live-session full vacuum:** retained default deferral and added `--allow-live-vacuum` as an explicit opt-in. The default remains safe; the override applies only to full conversion.
- **Finding 5 — definitions database coverage:** retained separate definitions-store reporting and the no-create regression.
- **Finding 6 — maximum batch:** retained the 10,000 parser cap and regression.
- **Finding 7 — attachment accounting:** scans only `files/<memoryId>/` and adds `SELECT path FROM memory_files` to the reference set. A regression saves real alpha and beta memories with 1,000-byte and 2,000-byte attachments, removes their history-head copies of those references so `memory_files` is the only reference source, then adds a 3,000-byte alpha orphan; expected orphan totals are alpha 3,000 and beta 0.
- **Finding 8 — exit/reporting:** checkpoint pending now adds a warning and returns failure. Existing skipped/busy/failure reporting remains. A held-reader regression exercises the warning and exit code.
- **N1 — closed WAL doctor regression:** reconciler opens apply-false databases with immutable fallback. A regression removes WAL/SHM sidecars after a clean close and verifies doctor still lists the session store.
- **N2 — doctor lock and tree safety:** apply-false reconciliation does not acquire locks; runtime snapshots are loaded via `loadStrictReadOnly`. The regression creates an unsettled nested invocation and confirms no tree changes and no child/parent lock files.
- **N3 — per-memory orphan totals and legacy references:** resolved with the attachment accounting change and the two-real-memory regression above.
- **N4 — exact batch boundary:** removed `count >= maxBatch` premarks; the loop guard reports remaining work only when another candidate is left. A 16-row / `--max-batch 16` regression converts all rows and reports false.
- **N5 — progress and vacuum safety:** checkpoint pending adds an explanatory warning; successful attempts, not failed conversions, consume a batch slot; reclaimer probes existing locks with non-blocking shared flock rather than briefly taking exclusive locks; and `--allow-live-vacuum` overrides the live-session full-vacuum deferral. Regressions cover checkpoint warning, failed-row progress, active-lock deferral, and the explicit override.
- **Low L1:** retained the apply-false abandoned-candidate report path; it now uses immutable-fallback read opens and no execution-lock acquisition.
- **Low L2:** unreadable stores continue to be skipped with stderr diagnostics when another store can be opened.
- **Low L3:** compact dry-run scans remain strict read-only, and apply `convertedBytes` remains measured after reclamation.
- **Low L4:** the design document records the separate definition-store location, actionable `VACUUM INTO` sequence, and the full-vacuum lock safeguard/override semantics.

## Changed assertions and reasons

- Changed the first-run `workRemaining` assertion in `testApplyConvertsLegacyRuntimeAndCLISessionRows` from true to false. The fixture contains exactly one candidate in each conversion category and all complete in that invocation; reporting remaining work solely because a category count equals the batch size was the N4 defect. The second-run convergence assertion remains.
- In the prior repair, `testHeldSessionLockIsSkippedAndLeavesWorkRemaining` dropped `--max-batch 1`; otherwise equality with the batch count could mask whether a busy row itself set `workRemaining`. The test still asserts exit 1, zero session conversions, and the legacy row remains.
- In the prior repair, the low-space guidance assertions changed from requiring an unavailable “store lock” to checking the actual stop-writers sequence and cross-volume rename caveat.
- In the prior repair, the shared reclamation fixture grew from 16 to 32 rows so the multi-chunk test begins above 4,096 free pages. The NONE-mode shrink assertion now compares database plus WAL size after connection close because the main database alone omits retained WAL bytes.
- These changes correct stale or insufficient assertions; no pre-existing test was weakened.

## Scope notes

- `Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift` and `Sources/RielaCLI/RetentionSQLiteReclaimer.swift`, plus `Tests/RielaCLITests/RetentionReclamationTests.swift`, are outside the original `writePaths` but are directly named by the requested N1/N2/N5 repairs.
- `design-docs/specs/design-efficient-history-and-storage.md` is outside `writePaths` and was edited to record L4 and the accepted live-vacuum behavior.
- The pre-existing concurrent PR #181 edits were not edited by this repair: `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryStore.swift`, `README.md`, `Sources/RielaCLI/RielaRetentionService.swift`, `Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift`, `Sources/RielaCore/RielaRetentionConfiguration.swift`, `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift`, `Sources/RielaCore/WorkflowDefinitionStore+Retention.swift`, `Sources/RielaCore/WorkflowDefinitionStore.swift`, `Tests/RielaCLITests/RielaRetentionServiceTests.swift`, `Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift`, `Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift`, `Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift`, `Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift`, `docs/workflow-definition-store.md`, and `impl-plans/progress/merge-pr-181.md`. No memory CLI files were edited.
- Temporary logs and the scratch build are under ignored `tmp/eh-10-review-repair/`.

## Verification

- `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/eh-10-review-repair/build --filter "StorageDoctorCommandTests|StorageCompactCommandTests|DoctorCommandTests|DoctorBackendCapabilityTests|GarbageCollectionCommandTests|RetentionReclamationTests"'` — exit 0; 62 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/eh-10-review-repair/build --filter "StorageCompactCommandTests.testCheckpointPendingAddsWarningAndFailsApply"'` — exit 0; 1 test, 0 failures.
- `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/review-build --filter StorageDoctorCommandTests.testDoctorCountsOnlyMemorySpecificUnreferencedFilesUsingLegacyReferences'` — exit 0; 1 test, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageCompactCommand.swift Sources/RielaCLI/StorageRoots.swift Sources/RielaCLI/RetentionSQLiteReclaimer.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift Tests/RielaCLITests/StorageCompactCommandTests.swift Tests/RielaCLITests/RetentionReclamationTests.swift` — exit 0.
- `git diff --check` — exit 0.
