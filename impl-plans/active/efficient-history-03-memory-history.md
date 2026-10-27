# eh-03-memory-history: RielaMemory records on VersionedHistory (schema 7, retention, undo/redo, legacy conversion)

```json
{
  "planId": "eh-03-memory-history",
  "planPath": "impl-plans/active/efficient-history-03-memory-history.md",
  "dependsOn": ["eh-01-history-engine"],
  "wave": "W2a",
  "writePaths": [
    "Packages/RielaMemory/Sources/RielaMemory/RielaMemory.swift",
    "Packages/RielaMemory/Sources/RielaMemory/SQLiteMemorySupport.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemoryEvolutionHistory.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemorySnapshot.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemorySnapshotRetention.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemoryHistoryRetirement.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemoryHistoryAdapter.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemoryModels.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetentionTests.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/MemoryEvolutionHistoryTests.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/MemorySnapshotTests.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/MemorySnapshotRetentionTests.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetirementTests.swift",
    "Packages/RielaMemory/Tests/RielaMemoryTests/RielaMemoryTests.swift",
    "impl-plans/progress/eh-03-memory-history.md"
  ],
  "sharedPaths": []
}
```

## Continuation (session 523, design §13)

- The working tree already holds partial eh-03 work (modified RielaMemory
  sources/tests, new `MemoryHistoryAdapter.swift` and
  `MemoryHistoryRetentionTests.swift`, one `invalidHistoryRetention` case in
  `MemoryModels.swift`) but no progress record. First audit it: open
  `impl-plans/progress/eh-03-memory-history.md` with a done/missing table
  for the pinned API, tests and done criteria, and the current SHA-256 of
  every owned file as the pre-edit baseline. Then finish only what is
  missing. Do not rewrite accepted eh-01 code under `VersionedHistory/`.
- `MemoryModels.swift` edits are limited to `RielaMemoryError` history
  retention cases. Public RielaMemory API used by RielaCore and RielaCLI
  stays source-compatible (additive only), so the parallel W2a sibling
  eh-04 keeps building the root package.

## Intent and context

Design §3. Measured: one record had 8,118 versions and 3.77 GB of history.
After this plan, ordinary records keep 2 generations and snapshot-store
records keep 1, inside the write transaction. No base64-in-JSON rows are
written.

Current code:

- `recordEvolution(previous:next:db:forceRevision:)` (`MemoryEvolutionHistory.swift:173-196`)
  computes the head as `MAX(version)` from `memory_evolution` and inserts a
  base64 JSON reverse delta. Its callers are `RielaMemory.swift:84` (save),
  `:171` (update), `MemorySnapshot.swift:92` (commit), `:158` (baseline) and
  `MemoryEvolutionHistory.swift:102` (restore).
- `currentSchemaVersion = 6` and `memorySchemaMigrations` are in
  `SQLiteMemorySupport.swift:13-28`.
- `ensureSchema` (`RielaMemory.swift:490-575`) and `openDatabase`
  (`:470-488`) never set a journal mode or auto_vacuum.
- `MemorySnapshotHead.version` is the CAS token (`MemorySnapshot.swift:6,76`).
  `memory_snapshot_retention.version` pins a version.
- `MemoryHistoryRetirement.swift` implements `retire-history`.

## Non-goals

- No CLI or add-on changes; eh-08 owns `MemoryCommands.swift` and the
  `memories[]` plumbing.
- No changes to the KV, cache or write-intent stores.
- Do not delete `memory_evolution` or `memory_retirement` tables and do not
  rewrite their DDL. Legacy rows must stay readable.
- Do not change `EvolutionReverseDelta.swift`; it remains the legacy decoder.
- No attachment-file deletion (QA Q4).

## Pinned API (eh-08 and eh-10 depend on it)

Add defaulted parameters only; existing call sites must compile unchanged.

