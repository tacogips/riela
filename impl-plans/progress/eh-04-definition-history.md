# eh-04-definition-history progress

## Assignment

- Plan: `impl-plans/active/efficient-history-04-definition-history.md`.
- Dependencies: accepted `eh-01-history-engine` and `eh-02-runtime-contract`.
- Branch: `feat/efficient-history`.
- Implementation status: complete; changes remain unstaged in the working tree.

## Changed files and behavior

- `Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift`: maps engine SQL values to SQLite BLOB values and reads only the history `blob` column as binary. SQLite text columns also expose byte access, so treating every `SQLiteRow.data` result as BLOB corrupted the engine codec values.
- `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift`: creates engine tables before guarded triggers; rebuilds generation-10 definition rows with monotonic history numbers; imports compressed history; backfills same-store pins under the 256 MiB snapshot threshold; applies retention or records `pendingBackfill`; and removes the legacy blob table. The small-schema migration test verifies retained UUIDs, pin version 2, generation 11, and the retained window.
- `Sources/RielaCore/WorkflowDefinitionPins.swift`: implements normalized same-store and foreign-store targets, transactional same-store pins, foreign pins before local session writes, successful-commit deduplication, terminal-session missing-version handling, and normalized local store roots.
- `Sources/RielaCore/WorkflowDefinitionStore.swift`: adds configured retention defaults, engine-backed document lookup, pin release, retained audit status, undo/redo audit writes, retention state/backfill/report APIs, and contextual dropped-version errors. Version identity remains queryable after both the document row and audit rows are removed.
- `Sources/RielaCore/WorkflowDefinitionDiff.swift`: adapts the shared `VersionedHistoryDiff` implementation for definition JSON documents.
- `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift`: threads default and per-write retention through import/update/prompt update/restore, reads exact retained versions, and adds service undo/redo.
- Tests: updated generation-11/no-blob expectations in `WorkflowDefinitionStoreTests`; added `WorkflowDefinitionRetentionTests`; added foreign/same-store pin, failure/retry, held-lock ordering, release, unknown-version and path-normalization cases; added service restore/undo/redo tests; extended resume/rerun resolution tests to pin version 3 and advance 25 commits by 25 hours.

Existing test changes are limited to changed storage behavior: generation expectations moved from 10 to 11, blob assertions now inspect shared history rows, and one-time session-store counts no longer query the removed blob table. The resolution tests now use a fake clock and actual version 3 so a pinned version is proven to survive a real retention window.

## Per-file SHA-256

The first hash is the task-start baseline from `tmp/efficient-history/eh-04-definition-history/pre-edit-sha256.txt`; the second is the final source hash after implementation. `WorkflowDefinitionStoreSchema.swift` was inspected and left byte-identical. The new retention test did not exist at task start. The progress log's pre-update hash records the file immediately before this final log rewrite. Intermediate patch-by-patch hashes were not captured; this is the hash-evidence deviation for the continuation work.

