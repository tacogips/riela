# Riela Loop Engineering Application Gap Closure

Status: design, ready for implementation planning

Created: 2026-07-05

Source designs:

- `design-docs/specs/design-loop-engineering-first-line-tool.md`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `design-docs/specs/design-riela-architecture-review.md`

Implementation baseline:

- `impl-plans/active/loop-engineering-first-line-tool.md`

## Problem Statement

The first-line loop engineering plan is substantially implemented. Riela now
has authored loop metadata, runtime-owned `LoopEvidenceManifest` persistence,
structured `LoopGateResult` records with fail-closed required-gate thresholds,
`LoopRecoveryLineage` for run/resume/rerun, policy preflight and stdio
enforcement, `riela loop status/evidence/gates/recover`, GraphQL loop
projections, and package promotion readiness checks.

That makes one loop session auditable. It does not yet make Riela a loop
engineering application. An application is what an operator lives in across
many loop runs, over days and weeks, and it must answer questions one session
record cannot:

- Which loop runs exist right now, which are stuck, which gates rejected them?
- Is this loop getting better or worse over time? Which gate fails most?
- What did this run cost in tokens, money, and wall-clock, and is the next run
  allowed to spend that much?
- What changed between the last accepted run and this rejected one?
- What did previous runs teach us, and how do future runs inherit that?
- Can CI consume a gate verdict without parsing prose?
- Can two loops run concurrently without corrupting each other's worktree?

Today every one of these requires manual session-id bookkeeping, ad-hoc `jq`
over JSONL, or reading markdown by hand. This design closes the gap between
"auditable loop session" and "loop engineering application".

## Current-State Review

Verified against the working tree on 2026-07-05 (branch `feature/riela-note`).

