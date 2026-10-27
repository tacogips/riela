# eh-04-definition-history implementation progress

Workflow mode: `issue-resolution`, Step 6 implementation. Owner issue: “One shared versioned history and efficient session storage” (no GitHub number), workflow `opus-luna-design-and-implement-review-loop-session-518`. Accepted dependencies from the dispatch item: `eh-01-history-engine`, `eh-02-runtime-contract`. Codex agents: primary Luna implementer; read-only inspections by `/root/inspect_migration` and `/root/inspect_tests`.

## Current implementation state

Implemented in this pass:

- Added `SQLiteDatabaseHistoryExecutor` over `SQLiteDatabase` and made `WorkflowDefinitionStoreSchema.create` delegate to generation-11 schema creation.
- Added generation-11 definition history tables, guarded delete triggers, version-table migration with ordered history numbers, engine chain import, legacy blob table removal, bounded snapshot backfill decision, and retention application.
- Implemented same-store and foreign-store pin hooks with normalized database paths and foreign process-local dedupe.
- Added the store's clock seam, default history retention constant, engine-backed document/blob lookup, engine write integration, and service constructor/retention parameters.
- Preserved `createGeneration10DefinitionSchema` in `SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` without editing it.

## Current hashes

The implementation pre-edit baseline for files already present at the checkpoint was `git show HEAD:<path>`; current SHA-256 values:

- `Sources/RielaCore/WorkflowDefinitionStoreSchema.swift`: `30ff7e88…` → `42846d65…`
- `Sources/RielaCore/WorkflowDefinitionStore.swift`: `7818d1fd…` → `42805fed…`
- `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift`: `63d0a0bd…` → `770c9956…`
- New: `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift` `f0aa3f07…`; `Sources/RielaCore/WorkflowDefinitionPins.swift` `401fe972…`; `Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift` `d064764d…`.

Per-edit behavioral intentions are recorded in `tmp/efficient-history/eh-04-definition-history/edit-intentions.md`. No staging or Git write operations were performed.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/efficient-history/eh-04-definition-history/build.log 2>&1; echo $?` — exit 1. Initial own compile error was corrected; latest build is blocked by sibling in-progress `eh-05` edits in `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (`Range<Int>` passed where `[Int]` is expected) and `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift` (missing `encodedReservation`, `encodedNestedSnapshot`, `decodedReservation`, `decodedNestedSnapshot`, and `JSONObject` value mismatch). These files are outside eh-04 writePaths and were not modified.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionServiceTests|WorkflowDefinitionServiceResolutionTests|SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests"' > tmp/efficient-history/eh-04-definition-history/test.log 2>&1; echo $?` — exit 1 before tests executed, due to the same sibling compile errors. No test count is claimed.
- `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/efficient-history/eh-04-definition-history/changed-swift-files.nul'` — exit 0; selected-file manifest lists the six changed Swift source files.

## Remaining eh-04 work

Implementation is incomplete. Required items still outstanding include the full `moveHead`/undo/redo store API, retention state/backfill API/report, lazy release of stale pins, accurate dropped-version errors and audit `retained` mapping, full service undo/redo and retention propagation, shared diff adapter, migration root normalization and foreign-store pin filtering, and the plan's retention/pin/service regression tests plus changed assertion updates. Re-run build and the exact focused suites once the unrelated eh-05 compile failures are reconciled; then run the listed suite and selected-file strict lint on final source.
