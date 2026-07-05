# Loop Engineering Application Gap Closure Implementation Plan

**Status**: LA1a implemented - LA1b and later roadmap work not started
**Design Reference**: `design-docs/specs/design-loop-engineering-application-gap-closure.md`
**Created**: 2026-07-05
**Last Updated**: 2026-07-05

---

## Design Document Reference

**Source**: `design-docs/specs/design-loop-engineering-application-gap-closure.md`

### Summary

Turn the implemented first-line loop primitives (evidence manifests, gates,
recovery lineage, policy) into an operable loop engineering application:
fleet visibility (`loop list`/`history`), gate-addressed recovery and a
policy-forward `loop start`, cost evidence and budgets, cross-run diff and
stats, and a CI verdict contract (check exit codes plus SARIF findings
export). Lessons, worktree isolation, and the RielaApp timeline are staged
behind these.

### Scope

**Current implementation pass (LA1a)**:

- `LoopSessionOverview`, `LoopSessionSummary`, and `LoopGateOutcome` models.
- SQLite summary columns and read API:
  `workflow_id`, `session_status`, `created_at`, `loop_summary_json`, plus
  `loadSessionOverviews`.
- Read-only `riela loop list` and `riela loop history` surfaces over summary
  SQL, including `--workflow`, `--status`, `--gate-decision`, `--limit`, and
  JSONL/JSON/text/table rendering.
- `riela loop recover --from-gate`, resolving gate id to step id from
  evidence first, authored metadata second, then delegating to the existing
  rerun path.
- Focused parser, persistence, CLI, and compatibility tests.

**Explicit LA1a non-goals**:

- `loop start`, `loop promote`, cost evidence, budgets, diff/stats, GraphQL,
  CI verdict/SARIF, lessons, worktree isolation, and RielaApp timeline.
  These remain in the roadmap below but are deferred past this implementation
  pass by the accepted Step 3 design review.

**Full design roadmap** (phases LA1–LA4, detailed modules below):

- `LoopSessionOverview` API model, persisted `LoopSessionSummary` compact
  shape, and a SQLite summary-read API backed by new
  `workflow_id`/`session_status`/`created_at`/`loop_summary_json` columns.
- `riela loop list`, `riela loop history`.
- `riela loop recover --from-gate`.
- `riela loop start` with pre-run policy panel; `riela loop promote`.
- Runner-owned live usage accumulator feeding `LoopCostEvidence`/
  `LoopCostSummary` into evidence projection (persisted usage records
  cannot supply token counts — see design S3).
- `loop.budget` metadata, validation, step-boundary enforcement,
  `budgetExceeded` failure kind, and the tolerant persisted-enum decoding
  it requires.
- `riela loop diff` and `riela loop stats` with deterministic matching and
  bounded on-read aggregation.
- GraphQL projections: `loopSessions`, `loopWorkflowStats`,
  `loopEvidenceDiff`.
- `riela loop gates --check` exit-code contract and
  `riela loop findings --format sarif|json`.
- Focused Swift tests per module.

**Excluded** (tracked, not in these modules):

- LA5 lessons store/CLI/injection and LA6 worktree isolation + RielaApp
  timeline — outlined at the end; module specs written when their phase
  starts.
- Workflow self-evolution versioning — remains module 8 of
  `impl-plans/active/loop-engineering-first-line-tool.md`.
- Monetary cost estimation, materialized metrics tables, CI provider
  plugins, mid-step budget interruption, auto-merge of isolated worktrees.
- Running or validating workflows as part of this authoring step.

---

## Current LA1a Implementation Pass

This is the controlling plan for the next implementation step. Later module
sections remain as design-roadmap detail; implementers should not start LA1b
or LA2+ work unless a later review explicitly expands scope.

### LA1a Task Breakdown

