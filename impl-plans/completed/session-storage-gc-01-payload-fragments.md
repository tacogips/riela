# sgc-01-payload-fragments: reduced execution payloads (inputSnapshot fragment dedup)

**Status**: Ready
**planId**: sgc-01-payload-fragments
**dependsOn**: none (wave W1)
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md §3 (and §9 RuntimePayloadFragmentTests)
**Progress log**: impl-plans/progress/sgc-01-payload-fragments.md
**Evidence root**: tmp/session-storage-gc/sgc-01-payload-fragments/

## Intent and context

`executions[].inputSnapshot` is about 93% of session bytes. Each loop iteration
re-embeds upstream accepted outputs inside it, so whole-execution payload
digests almost never repeat (848 distinct out of 862).

This plan stores new execution payloads in a reduced form:

- every `inputSnapshot` subtree of 1024 bytes or more becomes a content-addressed
  fragment row, deduplicated within the root session;
- its place in the tree becomes a reference object;
- readers expand the references in Swift, verify each digest, and fail closed.

Every existing on-disk form stays readable. Compression is explicitly NOT
used (design §3.7).

Relevant existing code:

- Writer: `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift:writeExecutionRows` (lines 86-137), `payloadJSON` (271-276), `sha256` (278-280), `releasePayloadIfUnreferenced` (139-149), `releaseUnreferencedPayloads(rootSessionId:in:)` (151-184), `persistNestedReferences` (186-223), `insertNestedPayload` (225-243).
- Reader: the same file, `assembledSessionData(from:sessionId:storageMarker:db:)` (369-392). Its callers are `load` (line 355) and `+WebSummaries.swift:webSessionDetail` (line 191). Nested reader: `+NestedInvocations.swift:hydratedNestedSnapshot` (lines ~670-720), which already verifies `sha256(json(p.bytes)) == digest` (`nestedDigest`, line 755).
- Schema: `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift` (`createTables`, `create`, `migrateToGeneration11`) and `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` (`schemaGeneration = 11`, `schemaMigrations`, the step `fromGeneration: 10`).
- Retention: `Sources/RielaCLI/TerminalRetentionExecutor.swift:629-630` deletes the payloads of a root. `Sources/RielaCLI/SessionRetentionTombstones.swift:25-35` holds the trigger pattern for `workflow_runtime_payloads`.

## Non-goals

- No zlib or other compression, and no change to `Package.swift` or
  `Packages/RielaMemory`.
- No bulk rewrite of existing generation-11 rows, and no conversion code.
  Legacy conversion already goes through `upsertSnapshot` → `writeExecutionRows`,
  so it produces the reduced form automatically.
- No changes to the header payload (`ordinal -1`), root output, diagnostics or
  loop-evidence nested payloads. Only execution payloads are reduced.
- Do not touch `+WebSummaries.swift`, `CLIWorkflowSessionStore.swift` or any
  SQL `json_extract(p.bytes, '$.stepId'|'$.status'|'$.importedFrom')` readers.
  They read top-level execution fields, which are never hoisted.
- No GraphQL, CLI or doc changes. Docs belong to sgc-05.

## File-level changes

### 1. `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift` (new)

Contract (pin these names; nothing else depends on them outside this plan):

```swift
struct RuntimePayloadFragment: Equatable, Sendable { let digest: String; let json: String }
struct RuntimeReducedPayload: Equatable, Sendable { let json: String; let digest: String; let fragments: [RuntimePayloadFragment] }
enum RuntimePayloadFragmentEncoder {
  static let minimumFragmentBytes = 1024
  static let referenceKey = "$rielaPayloadRef"
  static let markerKey = "_rielaPayloadRefs"
  static func reduce(_ execution: WorkflowStepExecution, minimumFragmentBytes: Int = minimumFragmentBytes) throws -> RuntimeReducedPayload
  static func expand(_ execution: inout JSONValue, fragments: [String: String]) throws  // removes markerKey; throws on missing/mismatched digest
}
```

