# CLI Session Store Decode Resilience

## Status and issue

- Status: implemented and verified 2026-09-21
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
older row valid JSON but undecodable by the current model. Before this change,
`CLIWorkflowSessionStore.load(sessionId:)`, `loadAll()`, and `list(...)`
propagated that decode error. A single incompatible row could therefore prevent
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
full-record decoding. The original code did not satisfy that boundary:

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

The implemented allocation design is an independent raw-column identity scan of
`cli_workflow_sessions.session_id` and `workflow_id`, followed by direct
counter observation without inserting placeholder sessions into the in-memory
runtime store. Valid full records are then seeded through the resilient
`loadAll()` path. This requires a narrow runtime-store or ID-generator
observation seam; fabricating partial `WorkflowSession` values is rejected
because it would expose incompatible rows as usable runtime sessions.

The approved minimal observation seam belongs to
`Sources/RielaCore/RuntimeStore.swift`; the scope decision is recorded in
`design-docs/user-qa/qa-cli-session-store-decode-resilience.md`.

## Recovery hydration scope (issue #32, 2026-10-24)

- Status: design, ready for implementation planning
- Issue: tacogips/riela#32, "session resume of a maxStepsExceeded codex
  session stalls with no output and no backend child" (local copy
  `tmp/run/issue-32.md`). `session rerun` has the same symptom.
- Precedent: `impl-plans/fresh-run-identity-hydration.md` (#156, `fb912a5a`,
  `fca928cd`) made fresh runs metadata-only. It deliberately left resume,
  rerun and recovery on full hydration.

### Root cause (confirmed part)

`riela session resume` (`SessionCommands.swift:743`) and `session rerun`
(`:471`) call `makeSeededProductionRuntimeStore` with the default
`hydrateSessions: true`. `seedRuntimeStoreFromPersistedCLIState` then decodes
the whole store before the runner emits its first event:

- every CLI record (`loadAll()`), plus one canonical snapshot load with all
  `workflowMessages` for each record;
- every remaining canonical snapshot (`persistenceStore.loadAll()`).

`workflow run --resume` does the same, and its fail-closed wrapper then calls
`FailClosedSQLiteWorkflowRuntimeStore.hydrate()`, which runs a second full
`loadAll()` (`WorkflowRunCommand.swift:322-331`). The cost before the first
JSONL line is therefore O(entire store: sessions × executions × payload and
backend-event bytes), not O(target session). The stall scales with unrelated
history.

The report's ~2 s CPU over 15 minutes points to blocking rather than parsing.
That part was not reproduced on the current tree. It is recorded as residual
risk; this design adds no speculative change for it. The fix below removes
the unbounded pre-first-event work, and the regression test asserts that the
first event comes promptly. If a hung resume or rerun reproduces after the fix,
the implementer captures a process `sample` (stack) of it under `tmp/<task>/`
before closing #32. That captures the remaining blocking cause without
guessing at it here.

### Contract

1. `makeSeededProductionRuntimeStore(sessionStoreRoot:executionLocks:hydration:)`
   replaces `hydrateSessions: Bool` with a required
   `hydration: .none | .family(of: sessionId)`. There is no default, so every
   call site chooses explicitly. Call sites that pass
   `resumeSessionId`/`rerunFromSessionId` use `.family`. Fresh-run call sites
   (including `WorkflowPackageParityCommands.swift:449` if it never resumes)
   use `.none`.
2. Identity high-water marks are always metadata-only, in both modes:
   `observeStartupIdentities` plus `observePersistedIdentities`, with the
   existing stale-projection retry. Unrelated sessions therefore still advance
   the session, execution and communication counters, but are never decoded.
3. Family resolution uses the indexed canonical columns:
   `root = (SELECT root_session_id FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?)`,
   then every snapshot with `root_session_id = root` (index
   `idx_workflow_runtime_snapshots_root`), plus the target itself. The family
   covers what resume/rerun actually reads through the runtime store:
   - the target session and its messages (`resolveResumeEntry`,
     `resolveRerunEntry`, `rerunCarriedInbox`, preserved history);
   - reserved cross-workflow/fanout children that
     `recoverNestedInvocationsBeforeResuming` re-enters through
     `run(resumeSessionId: child)`;
   - a durable-supervisor reserved child snapshot with no CLI record yet,
     which is the reason for the comment at `CLIWorkflowSessionStore.swift:570-572`.

   A target that has only a CLI record and no canonical snapshot is a family
   of one.
4. Seeding order per family member does not change: the CLI record session
   (targeted `load(sessionId:)`) when present, otherwise the canonical
   snapshot, then that member's `workflowMessages`. Undecodable records keep
   the existing targeted-read warning and not-found contract above.
5. `FailClosedSQLiteWorkflowRuntimeStore.hydrate()` takes the same family id
   set instead of calling `loadAll()`.
6. Non-goals: no schema change and no new index (the root index exists). No
   change to fresh-run behavior or to decode tolerance.

### Regression coverage

- New tests in `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`
  (or a sibling suite). The isolated synthetic store holds about 200 unrelated
  sessions, each with multi-hundred-KiB execution payloads, backend event
  streams and messages, plus a target family (a parent with one reserved
  cross-workflow child).
- Structural assertion (deterministic): after `.family(target)` seeding, the
  runtime store returns sessions only for family ids. Unrelated ids are not
  loaded, and the next allocated session id is still above every unrelated id.
- Bound assertion: family seeding finishes within a generous absolute bound
  (seconds). It is a guard against a return to O(store) work, not a
  micro-benchmark; the structural assertion is the primary oracle.
- CLI assertion: `session resume <target> --output jsonl` (provider-free
  command or mock workflow) emits its first JSONL record within the bound, and
  `session rerun` from the same store does the same.
- Existing nested-resume, durable-reservation and fresh-run identity suites
  stay green.

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
