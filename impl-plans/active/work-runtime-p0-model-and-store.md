# Work Runtime P0: Model, Store, And Projection Implementation Plan

**Status**: Ready for implementation
**Workflow Mode**: feature
**Feature Fanout**: false — one module, one work package
**Design Reference**: `design-docs/specs/design-work-runtime-consolidation.md` sections 4, 8, 11, 13 (P0), 16
**Created**: 2026-09-20
**Last Updated**: 2026-09-21

## Accepted Design And Review

- Source of truth: `design-docs/specs/design-work-runtime-consolidation.md`.
- User decisions recorded in section 16: no implicit task on plain
  `workflow run`; acceptance judged from the gate payload `acceptance` field by
  the deterministic director; `RielaWork` depends on `RielaCore`, never the
  reverse.
- Jujutsu is out of scope for every phase. Git worktrees arrive in P4, not here.
- P0 adds a module, a store, and the snapshot projector. It changes no
  runtime behavior; deletions start in P1. No backward compatibility anywhere:
  no migrations, no tolerant decoding, no legacy import. A store with a
  different schema generation is discarded.

## Task Checklist

Check a box only after its task's completion evidence is recorded in the
progress log with the exact command and result.

- [ ] P0-1 Module and identifiers
- [ ] P0-2 Domain model
- [ ] P0-3 Store schema and CRUD
- [ ] P0-4 Evidence projector
- [ ] P0-5 Completion evaluator
- [ ] P0-6 CLI read surface
- [ ] P0-7 Fixture proof and docs

## Accepted Deltas (2026-09-21, design step)

Recorded against the accepted design after re-verifying the tree; none is a
redesign.

- **D1 checklist**: the plan gains the Task Checklist above so acceptance
  ("every checkbox checked with evidence") has literal checkboxes. Format
  only.
- **D2 README drift**: `impl-plans/README.md` line 46 says
  `riela task show|list|import-session`; `import-session` is in no plan task
  and has no `SurfaceCatalog` row. P0-7 corrects the README row to
  `show|list`; the command is NOT added in P0.
- **D3 acceptance parsing**: `LoopGatePayloadParser` is `internal`
  (`Sources/RielaCore/LoopFindingFingerprint.swift:28`). `CompletionEvaluator`
  reads the gate step's accepted output payload's `acceptance`
  (`{ "met": Bool, "note": String? }`) with its own decoding in `RielaWork`;
  the parser is not modified and no visibility change is expected for it.
- **D4 Swift spelling**: design §4 `Task` is spelled `WorkTask` in Swift
  (avoids `_Concurrency.Task` shadowing inside an async module); its
  `guard` field is the property `guardPolicy` with `CodingKey` `"guard"`.
  JSON shapes are exactly the design's.
- **D5 generation guard**: "one `PRAGMA user_version` covers both schemas"
  is realized by bumping `SQLiteWorkflowRuntimePersistenceStore.schemaGeneration`
  from 4 to 5 (`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:108`)
  and creating the `work_*` tables inside the runtime store's prepare path
  guard window via `WorkStore.prepareSchema`. Existing local session stores
  are discarded on first open — accepted, matches the no-migration rule.
- **D6 catalog gates**: flipping `task.show`/`task.list` CLI availability
  requires updating
  `Tests/RielaCoreTests/SurfaceCatalogTests.swift:testWorkRuntimeOperationsAreBlockedOnTheP0Plan`
  to assert the post-P0 split (show/list CLI implemented with
  `riela task show|list` bindings; `task.submit`, `task.serve`, `intent.*`
  and every GraphQL/library face still `blocked` citing this plan or
  "work-runtime P5"), and registering the commands so
  `Tests/RielaCLITests/SurfaceParityCLITests.swift:testEveryRegisteredCommandHasACatalogRowAndViceVersa`
  keeps its bijection. The library face stays `blocked`:
  `testLibraryFacadeIsExactlyTheSixDesignedEntryPoints` pins the facade.