Rules from design §3.1:

- **Full encoding.** The full text is produced exactly as `payloadJSON`
  produces it today (`JSONEncoder`, `.sortedKeys`, `RuntimeSnapshotDates`).
  Reuse the same encoder configuration. Do not add another one with different
  options.
- **Hoisting.**
  - Walk only `inputSnapshot`, bottom-up. Candidates are objects, arrays and
    strings, including the `inputSnapshot` value itself.
  - Hoist a candidate when its serialized text, after its own children have
    been replaced, is at least `minimumFragmentBytes` UTF-8 bytes.
  - A fragment's text is the sorted-keys serialization of the subtree, with its
    hoisted children already replaced by `{"$rielaPayloadRef":"<hex>"}`. Its
    digest is `JSONCanonical.sha256Hex(Data(text.utf8))`, the same function as
    `SQLiteWorkflowRuntimePersistenceStore.sha256`.
- **Marker.** When at least one value is hoisted, the execution's top-level
  `_rielaPayloadRefs` is the sorted, de-duplicated array of ALL fragment
  digests reachable from it, transitively.
- **Escape rule.** If `inputSnapshot` contains an object key
  `$rielaPayloadRef` at any depth, return the unreduced full text and no
  fragments.
- **Digest.** The returned `digest` is sha256 of the returned `json`, which is
  the reduced text.
- **Expansion.** Recursive substitution. Verify `sha256(fragmentText) ==
  digest` for every fragment used. Throw
  `WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime payload fragment missing or corrupt: <digest>")`
  when a fragment is missing or mismatched. Remove `_rielaPayloadRefs`.
- Imitate the JSON-tree handling in
  `+NestedInvocations.swift:hydratedNestedSnapshot` and its
  `nestedJSONObject` helpers.

### 2. `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`

- In `createTables`, add the table
  `workflow_runtime_payload_refs(root_session_id TEXT NOT NULL, parent_digest TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(root_session_id, parent_digest, digest)) WITHOUT ROWID`
  and `CREATE INDEX IF NOT EXISTS workflow_runtime_payload_refs_root_digest ON workflow_runtime_payload_refs(root_session_id, digest)`.
  Use `IF NOT EXISTS` for both.
- Add `static func migrateToGeneration12(in db: SQLiteDatabase) throws`. It
  runs only the DDL above (call `createTables`). It does no data rewrite.

### 3. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`