| Path | Before | After |
|---|---|---|
| `Sources/RielaCore/WorkflowDefinitionStoreSchema.swift` (unchanged) | `42846d654d3584e26243e7943b910a9368721ed876c2a68ca62a48dc9e158fc2` | `42846d654d3584e26243e7943b910a9368721ed876c2a68ca62a48dc9e158fc2` |
| `Sources/RielaCore/WorkflowDefinitionStore.swift` | `42805fed21aae25bff9ce0956d5c26159a59fbae6f3fd2445a316509e3097db1` | `11dfade313d3b2218efd193bfc4b049454a04b81c7cfa3602ea425ee1eb1d4d0` |
| `Sources/RielaCore/WorkflowDefinitionDiff.swift` | `5e087b7b76ae4cc5d1e2f9b6fa07829abc973d1ade92f49a5179d776039cf70c` | `37eef5809263fab1561209f47ee03b89295936bdcd2e264ed838a4fbc99077cb` |
| `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` | `f0aa3f07d9dfb4cea4268e1116920fa7eb1aa62dcf638e17c30920ed0a9eca04` | `87884025e54a8fbc3b6de15e2b08c73258d109356d9f58e42c150be8030270e2` |
| `Sources/RielaCore/WorkflowDefinitionPins.swift` | `401fe9721687cf7b41412137016bc285bcb6e028dfc0776ceb5475115b3af925` | `53aa739d3508b903787c629f5ded0b0f9e509c26222bfce64df0cd4962d45fcf` |
| `Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift` | `d064764d928037fa8c395ebf93a7a3779d3c9eb1a3919790ddf2f6bf4f176543` | `f6a750d061b711fdc8ea90cdf29d21a827a3fd775d97187b6e3e5d2090bab729` |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` | `770c9956c6206203ab2fff562fd52f54b052f21a4f5c610327e1526a93087416` | `cccb27cdee1eff77174585e3b59a924213b1e0526eee427bb9475903fde9587c` |
| `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` | `87c3ab57d50361937757ad10b17df2d78de1f4098ef0d6106c480127de395be0` | `69a9ba47cbed935725771f954c5d2b716f8ed3d36a472951302556b967cb44a3` |
| `Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift` | `90b93211c9ea438b594bc7e8d0603a087f81ffedfb74ce3911fc3c9331187492` | `22e134da5b0cac258d5e431cabffe675b9d686eb6cb17a468fd7903f95bfe4b9` |
| `Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` (new) | missing | `490e5cd44fd87e82ea8d15b58b3619fde90d1296c37ca3adf5da9058b33c7137` |
| `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift` | `01ae622b2554779696b8737b1b17dbb1318de8f3504425293207448f1c93269b` | `86ba6f1ad16a2a47ec702b1f142f1be1928c2db4f83c6881e319ecae42ccc699` |
| `Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift` | `2b539cafff1dac69fc67d246f40e262624841d46314f1ff459e83bc2a6a365a3` | `71cbc044ae25fd9ed122e2fdc477a4d2748c77355e4e895697fe4a24a64fdadc` |
| `impl-plans/progress/eh-04-definition-history.md` (before final rewrite) | `31ed6a56acb4393e7899333a0904b38b5056ddacc98bafae087d1456efebe5c6` | updated by this entry |

## Verification

All Swift commands ran in an arm64 shell. Complete logs are under `tmp/efficient-history/eh-04-definition-history/`.

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build complete. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionServiceTests|WorkflowDefinitionServiceResolutionTests"'` | 0 | 46 tests, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeSchemaMigrationTests/(testAnOlderSessionStoreIsDiscardedAndRecreatedAtTheCurrentGeneration|testGeneration10UpgradesTo11WithoutLosingSnapshot|testGeneration9UpgradesThrough10To11WithoutLosingSnapshot)"'` | 0 | 3 tests, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests" 2>&1 | tee tmp/efficient-history/eh-04-definition-history/store-suites.log'` | 0 | 34 tests, 0 failures. |
| `grep -c -e 'no such table' -e 'already exists' tmp/efficient-history/eh-04-definition-history/store-suites.log` | 1 | Printed `0`; grep status 1 means no matching errors. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionStoreSchema.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaCore/WorkflowDefinitionDiff.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift'` | 0 | Strict lint passed for every owned Swift file. |
| `git diff --check` | 0 | Clean. |

## Deviations and risks

- Added `definition_version_identities(version_id, workflow_name, history_version, created_at)` in the owned schema/store files. The plan requires known dropped UUIDs to return `versionNotRetained`, while retention can delete both the version row and every audit row that mentions it. The immutable, document-free identity index preserves that distinction and is covered by a test after the corresponding audit row has been pruned. This adds a small permanent identity row per committed version; payload documents and audit rows still follow their planned retention rules.
- The held-foreign-lock test holds the definition database writer lock and verifies the local session database is not opened before the lock is released. The runtime opener waits on locks and has no short busy-timeout injection seam in eh-04-owned files, so the planned “held lock throws” assertion is covered separately by an injected foreign pin insert failure; that failure leaves the local store absent and a retry succeeds.
- No out-of-scope file edits. The runtime schema migration and CLI session store call sites remain untouched.

## Done criteria