```swift
// RielaMemoryStore
public func save(..., payload: MemoryJSONValue, historyRetention: Int? = nil) throws -> MemoryRecord
public func update(..., payload: MemoryJSONValue, historyRetention: Int? = nil) throws -> MemoryRecord
public func restoreRecordVersion(memoryId:recordId:version:expectedHeadVersion:historyRetention: Int? = nil) throws -> MemoryRecord
public func undoRecord(memoryId: String, recordId: Int64, expectedHeadVersion: Int64) throws -> MemoryHeadMoveResult
public func redoRecord(memoryId: String, recordId: Int64, expectedHeadVersion: Int64) throws -> MemoryHeadMoveResult
public func recordDiff(memoryId: String, recordId: Int64, fromVersion: Int64, toVersion: Int64?) throws -> [VersionedHistoryDiffEntry] // nil = head
public func convertLegacyHistory(memoryId: String, maxRecords: Int) throws -> MemoryHistoryConversionReport
public struct MemoryHeadMoveResult: Codable, Equatable, Sendable { record: MemoryRecord; revision: Int64; headVersion: Int64; fromVersion: Int64 }
public struct MemoryHistoryConversionReport: Codable, Equatable, Sendable { converted: Int; remaining: Int; freedBytes: Int64 }
// MemoryEvolutionRevision gains optional fields: isHead: Bool?, revision: Int64?, storage: VersionedHistoryVersionInfo?
public static let memoryDefaultHistoryRetention = 2   // range 1...1000; outside → RielaMemoryError.invalidHistoryRetention(Int)
```

`expectedHeadVersion` everywhere now means the head **revision**. It equals
`MAX(version)` until an undo happens. Errors from the engine
(`VersionedHistoryError`) propagate unchanged, and eh-08 maps their `code`.

## File-level changes

1. **`MemoryHistoryAdapter.swift` (new).**
   - `memoryHistoryStore(db:)` builds `VersionedHistoryStore(tablePrefix:
     "memory", headStorage: .external, sql: RawSQLiteHistoryExecutor(db))`.
     The key is the record id as decimal text.
   - `currentHeadBytes(record)` returns `Data(encodedJSONString(record).utf8)`,
     the same canonical bytes `recordEvolution` uses today
     (`MemoryEncodingSupport.swift:3-16`).
   - `pins(recordId, db)` returns the `memory_snapshot_retention.version`
     values with `expires_at > now`.
   - A legacy check: the record has no `memory_history_heads` row but has
     `memory_evolution` rows.
2. **`SQLiteMemorySupport.swift`.**
   - Set `currentSchemaVersion = 7`.
   - Append the migration `from 6`: run `VersionedHistoryStore.ensureSchema()`
     only (additive DDL). Also add
     `FOREIGN KEY ... ON DELETE CASCADE`-equivalent cleanup: the engine
     tables cannot carry an FK on text keys, so when a `memory_entries` row
     is deleted, call `deleteAll(key:)`. Grep for `DELETE FROM memory_entries`
     and add the call in the same transaction, if any such delete exists.
3. **`RielaMemory.swift`.**
   - `openDatabase`: before `sqlite3_open_v2`, record whether the file was
     absent or zero length. After open, when it was new and `sqlite_master`
     is empty, run `PRAGMA auto_vacuum = INCREMENTAL` before
     `ensureSchema`'s `BEGIN IMMEDIATE`. This follows design §7 and the
     precedent at `RielaCacheStore.swift:397`.
   - `ensureSchema`: create the engine tables for fresh databases.
   - `save`, `update` and `restore` replace `recordEvolution` with
     `historyWrite(previous:next:db:force:historyRetention:)`. That function:
     - validates R (1...1000);
     - converts a legacy record first;
     - calls `engine.write` with `currentHeadValue = previous bytes`,
       `defaultRetainedGenerations = 2`, `force` (restore → true) and `pins`.
   - After `COMMIT`, when `freedBytes > 0` and `PRAGMA auto_vacuum = 2`, run
     `PRAGMA incremental_vacuum(min(freedPages, 4096))`. It is best-effort:
     ignore errors, and never fail the write.
4. **`MemoryEvolutionHistory.swift`.**
   - `evolutionHistory`, `recordVersion` and `restoreRecordVersion` dispatch
     between the new and legacy formats.
   - A new-format version below the window throws `versionNotRetained` from
     the engine.
   - The head entry carries `revision`.
   - `recordVersion` reconstructs through
     `engine.value(..., currentHeadValue: head bytes)`.
   - Add `undoRecord` and `redoRecord`, each in a `BEGIN IMMEDIATE`:
     1. Run the engine move.
     2. Decode the returned value into a `MemoryRecord`.
     3. Run `verifyEvolutionAttachments` on its files.
     4. Rewrite the `memory_entries` row (payload_json, tags_json,
        related_record_ids_json, files) the same way `restoreRecordVersion`
        writes `memory_entries` today.
   - Add `recordDiff` (it uses `VersionedHistoryDiff.diff`) and
     `convertLegacyHistory` (one `BEGIN IMMEDIATE` per call, at most
     `maxRecords` legacy records).
   - Keep `recordEvolution` only as the legacy reader path, or delete it
     once nothing calls it.