| Task | Deliverables | Write Scope | Dependencies | Parallelizable |
|------|--------------|-------------|--------------|----------------|
| LA1a.1 Summary models | `LoopSessionOverview`, `LoopSessionSummary`, `LoopGateOutcome`, defaulted Codable decoding, pure projection helpers | `Sources/RielaCore/LoopSessionOverview.swift`, focused tests | Existing `LoopEvidenceManifest`, authored loop metadata, recovery lineage | Yes, with LA1a.3 parser-only work |
| LA1a.2 SQLite summary persistence | Add nullable summary columns, writable-open migration/backfill, single save-path derived-column helper, `loadSessionOverviews` with bounded legacy fallback | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`, store tests | LA1a.1 projection shape | No, central store write path |
| LA1a.3 CLI parser options | Parse `loop list`, `loop history`, and mutually exclusive `recover --from-step/--from-gate`; update help text | `Sources/RielaCLI/RielaCommand.swift`, parser tests | Accepted CLI contract | Yes, before command execution wiring |
| LA1a.4 list/history execution | Render overviews from `loadSessionOverviews`; implement filters, status mapping, table/text/JSON/JSONL output; read-only behavior | `Sources/RielaCLI/LoopCommands.swift`, CLI tests | LA1a.2 and LA1a.3 | No, shares command file with recovery |
| LA1a.5 gate recovery | Resolve gate id from evidence result `stepId`, then authored `workflow.loop.gates[]`; error with known gate ids; delegate to `SessionRerunCommand` unchanged | `Sources/RielaCLI/LoopCommands.swift`, rerun tests | Existing evidence load and rerun command; LA1a.3 parser | No, same write scope as LA1a.4 |
| LA1a.6 Verification pass | Focused Swift tests, then broader affected suites; update progress log with exact commands and results | Tests and this plan's Progress Log only | LA1a.1-LA1a.5 | No, final integration step |

### LA1a Dependencies

- Existing persisted `WorkflowRuntimePersistenceSnapshot.loopEvidence` and
  `loop_evidence_json` storage.
- Existing authored `workflow.loop.gates[]` metadata and
  `LoopGateResult.stepId` evidence records.
- Existing `SessionRerunCommand` behavior for step-addressed recovery.
- Existing CLI output renderer conventions for JSONL/JSON/text/table.
- Existing SQLite migration style used by `loop_evidence_json`.

### LA1a Parallelization Rules

- LA1a.1 and LA1a.3 are parallelizable because their write scopes are
  disjoint (`RielaCore` models vs CLI parser).
- LA1a.2 must be serialized after LA1a.1 because it persists and decodes the
  summary model.
- LA1a.4 and LA1a.5 must be serialized with each other because both modify
  `Sources/RielaCLI/LoopCommands.swift`.
- LA1a.6 runs last after all code paths are integrated.

### LA1a Verification Commands

- `swift test --filter LoopSessionOverviewTests`
- `swift test --filter SQLiteWorkflowRuntimePersistenceStoreTests`
- `swift test --filter CommandParsingTests`
- `swift test --filter WorkflowCommandTests`
- `swift test --filter WorkflowCommandLivePersistenceTests`
- `swift test`
- `swiftlint`

Record each command, exit status, and any intentionally skipped command in
the Progress Log before handoff.

### LA1a Completion Criteria

- `loop list` and `loop history` load persisted sessions through
  `loadSessionOverviews`; no new `loadAll()` cross-run scan is introduced.
- Summary columns are written from a single save-path helper, including
  authored loop metadata when available, and remain consistent with freshly
  derived snapshot/manifest data.
- Pre-migration rows remain readable; not-yet-backfilled rows use bounded
  fallback decoding only for the requested window and never trigger
  write-on-read.
- `--status active` maps to `created|running`; stale running rows surface
  `possiblyStale: true` without mutating persisted status.
- `loop recover --from-gate` delegates to the existing rerun path with
  `--from-step` behavior unchanged and mutual-exclusion diagnostics covered.
- Parser and output behavior are covered for JSONL/JSON/text/table where
  applicable.
- The plan Progress Log names completed tasks, blocked tasks, verification
  commands, and any deviations from the accepted design.

## Modules

### 1. LA1 — Summary Model And Summary SQL

#### `Sources/RielaCore/LoopSessionOverview.swift`

**Status**: COMPLETE_LA1A

```swift
public struct LoopSessionOverview: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var sessionStatus: String
  public var loopKind: String?
  public var loopRequired: Bool?
  public var loopEvidenceRecorded: Bool
  public var gateSummary: LoopGateSummaryCounts?
  public var blockingFindingCount: Int?
  public var lastGateDecision: String?
  public var entryMode: String?
  public var sourceSessionId: String?
  public var cost: LoopCostSummary?    // populated from LA2 onward
  public var possiblyStale: Bool
  public var createdAt: Date
  public var updatedAt: Date
}

public struct LoopSessionSummary: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var loopKind: String?
  public var loopRequired: Bool?
  public var gateOutcomes: [LoopGateOutcome]   // gateId, decision, required, blockingFindingCount
  public var lastGateDecision: String?
  public var blockingFindingCount: Int
  public var entryMode: String?
  public var sourceSessionId: String?
  public var rootSessionId: String?
  public var attemptNumber: Int?
  public var cost: LoopCostSummary?
  public var evidenceUpdatedAt: Date
}
```

Note: the pre-existing `LoopEvidenceSummary` stays untouched for its current
consumers; `LoopSessionSummary` is the persisted summary-column shape
because the overview and `loop stats` need per-gate decisions, gate
requiredness (frozen from authored `loop.gates[]` at projection time),
lineage, and cost — none of which `LoopEvidenceSummary` carries.

**Checklist**:

- [x] Add `LoopSessionOverview`, `LoopSessionSummary`, and `LoopGateOutcome`
  value types with stable Codable names and defaulted decoding.
- [x] Add a pure builder deriving `LoopSessionSummary` from a manifest plus
  authored loop metadata (gate requiredness frozen in).
- [x] Add a pure builder `LoopSessionOverview.make(from:)` combining summary
  columns and a staleness threshold (`running` + stale `updatedAt` ⇒
  `possiblyStale: true`).
- [x] Deterministic encoding tests; legacy snapshot (no loop evidence)
  projects `loopEvidenceRecorded: false` with nil loop fields.

#### `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`

**Status**: COMPLETE_LA1A

```swift
public struct LoopSessionOverviewFilter: Sendable {
  public var workflowId: String?
  public var sessionStatus: String?
  public var limit: Int
}

