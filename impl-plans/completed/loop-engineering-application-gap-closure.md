# Loop Engineering Application Gap Closure Implementation Plan

**Status**: LA1a–LA4 COMPLETE (2026-07-12). All planned phases are implemented and verified: LA1a cockpit (list/history/recover-from-gate), LA1b `loop start` policy panel + `loop promote` advisory readiness, LA2 cost evidence + usage accumulation/persistence + budget declaration/validation + runner step-boundary enforcement (`budget_exceeded` event, warn-mode residual risk, `maxSessionAttempts` via `LoopRecoveryLineage` rootSessionId/attemptNumber), LA3 diff/stats cores + CLI + GraphQL projections, LA4 `gates --check` exit-code contract + SARIF export + CI example. LA5 (lessons) and LA6 (worktree isolation + app timeline) remain outline-only later phases — explicitly deferred: owner = next loop-engineering session; trigger = demand for lesson injection (LA5) / the RielaApp loop timeline iteration (LA6); per this plan's convention their module specs are authored at phase start and carry no checkboxes. The only open checkbox is the final full-suite acceptance run.
**Design Reference**: `design-docs/specs/design-loop-engineering-application-gap-closure.md`
**Created**: 2026-07-05
**Last Updated**: 2026-07-12

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
- [x] Parse `loop start <workflow> [--var k=v ...]`
  (`--isolate` is LA6; parser reserves and rejects it with a clear
  "not yet supported" diagnostic). No `--yes`/confirmation flag — the CLI
  has no interactive prompts and invocation is consent (design S2).
  `LoopCommandKind` gained `.start`/`.promote` (struct `LoopCommand` kept —
  the enum reshape was already rejected as source-breaking in LA1a); `--var`
  pairs are collected into inline `--variables` JSON (combining both forms is
  a usage error) and the remainder parses through the real `workflow run`
  parser so run options behave identically. Tests:
  `LoopStartPromoteCommandTests` (parse kinds, missing-id usage error, --var
  collection, --isolate rejection, --var/--variables conflict, malformed
  --var).
- [x] Parse `loop promote <workflow>` (same parser branch; workflow-id-vs-
  session-id usage diagnostics cover start/promote).
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

**Status**: DONE (2026-07-12)

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

- [x] Refuse workflows without `loop` metadata with a `workflow run` hint.
  Smoke: `loop start apple-calendar-fetch` → usage error naming
  `riela workflow run apple-calendar-fetch`.
- [x] Build the panel from `LoopPolicyEvaluator` preflight plus authored
  metadata; never print secret values. `LoopPolicyPanel` carries policy names
  and declared bounds only (mutation roots/scratch/commit/push, nested
  process, allowed backends, worker model, gates, budget, evidence sections);
  values come from `preflight().effective` with authored fallback.
- [x] Emit the `loop_policy` record (CLI-emitted line, not a runner event)
  before the runner's `session_started` in JSON/JSONL mode; print as a
  text panel in text mode. No interactive confirmation in any mode.
  Smoke on `loop-ci-gate-check` (mock scenario): first JSONL line is
  `{"type":"loop_policy","panel":{...}}`, second is `session_started`.
- [x] Delegate to the existing `workflow run` execution path unchanged
  (same progress records, persistence, evidence projection): the command
  re-parses passthrough tokens as `workflow run` options and awaits
  `WorkflowRunCommand.run` verbatim, prefixing only the panel output.

#### `Sources/RielaCLI/LoopPromoteCommand.swift`

**Status**: DONE (2026-07-12)

**Checklist**:

- [x] Reuse `WorkflowPackageLoopReadiness` checks plus package manifest
  promotion-artifact validation; read-only. Both are currently gated
  (`loop.required == true` / `promotionReady == true`) and would report
  optional-loop workflows as trivially ready — add an advisory mode that
  evaluates every check regardless and labels each issue
  `enforced`/`advisory` (design S2). Added ungated variants without changing
  the gated behavior: `packageLoopReadinessIssues(evaluating:)` (RielaCLI),
  `WorkflowPackageManifestValidator.loopPromotionReadinessIssues(_:)` and
  `.loopPromotionArtifactIssues(_:packageRoot:)` (RielaAddons; the gated
  validators now delegate to the shared bodies). Workflow checks are enforced
  when `loop.required`, package checks when `manifest.loop.promotionReady`.
- [x] Output `{ ready: Bool, issues: [...] }` (ready computed over
  enforced issues) in JSONL/JSON/text. Smoke: `loop promote
  loop-ci-gate-check` → `ready: false` with three enforced readiness issues.
- [x] Works for project/user-scope workflows and source packages
  (resolution honors `--scope`/`--workflow-definition-dir`; package-manifest
  checks run when the bundle carries a manifest). Tests:
  `LoopStartPromoteCommandTests` promote cases (advisory optional-loop,
  enforced required-loop, missing loop metadata, package manifest
  advisory/enforced).