5. **`MemorySnapshot.swift`.**
   - `commitSnapshot` writes with R = 1 always (QA Q6) and with the pins.
   - `MemorySnapshotHead.version` = the engine `revision`.
   - The baseline install at `:158` becomes `engine.importChain` or a first
     write.
   - The CAS compare uses the revision.
6. **`MemorySnapshotRetention.swift`.**
   - `retainSnapshot` checks `expectedHead` against the revision, but stores
     `memory_history_heads.head_version` in `version`.
   - `loadRetainedSnapshot` reconstructs that value version.
7. **`MemoryHistoryRetirement.swift`.**
   - Accept `user_version` 4...7.
   - For a new-format record, apply with
     `engine.applyRetention(R: 1, pins: [])` under the existing ownership,
     CAS and blocker checks. `retiredRevisionCount` = dropped count,
     `retiredDeltaBytes` = freedBytes, `retainedFloor` = head version.
   - Keep the existing VACUUM and secure-delete reclaim.
   - Legacy records keep today's path.

**Legacy conversion (on the first write, and in `convertLegacyHistory`):**

1. Read the head = `MAX(version)` and the legacy retained floor.
2. Walk the legacy chain at most R-1 steps with the existing `walkReverseChain`.
3. Call `engine.importChain(revision: head, headVersion: head, headValue:
   current bytes, previous: …)`.
4. Delete that record's `memory_evolution` and `memory_retirement` rows in
   the same transaction.

## Pitfalls

- Do not let the head revision regress. A converted record continues at
  `MAX(version) + 1`.
- An identical `update` adds no version and no revision bump. `restore` is
  forced and still creates a version.
- External head mode: always pass the current head bytes to every engine
  call. A nil value for a record that has a head is a bug.
- The PRAGMA runs outside any transaction. `incremental_vacuum` runs only
  after `COMMIT`.
- Existing tests that assert long histories under the default retention must
  pass `historyRetention:` explicitly instead of weakening their assertions.
  Record each changed test in the progress log with the reason.

## Tests

New `MemoryHistoryRetentionTests.swift`:

- A 660 KB JSON payload where each update changes a header field and appends
  an item, run for 1000 updates at the default R → exactly 1 non-head row,
  `storedBytes ≤ zlib(full)`. The revision increases strictly, and
  `evolutionHistory` for the old version 1 → `versionNotRetained`.
- `commitSnapshot` 50 times → 0 non-head rows. A retained snapshot label
  keeps its pinned version reconstructable.
- `historyRetention: 5` → exactly 4 non-head rows.
- `historyRetention: 0` or `1001` → `invalidHistoryRetention`.
- `restoreRecordVersion` to the retained previous version → byte-exact
  record. An identical update → no new version.
- `undoRecord`:
  - undo → `memory_entries` equals the previous value, and the revision
    bumps;
  - a second undo at R=2 → `nothingToUndo`;
  - redo → back;
  - a stale expected revision → `staleRevision`.
- A legacy schema-6 fixture (build it with the pre-change DDL from
  `SQLiteMemorySupport`/`MemoryEvolutionHistory` copied into the test, 20
  versions):
  - open → `user_version 7`;
  - the history is still listed through the legacy path;
  - the first update converts it: one previous row kept, and the legacy
    rows for the record are deleted;
  - `convertLegacyHistory` converts the remaining records and reports
    `remaining 0`.
- A fresh database → `PRAGMA auto_vacuum = 2`. After the retention delete
  plus the bounded vacuum, `freelist_count` is lower than before the vacuum
  and the file size does not grow.
- `retireHistory` on a new-format record → status `retired`, 0 non-head rows.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build --package-path Packages/RielaMemory' > tmp/efficient-history/eh-03-memory-history/build.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory' > tmp/efficient-history/eh-03-memory-history/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0 for the whole RielaMemory package suite, with
`MemoryHistoryRetentionTests` listed.

## Done criteria

- [ ] `grep -n "currentSchemaVersion = 7"` matches. No new `reverse_delta_json`
      writes: `grep -n "INSERT INTO memory_evolution"` now appears only in
      test fixtures, if anywhere.
- [ ] The pinned API is present with the exact names.
- [ ] The full RielaMemory test package passes. Every changed pre-existing
      test is justified in the progress log.
- [ ] The progress log opens with the continuation audit table and the
      pre-edit baselines.
- [ ] `git diff -- Packages/RielaMemory/Sources/RielaMemory/MemoryModels.swift`
      adds only history-retention `RielaMemoryError` cases; the progress log
      records no eh-03 edit under `VersionedHistory/` (eh-01-owned; its final
      hashes are in `impl-plans/progress/eh-01-history-engine.md`).
- [ ] The progress log is complete.
