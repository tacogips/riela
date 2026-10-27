# eh-05-session-rows: header-only canonical snapshots, execution rows, content-addressed payloads, nested references

```json
{
  "planId": "eh-05-session-rows",
  "planPath": "impl-plans/active/efficient-history-05-session-rows.md",
  "dependsOn": ["eh-02-runtime-contract", "eh-04-definition-history"],
  "wave": "W2b",
  "writePaths": [
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift",
    "Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift",
    "Sources/RielaCore/RuntimeExecutionReuse.swift",
    "Sources/RielaCore/SQLiteWorkflowStartupIdentities.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift",
    "Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift",
    "impl-plans/progress/eh-05-session-rows.md"
  ],
  "sharedPaths": ["Tests/RielaCLITests/PrivateWorkflowTests.swift"],
  "sharedPathNotes": [
    {"path": "Tests/RielaCLITests/PrivateWorkflowTests.swift", "intendedEdit": "Only if a fixture SQL statement reads or writes `$.executions` inside session_json directly: adapt that fixture to the execution-row storage. Never change or weaken an assertion of the four fast-path/fence tests (testEmbeddedBulkGraphRetainsCanonicalHistoryWithoutCLIProjection, testCanonicalTerminalFenceUsesCommittedStatusAndFailureKind, testCanonicalReuseKeepsExactInputsOrderAndReplacesOptionalMetadata, testCanonicalReuseRefusesRolledBackAndLegacyWriterWitnesses)."}
  ]
}
```

## Continuation (session 523, design §13)

- Runs in W2b, after eh-04 is accepted and the W2a gate passes. Every
  fresh runtime-store open runs eh-04's generation-11 definition schema, so
  this plan's suites cannot pass before that schema is complete (the
  session-518 run failed with `no such table: main.definition_history_versions`,
  `tmp/efficient-history/eh-05-session-rows/test-final-source-2.log`).
- The in-tree source is recorded as source-complete in
  `impl-plans/progress/eh-05-session-rows.md`. Resume from it: take the
  current SHA-256 of each owned file as the pre-edit baseline, run a fresh
  `swift build` and the exact focused suite, and rework only this plan's
  writePaths. Keep the recorded `PrivateWorkflowTests` fixture edit.
- First read `tmp/efficient-history/wave-W2a/handover-eh-05.md` (if it
  exists). It lists `SQLiteRuntimeSchemaMigrationTests`/`PrivateWorkflowTests`
  failures attributed to this plan's code during W2a. Each one must be green
  before this plan is accepted.

## Intent and context

Design §5 (session part).

Today:

- `workflow_runtime_snapshots.session_json` holds the whole session,
  including every execution.
- Every save rewrites that value. The witnessed fast path
  (`SQLiteWorkflowRuntimePersistenceStore.swift:856-900`) patches it with
  `jsonb_set`, but SQLite still rewrites the full row.
- `workflow_nested_invocations` embeds full child snapshots: `reservation_json`
  `childSnapshot` and `child_terminal_json` (`+NestedInvocations.swift:35,79,195`).

After this plan:

- `session_json` holds only the header.
- Executions are rows that point at payloads, which are content-addressed
  per family.
- Nested rows reference payloads.
- Per-save bytes stay bounded.

`load` still returns the identical `WorkflowSession` and
`WorkflowRuntimePersistenceSnapshot`, so callers through the store API
(GraphQL, viewer, web, Work Runtime, CLI) need no change.

Fast-path and fence contracts that must stay green (commits
`c1375bcb..a4e2cbfd`, `Tests/RielaCLITests/PrivateWorkflowTests.swift`):

- `loadStatus` scalar reads;
- the `validateTaskTerminalWrite` fence;
- the `$._rielaCanonicalWrite` witness with a guarded single-row update and
  the `canonical execution witness changed` error;
- the reuse cache `RuntimeExecutionReuse`;
- a rollback or a legacy writer that strips the witness forces the cold path.