## Applicable Prior Knowledge

- Run every Swift command through `arch -arm64 /bin/zsh -lc '...'`; the
  default agent shell is Rosetta and the xctest bundle refuses to dlopen.
- Never tail `swift test` output when failure lines may be needed; keep the
  complete log and exact exit status as evidence.
- SurfaceCatalog changes ripple into the parity gate tests listed in D6;
  update the gates in the same task as the row flip, never loosen them.
- Re-read syntax-critical files directly before authoring against them; do
  not trust summarized quotes.
- After the D5 generation bump, any pre-existing store under a reused
  `--session-store` root is discarded on open; live CLI checks must use a
  fresh temporary store root.

## Scope

### Included

- New SwiftPM target `RielaWork` (library) with dependency on `RielaCore` and
  `RielaSQLite`, plus `RielaWorkTests`.
- Domain types from design section 4: `Intent`, `Task`, `TaskState`,
  `Attempt`, `AttemptState`, `CompletionContract`, `GuardPolicy`,
  `DirectorPolicy`, `Decision`, `DecisionKind`, `Evidence`, `EvidenceKind`,
  `Finding`, `ContextBinding` (repository case only, no adapter yet), and the
  identifier newtypes. All `Codable`, `Equatable`, `Sendable`, with strict
  decoding: an unknown enum value is a decode error.
- `WorkStore`: SQLite tables `work_intents`, `work_tasks`, `work_attempts`,
  `work_decisions`, `work_evidence`, `work_findings` in the runtime records
  database, JSONB record columns with generated filter columns, and a
  schema generation guard that discards a mismatched store.
  `work_leases`, `work_outbox`, `work_delivery_receipts`,
  `work_intake_cursors` are P3.
- `WorkEvidenceProjector`: projects one persisted
  `WorkflowRuntimePersistenceSnapshot` (session, messages, `loopEvidence`,
  `loopMetadata`, `session.reviewFindings`) into `Evidence` and `Finding`
  records for an attempt, with `causedBy` edges as in design section 8.
- Deterministic completion check `CompletionEvaluator.evaluate(task:attempt:)`
  implementing the rule in design section 5: required gates accepted,
  verification present and passing, no open blocking finding, and, when the
  task declares natural-language acceptance, the gate payload `acceptance.met
  == true`. Pure function, no store access.
- Catalog rows for every `riela task` and `riela intent` operation in
  `SurfaceCatalog` before the commands exist, per
  `design-docs/specs/design-control-surface-parity.md`; GraphQL faces are
  declared `blocked` with evidence "work-runtime P5" until they land.
- CLI, read-only: `riela task show <taskId>` and `riela task list`. The P0
  proof is a test that runs the two loop example workflows with their mock
  scenarios, projects the terminal snapshots into a task each, and checks
  the ledger counts against `EXPECTED_RESULTS.md`.

### Excluded

- Dispatcher, attempt reservation, fenced launch, guard detectors, directors,
  deletion of auto-improve, `riela loop` deletion, routines, specialist fold,
  GraphQL, web, worktrees, capability ceilings. Each has a later phase.
- Any change to `DeterministicWorkflowRunner`, `RuntimeStore`,
  `SQLiteWorkflowRuntimePersistenceStore` public behavior, or existing tables.
  P0 only adds tables to the same database file.