- [x] Shared engine adapter and definition generation-11 schema/migration implemented; history tables precede dependent guarded triggers.
- [x] Retention window, 24-hour former-head protection, last-file protection, live pins, pending backfill, audit cleanup, and guarded deletes implemented and tested.
- [x] Store undo/redo, document/blob/version/history access, retained state, and backfill report APIs implemented.
- [x] Same-store and foreign-store pin hooks implemented with normalized paths; held-lock ordering, foreign failure/retry, release, terminal missing-version handling, rollback, and symlink/trailing-slash cases tested.
- [x] Service retention threading, undo/redo, restore validation, and shared diff adapter implemented and tested.
- [x] Focused definition suites and generation-open tests pass with nonzero counts; store-suite grep prints zero; remaining store-suite failures: none.
- [x] Progress record includes changed symbols/files, test changes, commands, exits, hash evidence, deviation and risk notes.

## Independent review repairs

Addressed all High and Medium findings, plus Low L2/L3; completed low-risk L1
consolidation. The design deviation requested by L4 is recorded in §4 of
`design-docs/specs/design-efficient-history-and-storage.md`.

- **H1:** commits now pass only `write.historyRetention` and the configured
  default to the history engine, so a resolved default is not saved as an
  explicit per-workflow override and later config defaults still apply.
  Pending backfill pins all existing engine versions before each write. Both
  explicit backfill and migration apply `saved ?? default` per workflow and
  clear an absent saved override after the engine call. Regression coverage
  changes a default from 10 to 3 after 12 writes, checks the newest three plus
  the file pin, then verifies a 50-generation workflow survives pending
  backfill configured with default 10.
- **H2:** definition commits force a history version; service no-op updates
  remain handled as `.unchanged` before commit. The original identical-document
  inputs were restored in `testIdenticalDocumentsShareBlobAndHistoryFiltersNewestFirst`
  and `testFileVersionPinMovesOnlyForFileOperations`; both assert 2 definition
  and engine version rows, and the file-operation case asserts the identical
  force update advances `last_file_version_id`. The service restore test also
  restores the current bytes and checks a `.restore` audit row.
- **M1:** added pre-insert conflict guards for REPLACE conflicts on versions,
  audit, engine history versions and immutable identities; added head delete
  guards. Tests attempt REPLACE on all four tables, unguarded deletes from
  audit/history/head tables, and verify the retention guard is empty after a
  commit that drops versions.
- **M2:** stale pins younger than 24 hours are retained. Pin timestamps now
  come from the saved session's `updatedAt`, which is written by the runtime
  store clock. Stale pin checks group rows by store root, open each foreign
  database once and query session ids in a batch. A fake-clock regression
  verifies a missing-session pin survives the first commit and releases after
  25 hours.
- **M3:** generation-11 backfill scans CLI `record_json` alongside runtime
  snapshots and includes both payload columns in the 256 MiB limit. A CLI-only
  fixture with no runtime snapshot keeps `defv-2` after migration.
- **M4:** added indexes for pin `(workflow_name, history_version)` and
  `definition_versions.document_digest`; foreign checks are batched by root;
  commit no longer rebuilds the previous head document. The remaining engine
  retention re-encoding cost at R up to 10000 belongs to eh-01 as the reviewer
  specified; the implementation keeps the documented 0...10000 API bound.
- **L1:** protected version selection and guarded-delete entry now each have a
  shared helper used by commit, explicit backfill and migration. The migration
  uses fractional ISO timestamps. **L2:** migration retention now propagates
  corrupt history errors instead of skipping the workflow. **L3:** dropped
  version errors use the store's configured default when no override exists;
  a regression checks the reported value is 3.
- **Test gaps:** added write-after-undo branch retention/expiry coverage and
  expanded the generation-10 fixture to distinct documents; migration checks
  exact `defv-2` bytes, revision 15 and next history version 16. The existing
  held-lock test continues to verify write ordering rather than a timed
  failure; see the previously recorded deviation above.

### Restored and changed assertions with reasons

- `WorkflowDefinitionStoreTests.testIdenticalDocumentsShareBlobAndHistoryFiltersNewestFirst`:
  restored the second write's original bytes. The test now explicitly proves
  identical documents still create two retained definition and engine versions
  while sharing their payload.