## Non-goals

- No CLI-record changes; eh-06 owns `CLIWorkflowSessionStore.swift`.
- No retention, prune or reconcile changes; eh-07 owns
  `TerminalRetention*.swift` and `SessionReconcileCommand.swift`.
- Do not touch the message log tables or `replaceMessages`.
- Do not change the eh-02 lines (generation 11, the migration registration,
  the open option, the `recordPinIfNeeded` call in `completeSnapshotWrite`,
  and the two `recordForeignPinIfNeeded` calls placed before `openDatabase()`
  in `save(_:)` and `save(_:appendingWorkflowMessages:)`). Keep them
  byte-identical, keep the same-store pin call on both the cold and fast
  paths, and keep each foreign call before its entry point opens a
  transaction. If the rewrite restructures these entry points, the foreign
  call must still run before any `db.transaction` (EH5-F3).

## Pinned contract (eh-06, eh-07 and eh-10 depend on it)

Tables are created in `SQLiteRuntimeExecutionRowsSchema.create(in:)` and,
identically, in `migrateToGeneration11(in:)`:

```
workflow_runtime_payloads(id INTEGER PRIMARY KEY, root_session_id TEXT NOT NULL, digest TEXT NOT NULL,
  bytes BLOB NOT NULL CHECK (json_valid(bytes, 8)), byte_count INTEGER NOT NULL, UNIQUE(root_session_id, digest))
workflow_runtime_executions(workflow_execution_id TEXT NOT NULL REFERENCES workflow_runtime_snapshots(workflow_execution_id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL, execution_id TEXT NOT NULL, root_session_id TEXT NOT NULL, payload_digest TEXT NOT NULL,
  PRIMARY KEY(workflow_execution_id, ordinal)) WITHOUT ROWID
INDEX workflow_runtime_executions_root_digest ON workflow_runtime_executions(root_session_id, payload_digest)
INDEX workflow_runtime_executions_execution ON workflow_runtime_executions(workflow_execution_id, execution_id)
workflow_nested_invocation_refs(invocation_key TEXT NOT NULL, role TEXT NOT NULL, ordinal INTEGER NOT NULL,
  root_session_id TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(invocation_key, role, ordinal)) WITHOUT ROWID
INDEX workflow_nested_invocation_refs_root_digest ON workflow_nested_invocation_refs(root_session_id, digest)
ALTER TABLE workflow_nested_invocations ADD COLUMN abandoned_at TEXT   -- only when the column is missing
```

- **Header marker.** New headers carry `"_rielaExecutionStorage": "rows"` and
  no `executions` key. Legacy rows have an inline `executions` array and no
  marker.
- **Nested rows.** New `reservation_json` and `child_terminal_json` keep a
  stub `childSnapshot: {session: {sessionId, workflowId, status, parentSessionId?, rootSessionId?}}`.
  The existing expression index on `$.childSnapshot.session.sessionId` and
  the `$.parentSessionId` path keep working. The rows add
  `"childSnapshotStorage": "refs"` and
  `"childSnapshotRef": {"headerDigest", "executionDigests": [..], "rootOutputDigest"?, "diagnosticsDigest"?}`.
  Callee workflow and node payloads are replaced by `"calleeDigest"` when
  present.
- **Public store API:**

  ```swift
  public static let executionStorageMarkerKey = "_rielaExecutionStorage"
  public func executionIdentities(sessionId: String) throws -> [String]          // ordinal order; legacy rows read inline
  public func legacyInlineSessionIds(limit: Int) throws -> [String]
  public func convertLegacySession(sessionId: String) throws -> Bool             // caller holds the execution lock
  public func legacyEmbeddedNestedInvocationKeys(limit: Int) throws -> [String]
  public func convertLegacyNestedInvocation(invocationKey: String) throws -> Bool
  public func releaseUnreferencedPayloads(rootSessionId: String) throws -> Int64 // bytes freed
  public struct PersistenceWriteSample: Sendable { public let boundBytes: Int; public let statements: Int }
  // init gains: persistenceWriteObserver: (@Sendable (PersistenceWriteSample) -> Void)? = nil  (test seam; nil in production)
  ```

