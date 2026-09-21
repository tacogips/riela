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

- [x] R1 Evidence entries: append to the progress log one dated entry per
  task P0-1 through P0-7 with the exact command and result counts (re-run
  the filtered suites to cite fresh output; the analysis commands below are
  the template), plus an explicit note that no `RielaCore` visibility change
  was needed (D8).
- [x] R2 Full-suite verification: `arch -arm64 /bin/zsh -lc 'swift build && swift test'`
  from the worktree root, complete log kept (no tailing), exit status
  recorded; compare the failure set name-by-name against the ten accepted
  environmental failures (6 AppKit view-hierarchy, 3 unix-socket-unlink
  `WorkflowRound7AdversarialTests`, `WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario`).
  Any other failure is a real defect: fix it and re-run. List any difference
  explicitly in the progress log. The known interleaved-submit timing flake,
  if it appears, is reported by name, retried once, and noted.
- [x] R3 Lint gate: `swiftlint lint --quiet` over every modified and
  untracked Swift source; zero violations recorded.
- [x] R4 Commit and push: commit all 14 modified + 26 untracked files,
  re-derived with `git status --porcelain --untracked-files=all` (no
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
- 2026-09-21 (R1 evidence, second session): re-ran the gates in the foreground
  from the worktree root and recorded the complete untailed logs under
  `tmp/work-runtime-p0-resume-20260921/plans/R1/attempt-1/`. Every count below
  is from this fresh run, not from the analysis `/tmp` templates; all three
  commands reproduce the analysis numbers exactly.
  - **P0-1 Module and identifiers** — `arch -arm64 /bin/zsh -lc 'swift build'`
    → exit 0, `Build complete! (3.20s)`, 0 `error:` lines (`build.log`). The
    layering half: `grep -rn 'import RielaWork' Sources/RielaCore` → exit 1,
    0 matches (`layering-grep.log`), pinned in CI by
    `WorkIdentifiersTests.testRielaCoreNeverImportsRielaWork`, which walks
    `Sources/RielaCore` and asserts an empty offender list.
    `WorkIdentifiersTests` → 5 tests, 0 failures. Module is the 10 files the
    task table names, `Sources/RielaWork/{WorkIdentifiers,WorkModels,
    WorkDecision,WorkEvidence,WorkContext,WorkStore,WorkStore+Schema,
    WorkEvidenceProjector,WorkFindingMerge,CompletionEvaluator}.swift`.
  - **P0-2 Domain model** — `WorkModelsCodableTests` → 13 tests, 0 failures
    (`filtered-tests.log`), covering round-trip per type and the strict-decoding
    contract (an unknown enum value is a decode error). The six fixtures P1
    reuses are checked in at `Tests/RielaWorkTests/Fixtures/{intent,work-task,
    attempt,decision,evidence,finding}.json`.
  - **P0-3 Store schema and CRUD** — `WorkStoreTests` → 15 tests, 0 failures
    (`filtered-tests.log`): schema creation on an empty database, upsert/load/
    list per table, `work_tasks.version` optimistic-concurrency conflict,
    `TaskListFilter` bounds, and discard on generation mismatch. The shared
    `user_version` bump (D5, 4→5) is covered by
    `SQLiteRuntimeSchemaMigrationTests` → 5 tests, 0 failures
    (`gate-tests.log`), rewritten per D11 to exercise the registered 2→3→4
    steps at the generation they target and to pin the new contract.
  - **P0-4 Evidence projector** — `WorkEvidenceProjectorTests` → 18 tests,
    0 failures (`filtered-tests.log`): the design §8 mapping source by source
    plus the `causedBy` edges, and the D9 three-part `WorkProjection` return
    (evidence, findings, decisions).
  - **P0-5 Completion evaluator** — `CompletionEvaluatorTests` → 13 tests,
    0 failures (`filtered-tests.log`): the satisfied path and every
    `UnmetRequirement` kind, including a task that declares acceptance
    criteria against a gate payload with no `acceptance` object, which is
    unmet. `LoopGatePayloadParser` was not modified (D3).
  - **P0-6 CLI read surface** — `TaskCommandTests` → 11 tests and
    `TaskCommandParsingTests` → 2 tests, 0 failures (`filtered-tests.log`);
    the parity gates hold with `CommandParsingTests` → 25,
    `SurfaceParityCLITests` → 8 and `SurfaceCatalogTests` → 7 tests,
    0 failures (`gate-tests.log`). `SurfaceCatalog+RowsConsole.swift:349-364`
    now carries `task.list`/`task.show` as implemented with `task list` /
    `task show` CLI bindings, while `task.submit` (line 348), `task.serve`
    (line 365) and `intent.create|list|show` (lines 366-368) stay
    not-yet-built, so the D6 split is the asserted one.
  - **P0-7 Fixture proof and docs** — `TaskProjectionProofTests` → 2 tests,
    0 failures (`filtered-tests.log`, 3.537s — the two example workflows run
    for real under their mock scenarios):
    `testTheQualityLoopExampleProjectsIntoASucceededTask` and
    `testTheRequiredGateFailureExampleProjectsIntoAFailedTask`, both asserted
    against the examples' `EXPECTED_RESULTS.md`. Docs landed: the design-doc
    status line reads "**P0 implemented 2026-09-21**"
    (`design-docs/specs/design-work-runtime-consolidation.md:3`), `README.md:672`
    adds the `## Work Runtime (RielaWork)` section, and `impl-plans/README.md:46`
    carries the D2-corrected `riela task show|list` row.
  - **Totals for this attempt**:
    `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaWorkTests|TaskCommandTests|TaskCommandParsingTests|TaskProjectionProofTests"'`
    → exit 0, 79 tests, 0 failures (`filtered-tests.log`, `filtered-tests.exit`);
    `arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceCatalogTests|SurfaceParityCLITests|SQLiteRuntimeSchemaMigrationTests|CommandParsingTests"'`
    → exit 0, 47 tests, 0 failures (`gate-tests.log`, `gate-tests.exit`).
    (In the second command `TaskCommandParsingTests` also matches the
    `CommandParsingTests` substring filter and contributes its 2 tests, so the
    47 is 25 + 5 + 7 + 8 + 2.)
  - **D8 / RielaCore visibility — nothing to record.** Scope requires a
    progress-log entry naming any `RielaCore` type whose visibility P0 widened.
    P0 widened none. `WorkStore.prepareSchema` reaches
    `SQLiteWorkflowRuntimePersistenceStore.requireCompatibleSchemaGeneration`
    and `discardIncompatibleStoreIfNeeded`, both of which were already `public`
    before this branch, so the guard runs in the `RielaWork` → `RielaCore`
    direction with no edit to a declaration's access level. The only
    `RielaCore` source changes on the branch are the D5 generation constant and
    the D6 catalog rows, neither of which is a visibility change.
- 2026-09-21 (reconcile node, combined-tree verification): the fanout join ran
  with `R1` as the only dispatched branch; `R2`-`R4` were never dispatched. The
  reconcile step therefore ran the R2 and R3 gates itself over the combined
  tree, in the foreground, with complete untailed logs under
  `tmp/work-runtime-p0-resume-20260921/reconcile/attempt-1/`. The `R2`/`R3`
  boxes are deliberately left unticked: branch acceptance belongs to the
  independent integration review, which can tick them by citing this entry
  instead of re-running the 16-minute suite.
  - **R2 gate — full build and test.**
    `arch -arm64 /bin/zsh -lc 'swift build'` → exit 0, `Build complete! (8.49s)`,
    0 `error:` lines (`full-build.log`, `full-build.exit`).
    `arch -arm64 /bin/zsh -lc 'swift test'` → exit 1, 961s wall
    (`full-test.log`, 745293 B, complete and untailed; `full-test.exit`):
    **Executed 2364 tests, with 2 tests skipped and 17 failures.** The failing
    set is **exactly the ten accepted environmental cases**, matched by name
    (`failures.txt`): six AppKit view-hierarchy
    (`RielaAppUXOnboardingControllerTests` ×4,
    `RielaAppSettingsEditorNavigationTests` ×1,
    `RielaAppWindowContentInsetTests` ×1), three unix-socket-unlink
    (`WorkflowRound7AdversarialTests.test{ChangeSet,Proposal,Snapshot}RejectsUnexpectedUnixSocket`)
    and `WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario`.
    **Zero non-baseline failures.** The 17-vs-10 gap is assertion lines, not
    extra cases: the 17 `error:` lines decompose over those same ten cases
    (4 + 3 + 3 + 1×7), so no eleventh failure hides in the count.
  - **R3 gate — lint.** `swiftlint lint --quiet` (0.65.0) over all 31 changed
    Swift sources (`lint-targets.txt`, the `.swift` subset of the 40 changed
    paths) → exit 0, zero violations (`swiftlint.log`, `swiftlint.exit`).
  - **P0 suites re-confirmed inside the full run**, independent of R1's
    filtered runs: WorkIdentifiers 5, WorkModelsCodable 13, WorkStore 15,
    WorkEvidenceProjector 18, CompletionEvaluator 13, TaskCommand 11,
    TaskCommandParsing 2, TaskProjectionProof 2 (= 79) and CommandParsing 25,
    SQLiteRuntimeSchemaMigration 5, SurfaceCatalog 7, SurfaceParityCLI 8 (+ the
    2 TaskCommandParsing the substring filter also catches = 47), each with
    0 failures. R1's two filtered totals reproduce exactly.
  - **Structural acceptance criteria re-checked at the tree**: `RielaWork`
    depends on `RielaCore` + `RielaSQLite` and `RielaWorkTests` copies
    `Fixtures` (`Package.swift`); all six `work_*` tables are created in
    `WorkStore+Schema.swift`; `grep -rn 'import RielaWork' Sources/RielaCore`
    → 0; `TaskCommands.swift:251` resolves through `canonicalRuntimeStoreRoot`;
    `json`/`jsonl`/`text` (plus `table`) are all rendered
    (`TaskCommands.swift:88-90,207-211`). The P0-7 design-doc status line is
    not an uncommitted edit — it already landed at `e2f8eaf`
    (`design-work-runtime-consolidation.md:3`), so `design-docs/` is correctly
    clean in `git status`.
  - **Reviewer finding 2 applied here** (it was accepted-but-unapplied by R1):
    the P0-6 citation now reads `349-364` for the implemented `task.list`/
    `task.show` rows and lists `task.serve` (line 365) among the not-yet-built
    ids, verified against `sed -n '347,366p'` of the catalog file.

- 2026-09-21 (R2 full-suite verification): **R2 is ticked.** Evidence under
  `tmp/work-runtime-p0-resume-20260921/plans/R2/attempt-1/`.
  - **Result.** `arch -arm64 /bin/zsh -lc 'swift build'` → `EXIT=0`,
    `Build complete! (8.49s)`, 0 `error:` lines (`full-build.log`,
    `full-build.exit`). `arch -arm64 /bin/zsh -lc 'swift test'` from the
    worktree root → `EXIT=1` (`full-suite.log`, 745293 B, complete and
    untailed; `full-suite.exit`): **Executed 2364 tests, with 2 tests skipped
    and 17 failures**, `Test Suite 'All tests'` started 09:34:24 and finished
    09:50:25 (961 s). The swift-testing half of the run is green in the same
    log: `Test run with 15 tests in 0 suites passed`, zero `✘` lines.
  - **Failure comparison, name by name — zero non-baseline failures.**
    Ten `Test Case '-[...]' failed` lines, re-derived in this step straight
    out of the complete log (`observed-failures.txt`) and diffed against the
    ten accepted environmental cases (`accepted-baseline.txt`): the diff is
    empty. The set is
    `RielaAppUXOnboardingControllerTests.{testEmptyInstanceGuideAndFilteredEmptyStateUseSeparateMessages,
    testEventSourceConfigurationRoutesToWebConfig,
    testInstanceDetailShowsSnapshotDetailAndCanOpenWebUI,
    testInstanceRemovalRequiresConfirmationAndKeepsSourceScopeVisible}`,
    `RielaAppSettingsEditorNavigationTests.testInstanceDetailRoutesConfigurationToWebConfigAtRuntime`,
    `RielaAppWindowContentInsetTests.testWorkflowInstanceWindowUsesTightSettingsInsetsAtRuntime`
    (six AppKit view-hierarchy),
    `WorkflowRound7AdversarialTests.test{ChangeSet,Proposal,Snapshot}RejectsUnexpectedUnixSocket`
    (three unix-socket-unlink) and
    `WorkflowCommandTests.testPackageAppEnvironmentEnablementRunAndMonitoringScenario`.
    **No difference to list**, so the conditional authorisation to fix a
    non-baseline failure never fired and no production file was touched.
    The 17-vs-10 gap is assertion lines within those same ten cases
    (4 + 3 + 3 + 1×7 = 17 `error:` lines), confirmed by count, so no eleventh
    case hides in the failure total. Derivation commands and their raw output:
    `derivation.log`.
  - **Interleaved-submit timing flake: did not appear.** `grep -ci interleav`
    over the complete log → 0. Named here rather than folded into the
    baseline; no retry was needed.
  - **Why this step cites the executed run instead of launching a new one.**
    The suite needs 961 s wall; a single foreground shell call in this agent
    is capped at 600 s, and the Riela turn contract forbids detaching the run
    (`&`, `nohup`, `disown`, `setsid`). A 600 s-truncated run would produce an
    incomplete log, which this plan's Verification section already rejects as
    a passing check — so re-running here could only produce weaker evidence
    than the completed run. Integration-review finding `R2-R3-ledger`
    (informational, accepted — `acceptance/wave-1-acceptance.json`)
    authorises the citation. The cited artifacts were copied byte-identically
    into the R2 evidence dir, with both sides' SHA-256 recorded in
    `log-provenance-sha256.txt`
    (`full-test.log` = `full-suite.log` = `4fa99991…88bc0f9`;
    `full-build.log` = `e617bbd7…ed4b2dd5`).
  - **The cited run covers this exact tree** (`tree-identity.log`): `HEAD`
    unmoved at `e2f8eaf`, 40 paths (14 modified + 26 untracked), and the
    newest build input — `Tests/RielaCLITests/{CommandParsing,TaskCommandParsing}Tests.swift`
    at 08:57:09 — predates the cited build by ~37 minutes. Everything touched
    after the run is markdown (this plan), which SwiftPM does not compile.
- 2026-09-21 (reconcile node, wave 2 — R2 join): the second fanout join
    dispatched `R2` alone (1 record, `status=completed`, `reviewStatus=approved`);
    `R1` was already accepted in wave 1; `R3`/`R4` were never dispatched
    (sequential dependencies), so they are pending, not failed. Zero
    failed/cancelled branches. HEAD unmoved at `e2f8eaf`, tree still 40 paths
    (14 modified + 26 untracked, status digest `e819df87…bd07a911`, unchanged
    since the wave-1 acceptance record). Nothing staged or committed here.
  - **Drift classified, no loss.** Both `changeEvidence` observations name
    R2's own `writePath` across its own step boundaries — self-drift. Decoding
    all seven R2 snapshots from
    `tmp/riela-fanout/78396512-87A3-4836-BA05-1B9B75BA155E/`: the
    `fanout-dispatch` and `before:opus-implementation` copies are byte-identical
    to each other (the pre-R2 state, 33717 B), and `after:opus-implementation`,
    `before:opus-review`, `after:opus-review`, `before:branch-evidence` and
    `after:branch-evidence` are all byte-identical to the file on disk
    (37383 B, SHA-256 `64ab9820…c4f92e80`). R2's branch diff is exactly two
    hunks, +54/-1. R1's entry, the wave-1 reconcile entry and R2's entry all
    survive; no earlier writer's content was replaced.
  - **Combined-tree gates re-run fresh at this node** (foreground, arm64 login
    shell, whole-output redirection with `.exit` siblings), evidence under
    `tmp/work-runtime-p0-resume-20260921/reconcile/attempt-2/`:
    `swift build` → EXIT=0, "Build complete! (10.89s)" (`build.log`);
    `swift test --filter "RielaWorkTests|TaskCommandTests|TaskCommandParsingTests|TaskProjectionProofTests"`
    → EXIT=0, Executed 79 tests with 0 failures plus the 15-test swift-testing
    run (`filtered-tests.log`);
    `swift test --filter "SurfaceCatalogTests|SurfaceParityCLITests|SQLiteRuntimeSchemaMigrationTests|CommandParsingTests"`
    → EXIT=0, Executed 47 tests with 0 failures (`gate-tests.log`);
    `swiftlint lint --quiet` over the 31 changed Swift sources re-derived from
    `git status --porcelain --untracked-files=all` → EXIT=0, zero violations
    (`swiftlint.log` empty, `lint-targets.txt`);
    `grep -rn 'import RielaWork' Sources/RielaCore` → 0 matches, exit 1
    (`layering-grep.log`).
  - **Full suite cited, not re-run.** The 961 s suite exceeds this node's
    foreground shell budget and detaching is forbidden. The cited log is
    complete — `Test Suite 'All tests'` started 9:34:24 (line 7) and failed
    9:50:25 (line 6020) — with exactly 10 `Test Case … failed` lines whose
    `diff` against the accepted ten-item baseline is empty. Its coverage of
    this tree re-confirmed here: `find Sources Tests Package.swift -newermt
    '2026-09-21 09:00:00'` is still empty, so no compiled input changed after
    the cited build; only this markdown file has moved.
  - **R3's evidence now exists twice over** (wave-1 `swiftlint.log` and
    `attempt-2/swiftlint.log`, both EXIT=0 / 31 targets / zero violations); its
    checkbox is left unticked because acceptance is the integration review's
    call and R3 is still a dispatchable branch. R2's optional `followup` — the
    P0-6 citation `351-365` → `349-364` plus `task.serve` — was already applied
    by the wave-1 reconcile node (lines 454-456, 531-532) and needs no rework.
    **R4 (commit + first `git push -u origin feat/work-runtime-p0`) remains the
    only genuinely unexecuted work.**

