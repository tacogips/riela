# eh-01-history-engine: the shared VersionedHistory component (RielaMemory module)

```json
{
  "planId": "eh-01-history-engine",
  "planPath": "impl-plans/active/efficient-history-01-history-engine.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Packages/RielaMemory/Package.swift",
    "Packages/RielaMemory/Sources/CZlib",
    "Packages/RielaMemory/Sources/RielaMemory/VersionedHistory",
    "Packages/RielaMemory/Tests/RielaMemoryTests/VersionedHistoryTests.swift",
    "impl-plans/progress/eh-01-history-engine.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §2 calls for ONE implementation of four things, used by both memory
(eh-03) and workflow definitions (eh-04):

- the history codec, the table layout and its SQL;
- write, undo, redo, restore, retention, pins and detachment;
- the diff.

It lives in the existing `RielaMemory` module, because root `RielaCore`
already depends on that product (`Package.swift:138`). That way the root
`Package.swift` stays untouched.

This plan builds the engine and its tests only. It makes no store
integration.

Repository context:

- RielaMemory uses raw `sqlite3` helpers (`SQLiteMemorySupport.swift`
  `execute`, `queryRows`, `SQLiteBinding`). It cannot import `RielaSQLite`.
- The only codec today is `EvolutionReverseDelta.swift` (a prefix/suffix
  splice with base64 in JSON). Leave that file untouched; eh-03 still uses it
  for legacy reads.
- The diff algorithm to move is in `Sources/RielaCore/WorkflowDefinitionDiff.swift`:
  - RFC 6901 escaping of `~` and `/`;
  - sorted UTF-8 keys;
  - arrays compared by index, with tail add/remove;
  - `replace` otherwise.

  Do NOT edit that file in this plan; eh-04 turns it into an adapter.
- No zlib exists in the repo. The Linux CI image `swift:6.3.3-noble` ships
  `zlib1g-dev`.

## Non-goals

- No edits to `memory_*` tables, `RielaMemory.swift`, `MemorySnapshot*.swift`
  or any RielaCore file.
- No structural-delta or keyframe codec, and no multi-splice delta.
- No `Package.resolved` change. No edit to the swift-crypto dependency line,
  which a concurrent run is changing.

## Pinned contract (eh-03, eh-04 and eh-05 code against this; keep the names exactly)

All types are `public`, `Sendable` where possible, and live under
`Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/`.

```swift
public enum VersionedHistorySQLValue: Equatable, Sendable { case text(String), int(Int64), blob(Data), null }
public protocol VersionedHistorySQL {
  func execute(_ sql: String, _ values: [VersionedHistorySQLValue]) throws
  func query(_ sql: String, _ values: [VersionedHistorySQLValue]) throws -> [[String: VersionedHistorySQLValue]]
}
public enum VersionedHistoryHeadStorage: Sendable { case stored, external }
public struct VersionedHistoryHead: Equatable, Sendable { key: String; revision: Int64; headVersion: Int64; retainedGenerations: Int? }
public struct VersionedHistoryVersionInfo: Codable, Equatable, Sendable {
  version: Int64; createdAt: String; isHead: Bool; detached: Bool
  encoding: String /* head|full|delta|external */; codec: String /* none|zlib */
  storedBytes: Int64; byteCount: Int64; sha256: String }
public struct VersionedHistoryWriteResult: Equatable, Sendable {
  enum Outcome { case written, unchanged }; outcome; version: Int64; revision: Int64
  droppedVersions: [Int64]; freedBytes: Int64 }
