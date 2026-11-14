# eh-02-runtime-contract: RielaSQLite blob and auto_vacuum support, the generation-11 skeleton and hook stubs

```json
{
  "planId": "eh-02-runtime-contract",
  "planPath": "impl-plans/active/efficient-history-02-runtime-contract.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaSQLite/SQLiteDatabase.swift",
    "Tests/RielaSQLiteTests/SQLiteDatabaseBlobAndAutoVacuumTests.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift",
    "Sources/RielaCore/SQLiteWorkflowMessageLog.swift",
    "Sources/RielaCore/WorkflowDefinitionHistorySchema.swift",
    "Sources/RielaCore/WorkflowDefinitionPins.swift",
    "Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeAutoVacuumTests.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/RuntimeStoreFirstOpenerAutoVacuumTests.swift",
    "Tests/RielaWorkTests/WorkStoreFirstOpenerAutoVacuumTests.swift",
    "impl-plans/progress/eh-02-runtime-contract.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/CLIWorkflowSessionStore.swift", "intendedEdit": "ONE edit only: the options argument in openDatabase(readOnly:strictReadOnly:) (~:411) becomes `readOnly ? .readOnlyDefault : .writableRuntimeStoreDefault`. Nothing else. eh-06 owns this file in wave 3 and keeps that line byte-identical."},
    {"path": "Sources/RielaWork/WorkStore.swift", "intendedEdit": "ONE edit only: the options argument of the writable open in openWritable() (~:390) becomes `.writableRuntimeStoreDefault`. Nothing else."}
  ]
}
```

## Intent and context

Design §2.1, §7 and §10. This plan pins every runtime-database contract
that the wave-2 plans need, so that eh-04 (definitions) and eh-05 (session
rows) can run in parallel without touching the same file.

Current code:

- `SQLiteRow` stores only `[String: String?]`
  (`Sources/RielaSQLite/SQLiteDatabase.swift:88-102`). `SQLiteValue` has no
  blob case (`:69-86`).
- `openConfiguredDatabase` calls `configure(options)`, which runs
  `enableWAL` → `PRAGMA journal_mode=WAL` (`:354-366`) before any schema code.
  For a new file this fixes its auto_vacuum mode, which is the reason for
  design finding DR-F1.
- `schemaGeneration = 10`
  (`SQLiteWorkflowRuntimePersistenceStore.swift:116`). The migrations are
  `fromGeneration: 2, 3, 9`. The 9→10 step calls the CURRENT
  `WorkflowDefinitionStoreSchema.create(in:)`, and `ensureSchema` (`:743-`)
  also calls it on every open.
- The runtime store opens with `.writableDefault` (`:715-740`). The message
  log opens the same file (`SQLiteWorkflowMessageLog.swift`).
- `upsertSnapshot` and `completeSnapshotWrite` (`:801-912`) are where every
  canonical save ends.