- Any change to `RielaCore` beyond making already-public loop types reachable
  from `RielaWork` if a needed type is `internal`. Record each such change in
  the progress log.

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| P0-1 Module and identifiers | `RielaWork` target and test target in `Package.swift`; `WorkIdentifiers.swift` with `IntentID`, `TaskID`, `AttemptID`, `DecisionID`, `EvidenceID` (string-backed, `Codable`, `Hashable`) | `Package.swift`, `Sources/RielaWork/WorkIdentifiers.swift`, `Tests/RielaWorkTests/WorkIdentifiersTests.swift` | none | Yes |
| P0-2 Domain model | Types listed in Included; strict decoding; fixtures for round-trip | `Sources/RielaWork/WorkModels.swift`, `Sources/RielaWork/WorkDecision.swift`, `Sources/RielaWork/WorkEvidence.swift`, `Sources/RielaWork/WorkContext.swift`, `Tests/RielaWorkTests/WorkModelsCodableTests.swift` | P0-1 | Yes with P0-3 |
| P0-3 Store schema and CRUD | `WorkStore` with `prepareSchema`, generation guard, upsert/load/list per table, filters (`TaskListFilter`: state, intentId, workflowId, limit 1...1000 as in `RoutineListFilter`) | `Sources/RielaWork/WorkStore.swift`, `Sources/RielaWork/WorkStore+Schema.swift`, `Tests/RielaWorkTests/WorkStoreTests.swift` | P0-1 | Yes with P0-2 (agree record shapes first) |
| P0-4 Evidence projector | `WorkEvidenceProjector.project(snapshot:task:attempt:) -> (evidence, findings)`; finding merge using `LoopFindingFingerprint` identity and `WorkflowReviewFindingSeverity` aliases | `Sources/RielaWork/WorkEvidenceProjector.swift`, `Sources/RielaWork/WorkFindingMerge.swift`, `Tests/RielaWorkTests/WorkEvidenceProjectorTests.swift` | P0-2 | No; owns the projection contract |
| P0-5 Completion evaluator | `CompletionEvaluator` and `CompletionVerdict` (satisfied, unmet requirements list); gate payload `acceptance` parsing added next to `LoopGatePayloadParser` consumers without modifying the parser | `Sources/RielaWork/CompletionEvaluator.swift`, `Tests/RielaWorkTests/CompletionEvaluatorTests.swift` | P0-2 | Yes with P0-4 |
| P0-6 CLI read surface | `riela task show|list`; JSON, JSONL, text outputs following `LoopCommands.swift` rendering; store root resolved through `canonicalRuntimeStoreRoot` | `Sources/RielaCLI/RielaCommand.swift`, `Sources/RielaCLI/TaskCommands.swift`, `Sources/RielaCLI/TaskCommandModels.swift`, `Tests/RielaCLITests/TaskCommandTests.swift`, `Tests/RielaCLITests/CommandParsingTests.swift` | P0-3, P0-4, P0-5 | No |
| P0-7 Fixture proof and docs | Run `examples/loop-engineer-quality-loop` and `examples/required-loop-gate-failure` with mock scenarios in a test, project each terminal snapshot into a task, assert gate, finding, verification, cost counts against `EXPECTED_RESULTS.md`; design-doc status line; README module list | `Tests/RielaCLITests/TaskProjectionProofTests.swift`, `design-docs/specs/design-work-runtime-consolidation.md`, `README.md` | P0-6 | No; final gate |

## Task Details

### P0-1 Module And Identifiers

**Deliverables**:

- `Package.swift`: `.library(name: "RielaWork", targets: ["RielaWork"])`,
  `.target(name: "RielaWork", dependencies: ["RielaCore", "RielaSQLite"])`,
  `.testTarget(name: "RielaWorkTests", dependencies: ["RielaWork", "RielaCore"])`.
  `RielaCLI` gains `RielaWork` as a dependency. `RielaCore` does not.
- Identifier newtypes with `init(_ raw: String)`, `rawValue`, and
  `static func generate()` producing lowercase UUID strings prefixed
  `intent-`, `task-`, `attempt-`, `decision-`, `evidence-`.

**Completion evidence**: `swift build` succeeds on the arm64 toolchain; a
compile-time test proves `RielaCore` does not import `RielaWork` by grepping
`Sources/RielaCore` for `import RielaWork` and asserting zero matches.

### P0-2 Domain Model

