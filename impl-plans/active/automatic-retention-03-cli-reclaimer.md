# ar-03-cli-reclaimer: SQLite reclamation without a full VACUUM (RielaCLI)

```json
{
  "planId": "ar-03-cli-reclaimer",
  "planPath": "impl-plans/active/automatic-retention-03-cli-reclaimer.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCLI/RetentionSQLiteReclaimer.swift",
    "Tests/RielaCLITests/RetentionReclamationTests.swift",
    "impl-plans/progress/ar-03-cli-reclaimer.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §5.3. Today `TerminalRetentionSecondary.reclaim`
(`Sources/RielaCLI/TerminalRetentionSecondary.swift:145`) runs `VACUUM` with
`wal_checkpoint(TRUNCATE)`. That needs about 2x the DB size in free space, and it
throws `reclamationBusy`. The operator's 6.0G DB has `auto_vacuum=0`. This plan
builds a standalone reclaimer that never throws. ar-05 replaces every
`reclaim(...)` call with it.

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- Do not edit `TerminalRetentionSecondary.swift` or the executor (ar-05 owns
  them).
- No config reading.
- No change to DB creation paths. Do not set `auto_vacuum` at schema creation.

## File-level changes

### `Sources/RielaCLI/RetentionSQLiteReclaimer.swift` (new)

Pinned contract (internal visibility is enough; ar-05 and ar-07 are in the same
module):

```swift
enum RetentionReclamationMode: String, Codable, Sendable { case automatic, manual }
enum RetentionReclamationAction: String, Codable, Sendable {
  case none, incrementalVacuum, converted, deferredInsufficientSpace, deferredAutomaticSizeLimit,
       checkpointPending, busy, diskFull, failed
}
struct RetentionReclamationResult: Codable, Equatable, Sendable {
  var database: String; var autoVacuum: String   // "none" | "full" | "incremental" | "unknown"
  var action: RetentionReclamationAction
  var fileBytesBefore: Int64; var fileBytesAfter: Int64; var reclaimedBytes: Int64; var reusableFreeBytes: Int64
  var warning: String?
}
struct RetentionSQLiteReclaimer: Sendable {
  var freeSpace: @Sendable (String) -> Int64? = { path in /* FileManager attributesOfFileSystem(forPath:)[.systemFreeSize] */ }
  var automaticConversionLimitBytes: Int64 = 64 << 20
  var automaticPageBudget: Int = 65_536
  var statementObserver: (@Sendable (String) -> Void)? = nil   // test hook: every SQL statement executed
  func reclaim(databasePath: String, mode: RetentionReclamationMode) -> RetentionReclamationResult
}
```

Algorithm (one call per DB file):

1. If the DB file is missing, return action `none` with zero sizes. Never create
   a DB.
2. Measure `size(db) + size(db-wal)` with `FileManager` attributes; a missing WAL
   counts as 0. This is `fileBytesBefore`.
3. Open with `SQLiteDatabase.open(path:, mode: .readWriteCreate, options:
   SQLiteOpenOptions(enableWAL: false, busyTimeoutMilliseconds: 250,
   requireJSONB: false, waitForLocks: false))`. `enableWAL: false` means the
   journal mode is never changed: a WAL DB stays WAL, and a rollback-journal
   memory DB stays rollback.
4. Run `PRAGMA journal_size_limit=67108864` through `query`.
5. Read `auto_vacuum` (0 = none, 1 = full, 2 = incremental), `page_size` and
   `freelist_count`.
6. Act on the mode:
   - **incremental (2):** run `PRAGMA incremental_vacuum(N)`, where N is
     `automaticPageBudget` in automatic mode and omitted (all free pages) in
     manual mode. Then `PRAGMA wal_checkpoint(PASSIVE)`. If the checkpoint row
     has `busy=1` or `log != checkpointed`, the action is `checkpointPending`;
     otherwise `incrementalVacuum`.
   - **full (1):** freed pages are already truncated on commit. Run only the
     PASSIVE checkpoint, with action `none` or `checkpointPending`.
   - **none (0):** conversion is allowed only when `freeSpace(directory) ≥
     2*fileBytesBefore + 256 MiB`. In automatic mode it also requires
     `fileBytesBefore ≤ automaticConversionLimitBytes`. A nil `freeSpace` fails
     closed as `deferredInsufficientSpace`. If the size limit fails, the action
     is `deferredAutomaticSizeLimit`; if space fails, `deferredInsufficientSpace`.
     When allowed, run `PRAGMA auto_vacuum=INCREMENTAL`, then `VACUUM` outside
     any transaction, then the PASSIVE checkpoint. Action `converted`.
7. Error mapping: a thrown `SQLiteError` with code 5 or 6 (BUSY or LOCKED) gives
   `busy`; code 13 (FULL) gives `diskFull`; any other error gives `failed`. In
   every error case `warning` holds the message. Never rethrow.
8. Afterwards measure sizes again (`fileBytesAfter`). Set
   `reclaimedBytes = max(0, before - after)`. Re-read `freelist_count ×
   page_size` for `reusableFreeBytes`; use 0 if it cannot be read.

## Patterns to imitate

- `TerminalRetentionSecondary.reclaim` and `checkpoint`: how they use
  `db.query("PRAGMA ...")`.
- `RielaDataGarbageCollector.readTaskStates`: how it builds explicit
  `SQLiteOpenOptions`.

## Pitfalls

- `SQLiteDatabase.execute` requires `SQLITE_DONE` on its first step
  (`Sources/RielaSQLite/SQLiteDatabase.swift:236`). PRAGMAs that return rows
  (`wal_checkpoint`, `incremental_vacuum`, `journal_size_limit`, reads) must go
  through `query`, which steps to completion. Use `execute` only for `VACUUM`
  and `PRAGMA auto_vacuum=INCREMENTAL`.
- Never call `wal_checkpoint(TRUNCATE)` or `RESTART`. They wait on and truncate
  other writers' WAL.
- Never run `VACUUM` in automatic mode on a DB larger than the limit, and never
  on an already incremental DB.
- Never throw out of `reclaim`. Callers treat its result as a warning only.
- Route every statement through one helper that calls `statementObserver`, so
  tests can assert that no `VACUUM` ran.

## Tests (`Tests/RielaCLITests/RetentionReclamationTests.swift`, class `RetentionReclamationTests`)

Build DBs under `<cwd>/tmp/retention-reclaim-<UUID>`. Make them WAL with a
table of about 2 MB blobs: insert, then delete most rows.

- an incremental DB (created with `PRAGMA auto_vacuum=INCREMENTAL` before the
  first table) after deleting rows, automatic mode -> action `incrementalVacuum`;
  the DB file size (`stat`) is strictly smaller than before; `reclaimedBytes > 0`;
  the observer saw no statement containing `VACUUM` except `incremental_vacuum`
- a NONE DB, automatic mode, `automaticConversionLimitBytes` set below its size,
  `freeSpace` huge -> `deferredAutomaticSizeLimit`; no `VACUUM`; file size unchanged
- a NONE DB, manual mode, `freeSpace` huge -> `converted`; afterwards
  `PRAGMA auto_vacuum` returns 2 and the file shrank
- a NONE DB, manual mode, `freeSpace` returns 1 -> `deferredInsufficientSpace`;
  no `VACUUM`
- `freeSpace` returns nil -> `deferredInsufficientSpace`
- a missing path -> `none` and no file created
- a second connection holding `BEGIN IMMEDIATE` on the DB, manual conversion ->
  `busy` with a warning, and the call returns normally
- a rollback-journal DB (opened `enableWAL: false`) -> its journal mode is
  unchanged after reclaim (`PRAGMA journal_mode` is not `wal`)

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter RetentionReclamationTests > tmp/automatic-retention/ar-03-cli-reclaimer/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 8 and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/RetentionSQLiteReclaimer.swift Tests/RielaCLITests/RetentionReclamationTests.swift > tmp/automatic-retention/ar-03-cli-reclaimer/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `grep -c "wal_checkpoint(TRUNCATE)\|wal_checkpoint(RESTART)" Sources/RielaCLI/RetentionSQLiteReclaimer.swift`
  prints 0.
- `grep -n "func reclaim(databasePath: String, mode: RetentionReclamationMode) -> RetentionReclamationResult" Sources/RielaCLI/RetentionSQLiteReclaimer.swift`
  matches.
- The verification records exist in `impl-plans/progress/ar-03-cli-reclaimer.md`.