public struct VersionedHistoryHeadMove: Equatable, Sendable { fromVersion: Int64; toVersion: Int64; revision: Int64; value: Data }
public enum VersionedHistoryError: Error, Equatable, Sendable {
  case staleRevision(expected: Int64, actual: Int64)
  case nothingToUndo(oldestRetained: Int64)
  case nothingToRedo
  case versionNotRetained(version: Int64, retained: [Int64], retainedGenerations: Int?)
  case historyCorrupt(String)
  case invalidRetention(Int)
  public var code: String // stale_revision|nothing_to_undo|nothing_to_redo|version_not_retained|history_corrupt|invalid_retention
}
public struct VersionedHistoryStore {
  public init(tablePrefix: String, headStorage: VersionedHistoryHeadStorage, sql: any VersionedHistorySQL,
              now: @escaping @Sendable () -> Date = Date.init,
              withGuardedDelete: @escaping (() throws -> Void) throws -> Void = { try $0() })
  public func ensureSchema() throws                       // CREATE TABLE/INDEX IF NOT EXISTS for <p>_history_heads/_versions
  public func head(key: String) throws -> VersionedHistoryHead?
  public func write(key: String, value: Data, currentHeadValue: Data?, expectedRevision: Int64?, force: Bool,
                    retainedGenerations: Int?, defaultRetainedGenerations: Int, pins: Set<Int64>) throws -> VersionedHistoryWriteResult
  public func undo(key: String, currentHeadValue: Data?, expectedRevision: Int64?) throws -> VersionedHistoryHeadMove
  public func redo(key: String, currentHeadValue: Data?, expectedRevision: Int64?) throws -> VersionedHistoryHeadMove
  public func value(key: String, version: Int64, currentHeadValue: Data?) throws -> Data
  public func versions(key: String, limit: Int, beforeVersion: Int64?) throws -> [VersionedHistoryVersionInfo]
  public func applyRetention(key: String, currentHeadValue: Data?, retainedGenerations: Int, pins: Set<Int64>) throws -> (dropped: [Int64], freedBytes: Int64)
  public func importChain(key: String, revision: Int64, headVersion: Int64, headValue: Data,
                          previous: [(version: Int64, createdAt: String, value: Data)]) throws   // migrations / legacy conversion
  public func deleteAll(key: String) throws
}
public struct VersionedHistoryDiffEntry: Codable, Equatable, Sendable {
  path: String; op: String /* add|remove|replace */; beforeJSON: Data?; afterJSON: Data?
  encoding: String?  /* "bytes" only for the non-JSON fallback */
  beforeSHA256: String?; afterSHA256: String?; beforeByteCount: Int64?; afterByteCount: Int64?
  prefixByteCount: Int64?; suffixByteCount: Int64? }
public enum VersionedHistoryDiff { public static func diff(before: Data, after: Data) -> [VersionedHistoryDiffEntry] }
public enum VersionedHistoryCodec { /* compress/decompress + splice encode/apply, internal helpers may be internal */ }
```

`currentHeadValue` is required (non-nil) when `headStorage == .external` and
the key has a head. It is ignored for `.stored`.

`tablePrefix` must match `^[a-z]+$`. Validate it in `init`, because it is
interpolated into SQL.

## File-level changes

1. **`Packages/RielaMemory/Package.swift`.**
   - Add `.systemLibrary(name: "CZlib", path: "Sources/CZlib", providers:
     [.apt(["zlib1g-dev"]), .brew(["zlib"])])`.
   - Add `"CZlib"` to the `RielaMemory` target's dependencies.
   - Change nothing else. Before editing, diff this file against a fresh
     read: the concurrent run may have just changed the swift-crypto line.
     Keep whatever is there.
2. **`Packages/RielaMemory/Sources/CZlib/`**:
   - `module.modulemap`: `module CZlib [system] { header "shim.h" link "z" export * }`;
   - `shim.h`: `#include <zlib.h>`.
3. **`VersionedHistory/` files.** Suggested split:
   - `VersionedHistorySQL.swift`: the protocol, the value enum, and an
     internal `RawSQLiteHistoryExecutor` over `OpaquePointer`. It uses
     `sqlite3_bind_blob` with `SQLITE_TRANSIENT` and reads `sqlite3_column_blob`
     into `Data`. Imitate `SQLiteMemorySupport.swift` for the bind and step
     loop. It must be `public` (eh-03 uses it from the same module; tests use
     it).
   - `VersionedHistoryCodec.swift`:
     - zlib `compress2` (level 6) and `uncompress` with the stored
       `byte_count` as the destination size;
     - `codec = none` when the compressed output is not smaller;
     - splice blob layout `prefixLen u64 LE, suffixLen u64 LE, middle bytes`.
   - `VersionedHistoryStore.swift`: schema DDL (design §2.2 verbatim), the
     operations, anchors and retention.
   - `VersionedHistoryDiff.swift`: the diff, plus an internal JSON tree that
     keeps number literals verbatim.
   - `VersionedHistoryTypes.swift`: the public types.

## Key points a careless implementation gets wrong

- **Revision vs version.**
  - Every head change bumps `revision`: write, forced write, undo and redo.
  - A new version's number is the new revision value.
  - Undo and redo create no version row.
  - `unchanged` writes bump nothing.
  - Never compute the head from `MAX(version)`.
- **Anchors.**
  - A non-head row's `anchor_version` is its adjacent retained,
    non-detached version toward the head.
  - On undo or redo, re-encode exactly the old head (it becomes a row
    anchored on the new head) and the new head row (encoding `head`, or
    `external` with a NULL blob).
  - In external mode the caller then writes the returned `value` into its
    own head table.
