# DS179-01 Definition Store Core (RielaCore)

**planId**: `ds179-01-store-core`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy + (A) whole-workflow update + (B) improvement node
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §3, §5, §6, §13 (accepted by Step 3)
**dependsOn**: none (wave 1 of the serial chain 01→02→03→04→05→07→06)
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-01-store-core.md`

## Intent and context

Add the SQLite definition store to the runtime records database. Add the
session pin field and thread it through session creation. Later plans build
on these:

- the bundle document and operations service (02)
- CLI service resolution (03)
- the CLI commands (04)
- GraphQL (05)

This plan must pin every shared type below exactly. Later plans depend on
the names and shapes.

Repository facts:

- The runtime records DB is `SQLiteWorkflowRuntimePersistenceStore`
  (`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`):
  - `schemaGeneration` is 9 at `:115`
  - `schemaMigrations` is at `:127`
  - `discardIncompatibleStoreIfNeeded` is at `:179`
  - `openDatabase` is at `:686`
  - `ensureSchema` is at `:708`
- The SQLite wrapper is `Sources/RielaSQLite/SQLiteDatabase.swift`.
  `transaction(begin: "BEGIN IMMEDIATE", _:)` is at `:207`; `execute` and
  `query` are also there.
- Canonical JSON and sha256: `Sources/RielaCore/JSONCanonical.swift`
  (`JSONCanonical.encode`, `JSONCanonical.sha256Hex`). Reuse these; do not
  write a new canonicalizer.
- The session record is `WorkflowSession` (`Sources/RielaCore/RuntimeSession.swift:383`).
  It has a custom `init(from:)` that uses `decodeIfPresent` for optional
  fields such as `generatedWorkflow` (`:517`). Imitate it.
- Session creation input is `WorkflowSessionCreateInput`
  (`Sources/RielaCore/RuntimeStore.swift:109`). The in-memory creation is at
  `RuntimeStore.swift:467`. The run request is `DeterministicWorkflowRunRequest`
  (`Sources/RielaCore/DeterministicWorkflowRunner.swift:4`).
- Callees: `ResolvedWorkflowCallee` (`Sources/RielaCore/WorkflowCalleeResolution.swift:6`)
  is consumed at:
  - `DeterministicWorkflowRunner+CrossWorkflow.swift:23, :83`
  - `DeterministicWorkflowRunner+Fanout.swift:240`
  - `DeterministicWorkflowRunner+NestedPublication.swift:120`

  The child session is created in `DeterministicWorkflowRunner+NestedReservations.swift:288`.
  Root sessions are created in `DeterministicWorkflowRunner+Recovery.swift:31, :142`.
- Migration pattern: `SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`
  (`addGeneration4NestedRecoveryReason`, `createGeneration3NestedInvocationSchema`).

## Non-goals

- No bundle or document code. That is plan 02.
- No CLI, GraphQL, or app changes.
- Do not change the memory DB generation or the routine store generation.
- Do not add per-prompt blob rows, activation, fork, or workspace scopes.
- Do not change `WorkStore` (`RielaWork`).

## Pinned contract (exact public names; plans 02-05 depend on them)

All types go in a new file, `Sources/RielaCore/WorkflowDefinitionStore.swift`.
Every type is `public`, `Codable`, `Equatable` and `Sendable`.

- `enum WorkflowDefinitionOperation: String { case seed, `import`, forceUpdate, updatePrompt, update, restore }`.
  `update` is the whole-workflow store edit from design §5. It does not
  move `last_file_version_id`.
- `enum WorkflowDefinitionActorKind: String { case user, cli, api, improvementNode }`.
  There is no `addon` case (design §3, QA Q3).
- `struct WorkflowDefinitionActor { var kind: WorkflowDefinitionActorKind; var id: String? }`
- `enum WorkflowDefinitionEvidenceKind: String { case session, stepExecution, review }`
- `struct WorkflowDefinitionEvidenceRef { var kind: WorkflowDefinitionEvidenceKind; var id: String }`.
  Add `static func parse(_ token: String) throws -> Self` for the `kind:id`
  form. It rejects an empty id or an unknown kind.
- `enum WorkflowDefinitionApprovalState: String { case applied }`
- `struct WorkflowDefinitionDiffEntry { enum Op: String { case add, remove, replace }; var path: String; var op: Op; var before: JSONValue?; var after: JSONValue? }`
- `struct WorkflowDefinitionOverwrittenChanges { var sinceVersionId: String; var auditIds: [String]; var diff: [WorkflowDefinitionDiffEntry] }`
- `struct WorkflowDefinitionHead { workflowName, currentVersionId, lastFileVersionId: String; revision: Int; sourceDirectory: String; sourceScope: String; createdAt, updatedAt: Date }`
- `struct WorkflowDefinitionVersion { versionId, workflowName: String; parentVersionId: String?; documentDigest: String; operation: WorkflowDefinitionOperation; sourceDirectory, sourceScope, provenance: String; actor: WorkflowDefinitionActor; createdAt: Date }`
- `struct WorkflowDefinitionAuditRecord { auditId: String; createdOrder: Int; workflowName: String; operation; versionId: String; previousVersionId: String?; targetNodeId, targetField: String?; beforeDigest: String?; afterDigest: String; diff: [WorkflowDefinitionDiffEntry]; reason: String; evidence: [WorkflowDefinitionEvidenceRef]; actor; approvalState; overwrittenChanges: WorkflowDefinitionOverwrittenChanges?; createdAt: Date }`
- `struct WorkflowDefinitionSource { enum Kind: String { case store, file }; var kind: Kind; var workflowName: String; var versionId: String?; var storeRoot: String?; var digest: String; var sourcePath: String?; var sourceScope: String? }`.
  `storeRoot` is the absolute session-store root that holds the pinned
  version. It is set only for `kind store`, and it can differ from the
  session's own store under `auto` scope (design §3).
- `struct WorkflowDefinitionWrite`, the input to commit:

  ```
  workflowName; operation; documentData: Data; documentDigest: String;
  sourceDirectory; sourceScope; provenance; actor; reason: String;
  evidence; targetNodeId?; targetField?; diff; overwrittenChanges?;
  expectedCurrentVersionId: String?
  ```

  `expectedCurrentVersionId` is nil only for a head-creating write (seed or
  first import).
- `enum WorkflowDefinitionCommitOutcome { case created(WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord); case alreadyRegistered(WorkflowDefinitionHead) }`
- `struct WorkflowDefinitionStoreError: Error, Equatable, CustomStringConvertible { var code: Code; var message: String }`.
  `Code` has these cases: `missingReason`, `headExists`, `headMissing`,
  `staleHead`, `versionNotFound`, `invalidEvidence`, `storeUnavailable`.
- `struct WorkflowDefinitionStore` with `init(rootDirectory: String)`. It
  opens the same DB file as `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`,
  through the persistence store's open and ensure-schema path. Its methods:
  - `func head(workflowName: String) throws -> WorkflowDefinitionHead?`
  - `func version(versionId: String) throws -> WorkflowDefinitionVersion?`
  - `func blob(digest: String) throws -> Data?`
  - `func current(workflowName: String) throws -> (head: WorkflowDefinitionHead, version: WorkflowDefinitionVersion, document: Data)?`.
    It reads all three in a single read transaction.
  - `func history(workflowName: String, nodeId: String?, limit: Int?) throws -> [WorkflowDefinitionAuditRecord]`.
    Results are newest first (`created_order DESC`).
  - `func auditRecords(workflowName: String, afterVersionId: String) throws -> [WorkflowDefinitionAuditRecord]`.
    It returns the audit rows created after the given version's audit row.
    It exists for overwritten-changes computation.
  - `func commit(_ write: WorkflowDefinitionWrite) throws -> WorkflowDefinitionCommitOutcome`
- In a new file `Sources/RielaCore/WorkflowDefinitionDiff.swift`:
  `enum WorkflowDefinitionDiff { static func compute(before: JSONValue, after: JSONValue) -> [WorkflowDefinitionDiffEntry] }`.
- `WorkflowSession.definitionSource: WorkflowDefinitionSource?`,
  `WorkflowSessionCreateInput.definitionSource`,
  `DeterministicWorkflowRunRequest.definitionSource`, and
  `ResolvedWorkflowCallee.definitionSource`. All are optional and default
  to nil in every init.

## File-level changes

1. **`Sources/RielaCore/WorkflowDefinitionStoreSchema.swift` (new).**
   Define `enum WorkflowDefinitionStoreSchema { static func create(in: SQLiteDatabase) throws }`
   with idempotent `CREATE TABLE/INDEX/TRIGGER IF NOT EXISTS`:
   - `definition_blobs(digest TEXT PRIMARY KEY, bytes BLOB NOT NULL, size INTEGER NOT NULL, created_at TEXT NOT NULL)`
   - `definition_versions(version_id TEXT PRIMARY KEY, workflow_name TEXT NOT NULL, parent_version_id TEXT, document_digest TEXT NOT NULL REFERENCES definition_blobs(digest), operation TEXT NOT NULL, source_directory TEXT NOT NULL, source_scope TEXT NOT NULL, provenance TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT, created_at TEXT NOT NULL)`,
     plus the index `(workflow_name, created_at)`
   - `definition_heads(workflow_name TEXT PRIMARY KEY, current_version_id TEXT NOT NULL, last_file_version_id TEXT NOT NULL, revision INTEGER NOT NULL, source_directory TEXT NOT NULL, source_scope TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`
   - `definition_change_audit(created_order INTEGER PRIMARY KEY AUTOINCREMENT, audit_id TEXT NOT NULL UNIQUE, workflow_name TEXT NOT NULL, operation TEXT NOT NULL, version_id TEXT NOT NULL, previous_version_id TEXT, target_node_id TEXT, target_field TEXT, before_digest TEXT, after_digest TEXT NOT NULL, diff_json TEXT NOT NULL, reason TEXT NOT NULL CHECK (length(trim(reason)) > 0), evidence_refs_json TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT, approval_state TEXT NOT NULL, overwritten_changes_json TEXT, created_at TEXT NOT NULL)`,
     plus the index `(workflow_name, created_order)`
   - Triggers on `definition_versions` and `definition_change_audit`:
     `BEFORE UPDATE ... BEGIN SELECT RAISE(ABORT, '<table> is append-only'); END`
     and the same `BEFORE DELETE`.
   - `definition_blobs` gets `BEFORE UPDATE` abort only. Deletion stays
     possible for a future GC, but nothing in this run deletes blobs.
2. **`SQLiteWorkflowRuntimePersistenceStore.swift`.**
   - Set `schemaGeneration = 10` and update the doc comment ("Generation 10
     adds the definition store tables").
   - Append `SQLiteSchemaMigration(fromGeneration: 9) { try WorkflowDefinitionStoreSchema.create(in: $0) }`.
   - In `ensureSchema`, call `WorkflowDefinitionStoreSchema.create(in: db)`
     after `requireCompatibleSchemaGeneration`.
   - In `discardIncompatibleStoreIfNeeded`, set `isIncompatible = false` when
     `definition_heads` exists and `SELECT 1 FROM definition_heads LIMIT 1`
     returns a row. Do this check before deciding to delete. Normal open then
     reports the existing "no migration path" error.
3. **`SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`.** Add
   nothing there unless a helper fits better. Historical migrations must not
   call the current-schema builder, but a generation-10 table builder is the
   current one, so calling `WorkflowDefinitionStoreSchema.create` from the
   9→10 step is fine. Leave a comment saying a future generation 11 must
   freeze a copy.
4. **`WorkflowDefinitionStore.swift` (new).** Types plus the store.
   `commit` runs inside `db.transaction` (BEGIN IMMEDIATE) and does these
   steps in order:
   1. Reject a reason that is empty after trimming (`missingReason`).
   2. Read the head.
      - If `expectedCurrentVersionId == nil` and a head exists, return
        `.alreadyRegistered(head)` and write nothing. This is the
        insert-or-read seed race rule.
      - If `expectedCurrentVersionId != nil` and no head exists, throw
        `headMissing`.
      - If `expectedCurrentVersionId` differs from `head.currentVersionId`,
        throw `staleHead`.
   3. `INSERT OR IGNORE` the blob.
   4. Insert the version with `version_id = "defv-" + UUID().uuidString.lowercased()`
      and `parent_version_id` = the head's current version, or nil on create.
   5. Insert the audit record with `audit_id = "defa-" + uuid` and
      `approval_state = applied`. `before_digest` is the previous version's
      `document_digest`, or nil.
   6. Upsert the head with `revision + 1` (1 on create).
      `last_file_version_id` becomes the new version for
      `seed | import | forceUpdate` and is unchanged otherwise.

   Dates are stored as ISO8601 with milliseconds; reuse JSONCanonical's
   format. Encode JSON columns with `JSONCanonical.encode`.
   `history(nodeId:)` filters on `target_node_id = ?`.
5. **`WorkflowDefinitionDiff.swift` (new).** The deterministic structural
   walk:
   - Object keys are visited sorted by UTF-8 order (the same comparator as
     `JSONCanonical`).
   - Arrays are compared index by index. A tail beyond the shorter array
     becomes `add` or `remove` entries.
   - Leaves with differing values become `replace`.
   - Pointers follow RFC 6901: `~` is escaped as `~0` and `/` as `~1`.
   - The root pointer is `""`.
6. **`RuntimeSession.swift`.**
   - Add `definitionSource` to `CodingKeys`, the stored properties, the
     memberwise `init` (default nil), `init(from:)` (`decodeIfPresent`) and
     `encode`, if encode is custom.
   - Old snapshots without the key must decode.
7. **`RuntimeStore.swift`.** Add `definitionSource` to
   `WorkflowSessionCreateInput` (init default nil) and copy it into the
   created `WorkflowSession` at `:467`.
8. **`DeterministicWorkflowRunner.swift`.** Add `definitionSource` to the
   request (init default nil).
9. **`DeterministicWorkflowRunner+Recovery.swift`.** At both
   `WorkflowSessionCreateInput(` sites that create a root session from the
   request, pass `request.definitionSource`. Read both sites first: if one
   creates a session for a rerun or recovery, it must carry the request's
   value as well.
10. **`WorkflowCalleeResolution.swift`.** Add
    `ResolvedWorkflowCallee.definitionSource` (init default nil).
11. **`DeterministicWorkflowRunner+NestedReservations.swift`.** Add a
    `definitionSource: WorkflowDefinitionSource? = nil` parameter next to
    `generatedWorkflow` at `:257` and pass it into
    `WorkflowSessionCreateInput` at `:288`.
12. **`+CrossWorkflow.swift`, `+Fanout.swift` and `+NestedPublication.swift`.**
    Wherever a child session is reserved from a `callee`, forward
    `callee.definitionSource` to the reservation call. Follow each `callee`
    value to its reservation call; do not guess.

## Invariants

- Existing generation-9 stores open, migrate in place to 10, and keep all
  session rows.
- Stores below 9 behave as today and are discarded, unless they contain
  definition heads, which is impossible below 10.
- No method writes `definition_*` rows except `commit`.
- Audit and version rows can never be updated or deleted; the triggers
  enforce this.
- Session snapshots written before this change still decode, with
  `definitionSource == nil`.

## Pitfalls

- Do not bump `RoutineStore`, `SpecialistSupervisor` or memory generations.
- `discardIncompatibleStoreIfNeeded` opens read-only. Query `definition_heads`
  only after `tableExists`.
- `JSONValue` integers versus numbers: diff equality must use `JSONValue`'s
  `==`. Do not compare stringified values.
- Do not make `definitionSource` non-optional, and do not add a decode
  fallback that invents values.
- `commit` must do all of its steps in one transaction. A partial write
  (version without audit) must be impossible: inject a failing audit insert
  in a test and assert there is no version row.

## Tests to add

`Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift`:

- A fresh store gets all four tables, and `user_version == 10`.
- A generation-9 store opens, migrates to 10, and keeps its existing
  sessions:
  - Build a DB at the current schema, then drop the definition tables and
    triggers and set `PRAGMA user_version = 9`.
  - Expect the open to succeed, the tables to exist, `user_version == 10`,
    and the prior snapshot row to be intact.
- A create-head commit, then a second commit with `expected == nil`, returns
  `.alreadyRegistered` and the row count is unchanged.
- Two concurrent seed commits (two `Task`s on separate store instances)
  produce exactly 1 head, 1 version and 1 audit row.
- An update with a stale `expectedCurrentVersionId` throws `staleHead` and
  writes no rows.
- An empty or whitespace reason throws `missingReason` and writes no rows.
- `UPDATE definition_change_audit SET reason='x'` raises; so does `DELETE`
  on `definition_versions`.
- An identical document committed twice gives one blob row and two version
  rows.
- `history` returns newest first, `nodeId` filters, and `limit` applies.
- A store at generation 8 that contains a `definition_heads` row is NOT
  deleted by `discardIncompatibleStoreIfNeeded`. Build it by creating the
  definition tables plus a row, then setting `user_version = 8`.
- A commit with operation `update` on an existing head leaves
  `last_file_version_id` unchanged; a `forceUpdate` commit moves it.
- An `update` commit with a stale `expectedCurrentVersionId` throws
  `staleHead` and writes no rows. Plan 02 maps `staleHead` to the CLI code
  `definition_conflict`.
- `WorkflowDefinitionActorKind(rawValue: "addon") == nil`, and
  `WorkflowDefinitionActorKind(rawValue: "improvementNode")` decodes.
- `WorkflowDefinitionEvidenceRef.parse`: `"session:abc"` is valid;
  `"bogus:1"` and `"session:"` throw.
- `WorkflowDefinitionDiff`:
  - nested object replace gives the pointer `/a/b`
  - a key with `/` is escaped as `~1`
  - an array tail add or remove
  - identical documents give `[]`

`Tests/RielaCoreTests/WorkflowDefinitionSessionPinTests.swift`:

- A `WorkflowSession` JSON without `definitionSource` decodes to nil.
- A round-trip with a store source preserves every field, including
  `storeRoot`.
- `WorkflowSessionCreateInput(definitionSource:)` produces a session that
  carries the source (in-memory store `createSession`).
- A runner request with `definitionSource` set yields a root session with
  that source. Use the minimal deterministic local-adapter workflow pattern
  from existing `Tests/RielaCoreTests` runner tests; find one with
  `grep -ln "DeterministicWorkflowRunRequest(" Tests/RielaCoreTests`.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/01-build.log'`
  must exit 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionStoreTests|WorkflowDefinitionSessionPinTests|SQLiteRuntimeSchemaMigrationTests|SQLiteWorkflowMessageLogTests" 2>&1 | tee tmp/ds179/01-test.log'`
  must exit 0. Record testsRun and failureCount from the `Executed N tests,
  with M failures` line.
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkStoreTests 2>&1 | tee tmp/ds179/01-workstore.log'`
  must exit 0. It shares the generation guard.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <every changed .swift file>'`
  must print no violations.

Create `tmp/ds179/` first (`mkdir -p tmp/ds179`).

## Done criteria

- `grep -n "schemaGeneration: Int64 = 10" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
  matches.
- `grep -c "definition_change_audit" Sources/RielaCore/WorkflowDefinitionStoreSchema.swift`
  is at least 3.
- All verification commands exit 0.
- The progress log records each command, its exitStatus, testsRun,
  failureCount and the log path.

## Progress log expectations

Update `impl-plans/progress/ds179-01-store-core.md` after each file-level
change. Each entry records the file, the pre-edit and post-edit
`shasum -a 256`, and the reason. Before editing any shared path, re-read it
fresh. If it changed since your last read, note the drift and merge rather
than overwrite.
