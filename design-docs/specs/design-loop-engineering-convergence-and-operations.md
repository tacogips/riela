# Riela Loop Engineering Convergence And Operations Hardening

Status: design, ready for implementation planning

Created: 2026-07-08

Source designs:

- `design-docs/specs/design-loop-engineering-first-line-tool.md`
- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
- `design-docs/specs/design-loop-engineering-application-gap-closure.md`
- `design-docs/specs/design-incomplete-work-inventory.md`

Implementation baseline:

- `impl-plans/active/loop-engineering-first-line-tool.md` (all modules DONE
  except module 8 self-evolution versioning)
- `impl-plans/active/loop-engineering-application-gap-closure.md` (LA1a
  implemented; LA1b and later not started)

Numbering in this document continues the gap-closure design: gaps start at
G10, specifications at S9, and phases at LB1, so cross-references between the
two documents stay unambiguous.

## Problem Statement

The first-line loop plan made one loop session auditable. The gap-closure
design (LA1–LA6) specifies the observation application around many sessions:
fleet listing, cost, budgets, diff, stats, CI verdicts, lessons, isolation.

Operating real loops has since exposed failure modes that neither document
addresses. They are not observation gaps; they are control and feedback gaps:

- **Loops that stop converging keep running.** On 2026-07-08 the packaged
  `codex-design-and-implement-review-loop` iterated its step6↔step7 review
  loop indefinitely, re-raising the same unsatisfiable finding every round
  (`design-docs/specs/design-incomplete-work-inventory.md` section 6). The
  runner bounds iteration *counts* (`defaults.maxLoopIterations`, `maxSteps`
  — `Sources/RielaCore/DeterministicWorkflowRunner.swift:282`), and LA2
  budgets will bound tokens and wall-clock, but nothing recognizes the
  distinctive stall signature: the same gate rejecting the same blocking
  findings round after round. Count and cost bounds either fire long after
  progress stopped or cut off loops that are still making progress.
- **There is no accepted baseline, so there is no regression verdict.**
  LA3's `loop diff` compares two explicit sessions. Operators actually ask
  a baseline question: "did this run regress against the last run we
  accepted?" Nothing records which session is the accepted baseline and
  nothing renders a regression verdict CI can consume.
- **Concurrent runs of the same loop corrupt each other.** Event sources
  already bind events to workflow runs (`Sources/RielaCLI/EventLiveServe.swift`,
  `RielaEvents` bindings), so a cron or webhook can start a loop while the
  previous run is still mutating the worktree. LA6 worktree isolation
  separates *where* runs write; nothing prevents or serializes *whether* a
  second run of the same loop starts at all.
- **Loop outcomes are pull-only.** Every terminal state — accepted,
  rejected, failed, budget-exceeded — must be discovered by polling
  `loop list`. Long-running and event-triggered loops need push
  notification of terminal outcomes.
- **Trend and flakiness are invisible.** LA3 stats aggregate a window, but
  do not answer "is this loop getting better or worse" or "does gate X flip
  decisions on identical workflow definitions" (the flaky-gate signature).
- **Learning is manual.** LA5 gives lessons a store and CLI; nothing closes
  the loop from evidence to lessons to workflow improvement. `workflow
  self-improve` proposals cite no gate-failure statistics, no stall
  incidents, no regression history.

This design specifies the convergence-and-operations layer that closes those
gaps. Everything here is additive over the existing loop contract and over
the LA roadmap; where a specification depends on an unimplemented LA module,
the dependency is explicit and the shared code is specified once.

## Current-State Review

Verified against `main` on 2026-07-08.

