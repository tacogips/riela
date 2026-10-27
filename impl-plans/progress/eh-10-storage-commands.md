# eh-10-storage-commands progress

## Status

Completed repair for the independent Opus review. The storage doctor remains database-read-only, and compact now reports skipped work and uses bounded, resumable conversion and reclamation.

## Review resolutions

- **H1 definition pin memory/lock use:** pin discovery selects only JSON source fields, pages by rowid, and writes in transactions bounded by `--max-batch`. Same-store and foreign queries avoid materializing full JSON rows. Foreign and local pin timestamps use session creation time. The regression test uses 20 large legacy snapshots, observes statements, and performs a second-connection write during each page read.
- **H2 per-item failures and message tombstones:** session locks allow retired messages. Runtime, CLI, and nested conversion errors are reported per item while later items continue. Compact emits skipped items and returns failure for skips; the tombstoned-session test verifies other rows convert and a rerun converges.
- **H3 incremental vacuum budget:** manual reclamation loops 4096-page transactions, truncates the WAL between chunks, and stops when freelist is empty or the 30-second budget expires. `workRemaining` reflects residual pages. A regression fixture starts above 4096 free pages and reaches freelist zero in one invocation.
- **H4 live-session full vacuum:** before full conversion, the reclaimer probes both supported execution-lock directories using non-blocking `flock`. It reports `deferredLiveSessions` while a lock is held. The lock regression asserts that action.
- **M5 definition database coverage:** doctor reports the definition DB as a separate `definitions` store. Compact includes it only when it exists and does not create it for a bare store. Tests cover an imported workflow and the absent-file case.
- **M6 max batch agreement:** parser maximum is 10000, matching the conversion/listing APIs. Values above that are usage errors; the regression covers 10001.
- **M7 attachment references:** doctor reads `memory_evolution_attachments` and JSON record file lists, scans `<memoryRoot>/files`, compares normalized full paths, and does not scan compressed history blobs or concatenate payloads. Regression verifies one referenced 12-byte file and one 29-byte orphan.
- **M8 exit/reporting:** compact returns failure for busy, skipped, or failed work; insufficient-space deferral sets `workRemaining` but remains a successful deferral. Text reports include work remaining, warnings, skipped rows, reclaimable bytes, and largest records/sessions. The `VACUUM INTO` guidance now gives an operator sequence and says cross-volume rename is not atomic and no store-wide CLI lock is exposed.
- **L1-L4:** abandoned-candidate reporting calls the reconciler with `apply: false`; unreadable doctor stores are skipped with stderr diagnostics if another store opens; compact dry-run session scans use strict read-only SQL, and apply `convertedBytes` is measured after reclamation. Locked rows no longer block later rows in the fetched candidate window. Definition-store location and the actionable vacuum caveat are recorded in `design-efficient-history-and-storage.md`.

## Changed assertions and reasons

- Strengthened `testHeldSessionLockIsSkippedAndLeavesWorkRemaining`: removed `--max-batch 1` so `workRemaining` cannot pass merely because the candidate count equals the limit. It now expects exit 1 for a busy session, zero converted sessions, and the legacy inline row still present.
- Updated the low-space alternative assertion from requiring a nonexistent “store lock” to requiring the stop-writers sequence and an explicit cross-volume atomicity caveat.
- Increased the shared reclamation fixture from 16 to 32 rows so the free-page regression starts above 4096 pages. Existing size and shrink assertions remain intact.
- The new NONE-mode shrink assertion compares the reclaimer's DB-plus-WAL sizes after connection close; measuring the main DB file alone missed free space retained in WAL.
- No other existing test assertions were weakened. Added regressions for streamed pin backfill, a <128 MiB peak-RSS increase on large legacy rows, concurrent writer access, tombstones, parser/listing batch limits, definition inspection/creation behavior, attachment accounting, unreadable stores, legacy-inline/envelope and WAL doctor fixtures, full-vacuum lock deferral, NONE-mode conversion shrink, and multi-chunk incremental vacuum.

## Scope notes

- `Sources/RielaCore/WorkflowDefinitionStore.swift` and `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` are outside the plan's original writePaths but were explicitly named by H1 and M5. The schema's merged retention behavior was preserved; the existing timestamp fallback remains.
- `Sources/RielaCLI/RetentionSQLiteReclaimer.swift` and `Tests/RielaCLITests/RetentionReclamationTests.swift` were explicitly named by H3/H4. Their changes are required by this repair.
- `design-docs/specs/design-efficient-history-and-storage.md` is outside writePaths and was edited only for the requested L4 documentation note.
- No memory CLI implementation files were edited.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "StorageDoctorCommandTests|StorageCompactCommandTests|DoctorCommandTests|DoctorBackendCapabilityTests|GarbageCollectionCommandTests"'` — exit 0; 41 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "RetentionReclamationTests"'` — exit 0; 13 tests, 0 failures.
- Additional focused regressions: `testDefinitionPinBackfillSelectsOnlyFieldsAndDoesNotHoldLongWriterLock`, `testLegacyCLIListingCapsAtParserMaximum`, and `testNoneAutoVacuumShrinksAfterLegacySessionConversion` — all passed individually.
- Combined focused coverage — 54 tests, 0 failures across the plan suites and retention suite. The three additional regression runs overlap the plan-suite run.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageCompactCommand.swift Sources/RielaCLI/StorageRoots.swift Sources/RielaCLI/RetentionSQLiteReclaimer.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Tests/RielaCLITests/StorageDoctorCommandTests.swift Tests/RielaCLITests/StorageCompactCommandTests.swift Tests/RielaCLITests/RetentionReclamationTests.swift` — exit 0.
- `git diff --check` — exit 0.

## Remaining ownership

Surface parity and help/catalog registration remain eh-11-owned as specified in the plan.