func loadSessionOverviews(_ filter: LoopSessionOverviewFilter) throws -> [LoopSessionOverview]
```

**Checklist**:

- [x] Add nullable `workflow_id`, `session_status`, `created_at`, and
  `loop_summary_json` columns via `ALTER TABLE` migration when absent
  (same pattern as `loop_evidence_json`). The current table keeps
  workflow id/status/timestamps only inside the `session_json` blob, so
  SQL-side filtering needs these real columns.
- [x] Single save-path write helper derives all four derived columns (and
  the summary from the manifest) in the same call as the blob write, so
  the pair cannot drift. Reads never write.
- [x] One-shot backfill sweep for pre-migration rows on the next writable
  open (any save path); bounded and resumable.
- [x] Add `loadSessionOverviews` reading only summary-level columns with
  SQL-side `WHERE`/`ORDER BY updated_at DESC`/`LIMIT`; never call
  `loadAll()`. Read-only reads that encounter not-yet-backfilled rows
  fall back to decoding blobs for the requested window only, with a
  `pre-migration rows scanned` diagnostic — no write-on-read.
- [x] `--status active` maps to persisted `created|running`; stale
  `running` rows marked `possiblyStale`, never re-statused.
- [x] Pre-migration stores stay readable; rows without evidence project
  overview rows with `loopEvidenceRecorded: false`.
- [x] Consistency regression test: saving a snapshot with loop evidence
  always yields summary columns matching a fresh derivation from the
  snapshot/manifest.

### 2. LA1 — Cockpit CLI Surfaces

#### `Sources/RielaCLI/RielaCommand.swift`

**Status**: COMPLETE_LA1A_PARSE_SCOPE

```swift
public enum LoopCommand: Equatable, Sendable {
  case status(CLICommandOptions)
  case evidence(CLICommandOptions)
  case gates(LoopGatesOptions)          // gains --check in LA4
  case recover(LoopRecoverOptions)      // gains --from-gate
  case list(LoopListOptions)
  case history(LoopHistoryOptions)
  case start(LoopStartOptions)
  case promote(LoopPromoteOptions)
}
```

**Checklist**:

- [x] Parse `loop list [--workflow] [--status] [--gate-decision] [--limit]`.
- [x] Parse `loop history <workflow> [--limit]`.
- [x] Parse `loop recover <session-id> --from-gate <gate-id>`; reject
  combining `--from-step` and `--from-gate`.
- [ ] Parse `loop start <workflow> [--var k=v ...]`
  (`--isolate` is LA6; parser reserves and rejects it with a clear
  "not yet supported" diagnostic). No `--yes`/confirmation flag — the CLI
  has no interactive prompts and invocation is consent (design S2).
- [ ] Parse `loop promote <workflow>`.
- [x] Help text for LA1a surfaces; existing parse behavior unchanged.
  Note: reshaping `LoopCommand` from struct(kind, options) to an enum with
  per-case payloads is source-breaking for library consumers of
  `RielaCLI` types even though CLI behavior is identical — covered in
  migration notes.

#### `Sources/RielaCLI/LoopCommands.swift` (list/history/recover-from-gate)

**Status**: COMPLETE_LA1A

**Checklist**:

- [x] `loop list`/`loop history` load via `loadSessionOverviews`; render
  JSONL/JSON/text/table; `--gate-decision` filters on `lastGateDecision`.
- [x] History threads lineage: rows expose `entryMode`/`sourceSessionId`.
- [x] `--from-gate` resolution: evidence gate result stepId → authored
  `workflow.loop.gates[]` stepId → error listing known gate ids; then
  delegate to `SessionRerunCommand` unchanged.
- [x] Read paths never mutate stored snapshots.

#### `Sources/RielaCLI/LoopStartCommand.swift`

**Status**: NOT_STARTED

```swift
public struct LoopPolicyPanel: Codable, Equatable, Sendable {
  public var workflowId: String
  public var loopKind: String?
  public var required: Bool
  public var mutationRoots: [String]
  public var scratchRoot: String?
  public var commit: String
  public var push: String
  public var nestedProcessPolicy: [String: String]
  public var allowedBackends: [String]
  public var requiredWorkerModel: String?
  public var gates: [LoopGatePanelEntry]
  public var budget: LoopBudgetDeclaration?   // LA2
  public var evidenceRequiredSections: [String]
}
```

**Checklist**:

- [ ] Refuse workflows without `loop` metadata with a `workflow run` hint.
- [ ] Build the panel from `LoopPolicyEvaluator` preflight plus authored
  metadata; never print secret values.
- [ ] Emit the `loop_policy` record (CLI-emitted line, not a runner event)
  before the runner's `session_started` in JSON/JSONL mode; print as a
  text panel in text mode. No interactive confirmation in any mode.
- [ ] Delegate to the existing `workflow run` execution path unchanged
  (same progress records, persistence, evidence projection).

#### `Sources/RielaCLI/LoopPromoteCommand.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Reuse `WorkflowPackageLoopReadiness` checks plus package manifest
  promotion-artifact validation; read-only. Both are currently gated
  (`loop.required == true` / `promotionReady == true`) and would report
  optional-loop workflows as trivially ready — add an advisory mode that
  evaluates every check regardless and labels each issue
  `enforced`/`advisory` (design S2).
- [ ] Output `{ ready: Bool, issues: [...] }` (ready computed over
  enforced issues) in JSONL/JSON/text.
- [ ] Works for project/user-scope workflows and source packages.

### 3. LA2 — Cost Evidence And Budgets

#### `Sources/RielaCore/LoopCostEvidence.swift`

**Status**: NOT_STARTED

