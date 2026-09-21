# Work Runtime P0: Model, Store, And Projection Implementation Plan

**Status**: Implemented 2026-09-21
**Workflow Mode**: feature
**Feature Fanout**: false — one module, one work package
**Design Reference**: `design-docs/specs/design-work-runtime-consolidation.md` sections 4, 8, 11, 13 (P0), 16
**Created**: 2026-09-20
**Last Updated**: 2026-09-21 (implementation)

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

- [x] P0-1 Module and identifiers
- [x] P0-2 Domain model
- [x] P0-3 Store schema and CRUD
- [x] P0-4 Evidence projector
- [x] P0-5 Completion evaluator
- [x] P0-6 CLI read surface
- [x] P0-7 Fixture proof and docs

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

## Accepted Deltas (2026-09-21, implementation step)

Found while implementing; each is a consequence of the accepted design meeting
the tree, not a redesign.

- **D7 diff allow-list**: D6 requires the `task` commands to be *registered*
  so `SurfaceParityCLITests` keeps its bijection. Registering them is
  impossible inside the original file list:
  `Sources/RielaCLI/RielaClientCommandRouter.swift` holds the router's
  subcommand literal, `Sources/RielaCLI/CLISurfaceEnumeration.swift` holds
  `expandedRoutes`/`expand(route:)` (an unclassified route fails
  `testEveryRouterRouteIsClassifiedAsALeafOrExpanded`), and
  `Tests/RielaCLITests/SurfaceParityCLITests.swift:testAnUnclassifiedRouteWouldHideItsSubcommands`
  literally asserts that `task` is *not* classified. All three join the
  Verification allow-list. The gate keeps its meaning: the negative case now
  names a family that is genuinely unregistered.
- **D8 generation-guard direction**: D5's "creating the `work_*` tables inside
  the runtime store's prepare path" cannot mean `RielaCore` calling
  `RielaWork` — design section 16 forbids that import, and the constraint list
  repeats it. It is implemented the only compatible way:
  `WorkStore.prepareSchema` runs the core guard
  `SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration`
  and then creates the `work_*` tables on the same connection. One
  `user_version` still covers both schemas. No `RielaCore` visibility changed:
  both the guard and `discardIncompatibleStoreIfNeeded` were already `public`.
- **D9 projector return**: P0-4 sketches `-> (evidence, findings)` but the same
  task also requires `LoopRecoveryLineage` to become a `Decision`. The
  projector returns `WorkProjection { evidence, findings, decisions }`.
- **D10 severity spelling**: design section 4's `FindingSeverity` and
  `FindingStatus` are "the same aliases as today", and section 3.8 names
  `WorkflowReviewFinding`'s scale as the surviving one, so they are public
  typealiases of `WorkflowReviewFindingSeverity`/`WorkflowReviewFindingStatus`
  rather than duplicate enums. `WorkFindingMerge.severity(fromLoopSeverity:)`
  extends the alias table with the loop-only `informational` (non-blocking)
  and maps anything unrecognized to `high`, so a typo cannot silently stop a
  finding from blocking completion.
- **D11 migration tests**: bumping the generation to 5 with no `fromGeneration: 4`
  step makes generations 2, 3 and 4 unmigratable, which is the intent, but it
  also made `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`
  assert a path that no longer exists (3 tests, 9 assertions, failing).
  The file is rewritten, not weakened: the registered `2 → 3 → 4` steps are
  still exercised directly through `SQLiteSchemaMigrator` at the generation
  they target, and two new tests pin the new contract (no generation below the
  current one has a path; an older store is discarded and recreated). It joins
  the allow-list.

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
  contradicted the plan's own Scope.) (2026-09-21, implementation: extended
  again for D7 — `Sources/RielaCLI/RielaClientCommandRouter.swift`,
  `Sources/RielaCLI/CLISurfaceEnumeration.swift`,
  `Tests/RielaCLITests/SurfaceParityCLITests.swift` — and for D11,
  `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`.)

## Resume Completion Tasks (2026-09-21, second session)