### 3. LA2 — Cost Evidence And Budgets

#### `Sources/RielaCore/LoopCostEvidence.swift`

**Status**: DONE (value types + manifest fields, 2026-07-12). Usage accumulator
and budget sub-modules below remain NOT_STARTED.

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

- [x] Add cost value types; `LoopEvidenceManifest` gains
  `costs: [LoopCostEvidence]` and `costSummary: LoopCostSummary?`
  (optional, defaulted decoding). `LoopCostEvidence` added in
  `Sources/RielaCore/LoopCostEvidence.swift`; `LoopCostSummary` already existed
  from LA1a (`LoopSessionOverview.swift`) and is not duplicated. The manifest
  gained a faithful custom `Codable` (existing fields decode/encode unchanged;
  `costs` defaults to `[]`, is omitted from output when empty, and `costSummary`
  defaults to `nil`), so pre-cost manifests serialize byte-identically and
  decode unchanged.
- [x] `LoopSessionSummary` carries the compact totals (module 1). Present since
  LA1a (`LoopSessionSummary.cost` / `LoopSessionOverview.cost`);
  `LoopCostSummary.make(from:)` now derives honest partial totals from per-step
  evidence.
- [x] Deterministic encoding + legacy-decode tests.
  `Tests/RielaCoreTests/LoopCostEvidenceTests.swift` (6 tests): cost-evidence
  round-trip, legacy cost-evidence decode, partial-sum summary logic +
  `isPartial`, all-usage summary, manifest round-trip with costs, and manifest
  legacy decode asserting omitted keys. Full `swift test` 1,739 tests / 4 skips /
  0 unexpected failures.

#### `Sources/RielaCore/DeterministicWorkflowRunner+Cost.swift` (usage accumulator)

**Status**: Cost accumulation + projection + persistence DONE and verified
end-to-end 2026-07-12 (via execution-`recentBackendEvents` folding, no runner
threading). Only the *secondary* SQLite persistence of usage on
`WorkflowBackendEventRecord` (for re-projection after the in-memory 100-event
eviction) remains — the accumulator stays authoritative and the primary path
works.

Persisted backend event records drop the usage payload
(`RuntimeStore.swift:644` persists sequence/time/type/channel/content/
toolName only), so cost cannot be projected from the store after the fact.
The runner's backend-event handler receives `AdapterBackendEvent.usage`
live and is the source of truth.

**Checklist**:

- [x] Accumulate normalized token counts per step and per session. Normalization
  + per-step accumulation in `LoopCostAccumulator`. Wired **without** threading a
  live accumulator through the runner: the backend-event handler already persists
  each `usage` event onto the execution's `recentBackendEvents`, and
  `LoopCostAccumulator.evidence(from:)` folds those per agent execution (skips
  non-agent nodes; counts agent steps that emitted no usage). Shared helper, not a
  forked parser.
- [x] Hand accumulated `LoopCostEvidence` to evidence projection; the projector
  consumes accumulator output, it does not read persisted event rows.
  `DefaultLoopEvidenceProjector` uses explicit `input.costs` when provided and
  otherwise derives cost from `input.session.executions` via
  `LoopCostAccumulator.evidence(from:)`, setting `manifest.costs`/`costSummary`.
  **Verified end-to-end**: running `loop-ci-gate-check` with a usage-emitting mock
  scenario then `loop status` shows real cost (`totalInputTokens: 1200,
  totalOutputTokens: 300, totalTokens: 1500, stepsWithUsage: 1`) — projected,
  persisted in the manifest, and read back post-reload. Tests:
  `LoopCostAccumulatorTests.testEvidenceFromExecutionsFoldsBackendEventUsage`,
  `LoopEvidenceProjectorTests.testProjectorDerivesCostFromExecutionBackendEvents`.
- [x] Additive optional token-count fields on `WorkflowBackendEventRecord`
  as a secondary improvement for future re-projection; accumulator stays
  authoritative (100-record `recentBackendEvents` eviction can undercount
  persisted rows). Landed as the optional `usage: JSONObject?` payload on the
  record (richer than bare token counts — `LoopCostAccumulator` normalizes it
  at re-projection): `RuntimeStore.appendRecentBackendEvent` persists
  `input.usage` onto every record, and executions reload with the payload
  intact (asserted in the eviction tests below). The earlier plan note that
  persistence drops usage is stale.
- [x] Steps without usage events count in `stepsWithoutUsage` with a
  diagnostic; totals are honest partial sums flagged partial when
  `stepsWithoutUsage > 0`; no fabricated numbers. Implemented in
  `LoopCostAccumulator`/`LoopCostSummary.make(from:)`/`isPartial` and tested
  (`LoopCostAccumulatorTests`: no-usage + mixed cases). Pre-existing sessions
  render cost as not recorded (nil `costSummary`).
