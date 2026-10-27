# eh-06-cli-session-envelope: one canonical session copy; CLI records become envelopes

```json
{
  "planId": "eh-06-cli-session-envelope",
  "planPath": "impl-plans/active/efficient-history-06-cli-session-envelope.md",
  "dependsOn": ["eh-05-session-rows", "eh-04-definition-history"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift",
    "Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift",
    "impl-plans/progress/eh-06-cli-session-envelope.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §5, "One source of truth". In production,
`cli_workflow_sessions.record_json` held a second full copy of every session
(12.2 GB).

Current code (`Sources/RielaCLI/CLIWorkflowSessionStore.swift`):

- `PersistedCLIWorkflowSession {workflowName, session, resolution,
  mockScenarioPath?, runtimeVariables?}` (`:5-25`).
- `upsertRecord` (`:448-469`) writes the full record with `.iso8601` dates
  (`:471-475`).
- The table (`:425-438`) has generated columns `workflow_name`
  (`$.workflowName`), `workflow_id` and `status` (from `$.session.*`).
- The combined save `save(_:runtimeSnapshot:)` (`:147-172`) runs one
  transaction for both stores.
- Readers:
  - `read`, `load`, `loadStrictReadOnly` (`:185-236`);
  - `loadAll` (`:238-250`);
  - `list` (`:333-369`);
  - `observePersistedExecutionIdentities` (`:319-331`, `json_each(record_json,'$.session.executions')`);
  - `seedRuntimeStoreFromPersistedCLIState` (`:572-616`).
- Embedded and private runs write no CLI row. Keep that.
- Inherited from eh-02 (wave 1): `openDatabase(readOnly:strictReadOnly:)`
  (~`:411`) already passes
  `options: readOnly ? .readOnlyDefault : .writableRuntimeStoreDefault`.
  That line must stay byte-identical (EH5-F2: the CLI store is the first
  opener of the runtime file for every `riela workflow run`).
- Definition pins (design §4, EH5-F3): the runtime store's `save(snapshot, in:)`
  runs inside this file's `db.transaction`, so only the same-store pin hook
  runs there. A foreign-store pin must be written by
  `WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot:sessionStoreRoot:)`
  (eh-04) BEFORE this file opens its transaction.

## Non-goals

- No schema rebuild of `cli_workflow_sessions`. The generated columns must
  keep working through the stub.
- No change to callers' API: `PersistedCLIWorkflowSession` keeps its fields,
  and `session` stays non-optional in memory.
- Retention (`TerminalRetention*.swift`) belongs to eh-07, and conversion
  orchestration to eh-10.

## Pinned contract (eh-07 and eh-10 depend on it)

**New-row `record_json` envelope:**

```
{"workflowName", "resolution", "mockScenarioPath"?, "runtimeVariables"?,
 "sessionStorage": "canonical",
 "session": {"sessionId", "workflowId", "status", "updatedAt"}}