| First-line phase | State | Evidence |
| --- | --- | --- |
| P0 contracts and policy | Implemented | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift`, `LoopPolicyEvaluator.swift`, `Sources/RielaCLI/WorkflowPackageLoopReadiness.swift` |
| P1 evidence manifest | Implemented | `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEvidenceProjector.swift`, `loop_evidence_json` in `SQLiteWorkflowRuntimePersistenceStore.swift` |
| P2 recovery semantics | Mostly implemented | `Sources/RielaCore/LoopRecoveryLineage.swift`, `riela loop recover --from-step` in `Sources/RielaCLI/LoopCommands.swift`; missing gate-addressed recovery |
| P3 first-party hardening | Partial | `codex-design-and-implement-review-loop` and `examples/required-loop-gate-failure` carry full loop metadata, mocks, expected results |
| P4 self-evolution safety | Not started | Plan module 8 (`WorkflowHistoryModels`, `WorkflowSelfImproveVersioning`, `WorkflowVersionCommands`) remains NOT STARTED; `workflow self-improve` still does single-file backup |
| P5 product loop UX | Partial | `loop status/evidence/gates/recover` exist; no `loop list`, no `loop start`, no `loop promote`, no policy display before start, no RielaApp evidence timeline |
| P6 durable learning and metrics | Not started | No lesson model, no loop metrics, no cross-run aggregation |

Additional grounded observations:

- Token usage is already extracted per backend event.
  `Sources/AgentRuntimeKit/AgentUsageStats.swift` normalizes
  `input_tokens`/`output_tokens`/`total_token_usage` payloads, and
  `Sources/CodexAgent/CodexAgentAdapter.swift:303` emits `turn.completed`
  usage as an `AdapterBackendEvent` with `channel: .usage`. The usage payload
  is visible in the live run-event stream but is **dropped at persistence**:
  `appendRecentBackendEvent` (`Sources/RielaCore/RuntimeStore.swift:644`)
  persists only sequence/time/type/channel/content/toolName, and
  `WorkflowBackendEventRecord` has no usage field. Nothing aggregates usage
  into loop evidence, session output, or any cross-run surface, and persisted
  records cannot recover the counts after the fact. Cost evidence must
  therefore be accumulated by the runner while the run is live (S3).
- `riela memory` and `RielaMemoryStore` exist
  (`Sources/RielaCLI/ProductionNodeAdapter+ChatMemory.swift`), but they are a
  workflow-facing memory surface without lesson provenance, expiry,
  redaction status, or revocation semantics.
- `design-docs/specs/design-riela-architecture-review.md` flags that
  cross-session reads currently use full-store `loadAll()` scans and per-call
  SQLite connection opens. Any cross-run loop surface built naively on
  `loadAll()` would make that worse; this design must ride the
  prepared-handle/summary-SQL direction instead of fighting it.
- `LoopBlockingFinding` already carries `filePath`, `line`, `severity`,
  `message`, and `evidenceRefs` — the exact fields a SARIF export needs.
- CLI exit codes are inconsistent across command families (architecture
  review Theme 2). New gate-verdict exit codes must be explicitly specified,
  not inherited from local convention.

## Gap Analysis

Ranked by how much each gap blocks the "application" claim, with the cheapest
high-leverage items first.

### G1. No loop fleet visibility (`loop list`)

Every loop command today requires a known session id. There is no way to ask
"what loop runs exist, which are active, which gates rejected". This is the
single most used screen of any loop application and it is missing.

### G2. No gate-addressed recovery and no pre-run policy display

`loop recover` requires a step id, but the operator thinks in gates ("the
adversarial review rejected it — rerun from there"). Policy display before a
run exists only inside evidence after the fact; a first-line tool should show
mutation/process/budget policy before work starts.

### G3. No cost and budget model

Riela bounds steps (`maxSteps`) and loop iterations (`maxLoopIterations`) but
not tokens, spend, or wall-clock. Usage data is already parsed per event,
observable in the live JSONL stream, and then dropped at persistence.
Unbounded agent loops are the top operational fear of loop
engineering; a loop application must record what a run consumed and enforce
what a run may consume.

### G4. No cross-run history, comparison, or metrics

Evidence manifests are per-session islands. Nothing answers "success rate of
this loop over the last 20 runs", "which gate fails most", or "what changed
between the accepted baseline and this rejected run". Loop engineering is
literally the practice of improving repeated cycles; without trend and diff
surfaces the improvement half of the loop is blind.

### G5. No CI/headless verdict contract

JSONL output exists, but there is no check-mode exit code for "required gates
accepted" and no standard findings export. A loop application must be
consumable by CI without `jq` acrobatics. `LoopBlockingFinding` already has
file/line/severity — SARIF export is cheap and unlocks GitHub/GitLab review
annotation for free.

### G6. No durable learning (P6)

Lessons from failed and accepted loops evaporate. The first-line design
already decided the shape (distilled, scoped, expiring, revocable, redacted —
never raw transcripts); nothing implements it.

### G7. Workflow self-evolution versioning still unimplemented (P4)

Already fully specified in the first-line detail design and plan module 8.
This design does not respecify it; it stays a tracked dependency because loop
metrics (G4) and lessons (G6) are what make self-improve proposals
evidence-driven rather than speculative.

### G8. No concurrent-loop isolation

Two loops mutating the same worktree corrupt each other's changed-file
evidence and diffs. Fanout already has `isolated-workspace` write ownership
for branches; whole-loop isolation via git worktree is the missing analog.

### G9. No RielaApp evidence timeline (P5 UI)

RielaApp shows the execution graph but not the loop story: stages, gate
decisions, blocking findings, risks, cost. Deferred to last because CLI and
GraphQL projections must stabilize first, and because
`design-riela-architecture-review.md` P2 restructuring (DaemonInstanceStore,
window-controller consolidation) will move the UI code this would touch.

## Design Decisions

1. **No new engine, no new store.** Every new surface projects from the
   already-persisted `WorkflowRuntimePersistenceSnapshot.loopEvidence` and
   session records. New writes are additive optional fields on existing
   models, exactly as the first-line plan did.
2. **Cross-run reads get summary SQL, not `loadAll()`.** `loop list`,
   `loop history`, and `loop stats` are the first consumers of a
   summary-level query API on the SQLite persistence store, aligning with
   the architecture-review prepared-handle direction instead of adding new
   full-store scans. Because the current snapshot table stores workflow id,
   status, and timestamps only inside the `session_json` blob, this requires
   promoting them to real columns maintained by the save path (S1) — not
   `json_extract` scans over full blobs.
3. **Cost evidence is accumulated live by the runner, best-effort.** Usage
   payloads reach the runner's backend-event handler during execution but
   are not persisted afterwards (see Current-State Review), so the runner —
   not the evidence projector — owns a per-step/per-session usage
   accumulator and hands the result to evidence projection and budget
   enforcement. Absent usage data yields absent fields plus a diagnostic —
   never fabricated numbers (same rule as digests). Sessions persisted
   before this feature have no recoverable cost; they render as
   not recorded.
4. **Budgets are loop metadata, enforced at deterministic boundaries.**
   Budget checks run between steps and at attempt boundaries, where the
   runner already owns control flow. Mid-step overruns are recorded, not
   interrupted, in the MVP (interrupting a live agent process is a policy
   decision with its own failure modes).
5. **Verdict surfaces are contracts.** `--check` exit codes and SARIF export
   get explicit documented codes and schema versions; they do not inherit the
   currently inconsistent per-command exit-code habits.
6. **Lessons are a new small store, not a retrofit of `riela memory`.**
   The chat memory store has no provenance/expiry/redaction/revocation
   semantics and serves a different consumer (workflow prompts). Lesson
   records get their own SQLite-backed store under the data root with the
   fields the first-line design mandated. A read-only bridge addon can expose
   lessons to workflows later.
7. **Self-evolution versioning stays in plan module 8.** This design links to
   it and orders it after metrics exist, so self-improve proposals can cite
   gate-failure statistics as rationale.

## Specifications

### S1. Loop session list and summary SQL (G1)

New CLI:

```bash
riela loop list [--workflow <id>] [--status active|completed|failed|all]
                [--gate-decision accepted|rejected|needs_work]
                [--limit <n>] [--output jsonl|json|text|table]