- [x] Duration from step execution timestamps when present. `LoopCostAccumulator`
  accepts an explicit `durationMs` and otherwise derives it from the span of
  observed usage-event timestamps (tested).
- [x] Add usage-emitting mock adapter support (mock adapters emit no usage
  events today) so cost and budget paths are testable. `MockNodeResponse` gained
  an optional `usage` JSONObject; `ScenarioNodeAdapter.execute` emits a `.usage`
  backend event (via `context.backendEventHandler`) before returning when it is
  present. Tests: `ScenarioNodeAdapterUsageTests` (emits with payload / omits
  when unset). Existing scenarios decode unchanged (optional field).
- [x] Tests: codex-style usage events, no-usage backend, mixed sessions,
  eviction case. `LoopCostAccumulatorTests` (10 tests): codex-style single
  total (`testCodexStyleSingleTotalUsageEvent`), cumulative last-value-wins,
  no-usage step diagnosis, mixed-session ordering + partial totals, duration
  derivation/override, execution folding, backend/model backfill, plus two
  eviction cases through a real `InMemoryWorkflowRuntimeStore` round-trip:
  usage arriving after 120 deltas survives the 100-record cap (persisted
  `usage` payload asserted on the reloaded record) and early usage evicted by
  later records degrades to honest `stepsWithoutUsage`/nil totals — never a
  fabricated number.

#### `Sources/RielaCore/LoopEngineeringModels.swift` + `WorkflowLoopValidation.swift` (budget)

**Status**: DONE (declaration + validation, 2026-07-12). Runner enforcement is
the separate `DeterministicWorkflowRunner+Budget.swift` module below, still
NOT_STARTED.

```swift
public struct LoopBudgetDeclaration: Codable, Equatable, Sendable {
  public var maxTotalTokens: Int?
  public var maxWallClockMs: Int?
  public var maxSessionAttempts: Int?
  public var onExceeded: String   // "fail" | "warn"
}
```

**Checklist**:

- [x] Add optional `budget` to `WorkflowLoopMetadata`. Added `LoopBudgetDeclaration`
  and the optional `budget` field (property, coding key, memberwise init,
  tolerant `decodeIfPresent`) mirroring `convergence`.
- [x] Validate: at least one bound present, positive values only,
  `onExceeded` in {fail, warn}; `warn` invalid when `loop.required == true`.
  Implemented in `validateTypedLoopBudget`.
- [x] Raw validation accepts the new key; absent budget keeps all existing
  workflows valid. Implemented in `validateRawLoopBudget` (wired into
  `validateRawLoopMetadata`); absent `budget` returns early. Tests:
  `WorkflowLoopValidationTests` gains accept/invalid-bounds/unknown-onExceeded
  cases (16 tests green); full `swift test` 1,742 tests / 4 skips / 0 unexpected.

#### `Sources/RielaCore/DeterministicWorkflowRunner+Budget.swift`

**Status**: DONE (2026-07-12, second pass). Step-boundary enforcement, the
`budget_exceeded` event, warn-mode evidence, and `maxSessionAttempts` lineage
enforcement all landed (in `DeterministicWorkflowRunner+LoopPolicy.swift`
rather than a separate `+Budget.swift` — the boundary hook shares the loop
policy module).

**Checklist**:

- [x] Check the usage accumulator's running session totals and session
  wall-clock at step boundaries. `enforceLoopBudgetAtStepBoundary` reloads the
  session at each boundary (first boundary skipped) and evaluates the pure
  `loopBudgetViolationDetails` (token totals via `LoopCostAccumulator`, wall
  clock from `session.createdAt`); absent usage never fabricates a violation.
- [x] Add `WorkflowSessionFailureKind.budgetExceeded` **and build tolerant
  persisted decoding**. Added `WorkflowSessionFailureKind.budgetExceeded` (+
  registered in `knownRawValues`). **Note (stale plan text):** the tolerant
  decode already exists — `WorkflowSessionFailureKind` was refactored (in the
  LB1 pass) from a closed enum to a `RawRepresentable` struct that decodes any
  raw string and exposes `compatibilityDiagnostic` for unknown values, so
  unknown persisted kinds are already preserved with a diagnostic rather than
  failing the snapshot. Test: `RuntimeSessionTests.testBudgetExceededFailureKindRoundTripsAndIsKnown`
  (plus the existing unknown-raw-value tolerance tests). 9 suite tests green.
- [x] `onExceeded == "fail"`: fail the session before the next step with a
  deterministic diagnostic; `"warn"`: record a residual risk and continue.
  Fail throws `loopBudgetExceeded` (finalized as `failureKind: budgetExceeded`
  through the existing interrupted-session path); warn continues and
  `DefaultLoopEvidenceProjector.budgetProjection` records an accepted
  `LoopResidualRisk` (owner `loop-budget`, severity medium) from the same
  deterministic persisted inputs.
