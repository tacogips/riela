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

- **Undeclared loops have no convergence or terminal-preservation guard.** On
  2026-07-08 the packaged `codex-design-and-implement-review-loop` iterated its
  step6↔step7 review loop indefinitely, re-raising the same unsatisfiable
  finding every round (`design-docs/specs/design-incomplete-work-inventory.md`
  section 6). Authored `loop.convergence` enforcement has since shipped, but a
  workflow with no `loop` object still bypasses it. Such a workflow can repeat
  one gate until `maxSteps` fails, including after consuming capacity needed
  by commit or output stages.
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

S9/S9a surfaces were re-verified against the
`feat/loop-guardrail-defaults` branch baseline on 2026-07-22. Operations
surfaces outside this work package retain their historical roadmap status and
were not re-audited here.

| Surface | State | Evidence |
| --- | --- | --- |
| Loop metadata, gates, policy, validation | Implemented | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift`, `LoopPolicyEvaluator.swift` |
| Evidence manifest + projection | Implemented | `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEvidenceProjector.swift` |
| Gate results from step outputs | Implemented | `LoopEvidenceProjector.swift:110` — each gate-step execution with an accepted `loopGate` payload yields one `LoopGateResult`; repeated visits yield one result per visit |
| Authored convergence tracking and `loop_stall` enforcement | Implemented | `Sources/RielaCore/LoopConvergenceTracker.swift`, `DeterministicWorkflowRunner+LoopPolicy.swift`, `LoopFindingFingerprint.swift`, `WorkflowRunEvent.swift` |
| Tolerant persisted failure kinds, including `loopNotConverging` | Implemented | `WorkflowSessionFailureKind` is a raw-value struct in `Sources/RielaCore/RuntimeSession.swift`; unknown values remain decodable and expose a compatibility diagnostic |
| Synthesized defaults, default-policy provenance, graceful terminal routing, terminal reservation, and default opt-out | Not implemented | This work package; specified by S9a |
| Recovery lineage, `loop recover --from-step/--from-gate` | Implemented | `Sources/RielaCore/LoopRecoveryLineage.swift`, `Sources/RielaCLI/LoopCommands.swift` |
| Summary SQL + `loop list`/`history` (LA1a) | Implemented | `Sources/RielaCore/LoopSessionOverview.swift`, `loadSessionOverviews` in `SQLiteWorkflowRuntimePersistenceStore.swift` |
| Baseline, regression, concurrency, notifications, trend, and retrospective surfaces | Historical roadmap state | Outside this S9a work package; phases LB2–LB6 remain documented below without a new implementation audit |
| Event-triggered workflow runs | Implemented | `Sources/RielaCLI/EventLiveServe.swift`; `RielaEvents` event→workflow bindings (`directWorkflow`, `workflowName`) |
| Outbound run-outcome notification | Absent | no runner or CLI egress on terminal states; `riela hook` is inbound vendor-hook ingestion (`Sources/RielaCLI/ScopedParityCommands.swift:70`), not egress |

Grounded observations that shape the specifications:

- **The runner already enforces authored convergence at the per-gate-visit
  seam.** `workflowRoutingReconciler(workflow:step:)` and
  `enforceLoopConvergenceIfNeeded` in
  `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift` consume the
  shared `LoopGatePayloadParser` in `LoopFindingFingerprint.swift`. The current
  entry guards require `workflow.loop`; S9a widens only those guards to consume
  the resolved effective-policy state plus step annotations, without adding a
  second parser or tracker.
- **A finding identity already exists.** `LoopBlockingFinding` carries
  optional `id`, `filePath`, `line`, `severity`, `message`. The LA3 diff
  spec matches findings by `(filePath, message)` with line drift tolerated.
  Convergence detection must reuse the same identity so "diff says nothing
  changed" and "convergence guard says the loop stalled" can never disagree.
- **Persisted failure-kind compatibility is already tolerant.**
  `WorkflowSessionFailureKind` is a raw-value struct
  (`Sources/RielaCore/RuntimeSession.swift:17`), includes
  `loopNotConverging`, and preserves unknown values with a compatibility
  diagnostic. S9a does not need a new failure-kind case for graceful default
  routing.
- **`loop_stall` already has a structured event contract.** S9a retains the
  existing gate id, violation kind, action, visit, repeated-round, and
  fingerprint fields, and adds optional policy provenance. The event type
  itself is not new.
- **Env-name secret references are the established convention.** Event
  contracts reference secrets by environment variable name
  (`chatWebhookBearerTokenEnv`, `Sources/RielaEvents/EventContracts.swift:341`),
  never by value. Notification channels follow the same convention.
- **The staleness heuristic exists.** LA1a shipped a 600-second staleness
  threshold for `possiblyStale` running rows. The concurrency lease reuses
  the same threshold semantics rather than inventing a second notion of
  "probably dead".

## Gap Analysis

### G10. No default convergence guard or terminal preservation

The authored convergence guard handles workflows that declare
`loop.convergence`, but workflows with no `loop` object retain only blunt
iteration and step bounds. They neither detect repeated identical findings nor
reserve capacity for a deterministic terminal path. The remaining gap is a
conservative synthesized policy with explicit provenance, opt-out, and
backward-compatible terminal handling.

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
3. **Authored loop behavior remains explicit; undeclared workflows get a
   conservative convergence floor.** A workflow with an authored `loop`
   object keeps exactly its declared convergence behavior, including no
   convergence enforcement when `loop.convergence` is absent. A workflow with
   no `loop` object receives the default guard specified in S9a unless the CLI
   opts out. New declaration and event fields decode with defaults so old
   snapshots continue to decode.
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
7. **Tolerant failure-kind decoding is an established shared contract.** LA2
   (`budgetExceeded`) and LB1 (`loopNotConverging`) both use the implemented
   raw-value failure-kind model; S9a introduces no new failure kind.
8. **Trend and flakiness extend LA3's `LoopWorkflowStats`.** Additive fields
   on the same aggregation over the same summary rows — no second stats
   pipeline, no materialized tables.
9. **Retrospective automation is a workflow template plus small CLI hooks,
   not runtime intelligence.** The runtime supplies deterministic inputs
   (stats, diffs, stall records); an example workflow distills lessons; the
   human-reviewed path stays mandatory for workflow mutation.

## Specifications

### S9. Loop convergence guard (G10)

The authored convergence contract below is implemented and is the baseline
that S9a extends. Its optional metadata is:

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

**Runner integration.** The runner-owned `LoopConvergenceTracker`:

- Is fed at the gate-step routing-reconciler seam through the shared
  `LoopGatePayloadParser` used by the evidence projector and tracker.
- Tracks, per `gateId`: visit count, last fingerprint set, consecutive
  identical-rejection rounds.
- Checks bounds after recording each gate visit and before the runner
  dispatches the next step. On violation with `onStall == "fail"`, the
  session fails with `WorkflowSessionFailureKind.loopNotConverging` and a
  deterministic diagnostic naming the gate id, visit count, repeated-round
  count, and a bounded listing of the repeated fingerprints. With `warn`,
  the runner records a residual risk plus diagnostic and continues.
- Emits the existing `loop_stall` progress record carrying gateId, visits,
  repeated rounds, fingerprints, and the action taken.

**Evidence.** `LoopEvidenceManifest` contains an optional
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

This manifest section remains evidence for an authored, enabled
`loop.convergence` declaration. It is absent for `authored-inactive`,
`disabled`, and synthesized `default` policy states; `action` therefore remains
limited to `fail` or `warn`, and old snapshots retain defaulted decoding. This
boundary avoids projecting a request-level default or CLI opt-out as if it were
authored workflow metadata.

Default-policy enforcement instead uses the persisted accepted `loopGate`
payloads and step-execution identities as its canonical gate evidence. During
the run, the shared parser reconstructs visit counts and finding fingerprints
from those executions. A violation persists its `default` provenance and
disposition in the `loop_stall` progress record and, when graceful routing is
available, the `loopGuardOutcome` output marker. The runtime never reads
`LoopConvergenceEvidence` to make a routing decision. Thus default sessions are
observable when the guard acts without widening the authored-policy manifest
contract; a default session with no violation adds no convergence manifest.

**Failure-kind compatibility.** `loopNotConverging` and tolerant unknown-value
decoding are already implemented by the raw-value
`WorkflowSessionFailureKind`. S9a reuses that failure only when a default guard
cannot route to a terminal corridor; it adds no closed failure-kind case.

**Non-goals.** No semantic finding similarity, no cross-session convergence
tracking (a rerun starts fresh; cross-session patterns are S13 flakiness),
no automatic recovery from a stall (the operator uses
`loop recover --from-gate`).

### S9a. Default convergence guard and terminal preservation

S9 remains the contract for explicitly authored convergence policies. This
extension supplies a deterministic safety floor only when the workflow has no
authored `loop` object. It does not merge defaults into, reinterpret, or
otherwise change any explicit loop declaration.

#### Effective policy and provenance

At run entry the runner resolves exactly one of four states, in this precedence
order:

1. `declared`: `workflow.loop.convergence` is present and enabled. The authored
   bounds and `onStall` action apply without default merging. The CLI opt-out
   has no effect on this state.
2. `authored-inactive`: `workflow.loop` is present but `loop.convergence` is
   absent. No convergence tracker or synthesized bound applies. This preserves
   the existing behavior of workflows that author other loop metadata without
   authoring convergence policy; the CLI opt-out has no additional effect.
3. `disabled`: an authored convergence declaration sets `enabled: false`, or a
   workflow with no `loop` object is run with
   `--disable-default-loop-guard`. Declaration-level disablement is represented
   as follows and may omit both bounds:

   ```json
   {
     "loop": {
       "convergence": {
         "enabled": false
       }
     }
   }
   ```

   The CLI flag disables only synthesized defaults; it never disables an
   explicit enabled convergence policy or changes an `authored-inactive`
   workflow.
4. `default`: the workflow has no `loop` object and the CLI has not opted out.
   The effective declaration is `maxGateVisits: 4`,
   `maxRepeatedFindingRounds: 2`. A gate may execute four times; the fifth
   visit violates the visit cap. The second consecutive rejected or
   needs-work visit with the same blocking-finding fingerprint set violates
   the repeated-finding bound.

`LoopConvergenceDeclaration.enabled` is optional and decodes as `true`.
Validation accepts omitted bounds only when it is `false`; `enabled: false`
combined with either bound or a non-default `onStall` is rejected as
contradictory. Existing `onStall` values remain closed to `fail` and `warn`.
The default guard's terminal-routing disposition is runtime policy derived
from `default` provenance, not a new persisted enum case.

The resolved state and its provenance are request-local runtime context; they
do not mutate or backfill the workflow declaration. The runner evaluates only
`declared` and `default` policies through the same `LoopConvergenceTracker` and
`LoopPolicyEvaluator` components. `authored-inactive` and `disabled` do not
produce convergence violations or `loop_stall` events, so they have no stall
policy source to persist. Within the `default` state, terminal-step reservation
is independently identified by `policySource: "step-budget"` as described
below. Every actual
convergence violation retains the existing `loopStallGateId`,
`loopStallViolationKind`, `loopStallGateVisits`,
`loopStallRepeatedRounds`, and `loopStallFingerprints` fields and adds
`loopStallPolicySource` with `declared` or `default`. Explicit `warn` continues
and explicit `fail` fails exactly as before.

Default-policy gate discovery cannot depend on `workflow.loop` because that
object is absent by definition. A step participates when `step.loop.gateId` is
present or `step.loop.role == "gate"`. Its stable gate identity is the authored
`gateId`, falling back to the step id for a role-only gate. The shared
`LoopGatePayloadParser` already supports this fallback; the routing-reconciler
and convergence-enforcement entry guards must use the effective policy plus
step annotation instead of requiring `workflow.loop != nil`. Steps without
either gate annotation are never inferred as gates from prompt or output text.

#### Graceful terminal routing

A default-policy violation must not fail immediately when the workflow has a
deterministic terminal corridor. Corridor selection is a shared graph contract
used by both convergence routing and terminal-step reservation. It takes an
origin step: the just-published gate for a convergence violation, or the
runner's selected current step before dispatch for reservation. From that
origin and the validated execution graph it derives the corridor as follows:

- Enumerate transitionless, root-output-producing sinks statically reachable
  from the origin. Conditional branches count as reachable until runtime has
  already selected and persisted one branch.
- For each reachable sink, walk backward through the maximal suffix whose
  steps have one unconditional outgoing edge into that suffix. A gate,
  branching step, fanout/cross-workflow boundary, or multiple incoming edges
  stops extension; multiple incoming edges do not invalidate the suffix
  already found.
- A corridor is selectable only when all reachable output paths converge on
  the same suffix and therefore the same corridor entry. Distinct reachable
  output sinks, distinct suffixes, or a suffix containing a fanout or
  cross-workflow boundary are ambiguous and produce no corridor. This avoids
  predicting an unresolved condition or choosing among terminal outcomes.

On a default-policy violation with a corridor, the runner replaces the
loop-back destination with the corridor entry and persists an additive marker
in the routed payload and final root output:

```json
{
  "loopGuardOutcome": {
    "decision": "accept-with-residual-risks",
    "policySource": "default",
    "gateId": "implementation-review",
    "violationKind": "repeatedFindingsStall",
    "gateVisits": 2,
    "repeatedRounds": 2,
    "findingFingerprints": ["..."],
    "residualRisks": ["default loop convergence guard stopped further revision"]
  }
}
```

The marker is derived only from the persisted accepted `loopGate` payloads and
step-execution identities used to reconstruct the violating tracker state; it
does not depend on `LoopConvergenceEvidence`. Fingerprints remain bounded. The
marker does not rewrite the gate's original decision or erase findings. The
`loop_stall` event action is
`accept-with-residual-risks`. Workflows without a deterministic terminal
corridor still fail, and authored `onStall: "fail"` always fails even when a
corridor exists.

#### Reserved terminal steps

The step budget remains a hard total limit. Terminal reservation is part of the
synthesized default safety policy and applies only in the `default` state when
an unambiguous corridor exists. `declared`, `authored-inactive`, and `disabled`
requests retain their existing step-budget and routing behavior. Consequently,
both declaration-level disablement and `--disable-default-loop-guard` disable
reservation as well as default convergence enforcement; neither opt-out
disables or raises the existing hard `maxSteps` limit.

After recovery and ordinary routing have selected the current step, but before
that step consumes a `maxSteps` slot or is dispatched, the runner applies the
shared corridor selection contract with that current step as origin. If the
current step is already in the selected corridor, it proceeds and may consume
reserved capacity. Otherwise the runner reserves enough remaining capacity to
complete the corridor. The default reserve floor is three steps; when the
corridor is longer, its actual length is reserved. A non-terminal dispatch
that would consume the reserve is replaced by the corridor entry. The marker
is persisted with the corridor-entry inbound payload, carried unchanged
through the corridor, and merged into the final root output. A reserve
activation has its own marker shape because it may occur outside a gate while
the synthesized default state is active:

```json
{
  "loopGuardOutcome": {
    "decision": "accept-with-residual-risks",
    "trigger": "terminal-step-reserve",
    "policySource": "step-budget",
    "stepBudget": 20,
    "visitedSteps": 17,
    "reservedTerminalSteps": 3,
    "residualRisks": ["step budget reserved for terminal workflow stages"]
  }
}
```

Gate ids, finding fingerprints, and convergence violation kinds are omitted
for reserve activation; it does not fabricate a gate-convergence violation,
emit `loop_stall`, or extend the closed `LoopConvergenceViolationKind` enum.
Steps already in the selected corridor may use the reserve. If `maxSteps` is
smaller than the corridor itself, or no unambiguous corridor exists, existing
`maxStepsExceeded` failure behavior applies. This preserves the configured
hard limit while preventing an undeclared revision loop from consuming commit,
push, or output capacity. Authored policies never enter this reservation path.

#### CLI and cross-workflow propagation

`riela workflow run --disable-default-loop-guard` is a typed Boolean option
and appears beside `--max-steps` in help. The run request carries the opt-out
as execution context; it is not written into the workflow definition.

Live cross-workflow child requests inherit the parent's request-level
`maxSteps`, `maxLoopIterations`, and default-guard opt-out context alongside
`defaultTimeoutMs`. Each child receives the same per-session maximum; the
parent's already-consumed count is not subtracted. The child workflow's own
`loop.convergence` and `loop.budget` declarations always remain authoritative:
no authored budget or convergence declaration is copied from the parent or
replaced by request context.

#### Rollout and verification boundary

The first-party
`.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
declares an explicit `loop.convergence` policy so its behavior is reviewable
and independent of synthesized defaults. Tests pin default visit-cap and
fingerprint stalls, all four policy-resolution states and provenance, terminal
routing and residual-risk output, reserve exhaustion, non-gate reserve
activation under the default state, reservation absence for declared,
authored-inactive, and disabled states, a branch that converges on one terminal
suffix, an ambiguous
multi-sink branch that retains `maxStepsExceeded`, explicit-policy
preservation, both opt-outs, cross-workflow propagation, and the evidence
boundary: declared runs may project `LoopConvergenceEvidence`, while default
runs persist guard actions only through progress records and output markers.
CLI help and loop-engineering documentation state the exact defaults and the
limited scope of the opt-out.

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