```

Each record is a `LoopSessionOverview`:

```swift
public struct LoopSessionOverview: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var sessionStatus: String
  public var loopKind: String?
  public var loopRequired: Bool?
  public var loopEvidenceRecorded: Bool
  public var gateSummary: LoopGateSummaryCounts?   // accepted/rejected/needsWork/skipped counts
  public var blockingFindingCount: Int?
  public var lastGateDecision: String?
  public var entryMode: String?                    // run|resume|rerun from lineage
  public var sourceSessionId: String?
  public var cost: LoopCostSummary?                // S3, optional
  public var possiblyStale: Bool                   // running but not recently updated
  public var createdAt: Date
  public var updatedAt: Date
}
```

**New persisted summary shape.** The existing `LoopEvidenceSummary` is
count-oriented and cannot feed the overview or `loop stats` (it carries no
loop kind, no per-gate decisions, no gate requiredness, no lineage, no
cost). The summary column therefore persists a new compact type derived
from the manifest plus authored metadata at write time:

```swift
public struct LoopSessionSummary: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var loopKind: String?
  public var loopRequired: Bool?
  public var gateOutcomes: [LoopGateOutcome]     // gateId, decision, required, blockingFindingCount
  public var lastGateDecision: String?
  public var blockingFindingCount: Int
  public var entryMode: String?                  // from recovery lineage
  public var sourceSessionId: String?
  public var rootSessionId: String?              // S3 attempt accounting
  public var attemptNumber: Int?
  public var cost: LoopCostSummary?              // S3
  public var evidenceUpdatedAt: Date
}
```

Gate requiredness is resolved from the authored `loop.gates[]` declaration
at projection time and frozen into the summary, so `loop stats` can compute
"all required gates accepted" without re-reading workflow definitions.

**Schema change.** The current `workflow_runtime_snapshots` table has no
`workflow_id`, `status`, or `created_at` columns — they live inside the
`session_json` blob — so SQL-side filtering needs real columns. Via the
existing `ALTER TABLE` migration pattern, add: `workflow_id TEXT`,
`session_status TEXT`, `created_at` timestamp, and `loop_summary_json`.
All four are maintained by a single save-path write helper that derives
them from the snapshot being saved (the summary is always derived from the
manifest in the same call, so the pair cannot drift).

**Backfill and read-only safety.** Reads never write. Store read paths open
the database read-only today and `loop list`/`history`/`stats` keep that
invariant. Rows written before the migration are backfilled by a one-shot
sweep that runs when the store is next opened writable (any save path);
until then, a summary read that encounters pre-migration rows falls back to
decoding those rows' `session_json`/`loop_evidence_json` for the requested
window only, bounded by `LIMIT`, and reports a `pre-migration rows scanned`
diagnostic. Lazy write-on-read is explicitly rejected: it would contradict
the read-only connections and the "list never mutates" rule below.

**Status filter mapping.** `--status active` matches persisted
`created|running`; `completed` and `failed` match themselves; `all` skips
the filter. Because a crashed run can leave `running` rows behind, list
output marks `running` rows whose `updated_at` is older than a staleness
threshold (default 10 minutes) with `possiblyStale: true` rather than
guessing a different status.

GraphQL: `loopSessions(workflowId: String, status: String, limit: Int):
[LoopSessionOverview!]!` projected from the same summary query.

### S2. Gate-addressed recovery and pre-run policy display (G2)

**`loop recover --from-gate <gate-id>`.** Resolution order:

1. Load the session's evidence manifest; find the gate result with
   `gateId == <gate-id>`; use its `stepId`.
2. If no evidence gate result exists, fall back to the authored
   `workflow.loop.gates[]` declaration's `stepId`.
3. If neither resolves, fail with a diagnostic listing known gate ids.

The command then delegates to the existing `SessionRerunCommand` exactly as
`--from-step` does. `--from-step` remains supported; the two flags are
mutually exclusive.

**`loop start <workflow>`.** A discoverable wrapper over `workflow run` for
loop workflows:

```bash
riela loop start <workflow> [--var k=v ...] [--output jsonl|json|text]
                 [--isolate worktree]            # S6