- `WorkflowDefinitionStoreTests.testFileVersionPinMovesOnlyForFileOperations`:
  restored the identical-to-head force update input. It proves force import
  creates a version and moves the file pin even when bytes match.
- `WorkflowDefinitionStoreTests.testCommitIsAtomicAndAppendOnlyRowsRejectMutation`:
  removed a duplicate definition-version delete assertion and replaced it with
  audit/history delete, head delete, and REPLACE guards for all protected row
  identities. The added assertions cover the reviewer-identified bypasses.
- `WorkflowDefinitionServiceTests.testRestoreRequiresRetainedVersionAndAcceptsRetainedVersion`:
  added restore-to-current-bytes assertions because restore is required to
  write a new version and audit even when its target equals the head.
- `WorkflowDefinitionRetentionTests.testGenerationTenMigrationPreservesIdsAndAppliesWindowWhenSnapshotsAreSmall`:
  changed the fixture from one repeated blob to a distinct document per
  version so migration reconstruction and anchor re-encoding are exercised;
  added exact bytes, revision and next-version assertions.
- `WorkflowDefinitionSessionPinTests.testForeignSessionDeletionReleasesPinOnNextDefinitionCommit`:
  advanced its injected clock by 25 hours before asserting release, matching
  the new grace period for recently written pins.

No concurrent memory CLI files or tests were edited. The design document change
is in scope because L4 explicitly requested that deviation be recorded there.
Other worktree changes observed during this repair, and left untouched, include
the memory CLI/core edits and tests (`Sources/RielaCLI/MemoryCommandModels.swift`,
`MemoryCommands.swift`, `ParsedMemoryOptions.swift`, both
`ProductionNodeAdapter+Memory*.swift` files, `RielaCommand.swift`,
`DeterministicWorkflowRunner+Addons.swift`, `DeterministicWorkflowRunner+Memory.swift`,
`WorkflowMemoryValidation.swift`, `WorkflowModel.swift`,
`WorkflowAddonExecution.swift`, `MemoryEvolutionCommandTests.swift`,
`MemoryHistoryRetirementCommandTests.swift`, `MemoryHistoryCommandTests.swift`,
`WorkflowMemoryHistoryRetentionValidationTests.swift`, and
`impl-plans/progress/eh-08-memory-surfaces.md`). No other out-of-scope edits
were made by this repair.

### Repair verification

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build complete. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionServiceTests|WorkflowDefinitionServiceResolutionTests"'` | 0 | 50 tests, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeSchemaMigrationTests/(testAnOlderSessionStoreIsDiscardedAndRecreatedAtTheCurrentGeneration|testGeneration10UpgradesTo11WithoutLosingSnapshot|testGeneration9UpgradesThrough10To11WithoutLosingSnapshot)"'` | 0 | 3 tests, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests"'` | 0 | 34 tests, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionStoreSchema.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaCore/WorkflowDefinitionDiff.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift'` | 0 | Strict lint passed. |
| `git diff --check` | 0 | Clean. |
| `grep -c -e 'no such table' -e 'already exists' tmp/efficient-history/eh-04-definition-history/store-suites.log` | 1 | Printed `0`; grep status 1 means no matching errors. |

One repeat of the 50-test focused command exited 1 when the existing concurrent
service-seed test intermittently decoded `nodeId` as the wrong JSON type. The
isolated command
`arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionServiceResolutionTests/testConcurrentServiceFirstRunsSeedOneHeadAndOneAudit"'`
exited 0 (1 test, 0 failures), and the subsequent full focused rerun exited 0
(50 tests, 0 failures). The passing final run is the result in the table above.

### Review repair SHA-256