- Four writable openers can CREATE the shared
  `runtime-records/runtime-message-log.sqlite` file, and whichever opens it
  first fixes its auto_vacuum mode (step5 EH5-F2):
  - the `SQLiteWorkflowRuntimePersistenceStore` writable open (`:715-740`);
  - the `SQLiteWorkflowMessageLog` writable open (`:164`);
  - `CLIWorkflowSessionStore.openDatabase(readOnly:strictReadOnly:)`
    (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:395-413`, options at
    `:411`). Every `riela workflow run` opens the store through it first
    (`WorkflowRunLivePersistence.swift:163-167` →
    `openPersistenceDatabase()`);
  - `WorkStore.openWritable()` (`Sources/RielaWork/WorkStore.swift:386-391`,
    options at `:390`; its `databasePath` is
    `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath`, `:79-81`).

  All four must use `.writableRuntimeStoreDefault`.
- Two public runtime-store save entry points open their OWN connection and
  transaction: `save(_:)` (`:51-60`) and
  `save(_:appendingWorkflowMessages:)` (`:71-84`). The `in db:` variants
  (`:62`, `:86`) run inside a caller's transaction. Their callers are the
  CLI store (`CLIWorkflowSessionStore.swift:147-172`, handled by eh-06),
  `WorkStore+Reservation.swift:358,533,585` and
  `SpecialistSupervisor.swift:366`.

## Non-goals

- No change to save/load behavior, tables or JSON shapes; eh-05 owns those.
- No real definition logic; eh-04 owns it.
- Do not change `SQLiteOpenOptions.writableDefault` or `readOnlyDefault`.
  Other stores use them.

## Pinned contracts

1. `SQLiteValue.blob(Data)`. `SQLiteRow.data(_ column: String) -> Data?`
   returns the bytes for BLOB columns and the UTF-8 bytes for TEXT columns.
   The existing string subscript stays byte-for-byte compatible for TEXT and
   BLOB columns.
2. `SQLiteOpenOptions.incrementalAutoVacuumForNewFile: Bool` (default
   `false`, added to `init` as a trailing defaulted parameter), plus
   `public static let writableRuntimeStoreDefault` (= `writableDefault` with
   the flag set to true). When the flag is set:
   - `openConfiguredDatabase` records, before `sqlite3_open_v2`, whether the
     file was absent or zero length;
   - `configure()` then runs `PRAGMA auto_vacuum = INCREMENTAL` before
     `enableWAL` and outside any transaction, only when the file was new and
     `SELECT count(*) FROM sqlite_master` is 0.
3. `schemaGeneration = 11`, with a new step
   `SQLiteSchemaMigration(fromGeneration: 10) { db in try WorkflowDefinitionHistorySchema.migrateToGeneration11(in: db); try SQLiteRuntimeExecutionRowsSchema.migrateToGeneration11(in: db) }`.
4. Stub files, with exact signatures and no-op bodies. They hold one doc
   comment each, naming the owning plan.
   - `Sources/RielaCore/WorkflowDefinitionHistorySchema.swift`:
     `enum WorkflowDefinitionHistorySchema { static func migrateToGeneration11(in db: SQLiteDatabase) throws; static func create(in db: SQLiteDatabase) throws }`
     (eh-04).
   - `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`:
     `enum SQLiteRuntimeExecutionRowsSchema { static func migrateToGeneration11(in db: SQLiteDatabase) throws; static func create(in db: SQLiteDatabase) throws }`
     (eh-05).
   - `Sources/RielaCore/WorkflowDefinitionPins.swift` (eh-04):
     `enum WorkflowDefinitionPins` with two no-op stubs:
     - `static func recordPinIfNeeded(_ db: SQLiteDatabase, snapshot: WorkflowRuntimePersistenceSnapshot, sessionStoreRoot: String) throws`.
       Called inside the snapshot transaction. It handles SAME-store pins
       only; for a foreign target it does nothing.
     - `static func recordForeignPinIfNeeded(snapshot: WorkflowRuntimePersistenceSnapshot, sessionStoreRoot: String) throws`.
       Called with NO transaction open. It writes a FOREIGN-store pin in its
       own `BEGIN IMMEDIATE` on the foreign file (design §4: "a separate
       BEGIN IMMEDIATE runs before the session's first save").
5. `ensureSchema` calls `WorkflowDefinitionHistorySchema.create(in:)` and
   `SQLiteRuntimeExecutionRowsSchema.create(in:)` right after the existing
   `WorkflowDefinitionStoreSchema.create(in:)`.
6. `completeSnapshotWrite` calls
   `WorkflowDefinitionPins.recordPinIfNeeded(db, snapshot: snapshot, sessionStoreRoot: rootDirectory)`
   as its first statement, inside the save transaction, on both the cold and
   the fast path.
7. The two own-transaction entry points `save(_:)` and
   `save(_:appendingWorkflowMessages:)` call
   `try WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot: snapshot, sessionStoreRoot: rootDirectory)`
   after the `isSafeId` guard and BEFORE `openDatabase()`. The `in db:`
   variants do NOT call it, because they run inside a caller's transaction.
   eh-06 adds the matching call to the CLI save overloads.
8. All four writable openers of the runtime database file listed above use
   `SQLiteOpenOptions.writableRuntimeStoreDefault`.

## File-level changes

- **`SQLiteDatabase.swift`.**
  - Contracts 1-2.
  - Bind `.blob` with `sqlite3_bind_blob(..., SQLITE_TRANSIENT)`.
  - In the row-reading loop, when `sqlite3_column_type == SQLITE_BLOB`, also
    capture `Data`.
  - Keep `SQLiteRow` `Equatable`.
- **`SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`.**
  - Add `createGeneration10DefinitionSchema(in:)`: a FROZEN verbatim copy of
    today's `WorkflowDefinitionStoreSchema.create` DDL (tables, indexes,
    triggers).
  - Change the 9→10 step in `SQLiteWorkflowRuntimePersistenceStore.swift`
    to call it. The reason: eh-04 changes the current `create` (no blobs
    table, guarded triggers), and a 9→10→11 chain must still produce the
    generation-10 shape before step 10 runs. Imitate
    `createGeneration3NestedInvocationSchema`.
- **`SQLiteWorkflowRuntimePersistenceStore.swift`.**
  - Contracts 3, 5 and 6.
  - Use `.writableRuntimeStoreDefault` instead of `.writableDefault` in the
    writable open.
  - Update the generation doc comment: "Generation 11 adds shared definition
    history, definition pins and runtime execution rows."
- **`SQLiteWorkflowMessageLog.swift`.** Its writable open of the same file
  uses `.writableRuntimeStoreDefault`.
- **`Sources/RielaCLI/CLIWorkflowSessionStore.swift:411`.** Replace
  `options: readOnly ? .readOnlyDefault : .writableDefault` with
  `options: readOnly ? .readOnlyDefault : .writableRuntimeStoreDefault`.
  Leave the `mode` selection and every other line untouched. Record the
  post-edit hash. eh-06 (wave 3) edits this file next and must keep this
  line byte-identical.
- **`Sources/RielaWork/WorkStore.swift:390`.** In `openWritable()`, replace
  `.writableDefault` with `.writableRuntimeStoreDefault`. No other edit.
- **Tests.**
  - `SQLiteRuntimeSchemaMigrationTests.swift`: update the generation
    expectations to `SQLiteWorkflowRuntimePersistenceStore.schemaGeneration`,
    never a literal. Add a stamped generation-10 fixture → open → stamped 11,
    with the snapshot rows readable.
  - New `SQLiteRuntimeAutoVacuumTests.swift` and
    `SQLiteDatabaseBlobAndAutoVacuumTests.swift`.
  - New `Tests/RielaCLITests/RuntimeStoreFirstOpenerAutoVacuumTests.swift`
    (the CLI store as first opener) and
    `Tests/RielaWorkTests/WorkStoreFirstOpenerAutoVacuumTests.swift`
    (WorkStore as first opener). The second lives in RielaWorkTests because
    RielaCLITests has no direct RielaWork dependency (`Package.swift:394-406`).

## Pitfalls

- Never run the auto_vacuum pragma on an existing file. An existing NONE
  store must stay 0, because only the reclaimer converts existing stores.
- Do not run it inside `BEGIN`.
- The new-file check happens before `sqlite3_open_v2` creates the file.
- The same-store hook (`recordPinIfNeeded`) must be called inside the same
  transaction as the snapshot write. The foreign hook
  (`recordForeignPinIfNeeded`) must be called while no transaction is open.
  Never swap them.
- Do not add the foreign hook to the `in db:` save variants. That would
  recreate the cross-file lock inversion from EH5-F3.
- In the CLI store and WorkStore, change ONLY the options argument. Do not
  change `writableDefault` itself, because memory, cache, KV and retention
  stores use it.
- `WorkflowDefinitionStoreTests.swift` asserts `user_version == "10"`. That
  file belongs to eh-04 (wave 2), which updates it. Record its expected
  failure here as `outOfScope`; do not edit it.
- `Tests/RielaWorkTests/WorkStoreTests.swift` already uses the constant, so
  it needs no change.

## Tests (input → expected)

- Bind `.blob(Data([0, 255, 0]))` and read back with `data("c")` → exact
  bytes. A TEXT column via `row["c"]` keeps the same string as before.
- A fresh path with `writableRuntimeStoreDefault` → `PRAGMA auto_vacuum` reads
  `2` and `PRAGMA journal_mode` reads `wal`.
- A fresh path with `writableDefault` → `0`.
- A pre-existing NONE database with tables, reopened with the flag → `0`.
- A runtime store created through `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:)`
  → `auto_vacuum = 2`. Insert, delete and `PRAGMA incremental_vacuum(100)` →
  `freelist_count` decreases.
- A generation-10 fixture (create tables via `createGeneration10DefinitionSchema`
  plus a stamped snapshot row, `user_version = 10`) → open → `user_version = 11`,
  with the snapshot loadable.
- A generation-9 fixture → 11.
- `RuntimeStoreFirstOpenerAutoVacuumTests`. Use a fresh temp root R resolved
  with `resolvingSymlinksInPath()`. Make the first write
  `CLIWorkflowSessionStore(rootDirectory: R).save(record, runtimeSnapshot: snap)`.
  Then `PRAGMA auto_vacuum` on the runtime database file (compute the path
  with `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath` on the
  store's canonical runtime root) → `2`, and `journal_mode` → `wal`.
- Same suite: a NONE database with tables already exists at that path, then
  a CLI save → `auto_vacuum` stays `0`.
- `WorkStoreFirstOpenerAutoVacuumTests`. Use a fresh root where
  `WorkStore(rootDirectory:)` opens the file writable first (any write) →
  `auto_vacuum = 2` and `journal_mode = wal`. A pre-existing NONE file → `0`.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build' > tmp/efficient-history/eh-02-runtime-contract/build.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteDatabaseBlobAndAutoVacuumTests|SQLiteDatabaseTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeAutoVacuumTests|RuntimeStoreFirstOpenerAutoVacuumTests|WorkStoreFirstOpenerAutoVacuumTests|WorkStoreTests|SQLiteWorkflowMessageLogTests|SQLitePersistenceSessionExistsTests|PrivateWorkflowTests"' > tmp/efficient-history/eh-02-runtime-contract/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0, and a non-zero executed test count. The four
`PrivateWorkflowTests` fast-path and fence tests stay green.

## Done criteria

- [ ] `grep -n "schemaGeneration: Int64 = 11"` and `grep -n "fromGeneration: 10"`
      both match.
- [ ] All three stub files exist with the exact signatures, including both
      pin hooks, and `completeSnapshotWrite` calls `recordPinIfNeeded`.
- [ ] `grep -n "recordForeignPinIfNeeded" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
      shows exactly two calls, each placed before the `openDatabase()` line
      of `save(_:)` and of `save(_:appendingWorkflowMessages:)`.
- [ ] `grep -n writableRuntimeStoreDefault Sources/RielaCLI/CLIWorkflowSessionStore.swift Sources/RielaWork/WorkStore.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift Sources/RielaCore/SQLiteWorkflowMessageLog.swift`
      matches all four files. `git diff --numstat` shows `1 1` for the CLI
      store and for WorkStore.
- [ ] The listed tests pass. The `WorkflowDefinitionStoreTests` generation
      assertion failure is logged as outOfScope (for eh-04) if it occurs.
- [ ] The progress log is complete, including the pre/post hashes for
      `SQLiteWorkflowRuntimePersistenceStore.swift`. eh-05 edits it next.