```

Behavior:

- Loads the workflow; if it has no `loop` metadata, refuses with a hint to
  use `workflow run` (loop start is a contract surface, not an alias for
  everything).
- Computes the effective policy via the existing `LoopPolicyEvaluator`
  preflight and emits a policy panel before execution: mutation roots,
  scratch root, commit/push, nested-process policy, allowed backends and
  models, required gates with thresholds, budget (S3), and evidence
  requirements. In JSON/JSONL mode the panel is a `loop_policy` record
  emitted by the CLI before the runner's `session_started` (it is a
  CLI-emitted line, not a new runner event type); in text mode it prints
  as a panel.
- There is no interactive confirmation: explicit invocation of `loop start`
  is the consent, matching the rest of the CLI, which has no interactive
  prompts and defaults to JSONL. (An earlier draft had a text-mode
  confirmation; rejected — it would be the CLI's first mid-command prompt,
  dead code under the JSONL default, and a hang hazard for automation that
  sets `--output text`.)
- Then delegates to the ordinary `workflow run` path unchanged, including
  JSONL progress records.

**`loop promote <workflow>`.** Read-only promotion readiness report reusing
`WorkflowPackageLoopReadiness` and the package manifest promotion-artifact
validation: usage contract, gates, policies, mock scenarios, expected
results, evidence schema version. Important nuance: the existing readiness
function returns no issues unless `loop.required == true`, and
promotion-artifact checks are gated on the manifest's `promotionReady`
flag — reused as-is it would report optional-loop workflows as trivially
ready. `loop promote` therefore runs in an advisory mode that evaluates
every check regardless of those flags and labels each issue `enforced`
(would block publish today) or `advisory` (would block once promotion
flags are set). Output is `ready: true|false` over enforced issues plus
the full labeled list. No publish, no mutation.

### S3. Cost evidence and loop budgets (G3)

**Cost evidence.** New optional manifest section:

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

`LoopEvidenceManifest` gains `costs: [LoopCostEvidence]` and
`costSummary: LoopCostSummary?`; `LoopSessionSummary` (S1) carries the
compact totals.

**Sourcing (corrected by code review).** Usage payloads cannot be read back
from persisted records: `appendRecentBackendEvent`
(`Sources/RielaCore/RuntimeStore.swift:644`) drops the `usage` object, and
`WorkflowBackendEventRecord` has no usage field. The source of truth is
therefore a runner-owned accumulator: the deterministic runner already
installs the backend-event handler that receives
`AdapterBackendEvent.usage` live
(`DeterministicWorkflowRunner+ExecutionEvents.swift`), so it accumulates
normalized token counts per step and per session as events arrive (reusing
the `AgentUsageStats` normalization rules, not forking a second parser)
and hands the accumulated `LoopCostEvidence` to evidence projection at the
existing projection points. As a secondary, additive change, persisted
backend event records gain optional token-count fields so future
re-projection can improve — but the accumulator, not the store, feeds
evidence and budgets. Two honesty caveats are recorded as diagnostics:
steps whose backend emits no usage events count in `stepsWithoutUsage`
(totals are flagged partial whenever it is non-zero), and the per-execution
100-record cap on `recentBackendEvents` (`RuntimeStore.swift:652`) means
persisted event rows may undercount even after the additive field lands —
another reason the live accumulator is authoritative. Sessions persisted
before this feature render cost as not recorded, never zero.

Monetary cost is intentionally excluded from the MVP: price tables change
faster than releases and belong in operator-side reporting. Token and
duration totals are the stable runtime facts. (Rejected alternative below.)

**Budgets.** New optional authored metadata:

```json
{
  "loop": {
    "budget": {
      "maxTotalTokens": 2000000,
      "maxWallClockMs": 5400000,
      "maxSessionAttempts": 3,
      "onExceeded": "fail"
    }
  }
}
```

Semantics:

- `maxTotalTokens`: checked at step boundaries against the runner
  accumulator's running session total (same accumulator as cost evidence —
  budgets and cost share one code path by construction). Exceeding it fails
  the session with a new `WorkflowSessionFailureKind.budgetExceeded` before
  the next step starts.
- `maxWallClockMs`: session wall-clock, checked at the same boundaries.
- `maxSessionAttempts`: bound on rerun attempts for the same root session.
  Lineage chain-walking is not viable with today's records (resume lineage
  points a session at itself, and parent manifests are never updated with
  children), so `LoopRecoveryLineage` gains two additive fields computed at
  entry: `rootSessionId` (copied from the source session's lineage when
  present, else the source session id) and `attemptNumber` (source's
  `attemptNumber + 1` for rerun; unchanged for resume — resuming is
  continuing an attempt, not a new one). Enforcement at rerun entry reads
  only the source session's manifest: O(1), no ancestor walk, no cycle
  hazard. Sessions without the new fields count as attempt 1.
- `onExceeded`: `"fail"` (default) or `"warn"` (record a residual risk and
  continue). Required loops with `loop.required == true` treat `warn` as
  invalid at validation time — required loops fail closed.
- Budget consumption and the enforcement decision are recorded in evidence
  (`policy` decisions plus `costSummary`).
- Validation: non-positive numbers rejected; `budget` without any bound
  rejected.

Boundary enforcement is deliberate: the runner owns control flow between
steps. Killing a live agent process mid-step on token overrun is a separate
opt-in future policy (`interruptInFlight`), not the MVP.

Two contract notes surfaced by review: `WorkflowSessionFailureKind` today
is a closed raw-value enum whose decode throws on unknown values — there is
no existing tolerant-decode pattern to reuse, so tolerant decoding must be
built (see Compatibility). And `budget_exceeded` extends the closed
`WorkflowRunEventType` progress-record vocabulary — an additive JSONL
contract change that consumers and the live-persistence event switch must
absorb; it is called out in Compatibility rather than slipped in silently.
Budget tests need usage-emitting mock adapter support, which does not exist
yet and is part of the budget work, not an afterthought.

### S4. Loop history, diff, and stats (G4)

**`loop history <workflow>`** — the run series, newest first:

```bash
riela loop history <workflow> [--limit <n>] [--output jsonl|json|text|table]
```

Rows are `LoopSessionOverview` (S1) ordered by `createdAt`, plus lineage
threading: each row carries `entryMode` and `sourceSessionId` so rerun
chains render as chains.

**`loop diff <session-a> <session-b>`** — evidence-level comparison:

```bash
riela loop diff <session-a> <session-b> [--output json|text]
```

```swift
public struct LoopEvidenceDiff: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var baseSessionId: String
  public var targetSessionId: String
  public var sameWorkflow: Bool
  public var workflowDefinitionDigestChanged: Bool?
  public var gateChanges: [LoopGateChange]        // per gateId: decision/severity-count deltas
  public var blockingFindingsAdded: [LoopBlockingFinding]
  public var blockingFindingsResolved: [LoopBlockingFinding]
  public var changedFilesAdded: [String]
  public var changedFilesRemoved: [String]
  public var verificationChanges: [LoopVerificationChange]  // command outcome flips
  public var residualRiskDelta: LoopResidualRiskDelta
  public var costDelta: LoopCostSummaryDelta?
  public var diagnostics: [String]
}
```

Matching rules are deterministic and dumb on purpose: gates match by
`gateId`; blocking findings match by `(filePath, message)` with line drift
tolerated — findings without a file path all bucket under
`(nil, message)`, which is accepted and documented; changed files match by
path. Verification records carry only a `commandRef` into the manifest's
per-session `LoopCommandEvidence` list (command ids are not stable across
sessions), so verification matching joins `commandRef` to that command's
`argvSummary` and matches on the summary string. Cross-workflow diffs are
allowed but flagged (`sameWorkflow: false`) with a diagnostic. Diff is
computed on read from two persisted manifests — nothing new is stored.

**`loop stats <workflow>`** — aggregate over the persisted run series:

```swift
public struct LoopWorkflowStats: Codable, Equatable, Sendable {
  public var workflowId: String
  public var windowRuns: Int                       // runs considered (bounded by --limit, default 50)
  public var completedRuns: Int
  public var failedRuns: Int
  public var acceptedRuns: Int                     // all required gates accepted
  public var gateFailureCounts: [String: Int]      // gateId -> rejected/needs_work count
  public var rerunCount: Int                       // entries with entryMode == rerun
  public var meanDurationMs: Int?
  public var meanTotalTokens: Int?
  public var lastAcceptedSessionId: String?
  public var diagnostics: [String]
}
```

Computed on read from `LoopSessionSummary` rows (S1) — the summary's
`gateOutcomes` carry gateId, decision, and requiredness precisely so this
aggregation never re-reads full manifests or workflow definitions; no
materialized metrics tables in the MVP. If profiling shows the bounded read
is too slow at real store sizes, materialization is a later additive change
behind the same CLI contract.

GraphQL: `loopWorkflowStats(workflowId: String!, limit: Int):
LoopWorkflowStats` and `loopEvidenceDiff(baseSessionId: String!,
targetSessionId: String!): LoopEvidenceDiff`, both projected from the same
persisted records as the CLI (no GraphQL-only computation paths).

### S5. CI verdict contract: gate check and SARIF export (G5)

**Check mode.**

```bash
riela loop gates <session-id> --check
```

Exit codes (documented contract, additive to existing behavior):

- `0`: evidence recorded, all required gates present and `accepted`.
- `3`: evidence recorded, at least one required gate rejected / needs_work /
  missing, or blocking findings present on a required gate.
- `4`: no loop evidence recorded for the session (distinct so CI can treat
  "not a loop run" differently from "loop failed").
- `1`: operational error (session not found, store unreadable).

`--check` implies quiet JSONL summary output; it never mutates state. Codes
`3`/`4` are chosen to avoid colliding with the existing widespread use of
`1`/`2` and are asserted by contract tests so later exit-code unification
(architecture review `OutputRenderer` work) must preserve them.

**Findings export.**

```bash
riela loop findings <session-id> [--gate <gate-id>] --format sarif|json
```

SARIF 2.1.0 mapping: one run, `tool.driver.name = "riela-loop"`, one rule
per `gateId`, one result per `LoopBlockingFinding` with
`level` mapped from severity (`high→error`, `medium→warning`,
`low|informational→note`; severity is a free string in the model, so
unknown values map to `warning` with the original severity preserved in
`result.properties`), `physicalLocation` from
`filePath`/`line` when present, and the session/gate ids in
`result.properties`. Findings without file locations emit results without
locations (valid SARIF). `--format json` emits the raw typed findings for
non-SARIF consumers.

Non-goals: no CI provider plugins, no auto-commenting; the contract is exit
codes plus standard files. An example GitHub Actions workflow lands under
`examples/` as documentation, not product code.

### S6. Worktree-isolated loop runs (G8)

```bash
riela loop start <workflow> --isolate worktree [--keep-worktree]
```

Behavior:

- Requires a clean-enough git context: the repository must have a HEAD
  commit; a dirty primary worktree is fine (that is the point of isolating).
- Creates the worktree **outside the repository**, under the data root:
  `git worktree add <dataRoot>/loop-worktrees/<run-id> HEAD`. An earlier
  draft placed it under the loop's scratch root (`tmp/`), but a worktree
  inside the primary worktree pollutes the primary's `git status` and
  changed-file evidence — rejected. `<run-id>` is generated by `loop start`
  before the runner allocates a session id (session ids are created inside
  the runner at run start, too late to name the directory); evidence links
  the run id and the session id.
- Runs the workflow with the execution working directory pointed at the
  isolated worktree; mutation-policy allowed write roots are interpreted
  relative to it.
- Evidence records the isolation: worktree path, base commit, and final
  `git status --short` summary. `LoopWorktreeSummary` exists but has no
  path field today (branch/baseCommit/headCommit/dirtySummary only), so it
  gains an additive optional `isolatedWorktreePath`.
- On success, prints the worktree path and a ready-made
  `git -C <path> diff` hint. Merge-back is explicitly manual in the MVP.
  Cleanup: worktrees with no changes are removed automatically;
  changed worktrees are kept unless the operator removes them
  (`--keep-worktree` forces retention even when unchanged).
- Failure to create the worktree fails the run before any step executes.

Non-goals: no automatic merge, no branch management, no nested worktree
stacking, no non-git isolation backends in the MVP.

### S7. Distilled loop lessons (G6)

Models per the first-line design's memory decision:

```swift
public struct LoopLessonRecord: Codable, Equatable, Sendable {
  public var lessonId: String
  public var sourceSessionId: String
  public var workflowId: String
  public var scope: LoopLessonScope        // workflow | project | user
  public var title: String
  public var body: String                  // distilled prose, never raw transcript
  public var confidence: String            // low | medium | high
  public var createdAt: Date
  public var expiresAt: Date?
  public var invalidationTriggers: [String] // e.g. "workflow-definition-changed"
  public var redactionStatus: String       // redacted | unverified
  public var revoked: Bool
}
```

Storage: a small SQLite store under the data root
(`.riela/loop-lessons.sqlite3` for project scope, user data root for user
scope), using the shared SQLite infrastructure. Bodies are size-capped
(4 KiB) to structurally discourage transcript dumping; the store refuses
bodies over the cap.

CLI:

```bash
riela loop lesson add --from-session <session-id> --title ... --body ...
                      [--scope workflow|project|user] [--confidence ...]
                      [--expires-in <days>]