| Path | SHA-256 after repair |
|---|---|
| `Sources/RielaCore/WorkflowDefinitionStore.swift` | `f61d39670a82b8f2f625d9d518ea752f2041478509b8df74f02c6257bdf9f900` |
| `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` | `36f145016a109fd86158f1614096dd4dbfb0ea37abc73d83a0c64f69bff2c51c` |
| `Sources/RielaCore/WorkflowDefinitionPins.swift` | `5d0e2c1516ebe7e29ec608f67447c15dda0e0e4a711c3832b57a5388642c044b` |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` | `cc472a0e33210e6af02d44c33c43ac33d8bbe48b9efa460cae2840ac70cb069c` |
| `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift` | `4a77287b3497b5fb9a49e46216b8c5f6ec2f08b7deb185e011f301469b539acb` |
| `Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` | `2be77ef32ed8b4e2f09ae397302eb3564d3b8379fbf794f8095b9a4301154d7d` |
| `Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift` | `78df341a818381e4afbbce47b47bc68b923146c5973e96b87fd087d7630ac156` |
| `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift` | `009abc92bce25c2c869ca2d4fa6f1d54fade143d99abc430f54981a8c3c3cffa` |
| `design-docs/specs/design-efficient-history-and-storage.md` | `cb2fa4bbf678243727fb3e741103dee0e7509ed69412ee3dbdd1d672278dc158` |

The full migration/private suite log is
`tmp/efficient-history/eh-04-definition-history/store-suites.log`.

### Independent re-review follow-up (N1–N4, L1)

Completed the requested follow-up fixes in the eh-04 write paths:

- **N1 / M3:** explicit same-store maintenance backfill now imports both
  runtime snapshot pins and CLI session pins before applying retention. The
  new `testPendingBackfillKeepsSameStoreCLIPinUntilExplicitBackfill` uses a
  15-version generation-10 store, a CLI-only session with no runtime snapshot,
  and `pinBackfillByteLimit: 0`; explicit backfill inserts the v2 pin and keeps
  `defv-2` readable.
- **N2:** foreign-store session-id query errors now fail closed for that store
  group and leave its pins in place, while local query errors still propagate.
  `testForeignPinQueryFailureKeepsPinAndAllowsCommit` uses an openable foreign
  SQLite database with an incompatible snapshot schema and verifies the
  definition commit succeeds and the old pin/document survive.
- **N3:** `testPendingBackfillCommitPinsEveryExistingVersionBeforeWriting`
  leaves six versions available under the prior default of 10, advances the
  fake clock 25 hours per commit, then enables pending backfill and commits
  with the reduced default of 3. All seven versions remain. This setup is
  needed because six commits already using retention 3 would have discarded
  older versions before pending backfill began, making an all-seven assertion
  impossible. The existing H1 pending-state fixture now uses
  `INSERT OR REPLACE` instead of `UPDATE`: fresh-store schema creation leaves
  no retention-state row until migration/backfill, so the old update changed
  zero rows and did not actually enable pending state.
- **N4:** `current()` resolves bytes by the head's version id; the unused
  digest-based `readBlob` helper was removed. Force-import baseline reads now
  use `lastFileVersionId` directly. Migrated CLI pin timestamps use the
  injected store clock and fractional `canonicalDate`. Removed unused
  `sessionExists` and `_ = targetVersionNumber` code.
- **L1:** all three dropped-version/audit cleanup sites now use
  `deleteDroppedVersionsAndOrphanAudit`; the history engine's guarded-delete
  closure delegates to the shared `withGuardedDelete` helper.
- **L4:** the existing deviation note remains in design §4; no design change
  was needed for this follow-up.

#### Assertion changes and restoration record

- The pre-existing H1 pending-backfill test's state setup changed from
  `UPDATE` to `INSERT OR REPLACE`, for the zero-row reason above. Its
  post-commit and post-backfill assertions remain unchanged and now exercise
  the pending path.
- Added assertions in the N1 regression for exactly one inserted pin, pin
  history version 2, and readable `defv-2` after retention.
- Added assertions in the N2 regression for successful commit, retained pin,
  and readable pinned document after the foreign query error.
- Added an N3 assertion that all seven history versions remain after the
  pending commit at default retention 3. Its setup inserts the state row
  explicitly and asserts all six source versions existed before enabling the
  pending state.
- No pre-existing test was weakened or removed in this follow-up. The H2 and
  append-only test restorations and their reasons remain listed above.

#### Follow-up verification

All commands below ran under an arm64 shell. Logs are in
`tmp/efficient-history/eh-04-review-repair/`.

| Command | Exit | Result |
|---|---:|---|
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | Build complete. This ran after the eh-04 source edits; later test edits only changed test setup/assertions. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowDefinitionStoreTests\|WorkflowDefinitionSessionPinTests\|WorkflowDefinitionRetentionTests\|WorkflowDefinitionServiceTests\|WorkflowDefinitionServiceResolutionTests'` | 0 | 53 tests, 0 failures. See `focused-tests.log`. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SQLiteRuntimeSchemaMigrationTests\|PrivateWorkflowTests'` | 1 | Fresh compile was blocked by concurrent, out-of-scope edits in `SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift` and `SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` (stale `assembledSessionData` arguments; then missing `return`). These files were not edited by this repair. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter 'SQLiteRuntimeSchemaMigrationTests\|PrivateWorkflowTests'` | 0 | 34 tests, 0 failures using the most recently built test binary. See `migration-private-skip-build.log`. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionStoreSchema.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaCore/WorkflowDefinitionDiff.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift` | 0 | Strict lint passed for the owned Swift files. |
| `git diff --check` | 0 | Clean. |

