# eh-04-definition-history: workflow definition store on VersionedHistory (generation 11, window 10, pins, guarded deletes, undo/redo)

```json
{
  "planId": "eh-04-definition-history",
  "planPath": "impl-plans/active/efficient-history-04-definition-history.md",
  "dependsOn": ["eh-01-history-engine", "eh-02-runtime-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/WorkflowDefinitionStoreSchema.swift",
    "Sources/RielaCore/WorkflowDefinitionStore.swift",
    "Sources/RielaCore/WorkflowDefinitionDiff.swift",
    "Sources/RielaCore/WorkflowDefinitionHistorySchema.swift",
    "Sources/RielaCore/WorkflowDefinitionPins.swift",
    "Sources/RielaCore/SQLiteDatabaseHistoryExecutor.swift",
    "Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift",
    "impl-plans/progress/eh-04-definition-history.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §4 and QA Q3/Q5. #179 keeps every definition version and blob forever,
because its triggers forbid deletes. This plan moves documents into the
shared engine with a default window of 10 generations.

Never-dropped versions:

- the head;
- `last_file_version_id`;
- versions referenced by live session pins;
- versions that were head within the last 24 hours.

Current code:

- **Schema.** `WorkflowDefinitionStoreSchema.swift:31-93` defines the
  tables. `definition_versions.document_digest` has an FK to
  `definition_blobs`. The triggers are `definition_*_no_update` and
  `definition_*_no_delete`.
- **Store.** `WorkflowDefinitionStore.swift` provides:
  - `commit` (`:406-513`): one transaction that writes blob, version, audit
    and head. The head `revision` is +1. A seed returns `.alreadyRegistered`.
    The CAS is `expectedCurrentVersionId`.
  - `blob(digest:)` (`:357`), `version(versionId:)`, `history`, `head`.
  - `openDatabase` (`:515-521`) goes through
    `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:)`.
- **Pins.** A pin exists only as `session_json.$.definitionSource {kind,
  workflowName, versionId, storeRoot, digest}`. Resume and rerun load it via
  `SessionCommands.swift:12-31` → `WorkflowDefinitionService.loadPinned`.
- **Service.** `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift`
  calls `store.blob(digest:)` at `:117, :194, :339, :531`. Restore is at
  `:329-362`.
- **eh-02 stubs.** eh-02 created the stubs
  `WorkflowDefinitionHistorySchema.migrateToGeneration11(in:)` / `.create(in:)`
  and `WorkflowDefinitionPins.recordPinIfNeeded(_:snapshot:sessionStoreRoot:)`
  plus `WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot:sessionStoreRoot:)`.
  `completeSnapshotWrite` already calls the same-store hook inside the save
  transaction. The runtime store's own-transaction `save(_:)` and
  `save(_:appendingWorkflowMessages:)` already call the foreign hook before
  opening their transaction. eh-06 adds the foreign call to the CLI save
  overloads in wave 3. Do not move either call. eh-02 also froze the generation-10 DDL in
  `createGeneration10DefinitionSchema`. Do not edit that function.

## Non-goals

- No CLI, GraphQL, catalog or SDL changes; eh-09 owns those.
- No session-store changes. Do not edit
  `SQLiteWorkflowRuntimePersistenceStore*.swift` or
  `SQLiteRuntimeExecutionRowsSchema.swift`; eh-05 owns them and runs in the
  next wave (W2b). The eh-02 seams there already call
  `WorkflowDefinitionHistorySchema.create` / `.migrateToGeneration11`.

## Continuation (session 523, design §13)

- Runs in W2a next to eh-03 (disjoint paths). Resume from the in-tree
  source and the "Remaining eh-04 work" list in
  `impl-plans/progress/eh-04-definition-history.md`; take the current
  SHA-256 of each owned file as the pre-edit baseline.
- Entry fix: `create(in:)` and `migrateToGeneration11(in:)` must create the
  engine tables (`definition_history_*`) before any trigger, index or view
  that references them. The guarded-delete trigger on
  `definition_history_versions` was created first, so every fresh runtime
  store failed to open.
- W2a gate before eh-05 resumes: `swift build` exits 0, eh-04's own
  definition suites exit 0, and the schema opens. "The schema opens" means
  the three `SQLiteRuntimeSchemaMigrationTests` generation-open tests pass
  and the `SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests` log has
  zero `no such table`/`already exists` matches. Remaining failures in
  eh-05-owned code go to `tmp/efficient-history/wave-W2a/handover-eh-05.md`
  and do not block (see Verification).
- No changes to the legacy file snapshot store (`WorkflowHistoryStore`).

## Pinned API (eh-09 and eh-10 depend on it)

```swift
// WorkflowDefinitionStore
public static let defaultHistoryRetention = 10        // 0 = unlimited, valid 0...10000
public func commit(_ write: WorkflowDefinitionWrite) throws -> WorkflowDefinitionCommitOutcome   // WorkflowDefinitionWrite gains historyRetention: Int?, defaultHistoryRetention: Int
public func moveHead(workflowName: String, direction: WorkflowDefinitionHeadMoveDirection /* undo|redo */, reason: String,
                     expectedRevision: Int64?, expectedVersionId: String?, evidence: [WorkflowDefinitionEvidenceRef],
                     actorKind: String, actorId: String?) throws -> WorkflowDefinitionCommitOutcome