## File-level changes

- **`SQLiteRuntimeExecutionRowsSchema.swift`.** Fill the eh-02 stubs. Both
  must be idempotent: `IF NOT EXISTS`, plus a `PRAGMA table_info` check
  before the ALTER.
- **`SQLiteWorkflowRuntimePersistenceStore.swift`.**
  - **Cold path `upsertSnapshot`:**
    - Write the header JSON (the session with `executions = []` removed,
      plus the marker and the witness) via `INSERT … ON CONFLICT`.
    - Then for each execution: `INSERT OR IGNORE` the payload `(root,
      sha256(executionJSON), jsonb(executionJSON))` and upsert the execution
      row.
    - Delete execution rows with `ordinal >= count`.
    - Delete the now-unreferenced old payloads (indexed lookups on
      `(root_session_id, digest)` in both reference tables).
    - Drop the temp-table assembly (`riela_snapshot_execution_parts`).
  - **Fast path `reuseSnapshotExecutions`:**
    - Same guards (cache entry, ID-prefix match, witness equal).
    - A single guarded header UPDATE `WHERE workflow_execution_id=? AND
      json_extract(session_json,'$._rielaCanonicalWrite')=?` that replaces
      the header value. A changed-row count other than 1 throws
      `canonical execution witness changed`.
    - Then upsert only the changed or appended execution rows.
    - The 60-argument cap and the per-key `jsonb_set` loop go away.
  - **Other snapshot columns.** Write `root_output_json`, `diagnostics_json`
    and the loop columns only when they differ from the cached previous
    values. On the cold path, always write them.
  - **Loads.** `load`, `loadStrictReadOnly` and `loadAll` assemble
    `executions` from the rows inside the same read transaction:
    `jsonb_set(session_json,'$.executions',(SELECT jsonb_group_array(p.bytes)
    … ORDER BY e.ordinal))`, or the same thing in Swift.
  - Legacy inline rows decode as today.
  - The first save of a legacy row takes the cold path and converts it.
  - **Run-end payload release (design §5 "Run end", QA Q1).** When a save
    writes a terminal session status (`completed|failed|cancelled`), call
    `releaseUnreferencedPayloads(rootSessionId:)` for that session's root in
    the same transaction. The work is bounded by the family's payload rows
    through the `(root_session_id, digest)` indexes, never a whole-table
    scan. The bounded `incremental_vacuum` that follows the run is eh-07's
    job.
  - Startup identities receive only the appended execution IDs on the fast
    path. Pass all IDs on the cold path.
- **`+WebSummaries.swift`, `+Rollup.swift`, `+SessionFamily.swift`.**
  - Replace `json_each(session_json,'$.executions')` and every direct decode
    of `session_json` with the row-aware query or assembly. Support legacy
    rows through `json_type(session_json,'$.executions') = 'array'`.
- **`SQLiteWorkflowStartupIdentities.swift:12`.** Its backfill reads
  execution IDs from the rows, and still handles legacy rows.
- **`RuntimeExecutionReuse.swift`.** Also cache the previous root output,
  diagnostics and loop column strings, so the fast path can skip unchanged
  columns.
- **`+NestedInvocations.swift`.**
  - The writers store refs, as pinned above. The payloads are the same
    `(root, digest)` rows; the root is the parent's root session.
  - Insert the `workflow_nested_invocation_refs` rows for each digest.
  - The readers rebuild the full child snapshot from the refs.
  - Legacy embedded rows decode unchanged.
  - The fences (`recovery_reason` and fenced parent publication) are
    untouched.

## Pitfalls