- [x] `maxSessionAttempts`: additive `rootSessionId`/`attemptNumber` on
  `LoopRecoveryLineage` (optional; legacy decodes to nil = attempt one).
  Run entries start at attempt 1; resume carries the source attempt; rerun
  increments from `DeterministicWorkflowRunRequest.sourceRecoveryLineage`,
  which the CLI rerun/resume commands populate from the source session's
  persisted manifest (`persistedRecoveryLineage` in `SessionCommands.swift`)
  — source-manifest read only, no chain-walking. `enforceLoopSessionAttempts`
  fails entry with the deterministic diagnostic when the new attempt exceeds
  the bound.
- [x] Emit `budget_exceeded` progress record with consumed/allowed values.
  `WorkflowRunEventType.budgetExceeded` + `LoopBudgetExceededPayload`
  (diagnostic/action/consumedTokens/maxTotalTokens/elapsedMs/maxWallClockMs)
  added together with telemetry switches and the live-persistence trigger
  switch (`workflowRunEventTriggersLiveSessionPersistence`). Emitted once per
  session at the violating boundary in both fail and warn modes.
- [x] Record consumption and the enforcement decision in evidence policy
  decisions plus `costSummary`. The projector appends a `LoopPolicyDecision`
  (`policy: "budget"`, decision `within-budget`/`exceeded-warn`/
  `exceeded-fail`, reason = consumed vs declared bounds); a session failed
  with `budgetExceeded` always records `exceeded-fail` even when persisted
  rows cannot reproduce the live reading.
- [x] Reuse existing cancellation paths; no orphaned agent processes.
  Enforcement runs only between steps (no live agent process) and failure
  reuses the existing `finalizeInterruptedSessionFailed` path with the
  established `budgetExceeded` failure-kind mapping.
- [x] Tests: token bound trips between steps, wall-clock bound, warn mode,
  attempts bound on rerun, budgetless workflows unaffected.
  `DeterministicWorkflowRunnerBudgetTests` (18 tests): pure evaluation (4),
  runner fail/warn/budgetless/wall-clock, single `budget_exceeded` emission +
  payload, event Codable round-trip, rerun attempt increment + root recording,
  attempts-bound rerun refusal, legacy-lineage tolerance, and projector
  decision/residual-risk cases (4). All green with
  `LoopEvidenceProjectorTests`/`LoopCostAccumulatorTests`/
  `RuntimeSessionTests`/`LoopEvidenceDiffTests`/`WorkflowLoopValidationTests`.

#### `Sources/RielaCLI/LoopCommands.swift` (cost columns)

**Status**: DONE (2026-07-12).

**Checklist**:

- [x] `loop list`/`history`/`status` render cost summary columns when
  present; absent cost renders as not recorded, not zero. `renderOverviews`
  (list/history) gains a `cost:` text line and a `COST` table column via
  `LoopCommandRunner.costCell`; `renderStatus` appends a `cost:` line.
  `LoopEvidenceSummary` gained an optional `cost` (populated from
  `manifest.costSummary`) so `loop status` surfaces it. Absent → `not-recorded`,
  recorded-but-no-usage → `no-usage`, partial totals flagged `(partial)`. Tests:
  `LoopCommandRenderingTests` (4 cases). JSON/JSONL already include `cost` via
  the `LoopSessionOverview`/`LoopEvidenceSummary` Codable. Full suite 1,767 / 0
  unexpected.

### 4. LA3 — Diff, Stats, GraphQL

#### `Sources/RielaCore/LoopEvidenceDiff.swift`

**Status**: DONE (2026-07-12). Publishes the shared `LoopEvidenceDiff` contract
that W3 consumes.

```swift
public struct LoopEvidenceDiff: Codable, Equatable, Sendable { /* per design S4 */ }

public enum LoopEvidenceDiffer {
  public static func diff(base: LoopEvidenceManifest, target: LoopEvidenceManifest) -> LoopEvidenceDiff
}
```

**Checklist**:

- [x] Deterministic matching: gates by `gateId`; blocking findings by
  `(filePath, message)` with line drift tolerated (path-less findings
  bucket under `(nil, message)` — documented behavior); verification by
  joining `LoopVerificationEvidence.commandRef` to that manifest's
  `LoopCommandEvidence.argvSummary` and matching on the summary string
  (command ids are not stable across sessions); changed files by path.
- [x] `sameWorkflow: false` + diagnostic for cross-workflow diffs;
  `workflowDefinitionDigestChanged` nil when either digest is absent.