**Deliverables**:

- Types exactly as in design section 4, with these P0 simplifications recorded
  as such: `ContextBinding.repository` carries `root`, `baseRevision`,
  `isolation` (`shared` | `worktree`), `writeScopes`, and nothing else;
  `DirectorPolicy.agentWorkflow` is present but unused; `TaskTrigger` has
  `manual`, `schedule(cron: String, timezone: String?)`,
  `event(bindingId: String)`, `dependency`.
- `TaskState`, `AttemptState`, `DecisionKind`, `EvidenceKind` are closed
  enums with strict decoding.
- `Finding` carries both the authored `id` and the computed fingerprint; the
  fingerprint is computed by `LoopFindingFingerprint.make` and never stored
  without the source fields.

**Completion evidence**: round-trip tests for every type and a fixture JSON
under `Tests/RielaWorkTests/Fixtures` checked in for P1 to reuse.

### P0-3 Store Schema And CRUD

**Deliverables**:

- Database path: `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`,
  the same file. The runtime store's schema generation is bumped so that one
  `PRAGMA user_version` covers both schemas; a mismatched file is discarded
  by the existing `discardIncompatibleStoreIfNeeded` path and recreated.
- Tables: `work_intents(intent_id PK, record JSONB, title, state, created_at)`,
  `work_tasks(task_id PK, intent_id, parent_id, record JSONB, state, workflow_id, version, updated_at)`,
  `work_attempts(attempt_id PK, task_id, session_id UNIQUE, generation, record JSONB, state, created_at)`,
  `work_decisions(decision_id PK, task_id, attempt_id, record JSONB, kind, producer_kind, created_at)`,
  `work_evidence(evidence_id PK, task_id, attempt_id, kind, record JSONB, created_at)`,
  `work_findings(fingerprint, task_id, record JSONB, severity, status, gate_id, PRIMARY KEY(task_id, fingerprint))`.
  Indexes on every foreign key column and on `work_evidence(task_id, kind)`.
- Optimistic concurrency on `work_tasks.version` with `expectedVersion` on
  update, as `SpecialistSupervisorStore.claim` does today.
- Busy-timeout behavior inherits the runtime store's lock-wait semantics; no
  new contention timeout.

**Completion evidence**: store tests for schema creation on an empty database,
upsert/load/list per table, version conflict, filter bounds, and discard on
generation mismatch.

### P0-4 Evidence Projector

**Deliverables**:

- Mapping table from design section 8 implemented one source at a time:
  `LoopGateResult` to `gate`; `session.reviewFindings` and each gate's
  `blockingFindings` to `Finding` merged by fingerprint (authored id wins,
  then `(filePath, normalized message)`); `LoopVerificationEvidence` and
  `LoopCommandEvidence` to `verification` and `command`; `LoopChangedFile`
  to `changedFile`; `LoopCostEvidence` to `cost`; `LoopConvergenceEvidence`
  with `stallDetected` to `guardViolation`; `LoopRecoveryLineage` to a
  `decision` of kind `recover` or `rerun` with `producer: .policy("legacy-import")`.
- `causedBy`: findings point at their gate evidence; verification and command
  records point at the attempt's step evidence when a step id is present;
  guard violations point at the last gate visit.
**Completion evidence**: projector tests over the checked-in fixtures from
`LoopEvidenceProjectorTests` inputs asserting gate, finding, verification,
command, cost, and changed-file counts and `causedBy` edges.

### P0-5 Completion Evaluator

**Deliverables**:

- `CompletionEvaluator.evaluate(contract:attemptOutcome:ledger:) -> CompletionVerdict`
  where `CompletionVerdict` is `satisfied` or `unmet([UnmetRequirement])`,
  and `UnmetRequirement` enumerates `gateNotAccepted(gateId)`,
  `verificationMissing(name)`, `verificationFailed(name)`,
  `openBlockingFinding(fingerprint)`, `acceptanceNotMet`,
  `acceptanceAbsent`, `humanAcceptRequired`.