- Set `schemaGeneration = 12` and update its doc comment ("Generation 12 adds
  runtime payload fragment references").
- Append `SQLiteSchemaMigration(fromGeneration: 11) { try SQLiteRuntimeExecutionRowsSchema.migrateToGeneration12(in: $0) }`.
  Imitate the existing `fromGeneration: 10` entry.

### 4. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`

- **`writeExecutionRows`.** Replace `payloadJSON(execution)` and `sha256` with
  `RuntimePayloadFragmentEncoder.reduce`. Then, in the same transaction and in
  this order:
  1. `INSERT OR IGNORE` each fragment into `workflow_runtime_payloads`
     (`bytes = jsonb(?)`, `byte_count` = UTF-8 length of the fragment text).
  2. `INSERT OR IGNORE` the reduced execution payload.
  3. `INSERT OR IGNORE` one `workflow_runtime_payload_refs(root, parent_digest = executionDigest, digest = fragmentDigest)`
     row per fragment.
  4. Upsert the execution row, as today.

  Keep the `bytes` metric as the UTF-8 length of what is newly bound: the
  reduced text plus the fragment texts.
- **`releasePayloadIfUnreferenced(rootId:digest:in:)`.**
  1. Add a third `NOT EXISTS` on `workflow_runtime_payload_refs WHERE
     root_session_id=? AND digest=?`.
  2. Use `RETURNING digest`, or check the change count, to learn whether the
     row was actually deleted.
  3. Only if it was deleted: `DELETE FROM workflow_runtime_payload_refs WHERE
     root_session_id=? AND parent_digest=? RETURNING digest`, and call the same
     release for each returned child digest.

  Children are fragments, which carry no refs rows of their own, so the
  recursion is one level deep.
- **`releaseUnreferencedPayloads(rootSessionId:in:)`.**
  1. Delete unreferenced payloads (now also excluding digests referenced from
     `workflow_runtime_payload_refs`).
  2. Delete refs rows whose `parent_digest` no longer exists in
     `workflow_runtime_payloads` for that root.
  3. Delete fragments that became unreferenced.

  Return the total byte count of all deleted rows, as before. Do not loop
  unboundedly: two fixed rounds are sufficient by construction.
- **`persistNestedReferences`.** Execution payloads (the loop over
  `snapshot.session.executions`) go through `reduce`. Insert fragments and refs
  rows exactly as `writeExecutionRows` does, then insert the nested ref for
  the reduced execution digest via `insertNestedPayload`, or a sibling helper
  that accepts pre-reduced text. Header, rootOutput, diagnostics and
  loopEvidence stay unreduced.
- **`assembledSessionData`.** After the existing SQL assembly, and only if at
  least one assembled execution carries `_rielaPayloadRefs`:
  1. Collect the digests.
  2. Fetch `SELECT digest, json(bytes) AS payload FROM workflow_runtime_payloads WHERE root_session_id=? AND digest IN (…)`
     in chunks of at most 500 bindings, on the same `db` (the same read
     transaction).
  3. Expand each such execution.
  4. Re-encode the session JSON and return it.

  The root id is the root column of the execution rows, which equals the
  header's `rootSessionId ?? sessionId`. Read it from
  `workflow_runtime_executions.root_session_id` rather than re-deriving it.
  When no marker is present, the function must return exactly the same bytes
  as today, with no extra parse.

### 5. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`

- In `hydratedNestedSnapshot`, keep the existing digest check of each
  execution payload text. If the payload has `_rielaPayloadRefs`, fetch the
  fragments for `(root_session_id from the ref row, digests)` and expand them
  with `RuntimePayloadFragmentEncoder.expand` before appending.
- Make the reduced-text path match whatever `persistNestedReferences` now
  writes.

### 6. `Sources/RielaCLI/TerminalRetentionExecutor.swift`

- Next to `DELETE FROM workflow_runtime_payloads WHERE root_session_id=?`
  (line ~630), add the same delete for `workflow_runtime_payload_refs`, guarded
  by `db.tableExists("workflow_runtime_payload_refs")`.
- Delete the refs rows before the payloads. The order is not an FK
  requirement; it keeps the store consistent if the transaction aborts later.

### 7. `Sources/RielaCLI/SessionRetentionTombstones.swift`

- In `ensureSessionRetentionTriggers`, add INSERT/UPDATE guard triggers on
  `workflow_runtime_payload_refs`, keyed by `NEW.root_session_id`, with the
  same `RAISE(ABORT,'session payloads expired under terminal retention')`.
- Imitate the `workflow_runtime_payloads` block at lines 25-35, guarded by
  `tableExists`.

## Pitfalls (read before coding)

- **Text forms.** The digest of a fragment row must equal
  `sha256(json(bytes))` read back from SQLite. Store the exact text you
  hashed with `jsonb(?)`. Never hash a re-serialization. The existing nested
  check proves that `json(jsonb(text))` round-trips sorted-keys `JSONEncoder`
  output.
- **Determinism.** The same `WorkflowStepExecution` must always produce the
  same reduced text and digest. Iterate dictionary keys in sorted order when
  walking.
- **Flattened marker.** Fragments may contain `$rielaPayloadRef` objects that
  point to deeper fragments, but fragments never contain `_rielaPayloadRefs`.
  Only the execution payload lists every transitive digest, and refs rows
  always have the execution digest as their `parent_digest`.
- **Sharing.** Two executions that share a fragment must both have refs rows.
  Release must not delete a fragment while any other parent still lists it.
- **SQL readers.** Do not change `json_extract` readers, and do not move
  `stepId`, `status` or `importedFrom`.
- **Fail closed.** A missing fragment must throw. Never return an execution
  with unexpanded references, and never return a partially assembled session.
- **Fast path.** `writeExecutionRows(selected:)` is used for appends and
  changed indexes. The reduction must work on that path too.
- **Generation 12.** Older binaries refuse the store through the existing
  newer-generation error. Do not add a downgrade path.

## Tests

`Tests/RielaCoreTests/RuntimePayloadFragmentTests.swift` (new; imitate
`Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift` helpers
`snapshot(id:executions:date:)`, `execution(...)`, `temporaryDirectory()`,
`database(root:)`, `scalar`):

- The same execution reduced twice gives identical `json`, `digest` and
  `fragments`.
- An `inputSnapshot` containing the key `$rielaPayloadRef` gives unreduced
  text equal to `payloadJSON` and no fragments.
- A small `inputSnapshot` (under 1024 bytes) is not reduced, and its text is
  byte-equal to `payloadJSON`.
- **Benchmark (acceptance).** Build a synthetic loop session: at least 20
  iterations × 2 steps. The `inputSnapshot` of iteration k carries, in a
  `_rielaInput.messages` array, every prior upstream output, each a distinct
  object of at least 4 KiB.
  - Save it, then compute
    `stored = SUM(length(bytes))` over `workflow_runtime_payloads` for the root
    plus `SUM(length(root_session_id) + length(parent_digest) + length(digest))`
    over `workflow_runtime_payload_refs` for the root.
  - Compute `baseline` = the sum of UTF-8 lengths of the distinct
    `payloadJSON(execution)` texts.
  - Assert `baseline >= 5 * stored`. Log both numbers to the progress log.
- Round-trip: `load(sessionId:)` gives the saved session (`==`).
  `loadWebSessionDetail` returns the same session executions.
- A fragment row deleted with raw SQL makes `load` throw an error containing
  `runtime payload fragment missing or corrupt`. A fragment with corrupted
  bytes (the digest no longer matches) also throws.
- **Release.**
  - Replace one execution's `inputSnapshot` and save. The orphaned fragments
    and their refs rows are gone, while fragments shared with another execution
    remain.
  - Truncate the executions (a save with fewer executions). No orphan payload
    or refs row remains. Check with SQL: every refs `parent_digest` exists in
    payloads, and every fragment is referenced.
  - `releaseUnreferencedPayloads` returns the deleted byte total.
- **Nested.** A nested invocation persisted with a reduced child execution
  hydrates to an equal snapshot. Its fragments are shared with the child's own
  rows: there is no duplicate `(root, digest)` row, and the unique constraint
  holds.
- **Legacy reads.** A generation-11 full-text execution payload (insert one by
  hand with the old `payloadJSON` text and digest) and a legacy inline
  `session_json` both still load equal.
- **Migration.** A generation-11 database migrates to 12. The new table
  exists, the existing rows are unchanged (compare the `workflow_runtime_payloads`
  row count and digests before and after), and `stampedGeneration == 12`.

Updates:

- `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`: change the
  expected stamped generation from 11 to 12 at lines ~54, 116 and 142. Add
  `testGeneration11UpgradesTo12AddsPayloadRefsTable`.
- `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift` and
  `Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift`: update only
  the expectations that change because of fragments (statement counts,
  `boundBytes`, payload row counts). Keep the asserted bounds meaningful: a
  per-save cost must still not grow with store size. Explain each changed
  expectation in the progress log.

`Tests/RielaCLITests/RuntimePayloadFragmentReadParityTests.swift` (new). Byte
identity across the public read paths:

- **Fixture.** Build one `PersistedCLIWorkflowSession` plus runtime snapshot
  whose executions carry large, repeated `inputSnapshot` values. Write it into
  two temp stores:
  - store R through the normal `CLIWorkflowSessionStore.save(_:runtimeSnapshot:)`
    path, which produces the reduced form (assert that a
    `workflow_runtime_payload_refs` row exists);
  - store L as a legacy inline snapshot plus a legacy full CLI record.

  Imitate `Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift:insertLegacy`
  (line 489) and the legacy `session_json` rewrite in
  `SQLiteRuntimeExecutionRowsTests.testLegacyInlineSessionLoadsAndConvertsOnFirstSave`.
- **CLI output.** For each of `session status <id>`, `session export <id>`,
  `session logs <id>` and `session progress <id>` with
  `--session-store <store> --output json`, run
  `RielaCLIApplication().run([...])` (pattern in
  `Tests/RielaCLITests/SessionObservabilityCommandTests.swift`). Assert that the
  exit codes are equal and that stdout is byte-identical after replacing each
  store's root path with a placeholder.
- **Resume/rerun and GraphQL view inputs.** These must be equal across R and L:
  - `CLIWorkflowSessionStore.load` records;
  - `SQLiteWorkflowRuntimePersistenceStore.load` snapshots;
  - `loadWebSessionDetail`, which backs the GraphQL and web session views.

## Acceptance criteria (mechanically checkable)

- `rg -n "workflow_runtime_payload_refs" Sources/RielaCore Sources/RielaCLI`
  shows the schema, the writer, release, the reader, the retention delete and
  the triggers.
- `schemaGeneration` is 12, and the `fromGeneration: 11` step exists.
- The new and updated tests pass, and the benchmark assertion
  (`baseline >= 5 * stored`) passes with its numbers logged.
- No edits outside `writePaths`. Any other test that fails because of
  generation 12 is listed in the progress log for serial reconciliation.

## Verification (run in order; every log must end with `exit=0`)

Build cache: writes to `.build/` and `.swiftpm/` by these commands are
authorized and untracked. They are not part of `writePaths`, `sharedPaths` or
`artifactRoots`, and `artifactRoots` is intentionally empty. See the index
`impl-plans/active/session-storage-gc.md`, Shared execution rules, "Build
cache". Never block on them.

```
mkdir -p tmp/session-storage-gc/sgc-01-payload-fragments
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/session-storage-gc/sgc-01-payload-fragments/build.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-01-payload-fragments/build.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RuntimePayloadFragment|SQLiteRuntimeExecutionRows|RuntimePersistenceBoundedWrite|SQLiteRuntimeSchemaMigration|SQLiteWorkflowMessageLog|CLIWorkflowSessionEnvelope|CLIWorkflowSessionStoreResilience|TerminalRetentionTests|TerminalRetentionPlan|SessionMessageRetentionAdmission" 2>&1 | tee tmp/session-storage-gc/sgc-01-payload-fragments/test.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-01-payload-fragments/test.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCore/RuntimePayloadFragmentEncoder.swift Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift Sources/RielaCLI/TerminalRetentionExecutor.swift Sources/RielaCLI/SessionRetentionTombstones.swift Tests/RielaCoreTests/RuntimePayloadFragmentTests.swift Tests/RielaCLITests/RuntimePayloadFragmentReadParityTests.swift 2>&1 | tee tmp/session-storage-gc/sgc-01-payload-fragments/lint.log'
```

What each command must show:

- `build.log`: `exit=0`.
- `test.log`: `exit=0`, 0 failures, and the new test classes executed.
- `lint.log`: no new violations in changed lines. Compare against the HEAD
  copy if a violation already existed before this plan.

## Progress-log expectations

Record in `impl-plans/progress/sgc-01-payload-fragments.md`:

- the sha256 of each changed file, before and after;
- the benchmark numbers (`baseline`, `stored`, ratio);
- each command with its exit code and log path;
- every changed test expectation with its reason;
- any reconciliation item outside `writePaths`.