- [x] Cost delta only when both sides carry summaries.
- [x] Pure function, no I/O; exhaustive fixture tests including identical
  manifests (empty diff) and disjoint gate sets.
  `Tests/RielaCoreTests/LoopEvidenceDiffTests.swift` (11 tests): identical/empty,
  cross-workflow diagnostic, digest-change tri-state, disjoint gates, decision +
  severity delta, finding match with line drift + path-less bucket, changed-file
  diff, verification flip by summary, cost delta both/one-side, residual-risk
  delta, and diff `Codable` round-trip. Sub-types added: `LoopGateChange`,
  `LoopVerificationChange`, `LoopResidualRiskDelta`, `LoopCostSummaryDelta`. Full
  `swift test` 1,753 tests / 4 skips / 0 unexpected failures.

#### `Sources/RielaCore/LoopWorkflowStats.swift`

**Status**: DONE (aggregation logic, 2026-07-12). **Input-contract gap resolved:**
the gap was that `acceptedRuns` needs per-gate requiredness (only on
`LoopSessionSummary.gateOutcomes[].required`) while identity/status/timestamps live
on `LoopSessionOverview`. Fixed by carrying the frozen `gateOutcomes` onto
`LoopSessionOverview` (optional, populated in `make()` from the summary; legacy
overviews decode to nil → treated as empty). `LoopWorkflowStats.aggregate` is a
pure function over `[LoopSessionOverview]`. The CLI/GraphQL surfaces that call it
(via the existing bounded `loadSessionOverviews`) remain — see below.

**Checklist**:

- [x] Bounded-window aggregation (default 50, `--limit` override) over overview
  rows: run counts, accepted runs (all required gates accepted — requiredness from
  the frozen `gateOutcomes`, never from re-reading workflow definitions),
  `gateFailureCounts` by gateId, rerun count, mean duration (session wall-clock)
  and mean tokens over rows that carry cost, `lastAcceptedSessionId` (newest
  accepted). Implemented in `LoopWorkflowStats.aggregate`; the `--limit` override
  is the `limit` parameter, wired when the CLI command lands.
- [x] Diagnostics note partial cost coverage and evidence-less rows (plus a
  window-truncation note).
- [x] Pure aggregation over the input rows; no `loadAll()` (the function is pure;
  callers load via the bounded `loadSessionOverviews`). Tests:
  `LoopWorkflowStatsTests` (5 cases: required-gate acceptance, required-gate
  requirement, window limit, empty series, Codable). Full suite 1,772 / 0
  unexpected.

#### `Sources/RielaCLI/LoopCommands.swift` (diff/stats)

**Status**: DONE (2026-07-12). Both `loop diff` and `loop stats` are wired and
smoke-tested end-to-end.

**Checklist**:

- [x] Parse and run `loop diff <a> <b>` and `loop stats <workflow> [--limit]`;
  JSONL/JSON/text rendering. `.stats` reuses `parseOverviewOptions` (workflow
  target + `--limit`) + bounded `loadSessionOverviews` → `LoopWorkflowStats.aggregate`
  → `renderStats`. `.diff` gets a dedicated two-positional parse branch (session-a
  as target, session-b leads the remaining args and is recovered in `runDiff`),
  loads both manifests via `snapshotForRendering`, runs `LoopEvidenceDiffer.diff`,
  and renders JSON/JSONL + text (`diffTextLines`). Smoke: `loop stats demo-workflow`
  → empty-window stats (exit 0); `loop diff` with 0/1 args → typed usage error.
  Tests: `LoopCommandRenderingTests` (stats + diff text rendering).
- [x] Missing session or missing evidence yields a typed error, not an empty
  diff. `loop diff s1 s2` against a store without those sessions returns
  `{"error":"notFound(\"session not found: s1\")","exitCode":1}`; a session with
  no loop evidence throws "session '…' has no loop evidence to diff".

#### `Sources/RielaGraphQL/GraphQLContracts.swift` + `RielaGraphQL.swift`

**Status**: DONE (2026-07-12). Contract + concrete resolvers both landed.

**Checklist**:

- [x] DTOs: `GraphQLLoopSessionOverviewDTO`, `GraphQLLoopWorkflowStatsDTO`,
  `GraphQLLoopEvidenceDiffDTO` (+ nested `GraphQLLoopCostSummary(Delta)DTO`,
  `GraphQLLoopGateChangeDTO`, `GraphQLLoopVerificationChangeDTO`,
  `GraphQLLoopGateOutcomeDTO`, `GraphQLLoopGateFailureCountDTO`), each with an
  `init(domain:)` mapper. Extracted to a new file to keep `GraphQLContracts.swift`
  within the 1,200-line budget.
- [x] Queries: `loopSessions(workflowId, status, limit)`,
  `loopWorkflowStats(workflowId!, limit)`,
  `loopEvidenceDiff(baseSessionId!, targetSessionId!)` declared in the schema SDL
  `type Query`.