```swift
public struct LoopCostEvidence: Codable, Equatable, Sendable {
  public var stepExecutionId: String
  public var backend: String?
  public var model: String?
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?
  public var durationMs: Int?
  public var diagnostics: [String]
}

public struct LoopCostSummary: Codable, Equatable, Sendable {
  public var totalInputTokens: Int?
  public var totalOutputTokens: Int?
  public var totalTokens: Int?
  public var totalDurationMs: Int?
  public var stepsWithUsage: Int
  public var stepsWithoutUsage: Int
}
```

**Checklist**:

- [ ] Add cost value types; `LoopEvidenceManifest` gains
  `costs: [LoopCostEvidence]` and `costSummary: LoopCostSummary?`
  (optional, defaulted decoding).
- [ ] `LoopSessionSummary` carries the compact totals (module 1).
- [ ] Deterministic encoding + legacy-decode tests.

#### `Sources/RielaCore/DeterministicWorkflowRunner+Cost.swift` (usage accumulator)

**Status**: NOT_STARTED

Persisted backend event records drop the usage payload
(`RuntimeStore.swift:644` persists sequence/time/type/channel/content/
toolName only), so cost cannot be projected from the store after the fact.
The runner's backend-event handler receives `AdapterBackendEvent.usage`
live and is the source of truth.

**Checklist**:

- [ ] Accumulate normalized token counts per step and per session inside
  the runner's existing backend-event handling path, reusing the
  `AgentUsageStats` normalization rules for
  `input_tokens`/`output_tokens`/`total_token_usage` shapes (shared
  helper, not a forked parser).
- [ ] Hand accumulated `LoopCostEvidence` to evidence projection at the
  existing projection points (live and final persistence); the projector
  consumes accumulator output, it does not read persisted event rows.
- [ ] Additive optional token-count fields on `WorkflowBackendEventRecord`
  as a secondary improvement for future re-projection; accumulator stays
  authoritative (100-record `recentBackendEvents` eviction can undercount
  persisted rows).
- [ ] Steps without usage events count in `stepsWithoutUsage` with a
  diagnostic; totals are honest partial sums flagged partial when
  `stepsWithoutUsage > 0`; no fabricated numbers. Pre-existing sessions
  render cost as not recorded.
- [ ] Duration from step execution timestamps when present.
- [ ] Add usage-emitting mock adapter support (mock adapters emit no usage
  events today) so cost and budget paths are testable.
- [ ] Tests: codex-style usage events, no-usage backend, mixed sessions,
  eviction case.

#### `Sources/RielaCore/LoopEngineeringModels.swift` + `WorkflowLoopValidation.swift` (budget)

**Status**: NOT_STARTED

```swift
public struct LoopBudgetDeclaration: Codable, Equatable, Sendable {
  public var maxTotalTokens: Int?
  public var maxWallClockMs: Int?
  public var maxSessionAttempts: Int?
  public var onExceeded: String   // "fail" | "warn"
}
```

**Checklist**:

- [ ] Add optional `budget` to `WorkflowLoopMetadata`.
- [ ] Validate: at least one bound present, positive values only,
  `onExceeded` in {fail, warn}; `warn` invalid when `loop.required == true`.
- [ ] Raw validation accepts the new key; absent budget keeps all existing
  workflows valid.

#### `Sources/RielaCore/DeterministicWorkflowRunner+Budget.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Check the usage accumulator's running session totals and session
  wall-clock at step boundaries.
- [ ] Add `WorkflowSessionFailureKind.budgetExceeded` **and build tolerant
  persisted decoding** in the same change: no tolerant-decode pattern
  exists today (`decodeIfPresent(WorkflowSessionFailureKind.self, ...)`
  throws on unknown raw values and fails the whole snapshot). Unknown
  persisted values must decode to a preserved `other(String)`-style
  representation with a diagnostic. Document the old-binary limitation.
- [ ] `onExceeded == "fail"`: fail the session before the next step with a
  deterministic diagnostic; `"warn"`: record a residual risk and continue.
- [ ] `maxSessionAttempts`: add additive `rootSessionId`/`attemptNumber`
  to `LoopRecoveryLineage`, computed at entry from the source session's
  manifest (rerun increments; resume does not — it continues an attempt).
  Enforce at rerun entry by reading the source manifest only; no
  chain-walking (resume lineage is self-referential and parent manifests
  never record children, so chain-walking is not viable).
- [ ] Emit `budget_exceeded` progress record with consumed/allowed values;
  extend the closed `WorkflowRunEventType` enum and the live-persistence
  event switch together (additive JSONL contract change, noted in
  migration notes).
- [ ] Record consumption and the enforcement decision in evidence policy
  decisions plus `costSummary`.
- [ ] Reuse existing cancellation paths; no orphaned agent processes.
- [ ] Tests: token bound trips between steps, wall-clock bound, warn mode,
  attempts bound on rerun, budgetless workflows unaffected.

#### `Sources/RielaCLI/LoopCommands.swift` (cost columns)

**Status**: NOT_STARTED

**Checklist**:

- [ ] `loop list`/`history`/`status` render cost summary columns when
  present; absent cost renders as not recorded, not zero.

### 4. LA3 — Diff, Stats, GraphQL

#### `Sources/RielaCore/LoopEvidenceDiff.swift`

**Status**: NOT_STARTED

```swift
public struct LoopEvidenceDiff: Codable, Equatable, Sendable { /* per design S4 */ }

public enum LoopEvidenceDiffer {
  public static func diff(base: LoopEvidenceManifest, target: LoopEvidenceManifest) -> LoopEvidenceDiff
}
```