- Authored metadata remains optional and existing workflows stay valid. An
  absent `loop` object now activates S9a defaults; an authored `loop` object
  preserves its declared behavior. `loop.convergence.enabled` is additive and
  defaults to `true`; `enabled: false` is the declaration-level opt-out.
- `LoopConvergenceEvidence` and the `LoopSessionSummary.workflowDefinitionDigest`
  field are additive with defaulted decoding; old snapshots decode.
- `WorkflowSessionFailureKind.loopNotConverging` and tolerant unknown-value
  decoding are already implemented. S9a adds no failure-kind value.
- `loop_stall` is already an additive JSONL record type. S9a adds optional
  provenance and the `accept-with-residual-risks` action string without adding
  an event-type case. The later LB3 concurrency record types remain additive;
  consumers ignore unknown record types and fields.
- `loop_baselines` and `loop_concurrency_leases` are new tables created by
  the existing migration pattern; their absence in old stores is handled by
  `CREATE TABLE IF NOT EXISTS` on writable opens, and read paths treat a
  missing table as "no baseline / no lease".
- `loop regress` exit codes apply only to the new command; `loop diff
  --baseline` adds a flag to an LA3 command without changing its defaults.
- No existing CLI command changes shape; all new surfaces are new
  subcommands or new flags.
