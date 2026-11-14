# CLI Session Store Decode Resilience

## Status and issue

- Workflow mode: `issue-resolution`
- Issue: title-only reference, “Make CLIWorkflowSessionStore skip undecodable
  record_json rows instead of aborting the command”
- Primary implementation boundary:
  `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- Regression-test boundary:
  `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`
- Explicitly protected file: `Sources/RielaCLI/RielaCommand.swift`

## Problem

`cli_workflow_sessions.record_json` stores the full
`PersistedCLIWorkflowSession`. Adding a required Codable field can make an
older row valid JSON but undecodable by the current model. Today
`CLIWorkflowSessionStore.load(sessionId:)`, `loadAll()`, and `list(...)`
propagate that decode error. A single incompatible row can therefore prevent
workflow-run startup, session discovery, status, resume, and rerun from using
otherwise valid rows.

The store must tolerate incompatibility at the record boundary. It must not
make `WorkflowResolutionOptions.includeDeactivated` optional or defaulted, and
it must not rewrite or delete incompatible rows.

## Behavioral contract

### Scan reads

`loadAll()` and `list(workflowName:status:limit:)` decode each selected
`record_json` independently:

1. Query failures and schema/open failures still throw.
2. A record that decodes successfully is returned in the existing SQL order.
3. A record whose `PersistedCLIWorkflowSession` decode fails is omitted.
4. After all selected rows are examined, the operation emits one warning when
   at least one record was omitted.
5. No warning is emitted when every selected row decodes.

`list(...)` continues to apply its SQL predicates and bounded `LIMIT` before
decoding. It may consequently return fewer valid records than the requested
limit. It must not issue compensating queries.

### Targeted read

`load(sessionId:)` keeps its non-optional API and existing not-found error
contract:

1. An absent row throws `CLIWorkflowSessionStoreError.notFound` without a
   decode warning.
2. A present, decodable row is returned.
3. A present row whose full record cannot be decoded emits one skipped-record
   warning and then throws `CLIWorkflowSessionStoreError.notFound`.
4. Invalid session IDs, database failures, and query failures retain their
   current errors.

Treating an incompatible targeted record as not-found prevents Codable details
from leaking through command surfaces while the warning distinguishes the
condition operationally.

### Warning contract

The store owns an injectable `@Sendable (String) -> Void` warning sink and
remains `Sendable`. The default sink writes a single newline-terminated line to
`FileHandle.standardError`.

The stable message shape is:

```text
warning: skipped N unreadable CLI session record(s)
```

Aggregation is per public read invocation. `N` is the number of selected rows
whose full-record decode failed; there is no per-record output. The sink is a
diagnostic side channel only and does not alter returned records or errors.

## Read data flow

```text
SQLite query
  -> selected raw record_json values
  -> independent full-record decode
  -> valid-record accumulator + skipped counter
  -> one aggregate warning when skipped > 0
  -> return valid records
```

The read flow executes no `DELETE`, `UPDATE`, upsert, schema repair, or record
rewrite. Stored incompatible rows remain available for offline inspection or a
future explicit migration.

## Session identity and numbering

Session identity allocation must use raw indexed columns, not successful
full-record decoding. The current code does not yet satisfy that boundary:

- `seedRuntimeStoreFromPersistedCLIState` in
  `Sources/RielaCLI/CLIWorkflowSessionStore.swift` iterates `loadAll()`.
- `InMemoryWorkflowRuntimeStore.seedSession(_:)` in
  `Sources/RielaCore/RuntimeStore.swift` calls
  `MonotonicWorkflowRuntimeIDGenerator.noteExistingSessionId`.
- Therefore an unreadable row omitted by `loadAll()` is also omitted from the
  monotonic counter. If it has the highest suffix, a later run can allocate
  the same `session_id`.
- `Sources/RielaCore/RielaDataGarbageCollector.swift` reads raw `session_id`,
  but only for garbage collection; that read does not seed allocation.

The required allocation design is an independent raw-column identity scan of
`cli_workflow_sessions.session_id` and `workflow_id`, followed by direct
counter observation without inserting placeholder sessions into the in-memory
runtime store. Valid full records are then seeded through the resilient
`loadAll()` path. This requires a narrow runtime-store or ID-generator
observation seam; fabricating partial `WorkflowSession` values is rejected
because it would expose incompatible rows as usable runtime sessions.

The intake constraint limits edits to
`Sources/RielaCLI/CLIWorkflowSessionStore.swift` and its tests, while the
required direct observation seam belongs to
`Sources/RielaCore/RuntimeStore.swift`. Implementation must not claim the
numbering acceptance signal until the scope question in
`design-docs/user-qa/qa-cli-session-store-decode-resilience.md` is resolved.

## Validation and regression coverage

The regression fixture uses `RielaCLITemporaryDirectory`, saves one current
record through `save(_:)`, and inserts one valid-JSON but incompatible
`record_json` directly with `jsonb(?)`. The incompatible object omits
`WorkflowResolutionOptions.includeDeactivated`; production decoding remains
strict.

Assertions cover:

- `loadAll()` returns only the valid record and emits one count-1 warning.
- `list()` returns only the valid record and emits one count-1 warning.
- `load(badId)` emits one count-1 warning and throws
  `CLIWorkflowSessionStoreError.notFound`.
- The raw table still contains both rows after all reads.
- Warning capture is concurrency-safe and does not scrape process stderr.
- An unreadable highest-numbered row cannot cause the next session ID to reuse
  an existing raw `session_id`.
- Runtime seeding retains all valid sessions and excludes incompatible records
  as session objects.

Tests and ad-hoc stores must remain under temporary directories and must never
open the developer’s real `~/.riela` store.

## Rollout constraints

- No database migration is required.
- No compatibility decoder is added to
  `WorkflowResolutionOptions.includeDeactivated`.
- Existing JSONB storage and scalar filtering columns remain unchanged.
- `Sources/RielaCLI/RielaCommand.swift` remains unchanged.
- Warning volume is bounded to one line per affected read invocation.
- Existing unrelated `DaemonWorkflowNodePatchTests` and agent-VM
  interleaved-submit flakes are not treated as regressions.

## Verification

```bash
swift build
swift test --filter RielaCLITests.CLIWorkflowSessionStoreResilienceTests
swift test --filter WorkflowCommandSessionDiscoveryTests
swift test --filter WorkflowCommandLivePersistenceTests
swift test --filter CLIWorkflowSessionResolutionTests
git diff --check
git diff -- Sources/RielaCLI/RielaCommand.swift
rg -n "DELETE|UPDATE" Sources/RielaCLI/CLIWorkflowSessionStore.swift
```

The final two checks are review evidence: `RielaCommand.swift` must have no
diff, and any mutation statement reported by `rg` must be confirmed to remain
outside the read paths.