- [x] Project from the same persisted summary/manifest reads as the CLI — no
  GraphQL-only computation. Added concrete resolvers to the store-backed
  `GraphQLRuntimeSnapshotQueryService` (`loopSessions`/`loopWorkflowStats`/
  `loopEvidenceDiff` returning `GraphQLLoop*Result` wrappers). They build
  `LoopSessionOverview` from persisted snapshots (`session` + `loopEvidence` +
  `loopMetadata`, so gate requiredness is faithful) and reuse the same domain
  logic as the CLI (`LoopWorkflowStats.aggregate`, `LoopEvidenceDiffer.diff`) —
  no GraphQL-only computation. Tested
  (`GraphQLContractsTests.testLoopAnalyticsResolversProjectFromSnapshots`:
  newest-first sessions, accepted-run stats, diff, missing-session handling).
- [x] Schema contract and selection tables updated together (round-trip test).
  `GraphQLContractsTests` asserts the schema declares the three queries and the
  new types, plus a DTO projection round-trip. Full suite 1,776 / 0 unexpected.

### 5. LA4 — CI Verdict Contract

#### `Sources/RielaCLI/LoopCommands.swift` (`gates --check`)

**Status**: DONE (2026-07-12).

**Checklist**:

- [x] `--check` evaluates: exit 0 all required gates present+accepted;
  exit 3 required gate rejected/needs_work/missing or blocking findings on
  a required gate; exit 4 no loop evidence recorded; exit 1 operational
  error. Added `CLIExitCode.gateCheckFailed = 3` / `.noLoopEvidence = 4` and
  `LoopCommandRunner.runGatesCheck` — resolves required gate ids from the
  workflow's `loop.gates`, evaluates the latest visit per gate against the
  persisted manifest (no projected-on-read pass), and maps to the codes. Smoke:
  `loop gates <missing> --check` → exit 1 with `{"verdict":"error"}`.
- [x] Quiet JSONL verdict summary; read-only. Emits a `LoopGatesCheckResult`
  JSON verdict (`sessionId`, `verdict`, `requiredGates`, `failingGates`,
  `exitCode`); read-only (load + resolve only).
- [x] Contract tests pin all four codes explicitly (guard against later
  exit-code unification). `LoopCommandRenderingTests.testGateCheckExitCodesArePinned`
  asserts 0/1/2/3/4; `evaluateRequiredGates` cases cover pass/missing/rejected/
  blocking/latest-visit/vacuous. Full suite 1,781 / 0 unexpected.

#### `Sources/RielaCLI/LoopFindingsExport.swift`

**Status**: DONE (2026-07-12).

```swift
public enum LoopFindingsSARIFExporter {
  public static func sarif(manifest: LoopEvidenceManifest, gateId: String?) -> JSONObject
}
```

**Checklist**:

- [x] SARIF 2.1.0: one run, `tool.driver.name = "riela-loop"`, one rule per
  gateId, one result per blocking finding; severity mapping high→error,
  medium→warning, low|informational→note, unknown severity strings→warning
  with the original value in `result.properties.severity`.
- [x] `physicalLocation` only when `filePath` present (with `region.startLine`
  when `line` present); session/gate ids in `result.properties`.
- [x] `loop findings <session-id> [--gate <gate-id>] --format sarif|json`
  command (`.findings` kind + `runFindings`); `json` emits typed
  `LoopFindingExport` findings. Invalid `--format` → typed usage error.
- [x] No environment or variable values in output (only finding id/severity/
  message/path/line + session/gate ids).
- [x] Golden-file-style test validating the SARIF shape; empty-findings session
  emits a valid empty run. `LoopFindingsExportTests` (severity mapping, shape
  with/without filePath + unknown severity, empty run, gate filter). Full suite
  1,785 / 0 unexpected.

#### `examples/loop-ci-gate-check/`

**Status**: DONE (2026-07-12).

**Checklist**:

- [x] Example workflow + GitHub Actions YAML using `loop gates --check` and
  SARIF upload as documentation. `examples/loop-ci-gate-check/` (valid loop
  workflow with a required `implementation-review` gate) +
  `github-actions-loop-gate-check.yml` (run → `loop gates --check` → `loop
  findings --format sarif` → `upload-sarif`). Registered in
  `RielaExampleParityTests` (validates + parity, 9 tests green).