The first implementation session was killed by operator-machine OOM after
finishing the code and docs but before recording evidence, running the full
suite, or committing. The resume analysis live-verified the on-disk state
(build exit 0; filtered suites 79/79; gate suites 47/47; SwiftLint clean;
zero `import RielaWork` under `Sources/RielaCore`). Keep every file as-is;
the remaining work is exactly R1-R4, in order. Do not uncheck the P0 boxes:
R1 supplies the evidence that legitimizes them.

- [ ] R1 Evidence entries: append to the progress log one dated entry per
  task P0-1 through P0-7 with the exact command and result counts (re-run
  the filtered suites to cite fresh output; the analysis commands below are
  the template), plus an explicit note that no `RielaCore` visibility change
  was needed (D8).
- [ ] R2 Full-suite verification: `arch -arm64 /bin/zsh -lc 'swift build && swift test'`
  from the worktree root, complete log kept (no tailing), exit status
  recorded; compare the failure set name-by-name against the ten accepted
  environmental failures (6 AppKit view-hierarchy, 3 unix-socket-unlink
  `WorkflowRound7AdversarialTests`, `WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario`).
  Any other failure is a real defect: fix it and re-run. List any difference
  explicitly in the progress log. The known interleaved-submit timing flake,
  if it appears, is reported by name, retried once, and noted.
- [ ] R3 Lint gate: `swiftlint lint --quiet` over every modified and
  untracked Swift source; zero violations recorded.
- [ ] R4 Commit and push: commit all 15 modified + 26 untracked files (no
  renames exist; every `committedFiles` path must exist on disk), message
  scoped to the P0 feature, then first-push with
  `git push -u origin feat/work-runtime-p0`. Push no other branch.

Resume analysis evidence templates (2026-09-21, logs under `/tmp`):

- `arch -arm64 /bin/zsh -lc 'swift build'` → exit 0, `Build complete!`,
  0 error lines (`/tmp/wrp0-analysis-build.log`).
- `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaWorkTests|TaskCommandTests|TaskCommandParsingTests|TaskProjectionProofTests"'`
  → exit 0, 79 tests, 0 failures (WorkIdentifiers 5, WorkModelsCodable 13,
  WorkStore 15, WorkEvidenceProjector 18, CompletionEvaluator 13,
  TaskCommandParsing 2, TaskCommand 11, TaskProjectionProof 2;
  `/tmp/wrp0-analysis-filtered-tests.log`).
- `arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceCatalogTests|SurfaceParityCLITests|SQLiteRuntimeSchemaMigrationTests|CommandParsingTests"'`
  → exit 0, 47 tests, 0 failures (`/tmp/wrp0-analysis-gate-tests.log`).
- `grep -rn 'import RielaWork' Sources/RielaCore` → 0 matches, pinned by
  `WorkIdentifiersTests` (asserts zero offenders).

## Progress Log

- 2026-09-20: plan created from the accepted design; no code written.
- 2026-09-21: design step re-verified every seam in the tree (catalog rows
  blocked at `SurfaceCatalog+RowsConsole.swift:319-340`; runtime store
  generation 4; `LoopFindingFingerprint` public, `LoopGatePayloadParser`
  internal; snapshot fields; both examples' `EXPECTED_RESULTS.md`). Added
  the Task Checklist, Accepted Deltas D1-D6, Applicable Prior Knowledge,
  and extended the diff allow-list which contradicted Scope. No code
  written.
- 2026-09-21 (resume analysis, second session): prior implementation session
  killed by OOM after all code and docs landed on disk but before evidence,
  full-suite verification, commit, or push. Resume analysis verified the
  worktree state (see Resume Completion Tasks): build clean, 79/79 filtered
  tests, 47/47 gate tests, SwiftLint clean, layering grep zero. Branch
  `feat/work-runtime-p0` does not exist on origin yet; first push needs
  `-u`. Remaining work is R1-R4 only; no code rewrite.

## Residual Risks

- Sharing one SQLite file with the runtime store means a `work_*` schema bug
  can block session persistence. `WorkStore.open` must fail closed without
  touching runtime tables.