| Surface | State | Evidence |
| --- | --- | --- |
| Loop metadata, gates, policy, validation | Implemented | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift`, `LoopPolicyEvaluator.swift` |
| Evidence manifest + projection | Implemented | `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEvidenceProjector.swift` |
| Gate results from step outputs | Implemented | `LoopEvidenceProjector.swift:110` — each gate-step execution with an accepted `loopGate` payload yields one `LoopGateResult`; repeated visits yield one result per visit |
| Recovery lineage, `loop recover --from-step/--from-gate` | Implemented | `Sources/RielaCore/LoopRecoveryLineage.swift`, `Sources/RielaCLI/LoopCommands.swift` |
| Summary SQL + `loop list`/`history` (LA1a) | Implemented | `Sources/RielaCore/LoopSessionOverview.swift`, `loadSessionOverviews` in `SQLiteWorkflowRuntimePersistenceStore.swift` |
| `loop start`/`promote`, cost accumulator, budgets, diff, stats, `gates --check`, SARIF, lessons, isolation, GraphQL list/stats/diff | Not implemented | LA1b–LA6 modules in `impl-plans/active/loop-engineering-application-gap-closure.md`, all NOT_STARTED |
| Event-triggered workflow runs | Implemented | `Sources/RielaCLI/EventLiveServe.swift`; `RielaEvents` event→workflow bindings (`directWorkflow`, `workflowName`) |
| Outbound run-outcome notification | Absent | no runner or CLI egress on terminal states; `riela hook` is inbound vendor-hook ingestion (`Sources/RielaCLI/ScopedParityCommands.swift:70`), not egress |

Grounded observations that shape the specifications:

- **The runner already has a per-gate-visit seam.** Gate results are parsed
  from the accepted output payload key `loopGate` at projection time
  (`LoopEvidenceProjector.swift:110-150`). The same payload is reconciled at
  step completion by a routing reconciler the runner installs *only for gate
  steps*: `workflowRoutingReconciler(workflow:step:)`
  (`Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift:26`)
  returns `reconcileCompletionReviewRouting`
  (`Sources/RielaCore/LoopCompletionReviewRouting.swift`) exactly when
  `step.loop?.gateId != nil || step.loop?.role == "gate"`, and it is invoked
  at every candidate-publication site
  (`DeterministicWorkflowRunner.swift:639,723,849`,
  `DeterministicWorkflowRunner+Addons.swift:55`). This is the natural
  integration point for a convergence tracker: it already fires once per
  gate visit with the completion payload in hand and no other steps. The
  tracker can therefore observe per-visit blocking findings without new I/O,
  provided the `loopGate` payload parsing is extracted into a shared helper
  instead of forked.
- **A finding identity already exists.** `LoopBlockingFinding` carries
  optional `id`, `filePath`, `line`, `severity`, `message`. The LA3 diff
  spec matches findings by `(filePath, message)` with line drift tolerated.
  Convergence detection must reuse the same identity so "diff says nothing
  changed" and "convergence guard says the loop stalled" can never disagree.
- **`WorkflowSessionFailureKind` is a closed raw-value enum**
  (`Sources/RielaCore/RuntimeSession.swift:17`) and unknown persisted values
  still fail the whole snapshot decode. LA2 specifies tolerant decoding as a
  prerequisite for `budgetExceeded`; this design adds `loopNotConverging`
  and shares the same prerequisite — whichever change lands first builds
  tolerant decoding.
- **`WorkflowRunEventType` is a closed enum**
  (`Sources/RielaCore/WorkflowRunEvent.swift:3`); new progress records are
  additive JSONL contract changes and must be called out, exactly as LA2
  does for `budget_exceeded`.
- **Env-name secret references are the established convention.** Event
  contracts reference secrets by environment variable name
  (`chatWebhookBearerTokenEnv`, `Sources/RielaEvents/EventContracts.swift:341`),
  never by value. Notification channels follow the same convention.
- **The staleness heuristic exists.** LA1a shipped a 600-second staleness
  threshold for `possiblyStale` running rows. The concurrency lease reuses
  the same threshold semantics rather than inventing a second notion of
  "probably dead".

## Gap Analysis

### G10. No convergence guard

Iteration and (future) budget bounds are blunt: they cannot distinguish "ten
productive rounds" from "three identical rounds". The observed 2026-07-08
incident is exactly the signature a guard should catch deterministically:
same gate, same blocking-finding set, consecutive rounds. Highest priority
because it is an observed production failure with no mitigation beyond
manually killing the run.

### G11. No baseline and no regression verdict

Without a recorded accepted baseline, `loop diff` (LA3) answers "what
changed between A and B" but never "did we regress". CI can gate on a
session's own required gates (LA4 `--check`) but not on "this run is at
least as good as the last accepted one".

### G12. No concurrency guard for same-loop runs

Event-triggered loops make double-starts routine, not hypothetical. Two
concurrent runs of the same loop workflow interleave worktree mutations and
poison each other's changed-file evidence. LA6 isolation is complementary
(where runs write), not a substitute (whether a second run starts).

### G13. No outcome notification

Loop runs are long. Operators poll. Event-triggered runs finish silently.
A terminal-outcome push with an export-safe payload is missing.

### G14. No trend or flakiness analytics

LA3 stats summarize one window. Improvement work needs direction (better or
worse than the prior window) and flake detection (decision flips across runs
with an identical workflow definition digest).

### G15. Learning is not evidence-fed

LA5 lessons are written by hand. Self-improve proposals cite no statistics.
The loop-engineering promise — cycles that improve — has no automated
feedback path from evidence to improvement.

## Design Decisions

1. **Convergence is judged on finding identity, never on iteration counts
   or semantics.** Fingerprints are deterministic functions of persisted
   finding fields; no LLM-based similarity, no fuzzy matching. A guard that
   sometimes misfires nondeterministically is worse than none.
2. **One finding identity for diff and convergence.** The fingerprint reuses
   the LA3 matching rule — explicit `id` when authored, else
   `(filePath, whitespace-normalized message)`, line excluded — implemented
   once in RielaCore and consumed by both features.
3. **All new authored metadata is optional and additive.** Workflows without
   `loop.convergence`, `loop.concurrency`, or `loop.notifications` behave
   exactly as today. Absent fields decode as nil; old snapshots decode.
4. **Baselines are explicit operator state.** No inference of "latest
   accepted run is the baseline" — an implicit baseline that silently moves
   makes regression verdicts unreproducible. A baseline is set, shown, and
   cleared by explicit CLI commands and stored in one small table.
5. **The concurrency guard is an advisory lease, honestly documented.** It
   prevents routine duplicate starts through one runtime store. It is not a
   distributed lock: two data roots, or a crashed process holding a fresh
   lease, are documented limitations with staleness-based takeover.
6. **Notifications are best-effort egress at terminal persistence.** They
   never change a session outcome, never block completion beyond a bounded
   timeout, and carry export-safe payloads (ids, counts, decisions — no
   prompt text, no finding messages, no variable values).
7. **Tolerant failure-kind decoding is a shared prerequisite.** LA2
   (`budgetExceeded`) and LB1 (`loopNotConverging`) both need it; the design
   assigns it to whichever ships first and the other consumes it.
8. **Trend and flakiness extend LA3's `LoopWorkflowStats`.** Additive fields
   on the same aggregation over the same summary rows — no second stats
   pipeline, no materialized tables.
9. **Retrospective automation is a workflow template plus small CLI hooks,
   not runtime intelligence.** The runtime supplies deterministic inputs
   (stats, diffs, stall records); an example workflow distills lessons; the
   human-reviewed path stays mandatory for workflow mutation.

## Specifications

### S9. Loop convergence guard (G10)

New optional authored metadata:

```json
{
  "loop": {
    "convergence": {
      "maxGateVisits": 6,
      "maxRepeatedFindingRounds": 2,
      "onStall": "fail"
    }
  }
}
```

Semantics:

- `maxGateVisits`: upper bound on executions of any single gate step within
  one session. A backstop that fires even when findings mutate every round.
- `maxRepeatedFindingRounds`: N consecutive visits to the *same* gate whose
  decision is `rejected` or `needs_work` and whose blocking-finding
  fingerprint set is identical to the previous visit's set. `2` means: the
  second consecutive identical rejection round triggers the stall action.
  An `accepted` or `skipped` visit, or a visit whose fingerprint set
  differs, resets the counter for that gate.
- `onStall`: `"fail"` (default) or `"warn"`. Validation rejects `warn` when
  `loop.required == true` — required loops fail closed, mirroring the LA2
  budget rule. At least one of the two bounds must be present; values must
  be positive.

**Fingerprint.** `LoopFindingFingerprint.make(finding:)` in RielaCore:

1. If the finding carries an authored `id` that is not a runtime-synthesized
   one (the projector's acceptance-policy overlay synthesizes ids prefixed
   `gate-policy-` — `LoopEvidenceProjector.swift:169`), use `id`.
2. Otherwise `(filePath ?? "", message with whitespace runs collapsed and
   leading/trailing whitespace trimmed)`. `line` is excluded (drift
   tolerated) and `severity` is excluded (reviewers flip severity on
   identical findings). This is the LA3 diff identity, extracted into one
   shared implementation that S10 regression and LA3 diff also consume.

**Runner integration.** A runner-owned `LoopConvergenceTracker`:

- Fed at the gate-step routing-reconciler seam
  (`workflowRoutingReconciler`, which already fires once per gate visit —
  see Current-State Review). The `loopGate` payload parsing currently lives
  inside the evidence projector (`LoopEvidenceProjector.swift:129`); it is
  extracted into a shared parsing helper used by the projector, the routing
  reconciler, and the tracker — no forked parser.
- Tracks, per `gateId`: visit count, last fingerprint set, consecutive
  identical-rejection rounds.
- Checks bounds after recording each gate visit and before the runner
  dispatches the next step. On violation with `onStall == "fail"`, the
  session fails with `WorkflowSessionFailureKind.loopNotConverging` and a
  deterministic diagnostic naming the gate id, visit count, repeated-round
  count, and a bounded listing of the repeated fingerprints. With `warn`,
  the runner records a residual risk plus diagnostic and continues.
- Emits a `loop_stall` progress record (additive `WorkflowRunEventType`
  case; the live-persistence event switch updates with it) carrying gateId,
  visits, repeated rounds, and the action taken.

**Evidence.** `LoopEvidenceManifest` gains an optional
`convergence: LoopConvergenceEvidence`:

```swift
public struct LoopConvergenceEvidence: Codable, Equatable, Sendable {
  public var gateVisitCounts: [String: Int]
  public var stallDetected: Bool
  public var stalledGateId: String?
  public var repeatedRounds: Int?
  public var action: String?            // "fail" | "warn"
  public var diagnostics: [String]
}
```

Absent for sessions without convergence metadata; defaulted decoding for
old snapshots.

**Failure-kind compatibility.** `loopNotConverging` is a new persisted enum
case. Tolerant persisted decoding (unknown raw values decode to a preserved
`other(String)`-style representation with a diagnostic) is required and does
not exist yet; it ships with whichever of LB1 or LA2 lands first, per
Design Decision 7. Binaries predating that change cannot decode stalled
sessions — the same accepted, documented limitation LA2 records.

**Non-goals.** No semantic finding similarity, no cross-session convergence
tracking (a rerun starts fresh; cross-session patterns are S13 flakiness),
no automatic recovery from a stall (the operator uses
`loop recover --from-gate`).

### S10. Accepted baseline and regression verdict (G11)

**Baseline storage.** New table in the runtime persistence store, following
the existing migration pattern:

```sql
CREATE TABLE IF NOT EXISTS loop_baselines (
  workflow_id TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL,
  set_at      TEXT NOT NULL,
  note        TEXT
);
```

Writes happen only through the explicit baseline commands (writable open);
all read surfaces stay on read-only connections. One baseline per workflow
id in the MVP.

**CLI.**

```bash
riela loop baseline set <workflow> <session-id> [--note <text>] [--force]
riela loop baseline show <workflow>
riela loop baseline clear <workflow>
```

`set` validates that the session exists, has loop evidence, and that all
required gates are `accepted`; `--force` overrides the acceptance check and
records the override in the stored note and command diagnostics. `show` and
`clear` are trivial reads/deletes with JSONL/JSON/text output.

**Regression verdict.**

```bash
riela loop regress <workflow> [--session <id>] [--output jsonl|json|text]
```

- Target resolution: explicit `--session`, else the newest completed session
  with loop evidence from the summary API (`loadSessionOverviews`).
- Computes `LoopEvidenceDiff` (LA3 S4) from baseline manifest to target
  manifest and classifies regressions:
  - a required gate's decision downgraded (`accepted` in baseline →
    `rejected`/`needs_work`/missing in target),
  - `blockingFindingsAdded` on a required gate,
  - a verification command outcome flip from pass to fail (matched by the
    S4 `argvSummary` rule).
- Output is a `LoopRegressionVerdict` listing each regression with its
  classification, plus the underlying diff reference.

Exit-code contract, mirroring the LA4 `gates --check` codes and pinned by
contract tests:

- `0`: baseline and target evidence present, no regression.
- `3`: at least one regression detected.
- `4`: no baseline recorded, or target session has no loop evidence.
- `1`: operational error.

**Sugar.** `riela loop diff --baseline <workflow> [--session <id>]` resolves
baseline/target the same way and delegates to the ordinary diff rendering.

**Cross-plan dependency.** `LoopEvidenceDiffer` is specified in LA3 and not
yet implemented. If LA3 has not landed when this phase starts, this phase
implements the differ core exactly per the S4 specification as shared
RielaCore code — one implementation with two consumers, never two matchers.

### S11. Loop concurrency guard (G12)

New optional authored metadata:

```json
{
  "loop": {
    "concurrency": {
      "maxActive": 1,
      "onBusy": "fail"
    }
  }
}
```

- `maxActive`: MVP validates `maxActive == 1` (the lease table's primary key
  is the workflow id; N>1 pools are a later extension and rejected at
  validation until then).
- `onBusy`: `"fail"` (default) — refuse to start with a typed error;
  `"skip"` — exit successfully without creating a session, for cron/webhook
  triggers where "previous run still going" is normal.

**Lease.** New table in the runtime persistence store:

```sql
CREATE TABLE IF NOT EXISTS loop_concurrency_leases (
  workflow_id  TEXT PRIMARY KEY,
  session_id   TEXT NOT NULL,
  acquired_at  TEXT NOT NULL,
  heartbeat_at TEXT NOT NULL
);
```

- **Acquire**: at run entry, in a single writable transaction — insert, or
  replace an existing row only when its `heartbeat_at` is older than the
  staleness threshold (default 600 seconds, the same threshold LA1a uses
  for `possiblyStale`). A fresh existing row means busy. Stale takeover is
  recorded as a diagnostic on the new run.
- **Heartbeat**: refreshed by the existing live-persistence save path
  whenever it saves a snapshot for the lease-holding session — the single
  save-path helper touches the lease row in the same call, the same
  "derived writes happen in one helper" rule the LA1a summary columns
  follow. No new timers, no background thread.
- **Release**: deleted at terminal persistence (completed or failed). A
  crashed process leaves the row to expire via staleness.
- The lease row records the session id, so `loop list` and diagnostics can
  say *which* run holds the lease.

**Enforcement point.** A preflight helper invoked by every execution entry
that starts a new session for a workflow declaring `loop.concurrency`: the
CLI `workflow run` path, `loop start` (LA1b, when it lands), and the
event-triggered path (`EventLiveServe`). Resume and rerun of an existing
session re-acquire the same lease keyed by workflow id under the same rules.

**Busy behavior.**

- `fail`: the CLI exits non-zero with a typed `loop_concurrency_busy` error
  record naming the holding session id and its last heartbeat. No session
  is created.
- `skip`: the CLI exits `0`, emits a `loop_concurrency_skipped` JSONL record
  with the same details, and creates no session. Event-serve paths log the
  skip on the event receipt.

**Honesty.** This is an advisory guard against routine duplicate starts
through one runtime store. Two different data roots see different lease
tables; a paused-but-alive process can lose its lease to staleness takeover
and both runs then execute. The guard narrows the window; worktree
isolation (LA6) limits the damage when the window is hit. Both limitations
are documented on the command surfaces.

### S12. Loop outcome notifications (G13)

New optional authored metadata:

```json
{
  "loop": {
    "notifications": {
      "on": ["accepted", "rejected", "failed", "stalled"],
      "channels": [
        { "type": "webhook", "urlEnv": "RIELA_LOOP_WEBHOOK_URL" },
        { "type": "command", "argv": ["scripts/notify-loop.sh"] }
      ]
    }
  }
}
```

**Outcome classification** from the terminal snapshot plus manifest:

- `accepted`: session completed and every required gate is `accepted`.
- `rejected`: session completed but at least one required gate is
  `rejected`/`needs_work`/missing.
- `stalled`: session failed with `loopNotConverging` (S9).
- `failed`: any other failed terminal state (including `budgetExceeded`
  when LA2 lands).

**Payload** (`LoopOutcomeNotification`, schema-versioned): workflow id,
session id, outcome, entry mode, last gate decision, per-gate decisions
(gate id + decision only), blocking-finding count, cost summary when
recorded, started/ended timestamps. Export-safe by construction: ids,
counts, and decisions only — no prompt text, no finding messages, no
variable or environment values, no file paths.

**Channels.**

- `webhook`: HTTP POST of the JSON payload. The URL comes from the named
  environment variable (`urlEnv`), following the established env-name
  secret convention (`chatWebhookBearerTokenEnv`,
  `Sources/RielaEvents/EventContracts.swift:341`); workflow bundles never
  carry endpoint values. Optional `bearerTokenEnv`. Missing variable at
  dispatch time → skipped with a diagnostic, never an error.
- `command`: executes `argv` with the JSON payload on stdin, resolved
  workflow-relative first, cwd at the execution working directory. Exit
  status recorded; output discarded beyond a bounded diagnostic.

**Dispatch rules.**

- Runs after terminal persistence succeeds, from the process that owns the
  run (CLI run command or event-serve executor) — never from read paths.
- Best-effort: bounded timeout (default 5 seconds per channel), one retry,
  failures recorded as session diagnostics. Notification failure never
  changes the session outcome and never fails the command.
- Each dispatch (attempted, delivered, skipped, failed) is a diagnostic;
  nothing about notification goes into the evidence manifest itself, so
  the manifest stays a record of the work, not of the reporting.
- Package validation warns on `command` channels in packaged workflows
  (portability); webhook channels are portable by construction.

### S13. Trend and flakiness statistics (G14)

Additive fields on LA3's `LoopWorkflowStats` (same aggregation pass over the
same `LoopSessionSummary` rows — no second pipeline):

```swift
public struct LoopWorkflowTrend: Codable, Equatable, Sendable {
  public var recentWindowRuns: Int
  public var priorWindowRuns: Int
  public var acceptanceRateRecent: Double?
  public var acceptanceRatePrior: Double?
  public var meanTotalTokensRecent: Int?
  public var meanTotalTokensPrior: Int?
  public var meanDurationMsRecent: Int?
  public var meanDurationMsPrior: Int?
  public var diagnostics: [String]
}