The focused suite was first run before correcting the pending-state test setup;
that run failed only the new N3 assertion because the state `UPDATE` had
inserted no row. After replacing it with `INSERT OR REPLACE`, the full focused
suite passed. The initial 34-test fresh compile and its retry both encountered
the concurrent runtime-persistence source inconsistency; the skip-build rerun
passed all 34 tests.

After narrowing N2's catch to foreign stores only, the latest source build
passed. A later fresh focused run compiled the latest test binary and ran all
53 selected tests; the 12 retention tests passed, while 9 unrelated tests
failed because concurrent runtime-persistence edits produced SQLite syntax
errors near `AS` in `SQLiteWorkflowRuntimePersistenceStore.swift`. A final
skip-build run of `WorkflowDefinitionRetentionTests` using that latest binary
passed all 12 tests. The later migration/private fresh test attempt hit a
concurrent `@Sendable` capture error in
`SQLiteRuntimeExecutionRowsTests.swift`; the isolated retention build attempt
hit the private-result visibility error in
`SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`. Those files were
left untouched.

| Additional command | Exit | Result |
|---|---:|---|
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | Final eh-04 source build completed. See `build-final.log`. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowDefinitionStoreTests\|WorkflowDefinitionSessionPinTests\|WorkflowDefinitionRetentionTests\|WorkflowDefinitionServiceTests\|WorkflowDefinitionServiceResolutionTests'` | 1 | Latest binary ran 53 tests; the 12 retention tests passed, while 9 tests failed with `near "AS": syntax error` from concurrent runtime persistence changes. See `focused-tests-final.log`. |
| `arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter WorkflowDefinitionRetentionTests` | 0 | 12 tests, 0 failures against the latest built binary. See `retention-tests-final-skip-build.log`. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDefinitionStoreSchema.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaCore/WorkflowDefinitionDiff.swift Sources/RielaCore/WorkflowDefinitionHistorySchema.swift Sources/RielaCore/WorkflowDefinitionPins.swift Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift` | 0 | Strict lint passed after the final source edit. |
| `git diff --check` | 0 | Clean after the final source edit. |

#### Follow-up hashes

| Path | SHA-256 after follow-up |
|---|---|
| `Sources/RielaCore/WorkflowDefinitionStore.swift` | `6795c3f1b8e325de517e78053a9ee85c151fcc19ba5a23bf73246713474e7f30` |
| `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` | `61fed6ff5c2431ad118a8181e3a4e2de1e0abf31672f4dd17ce840807b172bd5` |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` | `b81db69bc885ceca439215c8b2b3c94d4a00e65842841d452992861679b4a116` |
| `Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` | `d805982a400bc3d0cb122f1b04b659351bba17a35231d2542a93b3dc834e743c` |

No out-of-scope files were edited by this follow-up. Concurrent worktree
changes were observed and left untouched in `Packages/RielaMemory/**`,
`Sources/RielaCLI/**` memory surfaces, the runtime persistence files
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift`,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift`,
and `Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift`, their related
tests `Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift`,
`Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`, and
`Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`, and progress
records `eh-05-session-rows.md` and `eh-08-memory-surfaces.md`.