- 2026-09-21 (R3 lint gate): **R3 is ticked.** Evidence under
  `tmp/work-runtime-p0-resume-20260921/plans/R3/attempt-1/`.
  - **Command.** `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <31 paths>'`
    from the worktree root, where the 31 paths are the `.swift` entries of
    `git status --porcelain --untracked-files=all`, re-derived at this node into
    `lint-targets.txt` (9 `Sources/RielaCLI` + `Sources/RielaCore`, 10
    `Sources/RielaWork`, `Package.swift`, 7 `Tests/RielaCLITests` +
    `Tests/RielaCoreTests`, 5 `Tests/RielaWorkTests`). The re-derived list
    `diff`s empty against the wave-1 `reconcile/attempt-1/lint-targets.txt`, so
    the gate covered the same 31 files the earlier runs did.
  - **Result.** `EXIT=0` (`swiftlint.exit`) with a 0-byte `swiftlint.log` —
    **zero violations**. SwiftLint 0.65.0 (`swiftlint-version.txt`) against the
    repo-root `.swiftlint.yml` (42 lines).
  - **Coverage proof, not just an empty log.** A 0-byte `--quiet` log is also
    what a no-op run would print, so the gate was re-run without `--quiet` into
    `swiftlint-verbose.log` (`swiftlint-verbose.exit` = `EXIT=0`): it emits
    `Linting '<file>' (n/31)` for all 31 files and the summary **`Done linting!
    Found 0 violations, 0 serious in 31 files.`** That line, not the byte count,
    is what makes this check passing.
  - **Freshly executed at this node, not cited.** The dispatch manifest
    authorised citing the two pre-existing clean logs
    (`reconcile/attempt-1/swiftlint.log` and `reconcile/attempt-2/swiftlint.log`,
    both 0 B / `EXIT=0` / 31 targets, re-confirmed present on disk). SwiftLint
    costs seconds rather than the 961 s of the R2 suite, so R3 ran it again
    instead: this entry rests on its own run, and the two earlier logs stand as
    corroboration — three independent clean runs over the same 31 files.
  - **Scope.** Plan-file edit only. No Swift source was touched (`find Sources
    Tests Package.swift -newermt '2026-09-21 09:00:00'` is empty); `HEAD` stays
    at `e2f8eaf`; nothing staged, committed, pushed or switched. All four prior
    entries are preserved verbatim: R1 (line 413), the wave-1 reconcile entry
    (486), R2 (535) and the wave-2 reconcile/R2-join entry (587).
    **R4 (commit + first `git push -u origin feat/work-runtime-p0`) is now the
    only unexecuted work in this plan.**