- [x] `EXPECTED_RESULTS.md` and mock scenario per first-party example
  conventions. `mock-scenario-rejected.json` drives a fail-closed run; the
  captured real outputs (validate/inspect, run `failed`, `gates --check` exit 3
  verdict JSON, SARIF 2.1.0 shape) are pinned in `EXPECTED_RESULTS.md` + `README.md`.

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
| loop start | `Sources/RielaCLI/LoopStartCommand.swift` | DONE | `LoopStartPromoteCommandTests` |
| loop promote | `Sources/RielaCLI/LoopPromoteCommand.swift` | DONE | `LoopStartPromoteCommandTests` |
| Cost models | `Sources/RielaCore/LoopCostEvidence.swift` | DONE | `LoopCostEvidenceTests` |
| Usage accumulator | `Sources/RielaCore/LoopCostAccumulator.swift` (execution folding; no runner threading) | DONE | `LoopCostAccumulatorTests` |
| Budget metadata + validation | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift` | DONE | `WorkflowLoopValidationTests` |
| Budget enforcement | `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift` (boundary hook lives with loop policy, not a separate `+Budget.swift`) | DONE | `DeterministicWorkflowRunnerBudgetTests` |
| Evidence diff | `Sources/RielaCore/LoopEvidenceDiff.swift` | DONE | `LoopEvidenceDiffTests` |
| Workflow stats | `Sources/RielaCore/LoopWorkflowStats.swift` | DONE | `LoopWorkflowStatsTests` |
| Diff/stats CLI | `Sources/RielaCLI/LoopCommands.swift` | DONE | `LoopCommandRenderingTests` |
| GraphQL projections | `Sources/RielaGraphQL/GraphQLContracts.swift`, `RielaGraphQL.swift` | DONE | `GraphQLContractsTests` |
| gates --check | `Sources/RielaCLI/LoopCommands.swift` | DONE | `LoopCommandRenderingTests` |
| SARIF export | `Sources/RielaCLI/LoopFindingsExport.swift` | DONE | `LoopFindingsExportTests` |
| CI example | `examples/loop-ci-gate-check/` | DONE | `RielaExampleParityTests` |

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
- [x] `loop start` shows the policy panel (record in JSONL mode) before
  `session_started` and otherwise matches `workflow run` behavior.
  Smoke on `loop-ci-gate-check`: `loop_policy` record precedes
  `session_started`; delegation reuses `WorkflowRunCommand.run` verbatim.
- [x] `loop promote` reports promotion readiness without mutation (read-only
  resolve + evaluate; smoke returns `ready`/`issues` JSON).
- [x] Evidence manifests carry per-step and summary token/duration cost
  with honest partial flags; no fabricated values (verified end-to-end
  2026-07-12 via the usage-emitting mock scenario; eviction undercount
  degrades to `stepsWithoutUsage`, tested).
- [x] Budget-declaring loops fail closed (or warn, where allowed) at step
  boundaries with `budgetExceeded` evidence; budgetless workflows are
  unaffected (`DeterministicWorkflowRunnerBudgetTests`, 18 green).
- [x] `loop diff` and `loop stats` produce deterministic outputs from
  persisted records only (`LoopEvidenceDiffTests`, `LoopWorkflowStatsTests`,
  `LoopCommandRenderingTests`).
- [x] GraphQL loop queries project from the same persisted reads as CLI
  (`GraphQLContractsTests.testLoopAnalyticsResolversProjectFromSnapshots`).
- [x] `loop gates --check` exit codes 0/3/4/1 are pinned by contract tests;
  SARIF output validates against the golden file
  (`LoopCommandRenderingTests.testGateCheckExitCodesArePinned`,
  `LoopFindingsExportTests`).
- [x] All schema changes are additive; pre-existing snapshots, workflows,
  and package manifests decode and behave unchanged.
- [x] Full `swift test` passes; `swiftlint` clean apart from pre-existing
  warnings. Verified 2026-07-12 on the final tree: full `swift test` =
  1,916 tests, 4 skips, 0 failures (0 unexpected); strict SwiftLint clean on
  every file changed this session; `git diff --check` clean.

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

### Session: 2026-07-12 remaining LA2 runner-integration design

**Precise design for the one remaining W2 slice** (LA2 runner cost accumulation +
budget enforcement) so it can be executed as a careful, dedicated pass without
destabilizing the central runner:

- **Feed point**: `DeterministicWorkflowRunner+ExecutionEvents.swift:62`
  (`adapterExecutionContext`) — the `@Sendable` backend-event handler already has
  `execution.executionId` and `backendEvent.usage`, and already forwards usage to
  `store.recordStepBackendEventReceipt` (which appends a `WorkflowBackendEventRecord`
  carrying `usage` to the per-execution `recentBackendEvents`, capped at 100).
- **Two viable wirings** (pick one): (a) add a `WorkflowRuntimeStore` method
  `loopCostEvidence(sessionId:)` that folds recorded per-execution usage into
  `LoopCostEvidence` via `LoopCostAccumulator` — small, but touches every store
  conformer; or (b) create a per-run `actor` box wrapping `LoopCostAccumulator`,
  thread it from `run()` (`DeterministicWorkflowRunner.swift:160`) through the
  step helpers to the two `adapterExecutionContext` call sites (726, 814), feed it
  in the handler, and read `evidence()` where results are built (209/383).
- **Persistence hop**: attach the evidence to the run at result-build time; the
  projector already consumes `LoopEvidenceProjectionInput.costs`, so
  `WorkflowRunResult` gains `costs` and `WorkflowRunCommand` passes them into the
  post-run projection. (Note: usage on `WorkflowBackendEventRecord` is in-memory
  and evicted at 100; the accumulator stays authoritative, per design.)
- **Budget enforcement**: at step boundaries, check the accumulator's running
  session totals + wall-clock against `WorkflowLoopMetadata.budget` (already
  added + validated); `onExceeded == "fail"` → fail the session with
  `WorkflowSessionFailureKind.budgetExceeded` (already added, tolerant-decoded)
  before the next step; `"warn"` → residual risk + continue; emit a
  `budget_exceeded` progress record (extend `WorkflowRunEventType` +
  live-persistence switch); `maxSessionAttempts` via additive
  `rootSessionId`/`attemptNumber` on `LoopRecoveryLineage` computed at rerun
  entry.

Everything this slice depends on is already built and tested: `LoopCostEvidence`,
`LoopCostAccumulator`, `LoopCostSummary.make`, projector `costs` consumption,
`LoopBudgetDeclaration` + validation, `budgetExceeded` + tolerant decode, and the
usage-emitting mock adapter (for deterministic integration tests). This is the
sole remaining W2 work; it is a coupled central-runner change and must be done
deliberately with new integration tests, not rushed.

### Session: 2026-07-12 LA2 declarative slices

**Tasks Completed**: Landed the two self-contained, offline LA2 slices that do not
touch the runner. (1) Cost value types: added `Sources/RielaCore/LoopCostEvidence.swift`
(`LoopCostEvidence` per-step record + `LoopCostSummary.make(from:)` honest
partial-sum derivation with `isPartial`; `LoopCostSummary` itself already existed
from LA1a and was not duplicated). `LoopEvidenceManifest` gained `costs` and
`costSummary` via a faithful hand-written `Codable` — existing fields decode/encode
exactly as before, `costs` defaults to `[]` and is omitted from output when empty
so pre-cost manifests serialize byte-identically, and `costSummary` defaults nil.
(2) Budget declaration: added `LoopBudgetDeclaration` and the optional
`WorkflowLoopMetadata.budget` field, plus `validateTypedLoopBudget` /
`validateRawLoopBudget` (at least one bound present, positive-only bounds,
`onExceeded ∈ {fail, warn}`, `warn` invalid when `loop.required`).

Also landed the LA3 diff contract: `Sources/RielaCore/LoopEvidenceDiff.swift`
(`LoopEvidenceDiff` + `LoopEvidenceDiffer.diff` and sub-types `LoopGateChange`,
`LoopVerificationChange`, `LoopResidualRiskDelta`, `LoopCostSummaryDelta`). Pure,
deterministic, no I/O; matching per design S4. This publishes the stable typed
diff contract that W3 (loop convergence/operations, LB2) consumes.

Also landed the pure LA2 usage-accumulator logic:
`Sources/RielaCore/LoopCostAccumulator.swift` — a self-contained value type
(mirroring `LoopConvergenceTracker`) that normalizes backend `usage` events
(`input_tokens`/`output_tokens`/`total_tokens`/`total_token_usage`), accumulates
per step with last-value-wins for cumulative snapshots, counts steps without
usage, and derives duration from explicit input or the usage-timestamp span. The
runner wiring, projection hand-off, additive record fields, and mock-adapter
usage emission remain (module marked PARTIAL).

**Tasks In Progress**: None for these slices. Remaining LA2 = runner-side usage
accumulator (`DeterministicWorkflowRunner+Cost.swift`) and budget enforcement
(`DeterministicWorkflowRunner+Budget.swift`, incl. `WorkflowSessionFailureKind.budgetExceeded`
tolerant decoding and `budget_exceeded` progress records). Remaining LA3 =
`LoopWorkflowStats` (input-contract gap documented in the module), CLI
`loop diff/stats`, GraphQL DTOs/queries. Then LA4.

**Verification**: `Tests/RielaCoreTests/LoopCostEvidenceTests.swift` (6 tests),
new `WorkflowLoopValidationTests` budget cases (suite 16 tests), and
`Tests/RielaCoreTests/LoopEvidenceDiffTests.swift` (11 tests); focused
`LoopSessionOverviewTests`, `LoopEvidenceProjectorTests`, `RuntimeStoreTests`,
`WorkflowLoopMetadataCodableTests`, `LoopEngineeringModelsTests` all green. Full
`swift test` progressed 1,742 → 1,753 tests / 4 skips / 0 unexpected failures across
the slices. Strict SwiftLint on every changed source file: 0 violations.
`git diff --check` clean.

**Blockers**: None.

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