```

**API:**

```swift
func legacyFullRecordIds(limit: Int) throws -> [String]   // rows without sessionStorage == "canonical"
func convertLegacyRecord(sessionId: String) throws -> Bool // caller holds the execution lock; canonical snapshot wins on conflicting status
enum CLIWorkflowSessionStoreError: case canonicalSnapshotMissing(sessionId: String)  // add to the existing error type
```

## File-level changes

- **Foreign pin pre-call (EH5-F3).** In BOTH internal `in db:` overloads
  `save(_:runtimeSnapshot:in:runtimeStore:)` and
  `save(_:runtimeSnapshot:appendingWorkflowMessages:in:runtimeStore:)`
  (`:147-172`), add
  `try WorkflowDefinitionPins.recordForeignPinIfNeeded(snapshot: snapshot, sessionStoreRoot: runtimeStore.rootDirectory)`
  after `validate(record:snapshot:)` and BEFORE `db.transaction`. The public
  overloads (`:94-145`) delegate to these, so they are covered; do not add a
  second call there. If `rootDirectory` is not readable on the runtime store,
  pass `canonicalRuntimeStoreRoot(sessionStoreRoot: rootDirectory)`. Any new
  save path this plan adds (for example the CLI-only `save(_:)` that now
  writes the snapshot too) gets the same pre-call before its transaction.
- **`upsertRecord`.** Encode the envelope instead of the full session.
  - Every save path that writes a CLI row must also write the canonical
    snapshot in the same transaction:
    - `save(_:runtimeSnapshot:)` already does;
    - a CLI-only `save(_:)` with a full session builds a
      `WorkflowRuntimePersistenceSnapshot` from `record.session`, the same
      way `seedRuntimeStoreFromPersistedCLIState` does, and saves both in one
      transaction.
- **Reads** (`read`, `load`, `loadStrictReadOnly`, `loadAll`, `list`):
  - Decode the envelope.
  - When `sessionStorage == "canonical"`, fill `session` from the canonical
    store (`SQLiteWorkflowRuntimePersistenceStore` load) in the same read
    transaction.
  - A missing snapshot throws `canonicalSnapshotMissing`. It must surface
    through the existing decode-resilience reporting, as an unreadable row
    and not a crash. Imitate how `CLIWorkflowSessionStoreResilienceTests`
    expects corrupt rows to be reported.
  - Legacy full rows decode as today.
- **`list` performance.** List summaries need only the stub fields plus the
  data the list already shows. If `list` currently needs the full session,
  load the canonical header without executions. Do not assemble every
  session's executions for a list.
- **`observePersistedExecutionIdentities`.** Call
  `SQLiteWorkflowRuntimePersistenceStore.executionIdentities(sessionId:)`
  (from eh-05) for envelope rows, and keep the `json_each` path for legacy
  rows.
- **`convertLegacyRecord`:**
  1. In `BEGIN IMMEDIATE`, read the legacy full record.
  2. Ensure the canonical snapshot exists, seeding it from the record if it
     is absent.
  3. Rewrite the row as an envelope. The stub status comes from the
     canonical snapshot.

## Pitfalls

- **eh-02 line.** Do not change the `openDatabase` options line set by eh-02.
  Record its hash before and after your edits; it must not change.
- **Foreign pin order.** Never call `recordForeignPinIfNeeded` inside
  `db.transaction`, and never call it from `upsertRecord` or other helpers
  that run in a transaction.
- **Dates.** The stub `updatedAt` uses the same `.iso8601` encoder as the
  rest of `record_json`. Do not mix in `RuntimeSnapshotDates`.
- **Generated columns.** `status` comes from `$.session.status`. The stub
  must be rewritten on every save, together with the snapshot.
- **Reconcile writes.** `SessionReconcileCommand` saves through
  `save(record, runtimeSnapshot:)`. It must keep working unchanged.
- **Status projections.** The `nonterminalOrConflictingStatus` protection
  compares the CLI and snapshot statuses. Because envelope and snapshot are
  written together, they agree.

## Tests (`CLIWorkflowSessionEnvelopeTests.swift`)

- Save a 3-execution session through `save(_:runtimeSnapshot:)`:
  - `length(record_json)` < 1 KB;
  - `json_type(record_json,'$.session.executions')` IS NULL;
  - `load` returns a session equal to the original;
  - the generated `status` column equals the session status.
- A legacy full row inserted with raw SQL loads equal, and
  `convertLegacyRecord` turns it into an envelope.
- A legacy row whose status conflicts with the canonical snapshot →
  converted with the canonical status.
- An envelope whose canonical snapshot is deleted → reported unreadable with
  `canonicalSnapshotMissing`; `list` still returns the other rows.
- `observePersistedExecutionIdentities` returns the same IDs for envelope
  and legacy rows.
- Update the existing `CLIWorkflowSessionStoreResilienceTests` fixtures that
  hand-edit `record_json`, keeping their assertions.
- Foreign pin through the CLI path: CLI session store A, a definition store
  B (imported through `WorkflowDefinitionStore`), and a snapshot with
  `definitionSource {kind: store, storeRoot: B, versionId}`. While another
  connection holds `BEGIN IMMEDIATE` on B (short busy timeout),
  `save(record, runtimeSnapshot:)` throws and A has no CLI row and no
  snapshot row. After release, the save succeeds and B has the pin row.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift test --filter "CLIWorkflowSessionEnvelopeTests|CLIWorkflowSessionStoreResilienceTests|SessionReconcileCommandTests|WorkflowCommandLivePersistence|SessionRecoveryHydrationScopeTests|RuntimeStoreFirstOpenerAutoVacuumTests|PrivateWorkflowTests|WorkflowCommandSessionDiscoveryTests"' > tmp/efficient-history/eh-06-cli-session-envelope/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/CLIWorkflowSessionStore.swift Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift'
```

Expected: exit 0, with every suite executed.

## Done criteria

- [ ] New rows contain no `$.session.executions`, proven by the test.
- [ ] The pinned API exists.
- [ ] `grep -n "recordForeignPinIfNeeded" Sources/RielaCLI/CLIWorkflowSessionStore.swift`
      shows a call before `db.transaction` in each `in db:` save overload
      (and in any new save path). `grep -n "writableRuntimeStoreDefault" Sources/RielaCLI/CLIWorkflowSessionStore.swift`
      still matches the eh-02 line.
- [ ] The listed suites pass. The progress log is complete.