- 2026-09-21 (reconcile node, wave 3 — R3 join): the third fanout join
  dispatched `R3` alone (`R1`/`R2` skipped as already accepted) and returned
  exactly one branch record, `completed` / `approved` / `needs_revision=false`.
  `R4` was never dispatched — it is a pending dependency, not a failure.
  - **Drift classification.** All seven snapshots in
    `tmp/riela-fanout/0208335A-3F77-44BB-B617-36CE922FAB63/` were decoded from
    `contentBase64` at this node and each file's declared `sha256` recomputed
    and matched. `fanout-dispatch` == `before:opus-implementation` at 40882 B /
    `762f46a6…`; `after:opus-implementation` == `before:opus-review` ==
    `after:opus-review` == `before:branch-evidence` == `after:branch-evidence`
    == on disk at 43252 B / `5e83a6bd…`. The pre-write hash is byte-identical to
    the `planFileSha256` recorded in `acceptance/wave-2-acceptance.json`, so
    nothing was lost between wave 2's acceptance and R3's window. The
    `hasDrift=true` flag on the join is R3's own intended write, not a conflict.
  - **Overwrite check.** `diff` of the decoded pre-write snapshot against the
    working file: 2 hunks, **+35 / −1**, the sole deletion being the unticked
    `- [ ] R3 Lint gate:` line replaced by its ticked twin. Every earlier
    writer's entry survives — six dated entries at lines 406, 413, 486, 535,
    587 and 636; `P0-1`..`P0-7` (28-34), `R1` (361), `R2` (366) and `R3` (374)
    all `[x]`, `R4` (376) still `[ ]`. No repair was required.
  - **Combined-tree gates** (`reconcile/attempt-3/`, all foreground through
    `arch -arm64 /bin/zsh -lc`, whole-output redirection, sibling `.exit`):
    `swift build` `EXIT=0` ("Build complete! (16.86s)");
    `swift test --filter "RielaWorkTests|TaskCommandTests|TaskCommandParsingTests|TaskProjectionProofTests"`
    `EXIT=0`, **Executed 79 tests, with 0 failures**;
    `swift test --filter "SurfaceCatalogTests|SurfaceParityCLITests|SQLiteRuntimeSchemaMigrationTests|CommandParsingTests"`
    `EXIT=0`, **Executed 47 tests, with 0 failures**; `swiftlint lint` over the
    31 re-derived changed/untracked Swift paths `EXIT=0`, **Found 0 violations,
    0 serious in 31 files**; `grep -rn 'import RielaWork' Sources/RielaCore`
    0 matches.
  - **Full suite carried, not re-run.** `find Sources Tests Package.swift
    Package.resolved -newermt '2026-09-21 09:34:00'` is empty — no build input
    is newer than the cited 961 s run
    (`reconcile/attempt-1/full-test.log`, 745293 B, build `EXIT=0`, test
    `EXIT=1`, 2364 tests, 2 skipped, 17 assertion failures across exactly the
    ten accepted environmental cases, 0 non-baseline failures), so that result
    still covers this tree. The newest Swift mtime in the worktree is 08:57:06.
  - **Tree state unchanged.** `git status --porcelain --untracked-files=all`
    is byte-identical to wave 2's capture (digest `e819df87…`, 14 modified +
    26 untracked = 40 paths); `git diff --summary` is empty, so there are no
    renames, deletions or mode changes; `HEAD` is still `e2f8eaf` with an
    unchanged reflog; `git ls-remote --heads origin feat/work-runtime-p0` is
    empty. This node staged and committed nothing.