- Gate payload `acceptance` parsing: `{ "met": Bool, "note": String? }` read
  from the accepted output payload of the gate step; absence or `met: false`
  yields `acceptanceNotMet` or `acceptanceAbsent` only when the task declares
  at least one `AcceptanceCriterion`. Tasks without criteria skip this check.

**Completion evidence**: table-driven tests over every unmet kind and the
satisfied path, including a task with criteria and a gate payload lacking
`acceptance`, which must be unmet.

### P0-6 CLI Read Surface

**Deliverables**:

- `RielaCommand.task(TaskCommand)` with `TaskCommandKind` `show`, `list`.
  Shared flags `--scope`, `--working-dir`, `--session-store`, `--output`
  follow `LoopCommand` so P2 can reuse the option parsing when `loop` is
  deleted.
- Help text in `RielaCLIApplication` lists the two subcommands with one line
  each.

**Completion evidence**: parsing tests, help tests, and a store-backed test
over a fixture ledger.

### P0-7 Fixture Proof And Docs

**Deliverables**:

- Run `examples/loop-engineer-quality-loop` and
  `examples/required-loop-gate-failure` with their mock scenarios into a
  temporary session store, project both terminal snapshots into tasks, and
  assert: the quality loop task is `succeeded` with the expected gate and
  finding counts; the required-gate-failure task is `failed` with
  `rejectedGateCount: 1` and `blockingFindingCount: 2`, matching
  `EXPECTED_RESULTS.md`.
- Design doc status line updated to "P0 implemented"; README gains one
  paragraph under the module list naming `RielaWork` and the three read-only
  commands; `impl-plans/README.md` row updated.

**Completion evidence**: `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaWorkTests|TaskCommandTests|TaskProjectionProofTests"'`
green, then a full `swift test` from the repository root with zero failures
beyond the known interleaved-submit timing flake.

## Verification

- Build and tests run through an arm64 shell, as recorded in project memory;
  a Rosetta shell fails to load the xctest bundle.
- SwiftLint on changed Swift sources.
- No file under `Sources/RielaCore` changes visibility without a progress-log
  entry naming the type and the reason.
- `git diff --stat` shows no changes outside `Package.swift`,
  `Sources/RielaWork`, `Sources/RielaCLI/Task*.swift`,
  `Sources/RielaCLI/RielaCommand.swift`, `Sources/RielaCLI/RielaCLIApplication.swift`,
  `Tests/RielaWorkTests`, `Tests/RielaCLITests/Task*.swift`,
  `Tests/RielaCLITests/CommandParsingTests.swift`,
  `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift` (and, only if a
  binding helper needs it, the other `SurfaceCatalog+Row*` files),
  `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (the D5
  generation constant and its migration table only),
  `Tests/RielaCoreTests/SurfaceCatalogTests.swift`, any parity gate test in
  D6, logged RielaCore visibility widenings, this plan, the design doc, and
  the two READMEs. (2026-09-21: list extended for D5/D6; the original list
  contradicted the plan's own Scope.)

## Progress Log

- 2026-09-20: plan created from the accepted design; no code written.
- 2026-09-21: design step re-verified every seam in the tree (catalog rows
  blocked at `SurfaceCatalog+RowsConsole.swift:319-340`; runtime store
  generation 4; `LoopFindingFingerprint` public, `LoopGatePayloadParser`
  internal; snapshot fields; both examples' `EXPECTED_RESULTS.md`). Added
  the Task Checklist, Accepted Deltas D1-D6, Applicable Prior Knowledge,
  and extended the diff allow-list which contradicted Scope. No code
  written.

## Residual Risks

- Sharing one SQLite file with the runtime store means a `work_*` schema bug
  can block session persistence. `WorkStore.open` must fail closed without
  touching runtime tables.