**Checklist**:

- [ ] Deterministic matching: gates by `gateId`; blocking findings by
  `(filePath, message)` with line drift tolerated (path-less findings
  bucket under `(nil, message)` — documented behavior); verification by
  joining `LoopVerificationEvidence.commandRef` to that manifest's
  `LoopCommandEvidence.argvSummary` and matching on the summary string
  (command ids are not stable across sessions); changed files by path.
- [ ] `sameWorkflow: false` + diagnostic for cross-workflow diffs;
  `workflowDefinitionDigestChanged` nil when either digest is absent.
- [ ] Cost delta only when both sides carry summaries.
- [ ] Pure function, no I/O; exhaustive fixture tests including identical
  manifests (empty diff) and disjoint gate sets.

#### `Sources/RielaCore/LoopWorkflowStats.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Bounded-window aggregation (default 50, `--limit` override) over
  `LoopSessionSummary` rows loaded via the summary API: run counts,
  accepted runs (all required gates accepted — requiredness comes from the
  summary's frozen `gateOutcomes`, never from re-reading workflow
  definitions), `gateFailureCounts` by gateId, rerun count, mean duration
  and tokens over rows that carry them, `lastAcceptedSessionId`.
- [ ] Diagnostics note partial cost coverage and evidence-less rows.
- [ ] Pure aggregation over inputs loaded via the summary API; no
  `loadAll()`.

#### `Sources/RielaCLI/LoopCommands.swift` (diff/stats)

**Status**: NOT_STARTED

**Checklist**:

- [ ] Parse and run `loop diff <a> <b>` and `loop stats <workflow>
  [--limit]`; JSONL/JSON/text rendering.
- [ ] Missing session or missing evidence yields a typed error, not an
  empty diff.

#### `Sources/RielaGraphQL/GraphQLContracts.swift` + `RielaGraphQL.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] DTOs: `GraphQLLoopSessionOverviewDTO`, `GraphQLLoopWorkflowStatsDTO`,
  `GraphQLLoopEvidenceDiffDTO`.
- [ ] Queries: `loopSessions(workflowId, status, limit)`,
  `loopWorkflowStats(workflowId!, limit)`,
  `loopEvidenceDiff(baseSessionId!, targetSessionId!)`.
- [ ] Project from the same persisted summary/manifest reads as the CLI —
  no GraphQL-only computation.
- [ ] Schema contract and selection tables updated together (round-trip
  test per architecture-review guidance).

### 5. LA4 — CI Verdict Contract

#### `Sources/RielaCLI/LoopCommands.swift` (`gates --check`)

**Status**: NOT_STARTED

**Checklist**:

- [ ] `--check` evaluates: exit 0 all required gates present+accepted;
  exit 3 required gate rejected/needs_work/missing or blocking findings on
  a required gate; exit 4 no loop evidence recorded; exit 1 operational
  error.
- [ ] Quiet JSONL verdict summary; read-only.
- [ ] Contract tests pin all four codes explicitly (guard against later
  exit-code unification).

#### `Sources/RielaCLI/LoopFindingsExport.swift`

**Status**: NOT_STARTED

```swift
public enum LoopFindingsSARIFExporter {
  public static func sarif(manifest: LoopEvidenceManifest, gateId: String?) -> JSONObject
}
```

**Checklist**:

- [ ] SARIF 2.1.0: one run, `tool.driver.name = "riela-loop"`, one rule per
  gateId, one result per blocking finding; severity mapping high→error,
  medium→warning, low|informational→note, unknown severity strings→warning
  with the original value in `result.properties`.
- [ ] `physicalLocation` only when `filePath` present; session/gate ids in
  `result.properties`.
- [ ] `loop findings <session-id> [--gate <gate-id>] --format sarif|json`
  command; `json` emits typed findings.
- [ ] No environment or variable values in output.
- [ ] Golden-file test validating the SARIF shape; empty-findings session
  emits a valid empty run.

#### `examples/loop-ci-gate-check/`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Example workflow + GitHub Actions YAML using `loop gates --check` and
  SARIF upload as documentation.
- [ ] `EXPECTED_RESULTS.md` and mock scenario per first-party example
  conventions.

---

## Later Phases (outline only — module specs written when the phase starts)

### LA5 — Distilled Loop Lessons

`Sources/RielaCore/LoopLessonRecord.swift`, a SQLite-backed
`LoopLessonStore` under the data root, `riela loop lesson
add/list/show/revoke`, opt-in injection via `loop.lessons.inject` exposing
`_rielaLoopLessons` with evidence recording of injected lesson ids, 4 KiB
body cap, default `redactionStatus: unverified`, expiry and
`workflow-definition-changed` invalidation.

### LA6 — Isolation And App Timeline