public func document(versionId: String) throws -> Data?                 // throws versionNotRetained for a known-but-dropped id
public func blob(digest: String) throws -> Data?                        // KEEP signature; resolves via any retained version with that digest
public func retentionState() throws -> String                           // "active" | "pendingBackfill"
public func backfillPinsAndApplyRetention(foreignSessionStoreRoots: [String], defaultHistoryRetention: Int) throws -> WorkflowDefinitionRetentionReport
public struct WorkflowDefinitionRetentionReport: Codable, Equatable, Sendable { pinsInserted: Int; versionsDropped: Int; auditRowsDropped: Int; freedBytes: Int64; state: String }
// WorkflowDefinitionOperation gains .undo, .redo; WorkflowDefinitionAuditRecord gains retained: Bool
// WorkflowDefinitionStoreError gains .versionNotRetained(versionId: String, retainedVersionIds: [String], retainedGenerations: Int?) with code "definition_version_not_retained"
// Clock seam (tests only; production uses the default):
//   WorkflowDefinitionStore.init(rootDirectory: String, now: @escaping @Sendable () -> Date = Date.init)
//   replaces the inline Date() at WorkflowDefinitionStore.swift:431 (keep its millisecond rounding) and feeds
//   the 24-hour former-head rule and VersionedHistoryStore(now:).
// WorkflowDefinitionService: init gains defaultHistoryRetention: Int = WorkflowDefinitionStore.defaultHistoryRetention
//   and now: @escaping @Sendable () -> Date = Date.init (passed to the store);
//   importDefinition/update/updatePrompt/restore gain historyRetention: Int? = nil; new undo(...)/redo(...) mirroring restore's parameters plus expectedRevision/expectedVersionId
```

Read the actual type names in `WorkflowDefinitionStore.swift` first (the
write struct, the outcome, the error enum and the evidence type). Extend
those existing types; do not create parallel ones.

## File-level changes

1. **`SQLiteDatabaseHistoryExecutor.swift` (new).**
   `struct SQLiteDatabaseHistoryExecutor: VersionedHistorySQL` over
   `SQLiteDatabase`. It maps values to the eh-02 `SQLiteValue.blob` and
   `SQLiteRow.data`.
2. **`WorkflowDefinitionHistorySchema.swift`.** Fill both functions.
   - **`create(in:)`** (the current shape for fresh databases; idempotent):
     - the engine tables (prefix `definition`, `.stored` head);
     - `definition_version_pins(workflow_name, history_version, session_store_root, session_id, created_at, PRIMARY KEY(session_store_root, session_id, workflow_name))`;
     - `definition_retention_guard(id INTEGER PRIMARY KEY CHECK (id = 1))`,
       with a `BEFORE INSERT` trigger that aborts when a row exists;
     - `definition_store_state(key TEXT PRIMARY KEY, value TEXT)`;
     - guarded `BEFORE DELETE ... WHEN NOT EXISTS (SELECT 1 FROM definition_retention_guard)`
       triggers on `definition_versions`, `definition_change_audit` and
       `definition_history_versions`.
     - Keep the `no_update` triggers on versions and audit rows.
   - **`migrateToGeneration11(in:)`** (runs inside the migrator
     transaction), in order:
     1. `create(in:)`, except the guarded triggers on `definition_versions`.
     2. Rebuild `definition_versions` as the new table, with `history_version
        INTEGER NOT NULL`, `UNIQUE(workflow_name, history_version)`, no FK and
        the same other columns.
        - Number the versions 1...k per workflow in the `created_order` of
          the audit row whose `version_id` matches. Every commit writes
          exactly one version and one audit row (`WorkflowDefinitionStore.swift:405-490`).
        - Drop the old triggers first, then create the guarded triggers on
          the new table.
     3. For each workflow, call `engine.importChain(revision:
        definition_heads.revision, headVersion: <history_version of
        current_version_id>, headValue: blob bytes, previous: …)`.
     4. `DROP TABLE definition_blobs`.
     5. Run the pin backfill **only if** `SELECT SUM(length(session_json))
        FROM workflow_runtime_snapshots ≤ 268435456`:
        - insert a pin row for each snapshot whose
          `json_extract(session_json,'$.definitionSource.kind') = 'store'`
          and whose `storeRoot` is NULL or resolves to this database file.
          `storeRoot` is a DIRECTORY and `db.path` is a FILE, so compare
          `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: storeRoot)`
          with `db.path`, both passed through
          `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath().path`
          (use the same helper as the pin hooks, see change 4);
        - then apply the window once, with R = 10, to every workflow.
        Otherwise, set `definition_store_state('retention', 'pendingBackfill')`.
   - `WorkflowDefinitionStoreSchema.create` (the current-shape builder)
     must not recreate `definition_blobs` or the old FK. Make it delegate
     the new parts to `WorkflowDefinitionHistorySchema.create`.
3. **`WorkflowDefinitionStore.swift`.**
   - **Commit order:**
     1. Read the head.
     2. Compute `pins`:
        - the current head's `history_version` (it becomes a former head);
        - `last_file_version_id`;
        - live pin rows, after lazy release;
        - the `previous_version_id` of audit rows with `created_at > now - 24h`.
     3. Run `engine.write` with `expectedRevision` from the head. Use
        R = `write.historyRetention ?? heads.retained_generations ??
        defaultHistoryRetention`, or R = 0 while the state is
        `pendingBackfill`.
     4. Insert the version row (`history_version` = the engine version) and
        the audit row, then upsert `definition_heads`. The `revision` equals
        the engine revision.
     5. Delete the `definition_versions` rows for the dropped versions.
     6. Delete the audit rows whose `version_id` and `previous_version_id`
        are both not retained (a NULL previous counts as not retained).
   - Every DELETE runs inside `withGuardedDelete`. That closure inserts the
     guard row, runs the body, then deletes the guard row, so the guard row
     never survives a commit.
   - **Lazy pin release.** A pin row is released when its session no longer
     exists:
     - Same store: check `workflow_runtime_snapshots` /
       `cli_workflow_sessions` with no tombstone. Use `tableExists` guards.
     - Foreign store: open a plain `SQLiteDatabase` at
       `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`
       with `SQLiteOpenMode.strictReadOnly`. Do NOT use the
       `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:)` initializer
       here: it opens writable, creates files and migrates the foreign store.
       An open failure keeps the pin; a missing directory releases it.
   - `moveHead`: run `engine.undo` / `redo` and write one audit row
     (operation `undo` / `redo`, diff = old → new head document, reason
     required). Update `current_version_id` and `revision`. Never move
     `last_file_version_id`.
   - `history(...)` sets `retained` on each audit record.
   - `document`, `blob` and `version` reconstruct through `engine.value`.
4. **`WorkflowDefinitionPins.swift`.** Fill BOTH eh-02 stubs. Design §4:
   a same-store pin is part of the snapshot transaction; a foreign-store pin
   is written in a separate `BEGIN IMMEDIATE` BEFORE the session's save
   transaction, and a failure fails the save (so the run start). Never hold
   a writer lock on one runtime file while asking for another (EH5-F3).
   - **Shared helpers (private).**
     - `pinTarget(snapshot:sessionStoreRoot:) -> (targetDatabasePath: String, isForeign: Bool)?`.
       Returns nil unless `snapshot.session.definitionSource?.kind == .store`
       and a `versionId` is set. Target root =
       `definitionSource.storeRoot ?? sessionStoreRoot`. Both paths are
       `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`
       of the root, normalized with
       `standardizedFileURL.resolvingSymlinksInPath().path`. `isForeign` =
       the two normalized paths differ.
     - `versionId` → `history_version` lookup in the target database.
   - **`recordPinIfNeeded(_ db:snapshot:sessionStoreRoot:)`** (inside the
     snapshot transaction, both cold and fast paths):
     - Target nil or `isForeign == true` → return without doing anything.
       It must never open another database file.
     - Same store → `INSERT OR IGNORE` the pin row in `db`.
   - **`recordForeignPinIfNeeded(snapshot:sessionStoreRoot:)`** (called with
     no transaction open; eh-02 calls it from the runtime store's
     `save(_:)` / `save(_:appendingWorkflowMessages:)`, and eh-06 from every
     CLI save overload):
     - Target nil or `isForeign == false` → return.
     - A process-wide `Mutex`-protected `Set` of
       `(targetDatabasePath, sessionId)` skips pins already written by this
       process. Insert into the set only AFTER the commit succeeds.
     - Otherwise open the foreign store writable through the normal
       `SQLiteWorkflowRuntimePersistenceStore(rootDirectory: targetRoot)`
       open + `prepareSchema` path (this may migrate the foreign store; that
       is allowed here because no local transaction is open). In its own
       `BEGIN IMMEDIATE`: look up `history_version`, then `INSERT OR IGNORE`
       the pin row with `session_store_root` = the normalized LOCAL root.
       Close the connection before returning.
     - Any open, busy or SQL failure throws. The caller has not begun its
       local transaction, so no local row is written.
   - **Unknown version** (the `versionId` is not a retained version in the
     target store), in either hook:
     - session status non-terminal → throw `versionNotRetained` (fails the
       save, fail closed);
     - session status terminal (`snapshot.session.status.isTerminal`,
       `RuntimeSession.swift:22`) → skip the pin and return. This keeps cancel and reconcile saves of a legacy session
       whose pinned version was already dropped from failing on every save
       (step5 low residual).
   - **Callers reviewed and left unchanged** (record this in the progress
     log): `WorkStore+Reservation.swift:358` and
     `SpecialistSupervisor.swift:366` create brand-new sessions without
     `definitionSource`; `WorkStore+Reservation.swift:533,585` re-save
     cancellations of sessions whose first save already went through a CLI
     or runtime-store entry point. They call the `in db:` variants, so only
     the same-store hook runs for them.
5. **`WorkflowDefinitionDiff.swift`.** Becomes an adapter over
   `VersionedHistoryDiff.diff`. It maps `beforeJSON` / `afterJSON` into
   `JSONValue` with `JSONDecoder`. The output must be identical to today's.
6. **`WorkflowDefinitionService.swift`.**
   - Thread `historyRetention` / `defaultHistoryRetention` through
     `importDefinition`, `update`, `updatePrompt` and `restore`.
   - Add `undo` and `redo`.
   - `loadPinned`, `restore`, `show` and `diff` on a dropped version throw
     `versionNotRetained`.
   - Restore validates that the source version is retained before any
     write.
   - Keep the existing reason and CAS validation order.

## Pitfalls

- Do not call the current `WorkflowDefinitionStoreSchema.create` from the
  10→11 migration before the rebuild. The generation-10 tables already exist,
  and recreating them with the new shape would conflict.
- Version UUIDs (`defv-…`), `digest` and `definitionSource` must be
  byte-identical after the migration. Existing pinned sessions must resume.
- `revision` must never decrease, including across the migration import.
- The guard row must not be visible after commit. Test it.
- A `pendingBackfill` store never deletes on commit.
- `ensureSchema` runs on every open. `create(in:)` must be idempotent and
  must not touch the data.
- Never open, migrate or write a foreign runtime database from
  `recordPinIfNeeded`. That hook runs inside the local `BEGIN IMMEDIATE`;
  a foreign `BEGIN IMMEDIATE` there causes a cross-file lock-order
  inversion between project and user stores (EH5-F3).
- Do not move the same-store pin insert out of the snapshot transaction.
- Do not add the foreign dedupe entry before the foreign commit succeeds;
  a failed attempt must retry on the next save.

## Tests

**Clock rule for every window-count test.** Rule 4 pins every head of the last
24 hours, so a test that commits quickly with the real clock drops nothing.
Every test that asserts a dropped version must commit through the fake `now`
seam and advance it by 25 hours between commits. Assert with a set formula,
not a bare count: retained = newest R ∪ {head} ∪ {last_file_version} ∪ pins ∪
{24-hour former heads}.

`WorkflowDefinitionRetentionTests.swift` (new, RielaCoreTests):

- Import (version 1, the `last_file_version_id`) plus 24 updates of one
  workflow, clock +25 h per commit → retained = versions 16...25 ∪ {1}. With a
  session snapshot pinning version 3 → also {3}.
- Same 25 commits with the real clock (all within 24 h) → nothing is dropped
  (rule 4 is proven, not bypassed).
- The head and `last_file_version_id` are always retained.
- The orphan blobs are gone: the engine row count equals the retained count.
- A `DELETE FROM definition_versions` outside retention → abort with the
  guard message. Inserting the guard row twice → abort.
- An audit row whose two versions are both dropped is deleted. An audit row
  with one retained side is kept.
- A generation-10 fixture (built with `createGeneration10DefinitionSchema`
  plus 15 committed versions and a snapshot pinning version 2):
  - open → generation 11;
  - `definition_blobs` is gone and the UUIDs are unchanged;
  - with the small session table, the window is applied and version 2 is
    kept.
  - When the session bytes are over 256 MiB (inject the threshold through
    an internal static for the test), the state is `pendingBackfill` and
    nothing is deleted. `backfillPinsAndApplyRetention` then drops the
    excess versions.
- Undo/redo:
  - undo → the head is the previous version, `last_file_version_id` is
    unchanged, and an audit row records `undo`;
  - redo → back;
  - undo at the oldest → `nothing_to_undo`.
- A cross-store pin (two store roots) → the pin row lands in the definition
  store. Deleting the foreign session releases it on the next commit.
- Held foreign lock (EH5-F3), in `WorkflowDefinitionSessionPinTests`:
  session store A, definition store B. Another connection holds
  `BEGIN IMMEDIATE` on B's database (set a short busy timeout for the test).
  The session's first `SQLiteWorkflowRuntimePersistenceStore(rootDirectory: A).save(snapshot)`
  → throws, and A has NO `workflow_runtime_snapshots` row for the session.
  Release the lock and save again → succeeds, and B has the pin row. This
  proves the foreign pin is written before the local transaction begins.
- `recordPinIfNeeded` with a foreign target, called inside an open
  transaction on A → returns without opening B (B's file mtime and size
  unchanged; with B absent, no file is created).
- Same-store pin, cold path and fast path → the pin row is written in the
  snapshot transaction (roll back the outer transaction → no pin row).
- Unknown pinned version: a non-terminal session → the save throws
  `versionNotRetained`; the same session with status `cancelled` → the save
  succeeds and no pin row is written.
- Path normalization: `storeRoot` written with a trailing `/` or through a
  symlink to the session store → treated as the same store (same-store
  pin, no foreign open).

Existing suites (update the assertions that legitimately changed: the
generation is now 11, `definition_blobs` is gone, deletes are guarded):

- `WorkflowDefinitionStoreTests`
- `WorkflowDefinitionSessionPinTests`
- `WorkflowDefinitionServiceTests`: restore of a retained version works; an
  over-window restore fails with `definition_version_not_retained`.
- `WorkflowDefinitionServiceResolutionTests`: a session pinned to version 3
  resumes and reruns after 25 updates made through a service with the fake
  clock (+25 h per commit), so versions outside the window really are
  dropped. Imitate `testResumeUsesPinnedStoreVersionAfterHeadMoves`.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build' > tmp/efficient-history/eh-04-definition-history/build.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|WorkflowDefinitionRetentionTests|WorkflowDefinitionServiceTests|WorkflowDefinitionServiceResolutionTests"' > tmp/efficient-history/eh-04-definition-history/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeSchemaMigrationTests/(testAnOlderSessionStoreIsDiscardedAndRecreatedAtTheCurrentGeneration|testGeneration10UpgradesTo11WithoutLosingSnapshot|testGeneration9UpgradesThrough10To11WithoutLosingSnapshot)"' > tmp/efficient-history/eh-04-definition-history/schema-open.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeSchemaMigrationTests|PrivateWorkflowTests"' > tmp/efficient-history/eh-04-definition-history/store-suites.log 2>&1; echo $?
grep -c -e 'no such table' -e 'already exists' tmp/efficient-history/eh-04-definition-history/store-suites.log
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected:

- The definition suites and the three generation-open tests exit 0, and
  every listed suite or test executes (3 tests for `schema-open.log`).
- The `store-suites.log` grep prints `0`.
- The exit status of `store-suites.log` is recorded but does not gate
  eh-04. Attribute each remaining failure by its failing frame or assertion:
  - In an eh-04 writePath: it blocks eh-04. Fix it.
  - In an eh-05 writePath (`SQLiteWorkflowRuntimePersistenceStore*.swift`,
    `SQLiteRuntimeExecutionRowsSchema.swift`, `RuntimeExecutionReuse.swift`,
    `SQLiteWorkflowStartupIdentities.swift`) or the eh-05 fixture
    (`Tests/RielaCLITests/PrivateWorkflowTests.swift`): append
    `<TestClass.testName> | <log path>:<line> | <first error line>` to
    `tmp/efficient-history/wave-W2a/handover-eh-05.md`. It does not block
    eh-04, and eh-04 does not edit those files.
  - Frame in neither set (for example
    `Sources/RielaCLI/PrivateWorkflowWorker.swift` "private inner workflow did
    not complete"): append it the same way with the marker `unattributed`.
    It is non-blocking for W2a. The W2b gate requires it green.

## Done criteria

- [ ] `grep -n "definition_blobs" Sources/RielaCore` matches only the frozen
      generation-10 function and the migration DROP.
- [ ] The pinned API exists with the exact names. `blob(digest:)` keeps its
      signature.
- [ ] Both pin hooks are implemented; the held-foreign-lock test passes; and
      `grep -n "SQLiteWorkflowRuntimePersistenceStore(rootDirectory" Sources/RielaCore/WorkflowDefinitionPins.swift`
      matches only inside `recordForeignPinIfNeeded`.
- [ ] The definition suites and the three generation-open tests pass. The
      `store-suites.log` grep for `no such table`/`already exists` prints
      `0`. Every other store-suite failure is attributed, and the eh-05 ones
      are in `tmp/efficient-history/wave-W2a/handover-eh-05.md`. The progress
      log records every changed pre-existing assertion with its reason.