- `--disable-default-loop-guard` and inherited child request fields are
  runtime-only context. They do not mutate workflow bundles or persisted
  authored policy. New event/output provenance fields are optional for
  decoding and ignored by older consumers.

## Phased Roadmap

Ordered by observed operational pain, then by dependency.

### LB1: Convergence guard (G10; authored baseline shipped, S9a pending)

The fingerprint helper, authored metadata and validation, runner tracker,
`loopNotConverging`, tolerant failure-kind decoding, `loop_stall` record, and
authored evidence section are implemented. The remaining single S9a work
package adds effective-policy resolution, synthesized defaults and provenance,
default-only terminal routing and reservation, both opt-outs, cross-workflow
request-context propagation, fixture adoption, tests, and documentation. It
has no dependency on an LA phase.

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
- **Terminal-corridor ambiguity.** Graphs with multiple reachable output
  sinks cannot be routed safely by inference. The runner fails with a
  diagnostic rather than choosing one, and tests cover unique, absent, and
  ambiguous corridors.
- **Step-budget contract drift.** Reserving capacity can end an undeclared
  workflow's revision work earlier than a caller expects. The hard `maxSteps`
  total remains unchanged, reserve activation is explicit in output evidence,
  and authored or opted-out workflows retain their existing routing and budget
  behavior.
- **Cross-workflow budget amplification.** Giving every child the parent's
  per-session `maxSteps` can multiply total work across nested calls. Existing
  dispatch-depth bounds remain in force, events identify parent and child
  sessions, and no parent-authored loop budget is copied into the child.

## Implementation Plan

`impl-plans/active/loop-engineering-convergence-and-operations.md` tracks the
S9a default-guard and terminal-preservation work. The completed historical
plan at `impl-plans/completed/loop-engineering-convergence-and-operations.md`
records LB1–LB4; LB5–LB6 remain roadmap material in this design.