riela loop lesson list [--workflow <id>] [--include-revoked]
riela loop lesson show <lesson-id>
riela loop lesson revoke <lesson-id>
```

`add` validates that the source session exists and records provenance;
`redactionStatus` defaults to `unverified` (the honest value — the runtime
cannot prove prose is secret-free).

Injection: opt-in authored metadata
`loop.lessons: { "inject": true, "maxLessons": 5 }`. When set, the runner
resolves non-revoked, non-expired lessons scoped to the workflow (then
project), newest-and-highest-confidence first, and exposes them as a
`_rielaLoopLessons` input section with title/body/confidence/source-session.
Injection is recorded in evidence (lesson ids used). Workflows without the
flag see nothing. The `workflow-definition-changed` invalidation trigger
compares the manifest's `workflowDefinitionDigest` when available; digest
absence leaves the lesson active with a diagnostic.

Automated distillation (an agent step that writes lessons at loop end) is a
follow-up workflow template, not runtime code: the CLI is sufficient for a
workflow-output step to call today.

### S8. RielaApp loop evidence timeline (G9)

Deferred, minimal spec: a per-session "Loop" pane in the existing session
detail UI rendering, top to bottom: policy panel, step evidence with
gate decisions inline (decision chips: accepted/rejected/needs_work),
blocking findings, verification outcomes, residual risks, and cost summary.
Data source is the same persisted snapshot the CLI reads — no new IPC, no
GraphQL dependency. Implementation should land after the architecture
review's RielaApp restructuring (DaemonInstanceStore extraction) to avoid
building on code scheduled to move, and is therefore sequenced last.

## Security Requirements

- Cost evidence contains counts and durations only — never prompt or
  response text.
- Lesson bodies are size-capped, default `redactionStatus: unverified`, and
  are excluded from telemetry export; `loop lesson list` output is
  local-only data.
- `loop start` policy display must never print secret values; it prints
  policy names and roots only (same rule as evidence).
- SARIF export includes file paths and finding messages — it is an export
  surface, so the command documents that output should be treated with the
  same care as a review report; no environment or variable values are
  included.
- Worktree isolation must create worktrees only under the data root's
  `loop-worktrees/` directory, mark ownership with a marker file, and never
  delete a worktree that lacks the marker or contains uncommitted changes.
- Budget enforcement failures are ordinary deterministic failures with
  evidence; they must not leave orphaned agent processes (reuse existing
  cancellation paths).

## Observability Requirements

- `loop start` emits the `loop_policy` JSONL record before `session_started`.
- Budget denials emit a `budget_exceeded` progress record with the consumed
  and allowed values.
- All new commands support `--output jsonl|json|text` (plus `table` where
  rows are natural), defaulting to JSONL like the rest of the CLI.
- Diff, stats, and list never mutate stored snapshots (same read-only rule
  as `loop evidence` for legacy sessions).

## Compatibility and Migration

- Every schema change is additive and optional: new manifest fields default
  to `nil`/empty; old snapshots decode; old CLIs ignore new JSON fields.
- `workflow_id`/`session_status`/`created_at`/`loop_summary_json` columns
  are added via `ALTER TABLE`; pre-migration rows are backfilled by a
  one-shot sweep on the next writable open, and read-only reads fall back
  to bounded blob decoding until then. Reads never write.
- `WorkflowSessionFailureKind.budgetExceeded` is a new persisted enum case.
  Code review confirmed there is **no** existing tolerant-decode pattern:
  today an unknown raw value throws and fails the whole snapshot decode.
  Tolerant decoding (unknown persisted values decode to a preserved
  `other(String)`-style representation with a diagnostic) must ship in the
  same change that introduces the new case. Binaries released before that
  change will still fail to decode budget-failed sessions — an accepted,
  documented limitation, since nothing can retrofit tolerance into
  already-shipped readers.
- `budget_exceeded` (runner event) and `loop_policy` (CLI-emitted by
  `loop start`) are additive JSONL record types. `WorkflowRunEventType` is
  a closed enum today, so the runner event is an intentional
  progress-stream contract addition; the live-persistence event switch and
  documented consumer guidance ("ignore unknown record types") update with
  it.
- The `LoopCommand` CLI parser type changes shape (struct kind+options →
  enum with per-case payloads). Parse behavior is unchanged, but this is a
  source-breaking change for any library consumer of `RielaCLI` types and
  is called out rather than hidden.
- `loop recover --from-step` behavior is unchanged; `--from-gate` is purely
  additive.
- Exit-code additions apply only to the new `--check` flag; existing default
  invocations keep their current codes.

## Phased Roadmap

Ordered for dependency and leverage; each phase is independently shippable.

### LA1: Fleet visibility and cockpit (G1, G2)

- Summary SQL read API + `loop_summary_json` column.
- `loop list`, `loop history` (history is the same query filtered by
  workflow — cheap to include here).
- `loop recover --from-gate`.
- `loop start` with policy panel (without `--isolate`).
- `loop promote` readiness report.

**Current implementation handoff (LA1a).** The issue-resolution handoff for
this pass intentionally implements the storage/listing/recovery subset first:
`LoopSessionOverview`/`LoopSessionSummary`/`LoopGateOutcome`, the SQLite
summary columns and `loadSessionOverviews` query, `loop list`, `loop
history`, and `loop recover --from-gate`. `loop start` and `loop promote`
remain part of LA1's design contract but are deferred to a later LA1b change
because the accepted scope and verification signals for this pass are the
summary SQL and read-only cockpit surfaces. This split also limits source
breakage around the `LoopCommand` parser reshape to the commands required by
the handoff.

### LA2: Cost evidence and budgets (G3)

- `LoopCostEvidence`/`LoopCostSummary` projection from usage backend events.
- Budget metadata, validation, boundary enforcement,
  `budgetExceeded` failure kind, evidence recording.
- Cost columns in `loop list`/`history` output.

### LA3: Comparison and metrics (G4)

- `loop diff` with deterministic matching rules.
- `loop stats` bounded-window aggregation.
- GraphQL projections for overview list, stats, and diff.

### LA4: CI verdict contract (G5)

- `loop gates --check` exit-code contract with contract tests.
- `loop findings --format sarif|json`.
- Example CI workflow under `examples/`.

### LA5: Lessons (G6)

- Lesson store, CLI, injection, evidence recording of injected lessons.

### LA6: Isolation and app UI (G8, G9)

- `loop start --isolate worktree`.
- RielaApp loop evidence timeline (after RielaApp restructuring).

Parallel track: first-line plan module 8 (self-evolution versioning)
proceeds independently; LA3 metrics become an input to self-improve
rationale when both exist.

## Rejected Alternatives

- **Monetary cost estimation in the runtime.** Price tables drift and vary
  by account; wrong dollar numbers in durable evidence are worse than none.
  Tokens and durations are stable facts; money is operator-side reporting.
- **Materialized metrics tables in the MVP.** Bounded on-read aggregation
  over summary rows is simple, cannot go stale, and the CLI contract hides
  the strategy; materialize later only if profiling demands it.
- **Retrofitting lessons into `riela memory`.** The chat memory store lacks
  provenance/expiry/revocation and serves prompts directly; entangling
  redaction-sensitive lessons with it risks silent prompt leakage of stale
  or revoked guidance.
- **Mid-step budget interruption.** Killing live agent processes on token
  overrun trades an overspend bounded by one step for partial-write and
  orphan-process risk; step-boundary enforcement is deterministic. In-flight
  interruption can come later as an explicit opt-in.
- **CI provider plugins.** Exit codes + SARIF are provider-neutral and
  testable; plugins are maintenance surface without new information.
- **A `loop watch`/scheduler daemon in this design.** Event sources (cron,
  file-change) already trigger workflows; a dedicated always-on loop
  scheduler is an operational feature with its own lifecycle design and is
  out of scope here.
- **Auto-merge for worktree isolation.** Merge conflicts require judgment;
  the application's job is a clean diff and a clear hint, not silent
  integration.

## Open Questions

- Should `loop list` also surface active (in-flight) sessions from live
  JSONL persistence, or only persisted snapshots? MVP reads persisted
  snapshots (which live persistence already updates during runs); a
  dedicated "active" indicator may need a staleness heuristic on
  `updatedAt`.
- Is `(filePath, message)` finding identity too weak for diff when agents
  rephrase messages? A normalized-message hash or explicit finding `id`
  passthrough (the field exists) may be needed after real-world use.
- Should lesson injection also draw user-scope lessons for project
  workflows? MVP: workflow scope then project scope only; user scope
  requires an explicit flag decision later.
- Do `loop stats` windows need time-based bounds (`--since`) in addition to
  count-based? Deferred until history data exists.
- Should `budgetExceeded` allow a checkpoint-style graceful stop (finish
  current gate, then stop) instead of failing at the next boundary?

## Risks

- **Summary-column drift.** `loop_summary_json` and the new plain columns
  duplicate projections of blob data and can drift if a write path updates
  one and not the other. Mitigation: single write helper that always
  derives all derived columns from the snapshot/manifest in the same call;
  a regression test asserts the pair stays consistent.
- **Usage-event coverage varies by backend.** Cursor/Claude paths may emit
  usage differently or not at all, mock adapters emit none today, and the
  100-record `recentBackendEvents` cap can evict usage events from
  persisted rows; totals must render honestly as partial
  (`stepsWithoutUsage`), and tests must cover the no-usage backend and
  eviction cases.
- **Old-reader decode breakage.** `budgetExceeded` in persisted sessions is
  undecodable by binaries that predate tolerant decoding. Scoped by
  shipping tolerance in the same release and documenting the limitation;
  the alternative (never adding failure kinds) would freeze the model.
- **Exit-code contract erosion.** The architecture review documents existing
  exit-code inconsistency; without contract tests the `--check` codes will
  erode the same way. Contract tests are part of the LA4 definition of done.
- **Lesson quality.** Distilled-lesson value depends on authoring
  discipline; injection of low-quality lessons degrades loops. Caps,
  confidence ordering, easy revocation, and evidence recording of injected
  lesson ids keep the feedback loop inspectable.
- **Worktree cleanup safety.** Deleting the wrong directory is
  catastrophic; removal must verify the path is under the scratch root, was
  created by this feature (marker file), and has no uncommitted changes.
- **RielaApp timing.** Building the timeline before the app restructuring
  would couple new UI to code the architecture review already scheduled to
  move; sequencing it last is deliberate.

## Review Note

This design went through an adversarial code-grounding review on
2026-07-05 (every cited symbol, column, and behavior re-checked against the
working tree). Material corrections folded in:

- Cost sourcing moved from "projector reads persisted usage events" to a
  runner-owned live accumulator, because persisted backend event records
  drop the usage payload (`RuntimeStore.swift:644`); historical sessions
  have no recoverable cost.
- The summary column is a new `LoopSessionSummary` shape; the existing
  `LoopEvidenceSummary` lacks the per-gate, lineage, and requiredness data
  the overview and stats need. The snapshot table also gains real
  `workflow_id`/`session_status`/`created_at` columns because the current
  schema keeps them inside the `session_json` blob.
- Lazy write-on-read backfill replaced by save-path writes plus a one-shot
  writable-open sweep — reads stay on read-only connections.
- `maxSessionAttempts` no longer relies on lineage chain-walking (resume
  lineage is self-referential and parents never learn their children);
  additive `rootSessionId`/`attemptNumber` fields make enforcement O(1).
- The claimed "existing open-enum pattern" for persisted failure kinds does
  not exist; tolerant decoding is specified as new work with an explicit
  old-binary limitation.
- `loop start`'s interactive confirmation was dropped; worktrees moved
  outside the repository; `loop promote` gained advisory mode;
  verification-diff matching, SARIF unknown-severity mapping, and the
  `LoopCommand` API-shape break were specified precisely.

## Implementation Plan

`impl-plans/active/loop-engineering-application-gap-closure.md` tracks
phases LA1–LA4 as concrete modules; LA5–LA6 are outlined there and get
detailed module specs when their phase starts.