- The reconstructed `WorkflowSession` must be equal to the saved one,
  including the execution order and every optional field. Use the existing
  `RuntimeSnapshotDates` encoding for executions, as today.
- **Execution IDs vs ordinals.** Execution IDs can repeat across retries, so
  key rows by ordinal, not by ID.
- A rollback must invalidate the cache. Keep the "a rollback removes this
  UUID" behavior: the witness lives only in the header.
- `validateTaskTerminalWrite` and `loadStatus` read only header fields. Do
  not make them assemble executions.
- `ON DELETE CASCADE` requires `foreign_keys=ON`. `SQLiteOpenOptions` enables
  it by default; verify it with a test.
- **Payload GC.** Never delete a payload that any execution row or nested
  ref in the same root still references. The checks run inside the same
  transaction.

## Tests

`SQLiteRuntimeExecutionRowsTests.swift`:

- Save and load a 3-execution session → equal sessions. `session_json` has no
  `executions` key and has the marker.
- Two executions with identical payloads → one payload row.
- Update one execution → its old payload row is deleted, unless another
  execution shares it.
- Nested invocation reservation plus child terminal → the child execution
  payloads deduplicate against the child's own rows (the payload count
  equals the child's execution payloads plus header/root/diagnostics). The
  rebuilt child snapshot equals the original.
- A legacy inline snapshot (insert it the generation-10 way, in raw SQL)
  loads equal. `convertLegacySession` converts it, and it loads equal
  again.
- A legacy embedded nested row is readable, and `convertLegacyNestedInvocation`
  converts it.
- Deleting the snapshot row cascades to the execution rows.
- `releaseUnreferencedPayloads` returns the freed bytes.
- A terminal save after a payload was orphaned (a hand-inserted orphan
  payload row in the same root) → that row is gone after the save. An orphan
  in another root is untouched.

`RuntimePersistenceBoundedWriteTests.swift`:

- A 500-step session saved after each step through `save(_:)` with the
  observer:
  - `boundBytes` of save 500 ≤ 1.5 × save 50 (each step has a similar-size
    payload);
  - the database file growth over saves 451-500 ≤ 1.5 × the growth over
    saves 51-100.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build' > tmp/efficient-history/eh-05-session-rows/build.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "SQLiteRuntimeExecutionRowsTests|RuntimePersistenceBoundedWriteTests|SQLiteRuntimeSchemaMigrationTests|SQLitePersistenceSessionExistsTests|RuntimeSnapshotDatesTests|WorkflowPreservedHistoryTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|PrivateWorkflowTests|WorkflowRuntimePersistence"' > tmp/efficient-history/eh-05-session-rows/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0. The four `PrivateWorkflowTests` fast-path and fence tests
pass, which is the CI canonical-persistence suite set
(`.github/workflows/private-workflow-regression.yml:98`).

## Done criteria

- [ ] `grep -n "riela_snapshot_execution_parts" Sources/RielaCore` → no match,
      and `grep -n 'String(repeating: ", ?, jsonb(?)"' Sources/RielaCore` → no
      match (the per-key fast-path patch loop is gone). A load-side
      `jsonb_set(session_json,'$.executions',…)` assembly is allowed. The eh-02
      `recordPinIfNeeded` call is still present, and
      `grep -c "recordForeignPinIfNeeded" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
      still prints `2`.
- [ ] The pinned API and tables exist.
- [ ] W2b gate: the full `SQLiteRuntimeSchemaMigrationTests` and
      `PrivateWorkflowTests` suites pass inside the focused run, including
      the four fast-path/fence tests named in the sharedPathNotes. Every item
      in `tmp/efficient-history/wave-W2a/handover-eh-05.md` is listed in the
      progress log as resolved, with its passing log line.
- [ ] All listed tests pass. Any `PrivateWorkflowTests` fixture edit is
      listed in the progress log with a before/after diff summary, and no
      assertion was edited.
