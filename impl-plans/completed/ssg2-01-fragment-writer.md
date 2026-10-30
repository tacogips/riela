# ssg2-01-fragment-writer: fragment encoder, writer, release guard (switch off)

**Archived 2026-10-30 (session 564)**: accepted in the integration review of
sessions 562/563. Progress log: `impl-plans/progress/ssg2-01-fragment-writer.md`.

**planId**: ssg2-01-fragment-writer
**dependsOn**: none (wave W1)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§3.1 (encoding rule), §3.2 (storage; Release → Guard), §3.3 (digests), §3.5
(writers, write switch), §9 (Determinism, Escape rule, Terminal save keeps
fragments, Migration), §12 row (a)
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-01-fragment-writer.md` (new; do not read or continue `sgc-01`)
**Evidence root**: `tmp/ssg2/ssg2-01-fragment-writer/`
**writePaths**: `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift` (new), `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`, `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift` (verify only), `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` (verify only), `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift` (new), `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`, `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`, `impl-plans/progress/ssg2-01-fragment-writer.md`
**sharedPaths**: none

## Intent and context

About 93% of session bytes are `executions[].inputSnapshot`, which re-embeds
upstream outputs on every loop iteration. This plan adds the encoder that
hoists large `inputSnapshot` subtrees into content-addressed fragment rows,
and the writer that stores them plus `workflow_runtime_payload_refs` rows.
The writer is behind an internal switch that stays **off by default** in this
plan, so production behavior does not change yet. Readers that expand fragments come
in ssg2-02; full reference-aware release, the switch flip and the benchmark
come in ssg2-03.

This plan also adds the **release guard** (design §3.2 Guard): without it,
the run-end release deletes every fragment of a terminal root session
(`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:747`
`releaseAtRunEnd`, `:873-874` → `releaseUnreferencedPayloads`), because
fragments are referenced by neither `workflow_runtime_executions` nor
`workflow_nested_invocation_refs`.

Already present in the working tree (preserve; verify only):

- `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift`: the
  `workflow_runtime_payload_refs` table, its index and
  `migrateToGeneration12(in:)`.
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`:
  `schemaGeneration = 12` and the `fromGeneration: 11` step.
- `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift` and
  `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`: generation
  expectations already moved to 12 (and 13 for the future-generation case).

Code to imitate:

- `+SessionFamily.swift:writeExecutionRows` (lines 86-137): the insert
  pattern `INSERT OR IGNORE INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count) VALUES(?,?,jsonb(?),?)`.
- `+SessionFamily.swift:payloadJSON` (271-276) and `sha256` (278-280): the
  only allowed serializer (`JSONEncoder`, `.sortedKeys`,
  `RuntimeSnapshotDates.encoding`) and digest (`JSONCanonical.sha256Hex`).
- `+SessionFamily.swift:persistNestedReferences` / `insertNestedPayload`
  (186-245): nested execution payload writes.
- `Sources/RielaCore/JSONValue.swift` (`.integer(Int64)` and `.number(Double)`
  are distinct cases) for tree walking.

## Non-goals

- No reader or expansion changes (`assembledSessionData`,
  `hydratedNestedSnapshot`): ssg2-02.
- No cascade release (deleting refs rows by `parent_digest`), no switch flip,
  no benchmark: ssg2-03.
- No compression, no `Package.swift` change, no bulk rewrite of existing rows.
- Do not reduce header, root output, diagnostics, loop evidence or nested
  callee payloads. Only execution payloads.
- Do not touch `+WebSummaries.swift`, `CLIWorkflowSessionStore.swift`, any
  `json_extract(p.bytes, ...)` reader, or `Sources/RielaCLI/*`.

## Contract (pinned; ssg2-02 and ssg2-03 depend on it)

New file `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`:

```swift
struct RuntimePayloadFragment: Equatable, Sendable { let digest: String; let json: String }
struct RuntimeReducedPayload: Equatable, Sendable { let json: String; let digest: String; let fragments: [RuntimePayloadFragment] }
enum RuntimePayloadFragmentEncoder {
  static let minimumFragmentBytes = 1024
  static let referenceKey = "$rielaPayloadRef"
  static let markerKey = "_rielaPayloadRefs"
  static func reduce(fullJSON: String) throws -> RuntimeReducedPayload
}
extension SQLiteWorkflowRuntimePersistenceStore {
  @TaskLocal static var writesReducedExecutionPayloadsOverride: Bool?
  static let writesReducedExecutionPayloadsByDefault = false   // ssg2-03 flips this to true
  static var writesReducedExecutionPayloads: Bool { writesReducedExecutionPayloadsOverride ?? writesReducedExecutionPayloadsByDefault }
}
```

`fullJSON` is exactly `payloadJSON(execution)`. ssg2-02 adds an `expand`
function to this file; leave room but do not implement it.

## File-level changes

### 1. `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift` (new)

`reduce(fullJSON:)`, per design §3.1:

- Parse `fullJSON` into `JSONValue`. Walk only the top-level `inputSnapshot`
  value, bottom-up, visiting object keys in sorted order.
- Candidates: objects, arrays and strings, including `inputSnapshot` itself.
  Serialize a candidate (after its children were replaced) with a sorted-keys
  `JSONEncoder`. If the UTF-8 length is `>= minimumFragmentBytes`, it becomes
  a fragment with `digest = JSONCanonical.sha256Hex(text)` and its place
  becomes `{"$rielaPayloadRef":"<digest>"}`.
- Deduplicate fragments by digest. Add top-level `_rielaPayloadRefs`: the
  sorted, de-duplicated array of every fragment digest the payload needs,
  transitively (fragments themselves never carry `_rielaPayloadRefs`).
- **No-hoist case:** return `fullJSON` unchanged, `digest = sha256(fullJSON)`,
  no fragments. Byte-identical to today.
- **Escape rule:** if `inputSnapshot` contains an object key
  `$rielaPayloadRef` at any depth, return the no-hoist result.
- Otherwise return the reduced text serialized with the sorted-keys encoder
  and `digest = sha256(reducedText)`.
- The switch extension shown in the contract.

### 2. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`

- **`writeExecutionRows`.** When `Self.writesReducedExecutionPayloads` is
  true, call `RuntimePayloadFragmentEncoder.reduce(fullJSON: payloadJSON(execution))`;
  otherwise keep today's text and digest. With a reduced payload, in the same
  transaction and in this order: `INSERT OR IGNORE` each fragment row
  (`byte_count` = fragment UTF-8 length), `INSERT OR IGNORE` the execution
  payload, then `INSERT OR IGNORE INTO workflow_runtime_payload_refs(root_session_id,parent_digest,digest)`
  one row per fragment (`parent_digest` = execution digest), then the
  execution upsert as today. `bytes` (metric) = reduced text plus newly bound
  fragment texts.
- **Guard** in `releasePayloadIfUnreferenced` and
  `releaseUnreferencedPayloads` (both the `SELECT SUM` and the `DELETE`): add
  `AND NOT EXISTS (SELECT 1 FROM workflow_runtime_payload_refs AS f WHERE f.root_session_id = p.root_session_id AND f.digest = p.digest)`
  (in `releasePayloadIfUnreferenced`, bind the root and digest the same way as
  the existing two `NOT EXISTS`). No `tableExists` check is needed: every
  generation-12 store has the table (`createTables`). Do not add cascade
  deletes.
- **`persistNestedReferences`.** For the execution loop only, when the switch
  is on, reduce, insert fragments and refs rows under the child `rootId` as in
  `writeExecutionRows`, then insert the nested ref for the reduced execution
  text (adapt `insertNestedPayload` or add a sibling that takes pre-computed
  text and digest; the nested ref digest must be the reduced digest).

### 3. `Sources/RielaCore/SQLiteRuntimeExecutionRowsSchema.swift` and `+SchemaMigrations.swift`