- 2026-09-21 (R4 commit and push): **R4 is ticked.** Evidence under
  `tmp/work-runtime-p0-resume-20260921/plans/R4/attempt-1/`.
  - **Commit set re-derived, not trusted.** `git status --porcelain
    --untracked-files=all` at `HEAD` `e2f8eaf` returned **40 paths — 14
    modified + 26 untracked** — digest
    `e819df87c96d0e697bd3d331b8c5d1bc9fb0439bd68d58b77c06a7ebbd07a911`,
    byte-identical to waves 2 and 3. The dispatch manifest's "15 modified"
    note is stale and was ignored, as the plan requires.
    `git diff --summary` is empty: **no renames, deletions or mode changes**,
    so every committed path exists on disk and the `riela/git-commit`
    rename guard is not in play.
  - **Pre-commit gates re-run on the exact committed tree** (foreground,
    `arch -arm64 /bin/zsh -lc`, whole-output redirection, sibling `.exit`):
    `swift build` `EXIT=0` ("Build complete! (17.25s)", 0 `error:` lines);
    `swift test --filter "RielaWorkTests|TaskCommandTests|TaskCommandParsingTests|TaskProjectionProofTests"`
    `EXIT=0`, **Executed 79 tests, with 0 failures**;
    `swift test --filter "SurfaceCatalogTests|SurfaceParityCLITests|SQLiteRuntimeSchemaMigrationTests|CommandParsingTests"`
    `EXIT=0`, **Executed 47 tests, with 0 failures**;
    `grep -rn 'import RielaWork' Sources/RielaCore` 0 matches (D8 holds).
    The 961 s full suite (R2, `reconcile/attempt-1/full-test.log`) and the
    31-file SwiftLint gate (R3) still cover this tree: `find Sources Tests
    Package.swift Package.resolved -newermt '2026-09-21 09:34:00'` is empty.
  - **Commit.** One feature commit on `feat/work-runtime-p0` carrying all 40
    paths; `tmp/` is gitignored (`.gitignore:41`) so no evidence artifact
    entered the commit. `impl-plans/README.md` is committed here, in the same
    commit as the implementation it describes (plan-index row: unchecked 7 ->
    0, status "Implemented 2026-09-21", D2 `import-session` correction).
  - **Push.** `git push -u origin feat/work-runtime-p0` only. No other branch
    was touched: `main` and `feat/control-surface-parity` are untouched, and
    there was no force push, reset, stash, branch deletion or branch switch.
  - **SHAs.** A commit cannot record its own hash, so the resulting SHAs and
    the push result are appended immediately below in a second, docs-only
    commit; the feature commit itself is the single commit holding the whole
    P0 implementation.

## Residual Risks

- Sharing one SQLite file with the runtime store means a `work_*` schema bug
  can block session persistence. `WorkStore.open` must fail closed without
  touching runtime tables.