- **Encoding rule.** Store `min(zlib(splice(anchor → value)), zlib(value))`.
  A tie goes to `full`. Detached rows are always `full`.
- **Retention.**
  - It runs only inside `write`, after the redo branch is detached.
  - It keeps the newest R non-detached versions, every version in `pins`,
    and pinned detached rows.
  - Before deleting, reconstruct every survivor whose anchor is about to be
    deleted, and re-encode it against its new toward-head neighbor.
  - Run every DELETE inside `withGuardedDelete`.
  - `R = 0` means unlimited; negative values throw `invalidRetention`.
  - Effective R is `retainedGenerations ?? persisted ?? defaultRetainedGenerations`.
    A non-nil `retainedGenerations` is persisted on the heads row.
- **Reconstruction.**
  - Walk from the head outward until the target or a `full` row.
  - Verify `content_sha256` and `byte_count`; on mismatch throw
    `historyCorrupt`.
  - A missing anchor also throws `historyCorrupt`. Never guess.
- **Freed bytes** are the sum of `length(blob)` over the deleted rows.
- **Transactions.** The engine never opens or commits a transaction, and
  never runs a PRAGMA. Callers do both.
- **Diff and JSON parsing.**
  - The diff must equal the current `WorkflowDefinitionDiff` output for JSON
    inputs: same paths, same order, same ops.
  - Do not parse with `JSONSerialization` (it confuses bool and number) or
    `MemoryJSONValue` (its Double is lossy). Use the internal tree.
  - The `beforeJSON`/`afterJSON` leaves are canonical JSON bytes (sorted
    keys, no whitespace).
  - The non-JSON fallback is exactly one entry with path `""`, op `replace`
    and encoding `bytes`.

## Tests (`VersionedHistoryTests.swift`, raw in-memory SQLite through `RawSQLiteHistoryExecutor`, both head storages)

- Codec: random binary, empty, Unicode and identical values each round-trip
  → exact bytes.
- A truncated or flipped blob → `historyCorrupt`.
- A 660 KB JSON document where each write changes a header field and appends
  an item, run for 1000 writes at R=2 → exactly 1 non-head row, whose
  `storedBytes` ≤ `zlib(full)` bytes. The head revision is 1000.
- An identical write → `unchanged`, and the revision does not change. A
  forced identical write → `written`.
- R=1 → 0 non-head rows. R=5 → exactly 4.
- 25 writes at R=10 with pins {3} → versions are {3} ∪ the newest 10, and
  version 3 reconstructs byte-exactly.
- Undo/redo:
  - undo, undo, redo → the head and value move, the revision bumps three
    times, and no rows are deleted;
  - undo past the oldest → `nothingToUndo`;
  - redo at the tip → `nothingToRedo`;
  - a write after an undo drops the unpinned redo rows, and a pinned redo
    row becomes `detached` and `full` and is excluded from undo.
- A stale `expectedRevision` → `staleRevision(expected, actual)`.
- `value` for a dropped version → `versionNotRetained` with the retained
  list.
- `withGuardedDelete` is invoked around every delete (counted by a spy).
- Diff:
  - golden cases copied from `Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift`'s
    diff-pointer assertions (read it; copy the inputs and expected
    `path`/`op`);
  - `~`/`/` escaping;
  - array tail add/remove;
  - number literal `1` vs `1.0`;
  - non-JSON input → one `bytes` entry.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build --package-path Packages/RielaMemory' > tmp/efficient-history/eh-01-history-engine/build.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory --filter VersionedHistoryTests' > tmp/efficient-history/eh-01-history-engine/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Packages/RielaMemory/Sources/RielaMemory/VersionedHistory Packages/RielaMemory/Tests/RielaMemoryTests/VersionedHistoryTests.swift'
```

Expected: exit 0 for all three, and the test log shows a non-zero count of
executed `VersionedHistoryTests`.

## Done criteria

- [ ] The pinned contract compiles with the exact names above:
      `grep -n "public struct VersionedHistoryStore" -r Packages/RielaMemory/Sources`
      finds a match.
- [ ] `git diff Packages/RielaMemory/Package.swift` shows only the CZlib target
      and dependency lines.
- [ ] All tests listed above exist and pass. Build, test and lint exit 0
      with logs saved.
- [ ] The progress log `impl-plans/progress/eh-01-history-engine.md` is
      complete.