Verify only. Change nothing unless a test proves a defect; record any change
with its reason.

## Pitfalls

- **Store the exact text you hashed** via `jsonb(?)`. Never hash a
  re-serialization. `sha256(json(bytes))` read back must equal the digest
  (the nested reader already relies on this round trip).
- **Determinism.** The same execution must always give the same text, digest
  and fragment list. Sort keys when walking; do not use dictionary iteration
  order.
- **Integers.** Keep `.integer` and `.number` distinct; never convert integers
  to `Double`.
- **The switch defaults to `false`.** Do not flip it here. Production must not
  write fragments before ssg2-03.
- **The guard is not optional.** Without it, any test that saves a terminal
  reduced root session loses its fragments.
- **Nested roots.** Nested execution fragments use the child snapshot's root
  id (`snapshot.session.rootSessionId ?? sessionId`), the same root as the
  nested ref rows.
- The fast path `writeExecutionRows(selected:)` must reduce too.

## Tests

New `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift` (imitate
helpers in `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`). Run
saves inside `SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true)`.
Check results with SQL only (no `load`; expansion arrives in ssg2-02):

- same execution reduced twice → identical `json`, `digest`, `fragments`;
- `inputSnapshot` smaller than 1024 bytes → output text byte-equal to
  `payloadJSON`, no fragments;
- `inputSnapshot` containing key `$rielaPayloadRef` → unreduced, no fragments;
- large repeated `inputSnapshot` → `_rielaPayloadRefs` present and sorted;
  every listed digest has a payload row; one refs row per (execution digest,
  fragment digest); `sha256(json(bytes)) == digest` for every fragment row;
- two executions sharing a subtree → one fragment row, two refs rows;
- **terminal save keeps fragments** (design §9): save a `completed` root
  session with a ≥ 1 KiB subtree (a) as a running→completed transition and
  (b) as a first save that is already `completed` → fragment row count and
  `SUM(byte_count)` of fragment rows are unchanged after the save, and no refs
  row points to a missing digest;
- switch off (default) → no refs rows and payload texts equal to
  `payloadJSON`;
- nested invocation persisted with the switch on → nested execution ref
  digest equals the reduced digest; fragments and refs rows exist under the
  child root.

`Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`: add
`testGeneration11UpgradesTo12AddsPayloadRefsTable` → a generation-11 database
with payload rows migrates to 12; the refs table and index exist; payload row
count and digests are unchanged; stamped generation is 12.

## Acceptance criteria

- `rg -n "writesReducedExecutionPayloadsByDefault = false" Sources/RielaCore` → one match.
- `rg -n "workflow_runtime_payload_refs" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`
  → writer inserts and the guard in both release functions.
- All tests above pass; the existing suites in the filter below still pass.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-01-fragment-writer
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-01-fragment-writer/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-01-fragment-writer/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RuntimePayloadFragmentWriter|SchemaMigration|SQLiteRuntimeExecutionRows|RuntimePersistenceBoundedWrite|SQLiteWorkflowMessageLog|CLIWorkflowSessionEnvelope|SessionStore|TerminalRetentionTests" 2>&1 | tee tmp/ssg2/ssg2-01-fragment-writer/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-01-fragment-writer/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RuntimePayloadFragmentEncoder.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift 2>&1 | tee tmp/ssg2/ssg2-01-fragment-writer/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-01-fragment-writer/lint.log; exit $s'
```

Evidence: `build.log` and `test.log` end with `exit=0`; `test.log` shows
`RuntimePayloadFragmentWriterTests` executed with 0 failures; `lint.log` ends
with `exit=0`. (`persistNestedReferences` lives in `+SessionFamily.swift`;
this plan does not edit `+NestedInvocations.swift`.)

## Progress log

Record in `impl-plans/progress/ssg2-01-fragment-writer.md`: pre/post sha256
of every changed file, each command with exit code and log path, every
acceptance item checked, and any out-of-plan failing test (for
reconciliation).