`loop start --isolate worktree`: `git worktree add` under the data root's
`loop-worktrees/<run-id>` (outside the repository — a worktree inside the
primary worktree would pollute its `git status` and changed-file evidence;
the run id is generated by `loop start` because session ids are allocated
inside the runner, too late to name the directory), marker-file ownership
check, auto-remove only unchanged worktrees, evidence records worktree
path (additive `isolatedWorktreePath` on `LoopWorktreeSummary`, which has
no path field today)/base commit/dirty summary. RielaApp loop evidence
timeline pane after the architecture-review RielaApp restructuring
(DaemonInstanceStore extraction) lands.

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Overview model | `Sources/RielaCore/LoopSessionOverview.swift` | COMPLETE_LA1A | `LoopSessionOverviewTests` |
| Summary SQL + column | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | COMPLETE_LA1A | `SQLiteWorkflowMessageLogTests` summary overview cases |
| CLI parser additions | `Sources/RielaCLI/RielaCommand.swift` | COMPLETE_LA1A | `CommandParsingTests` |
| loop list/history/recover-from-gate | `Sources/RielaCLI/LoopCommands.swift` | COMPLETE_LA1A | `WorkflowCommandTests`, `WorkflowCommandLivePersistenceTests` |
| loop start | `Sources/RielaCLI/LoopStartCommand.swift` | NOT_STARTED | planned |
| loop promote | `Sources/RielaCLI/LoopPromoteCommand.swift` | NOT_STARTED | planned |
| Cost models | `Sources/RielaCore/LoopCostEvidence.swift` | NOT_STARTED | planned |
| Usage accumulator | `Sources/RielaCore/DeterministicWorkflowRunner+Cost.swift` | NOT_STARTED | planned |
| Budget metadata + validation | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift` | NOT_STARTED | planned |
| Budget enforcement | `Sources/RielaCore/DeterministicWorkflowRunner+Budget.swift` | NOT_STARTED | planned |
| Evidence diff | `Sources/RielaCore/LoopEvidenceDiff.swift` | NOT_STARTED | planned |
| Workflow stats | `Sources/RielaCore/LoopWorkflowStats.swift` | NOT_STARTED | planned |
| Diff/stats CLI | `Sources/RielaCLI/LoopCommands.swift` | NOT_STARTED | planned |
| GraphQL projections | `Sources/RielaGraphQL/GraphQLContracts.swift`, `RielaGraphQL.swift` | NOT_STARTED | planned |
| gates --check | `Sources/RielaCLI/LoopCommands.swift` | NOT_STARTED | planned |
| SARIF export | `Sources/RielaCLI/LoopFindingsExport.swift` | NOT_STARTED | planned |
| CI example | `examples/loop-ci-gate-check/` | NOT_STARTED | planned |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Overview model + summary SQL | Persisted `loopEvidence` snapshots, `LoopEvidenceSummary` | Available |
| loop list/history | Summary SQL | This plan (module 1) |
| loop recover --from-gate | Evidence manifests, `SessionRerunCommand` | Available |
| loop start policy panel | `LoopPolicyEvaluator` preflight | Available |
| loop promote | `WorkflowPackageLoopReadiness`, manifest promotion validation | Available |
| Usage accumulator | Live `AdapterBackendEvent.usage` in the runner's event handler, `AgentUsageStats` normalization | Available (live only; persisted records drop usage payloads) |
| Cost evidence | Usage accumulator | This plan (module 3) |
| Budget enforcement | Usage accumulator (shared totals); tolerant failure-kind decoding | This plan (module 3) |
| Diff/stats | Summary SQL, evidence manifests, cost summary | This plan (modules 1, 3) |
| GraphQL projections | Overview/diff/stats models | This plan (module 4) |
| gates --check / SARIF | Gate results, blocking findings | Available |
| LA5 lessons | Evidence manifests; shared SQLite infra | Available (phase not started) |
| LA6 isolation/UI | Scratch-root policy; RielaApp restructuring (arch review P2) | Blocked on arch review work for UI |
| Self-improve rationale from stats | LA3 stats + first-line plan module 8 | Cross-plan |

## Dependency Ordering

1. Overview model and summary SQL (everything cross-run reads through it).
2. Cockpit CLI: list, history, recover --from-gate, start, promote.
3. Cost models and projection; then budget metadata, validation, and
   runner enforcement.
4. Diff and stats cores; then their CLI; then GraphQL projections.
5. gates --check contract; SARIF export; CI example.
6. LA5 lessons; LA6 isolation and app timeline (specs authored at phase
   start).

## Test Plan By Module

- Overview/summary: `swift test --filter LoopSessionOverviewTests`,
  summary-consistency regression in the SQLite store tests.
- CLI parsing: `swift test --filter CommandParsingTests`.
- Cockpit commands: `swift test --filter WorkflowCommandTests` and
  `WorkflowCommandLivePersistenceTests` (list/history against persisted
  fixtures; from-gate resolution; start policy panel record ordering).
- Cost/budget: `swift test --filter LoopEvidenceProjectorTests`,
  `swift test --filter DeterministicWorkflowRunnerTests` (budget cases).
- Diff/stats: `swift test --filter LoopEvidenceDiffTests`,
  `swift test --filter LoopWorkflowStatsTests`.
- GraphQL: `swift test --filter GraphQLContractsTests`.
- CI contract: exit-code contract tests + SARIF golden-file test in
  `Tests/RielaCLITests`.
- Final acceptance per phase: full `swift test` and `swiftlint`.

## Completion Criteria

- [x] `loop list`/`history` render persisted loop sessions without
  `loadAll()` full-store scans; legacy sessions appear with
  `loopEvidenceRecorded: false`.
- [x] `loop recover --from-gate` reruns from the gate's step with lineage
  recorded; `--from-step` unchanged.
- [ ] `loop start` shows the policy panel (record in JSONL mode) before
  `session_started` and otherwise matches `workflow run` behavior.
- [ ] `loop promote` reports promotion readiness without mutation.
- [ ] Evidence manifests carry per-step and summary token/duration cost
  with honest partial flags; no fabricated values.
- [ ] Budget-declaring loops fail closed (or warn, where allowed) at step
  boundaries with `budgetExceeded` evidence; budgetless workflows are
  unaffected.
- [ ] `loop diff` and `loop stats` produce deterministic outputs from
  persisted records only.
- [ ] GraphQL loop queries project from the same persisted reads as CLI.
- [ ] `loop gates --check` exit codes 0/3/4/1 are pinned by contract tests;
  SARIF output validates against the golden file.
- [x] All schema changes are additive; pre-existing snapshots, workflows,
  and package manifests decode and behave unchanged.
- [ ] Full `swift test` passes; `swiftlint` clean apart from pre-existing
  warnings. `swiftlint` is clean for LA1a; full `swift test` was attempted
  in this rerun and exited 1 without a final XCTest summary after
  `EventLiveServeSlackTests.testSlackGatewayServeDoesNotAdvanceOffsetWhenWorkflowProcessingFails`.

## Migration And Backward-Compatibility Notes

- `workflow_id`/`session_status`/`created_at`/`loop_summary_json` added via
  `ALTER TABLE`; save-path-only writes plus a one-shot writable-open
  backfill sweep; reads never write (read-only connections preserved), with
  bounded blob-decode fallback for not-yet-backfilled rows.
- New manifest/summary fields decode from absent data as nil/empty.
- `WorkflowSessionFailureKind.budgetExceeded` requires building tolerant
  persisted-enum decoding (none exists today — unknown raw values currently
  fail the whole snapshot decode); ships in the same change. Binaries
  predating that change cannot decode budget-failed sessions — accepted,
  documented limitation.
- `budget_exceeded` extends the closed `WorkflowRunEventType` JSONL
  progress vocabulary (additive record type; consumers should ignore
  unknown types); `loop_policy` is a CLI-emitted line from `loop start`,
  not a runner event.
- `LoopCommand` parser type reshape (struct → enum) is source-breaking for
  library consumers of `RielaCLI` types; CLI parse behavior unchanged.
- New exit codes apply only behind `--check`; default `loop gates` output
  and codes unchanged.
- `--isolate` is parsed-and-rejected until LA6 so the flag name is
  reserved without behavior drift.

## Progress Log

### Session: 2026-07-05 Step 6 LA1a Step 7 review-finding fix

**Tasks Completed**: Addressed Step 7 implementation-review findings.
Changed `loadSessionOverviews` so current-schema reads build
`LoopSessionOverview` from `workflow_id`, `session_status`, `created_at`,
`updated_at`, and `loop_summary_json` without selecting or decoding
`session_json`/`loop_evidence_json`; blob fallback is now reserved for
pre-summary-column rows or rows with missing/null summary data that still
advertise loop evidence. Changed the default stale threshold from 3600
seconds to 600 seconds. Added regressions for a running row older than 10
minutes and for current-schema overview reads surviving poisoned
`session_json`/`loop_evidence_json` blobs when summary columns are present.
**Addressed Feedback**: Fixed mid finding
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:177`
(overview reads decoded blobs for every row) and mid finding
`Sources/RielaCore/LoopSessionOverview.swift:224` (default stale threshold
was 3600 seconds instead of 600 seconds).
**Verification**:
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter LoopSessionOverviewTests` (3 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SQLiteWorkflowMessageLogTests` (12 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CommandParsingTests` (18 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests` (95 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandLivePersistenceTests` (8 tests).
- FAIL: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test` exited 1 without a final XCTest summary after `EventLiveServeSlackTests.testSlackGatewayServeDoesNotAdvanceOffsetWhenWorkflowProcessingFails`; preceding emitted suites were passing.
- PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` reported 0 violations.
**Tasks In Progress**: None for Step 7 review-finding fixes.
**Blockers**: Full-suite `swift test` still lacks a clean terminal pass; the
failure point is outside the modified LA1a summary SQL/staleness surfaces.

### Session: 2026-07-05 Step 6 LA1a review-finding fix

**Tasks Completed**: Addressed Step 6 self-review findings before Step 7.
Changed `loadSessionOverviews` to overfetch bounded ordered windows and
apply workflow/status/gate-decision filtering before returning the requested
limit, so newer nonmatching or null-column rows cannot hide older matches.
Extended `WorkflowRuntimePersistenceSnapshot` and the projector with optional
authored `WorkflowLoopMetadata`, passed that metadata from workflow run,
rerun, resume, and failed-resume persistence paths, and used it when freezing
`loop_summary_json` so saved summaries retain `loopKind`, `loopRequired`,
and gate requiredness. Added SQLite regressions for both findings.
**Addressed Feedback**: Fixed medium finding
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:153`
(`LIMIT` before final filtering) and medium finding
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:270`
(persisted summary omitted authored loop metadata).
**Verification**:
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter LoopSessionOverviewTests` (3 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SQLiteWorkflowMessageLogTests` (11 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CommandParsingTests` (18 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests` (95 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandLivePersistenceTests` (8 tests).
- NO-OP: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandInspectionTests` matched 0 tests because the file extends `WorkflowCommandTests`.
- PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` reported 0 violations.
**Tasks In Progress**: None for LA1a review-finding fixes.
**Blockers**: Full-suite `swift test` still lacks a clean terminal pass from
the prior Step 6 attempt; it was not rerun in this focused fix pass.

### Session: 2026-07-05 Step 6 LA1a implementation

**Tasks Completed**: Implemented LA1a summary and cockpit surfaces. Added
`LoopSessionOverview`, `LoopSessionSummary`, `LoopGateOutcome`,
`LoopGateSummaryCounts`, and placeholder nil-only `LoopCostSummary` fields
for later LA2 compatibility. Extended SQLite runtime persistence with
additive `workflow_id`, `session_status`, `created_at`, and
`loop_summary_json` columns; save-path summary derivation; bounded
writable-open backfill; and read-only `loadSessionOverviews` with decoded
fallback filtering for legacy/not-yet-backfilled rows. Added `loop list`
and `loop history` parsing/execution with `--workflow`, `--status`,
`--gate-decision`, `--limit`, and JSONL/JSON/text/table output. Added
`loop recover --from-gate` parsing and runtime resolution from persisted
evidence first, authored workflow loop metadata second, delegating to
existing `SessionRerunCommand`; `--from-step` behavior remains unchanged.
Updated top-level loop help text. Added focused model, persistence, parser,
and CLI integration tests.
**Addressed Feedback**: Step 5 had no high or mid findings. Scope stayed
within accepted LA1a; `loop start`, `loop promote`, costs/budgets,
diff/stats, GraphQL, CI/SARIF, lessons, worktree isolation, and RielaApp
timeline remain deferred.
**Verification**:
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter LoopSessionOverviewTests` (3 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SQLiteWorkflowMessageLogTests` (9 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CommandParsingTests` (18 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests.testSessionRerunUsesPersistedSessionStore` (1 test).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests` (95 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandLivePersistenceTests` (8 tests).
- PASS: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests.testTopLevelHelpReturnsSuccessfulSmokeOutput` (1 test).
- NO-OP: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandInspectionTests` matched 0 tests because the file extends `WorkflowCommandTests`; reran the specific changed test above.
- STALLED/STOPPED: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test` ran many passing tests but produced no final summary after repeated polling; the remaining `xctest` process was terminated and no test runner remained afterward.
- PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` after fixing one new test warning; final run reported 0 violations.
**Tasks In Progress**: None for LA1a.
**Blockers**: Full-suite `swift test` needs a clean terminal run in a later
verification window; focused LA1a and affected CLI/persistence suites pass.

### Session: 2026-07-05 Step 4 implementation-plan creation

**Tasks Completed**: Revised this plan after Step 3 accepted the design.
Narrowed the controlling implementation handoff to LA1a from
`design-docs/specs/design-loop-engineering-application-gap-closure.md`:
summary models, SQLite summary columns/read API, `loop list`,
`loop history`, and `loop recover --from-gate`. Marked `loop start` and
`loop promote` as LA1b/later work for this pass, matching the accepted
design review's LA1a boundary. Added explicit LA1a task breakdown,
deliverables, dependencies, parallelization rules, verification commands,
completion criteria, and progress-log expectations.
**Addressed Feedback**: Step 3 reported no high or mid severity findings and
accepted the design. Its review decisions are incorporated here by treating
the design doc's "Current implementation handoff (LA1a)" as controlling
scope, preserving later LA1b/LA2+ roadmap boundaries, and avoiding new
implementation code in the planning step.
**Tasks In Progress**: None; plan is ready for the later implementation
step.
**Blockers**: None for LA1a planning.

### Session: 2026-07-05

**Tasks Completed**: Authored design
`design-loop-engineering-application-gap-closure.md` (current-state review,
gap analysis G1–G9, specifications S1–S8, phased roadmap LA1–LA6) and this
implementation plan with detailed LA1–LA4 modules. Ran an adversarial
code-grounding self-review of both documents and folded the findings back
in: cost sourcing corrected to a runner-owned live usage accumulator
(persisted backend event records drop usage payloads at
`RuntimeStore.swift:644`); summary column respecified as a new
`LoopSessionSummary` shape plus real `workflow_id`/`session_status`/
`created_at` columns; write-on-read backfill replaced with save-path writes
and a one-shot writable-open sweep; `maxSessionAttempts` respecified via
additive `rootSessionId`/`attemptNumber` lineage fields; tolerant
failure-kind decoding identified as new required work; `loop start`
interactive confirmation dropped; `loop promote` advisory mode added;
worktree isolation moved outside the repository; diff/SARIF matching rules
made precise. Review verdicts on 11 grounding claims confirmed correct are
recorded in the design doc's Review Note.
**Tasks In Progress**: None; plan is in Planning status.
**Blockers**: None for planning. LA6 RielaApp timeline is sequenced after
the architecture-review RielaApp restructuring.
**Notes**: No workflows were run and no Swift sources were modified during
this authoring step.

## Related Plans

- **Previous**: `impl-plans/active/loop-engineering-first-line-tool.md`
  (first-line primitives; its module 8 self-evolution versioning proceeds
  in parallel).
- **Design**: `design-docs/specs/design-loop-engineering-application-gap-closure.md`
- **Depends On**: `design-docs/specs/design-riela-architecture-review.md`
  (summary-SQL direction, exit-code unification, RielaApp restructuring).