public struct LoopGateFlakiness: Codable, Equatable, Sendable {
  public var gateId: String
  public var runsConsidered: Int        // runs sharing the same workflow definition digest
  public var decisionFlips: Int         // adjacent-run decision changes within those runs
  public var diagnostics: [String]
}
```

- `--trend` splits the requested window into a recent half and a prior half
  (newest-first ordering already used by stats) and reports both plus the
  deltas; halves with too few runs report nil rates with a diagnostic.
- Flakiness only compares runs whose `workflowDefinitionDigest` matches the
  most recent run's digest — decision changes across definition changes are
  legitimate, not flake. Sessions without a digest are excluded and
  counted in diagnostics. Because the digest lives in the manifest, the
  summary shape gains an optional `workflowDefinitionDigest` field
  (additive `LoopSessionSummary` change, frozen at projection time like the
  other summary fields).
- CLI: `riela loop stats <workflow> [--limit n] [--trend]`; GraphQL parity
  rides the LA3 `loopWorkflowStats` projection (same DTO gains the same
  optional fields).

### S14. Evidence-fed retrospectives and self-improve rationale (G15)

Two thin integrations, no new runtime intelligence:

**Retrospective workflow template.** `examples/loop-retrospective/`: a
first-party workflow that takes a workflow id, reads `loop stats`
(S13/LA3), `loop history`, the latest `loop regress` verdict (S10) and
stall records (S9) through the CLI, distills at most N candidate lessons,
and writes them via `loop lesson add` (LA5 S7) behind a required review
gate. Ships with a deterministic mock scenario and `EXPECTED_RESULTS.md`
per first-party conventions. The template is documentation-grade product
surface: it proves the loop closes with today's CLI, and it is the place
where lesson-authoring discipline is encoded (distill, cap, cite source
sessions), not in runtime code.

**Stats-fed self-improve rationale.** `workflow self-improve` gains an
optional `--loop-stats` flag: when set, the improvement context includes the
workflow's `LoopWorkflowStats` JSON (including trend and flakiness when
available), the most recent stall diagnostics, and the latest regression
verdict. The self-improve change report records that these inputs were
provided, so proposals citing "gate X failed 7 of last 10 runs" are
distinguishable from speculative ones. This is context injection only — the
approval gate and (once first-line module 8 lands) snapshot/restore
semantics are unchanged.

Dependencies: the template depends on LA5 lessons for its write path (the
read-only analysis portion works without it); `--loop-stats` depends on LA3
stats. Both are sequenced last for that reason.

## Security Requirements

- Convergence diagnostics may quote finding fingerprints (paths and
  normalized messages) in local output; the `loop_stall` progress record
  carries gate id and counts only.
- Notification payloads are export-safe by construction (S12): ids, counts,
  decisions, timestamps. No prompt text, finding messages, file paths,
  variable values, or environment values. Endpoint URLs and tokens are
  env-name references, never stored values.
- Notification `command` channels execute operator-authored commands; they
  run with the same trust as the workflow's own verification commands, are
  recorded in diagnostics, and are warned about at package validation.
- The lease and baseline tables contain ids and timestamps only.
- Baseline `--force` overrides are always recorded (note + diagnostics) so
  an unaccepted baseline is never silent.

## Observability Requirements

- `loop_stall` progress records carry gate id, visit count, repeated
  rounds, and action.
- `loop_concurrency_busy` / `loop_concurrency_skipped` records name the
  holding session id and its last heartbeat.
- Notification dispatch attempts, deliveries, skips, and failures are
  session diagnostics.
- All new commands support `--output jsonl|json|text` (plus `table` where
  rows are natural) and default to JSONL, matching the CLI.
- `loop regress` and `loop baseline show` never mutate stored snapshots;
  baseline `set`/`clear` and lease writes are the only new write paths, and
  both are explicit-command or save-path writes — reads never write.

## Compatibility and Migration

- All authored metadata (`loop.convergence`, `loop.concurrency`,
  `loop.notifications`) is optional; absent metadata preserves today's
  behavior. Raw validation accepts the new keys; existing workflows stay
  valid.
- `LoopConvergenceEvidence` and the `LoopSessionSummary.workflowDefinitionDigest`
  field are additive with defaulted decoding; old snapshots decode.
- `WorkflowSessionFailureKind.loopNotConverging` requires tolerant persisted
  decoding, shared with LA2's `budgetExceeded` (Design Decision 7). Old
  binaries cannot decode stalled sessions — accepted, documented, same as
  LA2.
- `loop_stall`, `loop_concurrency_busy`, and `loop_concurrency_skipped` are
  additive JSONL record types; `WorkflowRunEventType` gains `loop_stall`
  and the live-persistence event switch updates with it. Consumers ignore
  unknown record types.
- `loop_baselines` and `loop_concurrency_leases` are new tables created by
  the existing migration pattern; their absence in old stores is handled by
  `CREATE TABLE IF NOT EXISTS` on writable opens, and read paths treat a
  missing table as "no baseline / no lease".
- `loop regress` exit codes apply only to the new command; `loop diff
  --baseline` adds a flag to an LA3 command without changing its defaults.
- No existing CLI command changes shape; all new surfaces are new
  subcommands or new flags.

## Phased Roadmap

Ordered by observed operational pain, then by dependency.

### LB1: Convergence guard (G10)

Fingerprint helper (shared with diff), authored metadata + validation,
runner tracker, `loopNotConverging` + tolerant failure-kind decoding
(unless LA2 landed it first), `loop_stall` record, evidence section.
No dependency on any LA phase.

### LB2: Baseline and regression verdict (G11)

`loop_baselines` table, `loop baseline set/show/clear`, `loop regress`
with exit-code contract, `loop diff --baseline`. Depends on the LA3 differ
core; lands it per S4 if LA3 has not.

### LB3: Concurrency guard (G12)

Lease table, acquire/heartbeat/release wiring into the save path, preflight
in run/loop-start/event-serve entries, busy/skip records. Depends only on
LA1a (shipped).

### LB4: Outcome notifications (G13)

Channel model + validation, outcome classification, dispatcher at terminal
persistence in CLI and event-serve paths, package-validation warning for
command channels. Benefits from LB1 (stalled outcome) but works without it.

### LB5: Trend and flakiness (G14)

Additive stats fields, `--trend`, summary digest field. Depends on LA3
stats.

### LB6: Retrospective template and self-improve rationale (G15)

`examples/loop-retrospective/` with mocks and expected results;
`workflow self-improve --loop-stats`. Depends on LA3 (stats) and LA5
(lesson write path); read-only analysis portions can land earlier if those
slip.

## Rejected Alternatives

- **LLM-based finding similarity for convergence.** Nondeterministic guard
  behavior is worse than none; reruns must reproduce. The deterministic
  fingerprint catches the observed failure signature (identical findings);
  paraphrase-drift stalls remain visible through `maxGateVisits` and LA2
  budgets.
- **Auto-recovery on stall** (automatically rerunning from an earlier step
  with modified inputs). Recovery choice requires judgment; the guard's job
  is to stop deterministically and leave an addressable record
  (`loop recover --from-gate` already exists).
- **Implicit baselines** ("latest accepted run"). A baseline that moves on
  its own makes regression verdicts unreproducible and CI green/red flappy.
- **A real cross-host lock service for concurrency.** Out of scale with
  riela's local-first model; the advisory lease plus isolation covers the
  actual observed risk (event-triggered double starts on one machine).
- **Notification via chat gateways in the MVP.** The chat surfaces are
  event-source-scoped (session, auth, room routing); reusing them as
  generic egress drags their lifecycle into the runner. Webhook + command
  channels cover chat via operator-side bridges; native chat channels can
  be a later additive channel type.
- **A materialized flakiness table.** Same reasoning as LA3: bounded
  on-read aggregation over summary rows, materialize only if profiling
  demands it.
- **Runtime-owned automated lesson writing.** Lesson quality depends on
  distillation judgment; encoding it as a reviewed workflow template keeps
  the human gate and keeps runtime deterministic.

## Open Questions

- Should `maxRepeatedFindingRounds` compare against the immediately
  preceding visit only (current spec) or against any earlier visit (catches
  A/B/A oscillation)? MVP: consecutive only; oscillation shows up in
  `maxGateVisits`.
- Should `onBusy: "queue"` (wait for the lease with a timeout) be added for
  event-triggered loops, or does skip + the event source's own retry cover
  it? Deferred until receipt data shows demand.
- Should the regression verdict also consider cost ("accepted but 3× the
  tokens") once LA2 cost data exists? Deferred; would make the verdict
  depend on inherently noisy totals.
- Should notification payloads optionally include a bounded findings
  summary behind an explicit `includeFindingTitles: true` opt-in? Default
  stays counts-only either way.
- Does `loop list` need a `lease` column showing which running session
  holds the workflow's lease? Cheap once LB3 lands; decide with real use.

## Risks

- **Fingerprint too strict.** Agents that rephrase the same finding every
  round evade `maxRepeatedFindingRounds`; `maxGateVisits` is the backstop
  and both bounds ship together for that reason.
- **Fingerprint too loose.** Distinct findings sharing a file and message
  (repeated boilerplate messages) could merge; the explicit-`id` preference
  gives authors an escape hatch, and diff shares the identity so the
  behavior is at least consistent and inspectable.
- **Lease staleness takeover races.** A paused-but-alive run can lose its
  lease; the guard is documented as advisory and worktree isolation (LA6)
  bounds the damage. The takeover diagnostic makes the race visible after
  the fact.
- **Save-path coupling.** Heartbeat and summary-column writes ride the same
  single save helper; a regression there affects both. The existing
  summary-consistency regression test pattern extends to the lease row.
- **Notification egress from a runtime tool.** Even export-safe payloads
  leave the machine; channels are opt-in authored metadata, env-name
  indirection keeps endpoints out of bundles, and package validation warns
  on command channels.
- **Exit-code contract erosion** for `loop regress`, same as LA4: pinned by
  contract tests as part of the phase's definition of done.
- **Cross-plan drift with LA3/LA5.** LB2 and LB5/LB6 consume LA modules
  that may land before, during, or after this work. Mitigation: the shared
  pieces (differ core, finding identity, stats shape) are specified once,
  here and in LA, with explicit "one implementation, two consumers" rules.

## Implementation Plan

`impl-plans/active/loop-engineering-convergence-and-operations.md` tracks
phases LB1–LB4 as concrete modules; LB5–LB6 are outlined there and get
detailed module specs when their phase starts.
