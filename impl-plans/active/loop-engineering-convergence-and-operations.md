# Loop Engineering Convergence And Operations Hardening Implementation Plan

**Status**: LB1 implemented, verification in progress
**Design Reference**: `design-docs/specs/design-loop-engineering-convergence-and-operations.md`
**Created**: 2026-07-08
**Last Updated**: 2026-07-10

---

## Design Document Reference

**Source**: `design-docs/specs/design-loop-engineering-convergence-and-operations.md`

### Summary

Add the control-and-feedback layer over the implemented loop primitives and
the LA observation roadmap: a deterministic convergence guard that stops
loops re-rejecting identical findings (observed 2026-07-08 incident), an
explicit accepted-baseline registry with a `loop regress` CI verdict, an
advisory concurrency lease preventing duplicate same-loop runs, best-effort
terminal-outcome notifications, trend/flakiness statistics, and an
evidence-fed retrospective template plus stats-fed self-improve rationale.

### Scope

**Current implementation pass (LB1)**:

- `LoopFindingFingerprint` shared identity helper (also the LA3 diff
  identity — one implementation).
- `loop.convergence` authored metadata (`maxGateVisits`,
  `maxRepeatedFindingRounds`, `onStall`) with validation.
- Shared `loopGate` payload parsing extracted from the evidence projector.
- Runner-owned `LoopConvergenceTracker`, stall enforcement at gate-visit
  boundaries, `WorkflowSessionFailureKind.loopNotConverging` with tolerant
  persisted decoding (coordinate with LA2 — whichever lands first builds
  it), `loop_stall` progress record.
- `LoopConvergenceEvidence` manifest section.
- Focused model, validation, runner, projector, and persistence tests.

**Explicit LB1 non-goals**:

- Baselines/regression (LB2), concurrency lease (LB3), notifications (LB4),
  trend/flakiness (LB5), retrospective template and `--loop-stats` (LB6).
  Modules for LB2–LB4 are specified below; LB5–LB6 are outlined and get
  module specs when their phase starts.

**Excluded** (tracked elsewhere):

- All LA1b–LA6 modules (`impl-plans/active/loop-engineering-application-gap-closure.md`).
- Workflow self-evolution versioning (first-line plan module 8).
- Cross-host locking, LLM-based finding similarity, auto-recovery on stall,
  chat-gateway notification channels, materialized stats tables.
- Running or validating workflows as part of this authoring step.

---

## Current LB1 Implementation Pass

This is the controlling plan for the next implementation step. Later module
sections are design-roadmap detail; implementers should not start LB2+ work
unless a later review explicitly expands scope.

### LB1 Task Breakdown

| Task | Deliverables | Write Scope | Dependencies | Parallelizable |
|------|--------------|-------------|--------------|----------------|
| LB1.1 Fingerprint + shared gate parsing | `LoopFindingFingerprint`, `loopGate` payload parsing extracted to a shared helper consumed by the projector | `Sources/RielaCore/LoopFindingFingerprint.swift`, `LoopEvidenceProjector.swift`, focused tests | Existing `LoopBlockingFinding`, projector parsing (`LoopEvidenceProjector.swift:129`) | Yes, with LB1.2 |
| LB1.2 Convergence metadata + validation | `LoopConvergenceDeclaration` on `WorkflowLoopMetadata`; raw + typed validation (positive bounds, at least one bound, `onStall` enum, `warn` invalid when `loop.required`) | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift`, tests | Existing loop metadata decoding | Yes, with LB1.1 |
| LB1.3 Tolerant failure-kind decoding | `WorkflowSessionFailureKind` tolerant persisted decoding preserving unknown raw values with a diagnostic; add `loopNotConverging` | `Sources/RielaCore/RuntimeSession.swift`, snapshot decode tests | None (coordinate with LA2: skip if LA2 already landed it, then only add the case) | Yes |
| LB1.4 Runner tracker + enforcement | `LoopConvergenceTracker`; feed at the gate-visit completion point (where completion payloads are already read for routing); fail/warn actions; `loop_stall` event (`WorkflowRunEventType` + live-persistence switch) | `Sources/RielaCore/LoopConvergenceTracker.swift`, `DeterministicWorkflowRunner*.swift`, `WorkflowRunEvent.swift`, runner tests | LB1.1, LB1.2, LB1.3 | No |
| LB1.5 Evidence section | `LoopConvergenceEvidence` on `LoopEvidenceManifest`; projector consumes tracker output at existing projection points; defaulted decoding | `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEvidenceProjector.swift`, tests | LB1.4 | No (shares projector file with LB1.1) |
| LB1.6 Verification pass | Focused suites then broader affected suites; progress log with exact commands | Tests and this plan's Progress Log only | LB1.1–LB1.5 | No |

### LB1 Dependencies

- Gate results parsed from accepted `loopGate` output payloads
  (`LoopEvidenceProjector.swift:110`); one result per gate-step execution.
- Completion payloads already inspected by the runner for routing
  (`LoopCompletionReviewRouting.swift`).
- Closed `WorkflowSessionFailureKind` (`RuntimeSession.swift:17`) and closed
  `WorkflowRunEventType` (`WorkflowRunEvent.swift:3`) — both changes are
  called out in migration notes.
- LA2 tolerant-decoding coordination: check the gap-closure plan status at
  implementation start; build or consume, never duplicate.

### LB1 Parallelization Rules

- LB1.1, LB1.2, LB1.3 have disjoint write scopes and can run in parallel
  (LB1.1 touches the projector only to extract parsing).
- LB1.4 serializes after all three; LB1.5 serializes after LB1.4 and shares
  the projector file with LB1.1's extraction.
- LB1.6 runs last.

### LB1 Verification Commands

- `swift test --filter LoopFindingFingerprintTests`
- `swift test --filter WorkflowLoopValidationTests`
- `swift test --filter LoopEngineeringModelsTests`
- `swift test --filter LoopConvergenceTrackerTests`
- `swift test --filter DeterministicWorkflowRunnerLoopPolicyTests`
- `swift test --filter LoopEvidenceProjectorTests`
- `swift test --filter SQLiteWorkflowMessageLogTests`
- `swift test`
- `swiftlint`

Record each command, exit status, and any intentionally skipped command in
the Progress Log before handoff.

### LB1 Completion Criteria

- A workflow declaring `loop.convergence` with `maxRepeatedFindingRounds: 2`
  fails with `loopNotConverging` on the second consecutive identical
  rejection round of the same gate; an intervening accepted/skipped visit or
  a changed fingerprint set resets the counter.
- `maxGateVisits` fails the session when any single gate step exceeds the
  bound regardless of finding identity.
- `onStall: "warn"` records a residual risk and continues; validation
  rejects `warn` when `loop.required == true`.
- The fingerprint prefers authored finding `id` (excluding synthesized
  `gate-policy-*` ids) and otherwise uses
  `(filePath ?? "", whitespace-normalized message)`; line and severity are
  excluded. The projector and tracker share one payload parser.
- `loop_stall` progress records appear in JSONL output and the
  live-persistence event switch handles the new type.
- Unknown persisted failure-kind raw values decode tolerantly with a
  diagnostic instead of failing the snapshot; `loopNotConverging`
  round-trips.
- Workflows without `loop.convergence` behave exactly as before; old
  snapshots decode.
- The plan Progress Log names completed tasks, verification commands, and
  any deviations from the accepted design.

## Modules

### 1. LB1 — Convergence Guard

#### `Sources/RielaCore/LoopFindingFingerprint.swift`

**Status**: DONE

```swift
public struct LoopFindingFingerprint: Hashable, Codable, Sendable {
  public var key: String

  public static func make(from finding: LoopBlockingFinding) -> LoopFindingFingerprint
  // authored id (not prefixed "gate-policy-") → id
  // else (filePath ?? "") + "\u{0}" + whitespace-collapsed trimmed message
}
```

**Checklist**:

- [x] Deterministic fingerprint per design S9 (id preference, synthesized-id
  exclusion, whitespace normalization, line/severity excluded).
- [x] Extract the projector's `loopGate` payload parsing
  (`gateResult(from:execution:stepGateIdsByStepId:)` and its helpers) into
  a shared internal helper both the projector and the tracker call.
- [x] Fixture tests: id preference, synthesized-id fallback, whitespace
  variants collapse equal, path-less findings, line drift ignored.
- [x] Note in doc comments that LA3 `LoopEvidenceDiffer` must consume this
  same identity when it lands.

#### `Sources/RielaCore/LoopEngineeringModels.swift` + `WorkflowLoopValidation.swift`

**Status**: DONE

```swift
public struct LoopConvergenceDeclaration: Codable, Equatable, Sendable {
  public var maxGateVisits: Int?
  public var maxRepeatedFindingRounds: Int?
  public var onStall: String   // "fail" | "warn", default "fail"
}
```

**Checklist**:

- [x] Optional `convergence` on `WorkflowLoopMetadata`; defaulted decoding.
- [x] Validation: positive values; at least one bound present; `onStall` in
  {fail, warn}; `warn` invalid when `loop.required == true`.
- [x] Raw validation accepts the new key; absent metadata keeps existing
  workflows valid (regression test).

#### `Sources/RielaCore/RuntimeSession.swift` (tolerant failure-kind decoding)

**Status**: DONE

**Checklist**:

- [x] Check LA2 status first: if tolerant decoding landed, only add
  `loopNotConverging`; otherwise build tolerant decoding here (unknown
  persisted raw values decode to a preserved `other(String)`-style
  representation with a diagnostic; encoding round-trips the original raw
  value) and note it in the LA2 plan.
- [x] Add `loopNotConverging` case.
- [x] Snapshot decode tests: unknown raw value survives, diagnostic
  emitted, whole-snapshot decode no longer fails; new case round-trips.
- [x] Document the old-binary limitation (same wording as LA2).

#### `Sources/RielaCore/LoopConvergenceTracker.swift` + runner integration

**Status**: DONE

```swift
public struct LoopConvergenceTracker: Sendable {
  public mutating func recordGateVisit(
    gateId: String,
    decision: LoopGateDecision,
    findings: [LoopBlockingFinding]
  ) -> LoopConvergenceCheck

  public struct LoopConvergenceCheck: Equatable, Sendable {
    public var gateVisits: Int
    public var repeatedRounds: Int
    public var violation: LoopConvergenceViolation?  // gateVisitsExceeded | repeatedFindingsStall
  }
}
```

**Checklist**:

- [x] Per-gate visit counts, last fingerprint set, consecutive
  identical-rejection round counter; accepted/skipped or changed set
  resets the counter; only `rejected`/`needs_work` visits count toward
  repeats.
- [x] Feed the tracker at the gate-step routing-reconciler seam
  (`workflowRoutingReconciler` in
  `DeterministicWorkflowRunner+LoopPolicy.swift:26`, which already fires
  once per gate visit with the completion payload), using the shared parser
  from LB1.1; enforcement decision taken before dispatching the next step.
- [x] `onStall == "fail"`: deterministic session failure with
  `loopNotConverging` and a diagnostic naming gate id, visit count,
  repeated rounds, bounded fingerprint listing; reuse existing
  cancellation paths (no orphaned agent processes).
- [x] `onStall == "warn"`: residual risk + diagnostic, run continues,
  counter keeps accumulating (warn fires once per gate, then diagnostics
  only — no warn spam loop).
- [x] `loop_stall` case on `WorkflowRunEventType` + live-persistence event
  switch update (additive JSONL contract change, in migration notes).
- [x] Runner tests: stall at exactly N rounds, reset on accepted visit,
  reset on changed findings, `maxGateVisits` backstop with mutating
  findings, warn mode, convergence-less workflows unaffected.

#### `Sources/RielaCore/LoopEvidenceManifest.swift` + `LoopEvidenceProjector.swift` (evidence)

**Status**: DONE

**Checklist**:

- [x] Optional `convergence: LoopConvergenceEvidence` (design S9 shape) on
  the manifest with defaulted decoding.
- [x] Projector consumes tracker output at the existing projection points
  (live and final persistence), same pattern LA2 specifies for the cost
  accumulator.
- [x] Legacy snapshots project `convergence: nil`; deterministic encoding
  tests.

### 2. LB2 — Baseline And Regression Verdict

#### `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (`loop_baselines`)

**Status**: NOT_STARTED

**Checklist**:

- [ ] `loop_baselines` table (workflow_id PK, session_id, set_at, note) via
  the existing migration pattern; `CREATE TABLE IF NOT EXISTS` on writable
  open; read paths treat a missing table as "no baseline".
- [ ] `setLoopBaseline` / `loadLoopBaseline` / `clearLoopBaseline`; writes
  only from explicit commands; reads stay read-only.

#### `Sources/RielaCore/LoopRegressionVerdict.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Classify regressions from a `LoopEvidenceDiff` per design S10:
  required-gate decision downgrade, `blockingFindingsAdded` on required
  gates, verification pass→fail flips.
- [ ] Pure function over two manifests + diff; exhaustive fixtures
  including empty diff and missing-gate cases.
- [ ] Cross-plan rule: consumes LA3's `LoopEvidenceDiffer`; if LA3 has not
  landed, implement the differ core here exactly per gap-closure S4 and
  mark the LA3 module COMPLETE_VIA_LB2 in that plan.

#### `Sources/RielaCLI/LoopBaselineCommands.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Parse and run `loop baseline set/show/clear` (set validates evidence
  + required-gate acceptance; `--force` recorded in note and diagnostics).
- [ ] Parse and run `loop regress <workflow> [--session <id>]`; target
  defaults to newest completed session with evidence via
  `loadSessionOverviews`; exit codes 0/3/4/1 pinned by contract tests.
- [ ] `loop diff --baseline <workflow> [--session <id>]` sugar.
- [ ] JSONL/JSON/text rendering; read paths never mutate snapshots.

### 3. LB3 — Concurrency Guard

#### `Sources/RielaCore/LoopEngineeringModels.swift` + `WorkflowLoopValidation.swift` (concurrency)

**Status**: NOT_STARTED

**Checklist**:

- [ ] Optional `concurrency` (`maxActive`, `onBusy`) on
  `WorkflowLoopMetadata`; validation: `maxActive == 1` in the MVP,
  `onBusy` in {fail, skip}.

#### `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (`loop_concurrency_leases`)

**Status**: NOT_STARTED

**Checklist**:

- [ ] Lease table per design S11; single-transaction acquire with
  staleness takeover (600 s default, shared with the `possiblyStale`
  threshold); heartbeat refreshed inside the existing single save-path
  helper for the lease-holding session; release at terminal persistence.
- [ ] Consistency regression: heartbeat and summary-column writes ride the
  same helper (extend the LA1a summary-consistency test pattern).

#### Run-entry preflight (`Sources/RielaCLI/WorkflowRunCommand.swift`, `EventLiveServe.swift`)

**Status**: NOT_STARTED

**Checklist**:

- [ ] Shared preflight helper invoked by `workflow run`, event-serve
  execution, and (when LA1b lands) `loop start`; applies only when
  `loop.concurrency` is declared; resume/rerun re-acquire under the same
  rules.
- [ ] `fail`: non-zero exit with typed `loop_concurrency_busy` record
  naming holder session id and last heartbeat; no session created.
- [ ] `skip`: exit 0 with `loop_concurrency_skipped` record; event-serve
  logs the skip on the event receipt.
- [ ] Advisory-guard limitations documented on the command surfaces.
- [ ] Tests: busy fail, busy skip, stale takeover with diagnostic, release
  on completion and failure, crash simulation (no release) expiring via
  staleness.

### 4. LB4 — Outcome Notifications

#### `Sources/RielaCore/LoopOutcomeNotification.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] `notifications` metadata (`on`, `channels`) + validation (known
  outcomes; webhook requires `urlEnv`; command requires non-empty argv).
- [ ] Outcome classification (accepted/rejected/stalled/failed) from
  terminal snapshot + manifest per design S12.
- [ ] Schema-versioned export-safe payload (ids, counts, decisions,
  timestamps only) with an encoding test asserting the absence of message,
  path, and variable content.

#### `Sources/RielaCLI/LoopNotificationDispatcher.swift`

**Status**: NOT_STARTED

**Checklist**:

- [ ] Dispatch after terminal persistence from the owning process (run
  command, event-serve); bounded timeout (5 s default), one retry,
  best-effort — never changes session outcome or command exit code.
- [ ] `webhook`: POST JSON, URL/bearer from named env vars (missing env →
  skipped with diagnostic); `command`: argv with payload on stdin,
  workflow-relative resolution, bounded output capture.
- [ ] Every attempt/delivery/skip/failure recorded as session diagnostics;
  nothing written into the evidence manifest.
- [ ] Package validation warns on `command` channels in packaged workflows.
- [ ] Tests: outcome mapping, env indirection, timeout, retry-once,
  dispatch failure leaves session outcome untouched.

---

## Later Phases (outline only — module specs written when the phase starts)

### LB5 — Trend And Flakiness

Additive `LoopWorkflowTrend`/`LoopGateFlakiness` fields on LA3's
`LoopWorkflowStats`; optional `workflowDefinitionDigest` on
`LoopSessionSummary` (frozen at projection time); `loop stats --trend`;
flakiness restricted to digest-matching runs. Depends on LA3.

### LB6 — Retrospective Template And Self-Improve Rationale

`examples/loop-retrospective/` (CLI-driven analysis → review gate →
`loop lesson add`), mock scenario + `EXPECTED_RESULTS.md`;
`workflow self-improve --loop-stats` context injection with the provided
inputs recorded in the change report. Depends on LA3 (stats) and LA5
(lesson write path).

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Fingerprint + shared parsing | `Sources/RielaCore/LoopFindingFingerprint.swift`, `LoopEvidenceProjector.swift` | DONE | focused tests passed |
| Convergence metadata + validation | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift` | DONE | focused tests passed |
| Tolerant failure-kind decoding | `Sources/RielaCore/RuntimeSession.swift` | DONE | focused tests passed |
| Convergence tracker + runner | `Sources/RielaCore/LoopConvergenceTracker.swift`, `DeterministicWorkflowRunner*.swift`, `WorkflowRunEvent.swift` | DONE | focused tests passed |
| Convergence evidence | `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEvidenceProjector.swift` | DONE | focused tests passed |
| Baseline table + API | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | NOT_STARTED | planned |
| Regression verdict core | `Sources/RielaCore/LoopRegressionVerdict.swift` | NOT_STARTED | planned |
| Baseline/regress CLI | `Sources/RielaCLI/LoopBaselineCommands.swift` | NOT_STARTED | planned |
| Concurrency metadata | `Sources/RielaCore/LoopEngineeringModels.swift`, `WorkflowLoopValidation.swift` | NOT_STARTED | planned |
| Lease table + save-path wiring | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | NOT_STARTED | planned |
| Run-entry preflight | `Sources/RielaCLI/WorkflowRunCommand.swift`, `EventLiveServe.swift` | NOT_STARTED | planned |
| Notification models | `Sources/RielaCore/LoopOutcomeNotification.swift` | NOT_STARTED | planned |
| Notification dispatcher | `Sources/RielaCLI/LoopNotificationDispatcher.swift` | NOT_STARTED | planned |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Fingerprint helper | `LoopBlockingFinding`, projector payload parsing | Available |
| Convergence tracker | Fingerprint, metadata, tolerant decoding, completion-payload routing point | This plan (LB1) |
| Tolerant failure-kind decoding | Coordination with LA2 (build-or-consume) | LA2 NOT_STARTED as of 2026-07-08 |
| Regression verdict | LA3 `LoopEvidenceDiffer` (or lands it per S4) | LA3 NOT_STARTED as of 2026-07-08 |
| Baseline/regress CLI | Baseline table, verdict core, `loadSessionOverviews` | LA1a shipped |
| Concurrency lease | LA1a save-path helper + staleness threshold | LA1a shipped |
| Run-entry preflight | Lease API; `EventLiveServe` execution path | Available |
| Notifications | Terminal persistence hooks; env-name secret convention | Available |
| LB5 trend/flakiness | LA3 stats | LA3 NOT_STARTED |
| LB6 retrospective/self-improve | LA3 stats, LA5 lessons | Not started |

## Dependency Ordering

1. LB1 fingerprint/metadata/tolerant-decoding in parallel; then tracker +
   runner; then evidence.
2. LB3 (only shipped dependencies) and LB2 (differ coordination) can start
   after LB1 in either order; LB2 first if LA3 has not started, so the
   differ lands once.
3. LB4 after LB1 (stalled outcome classification).
4. LB5 after LA3; LB6 after LA3 + LA5.

## Test Plan By Module

- Fingerprint: `swift test --filter LoopFindingFingerprintTests`.
- Metadata/validation: `swift test --filter WorkflowLoopValidationTests`,
  `LoopEngineeringModelsTests`.
- Tracker/runner: `swift test --filter LoopConvergenceTrackerTests`,
  `DeterministicWorkflowRunnerLoopPolicyTests`.
- Evidence: `swift test --filter LoopEvidenceProjectorTests`.
- Persistence (baselines, leases): SQLite store suites
  (`SQLiteWorkflowMessageLogTests` pattern).
- CLI (baseline/regress/preflight): `CommandParsingTests`,
  `WorkflowCommandTests`, `WorkflowCommandLivePersistenceTests`; `loop
  regress` exit codes pinned by contract tests.
- Notifications: dispatcher unit tests with a local test server / stub
  command.
- Final acceptance per phase: full `swift test` and `swiftlint`.

## Completion Criteria

- [x] LB1 completion criteria (above) all hold.
- [ ] `loop baseline set/show/clear` and `loop regress` behave per S10 with
  exit codes 0/3/4/1 pinned by contract tests; `loop diff --baseline`
  resolves the same pair.
- [ ] Declaring `loop.concurrency` prevents a duplicate run through the same
  store with `fail` and `skip` semantics; stale leases are taken over with
  a diagnostic; leases release on terminal persistence.
- [ ] Declared notification channels fire on terminal outcomes with
  export-safe payloads; dispatch failure never alters session outcome.
- [ ] All schema changes are additive; pre-existing snapshots, workflows,
  and stores decode and behave unchanged; new tables are created lazily on
  writable opens.
- [ ] Full `swift test` passes; `swiftlint` clean apart from pre-existing
  warnings.

## Migration And Backward-Compatibility Notes

- `loop.convergence`, `loop.concurrency`, `loop.notifications` are optional
  authored keys; raw validation accepts them; absent keys preserve current
  behavior.
- `WorkflowSessionFailureKind.loopNotConverging` requires tolerant persisted
  decoding, shared with LA2's `budgetExceeded`; whichever plan lands first
  implements it and the other consumes it. Old binaries cannot decode
  stalled sessions — accepted, documented limitation.
- `loop_stall` extends the closed `WorkflowRunEventType` enum (additive
  JSONL contract change; live-persistence switch updates with it).
  `loop_concurrency_busy`/`loop_concurrency_skipped` are CLI-emitted
  records, not runner events.
- `loop_baselines` and `loop_concurrency_leases` are new tables created via
  `CREATE TABLE IF NOT EXISTS` on writable opens; read paths treat missing
  tables as empty. Reads never write.
- `loop regress` exit codes apply only to the new command; no existing
  command changes shape.
- `LoopSessionSummary.workflowDefinitionDigest` (LB5) is additive with
  defaulted decoding.

## Progress Log

### Session: 2026-07-08 plan creation

**Tasks Completed**: Authored design
`design-loop-engineering-convergence-and-operations.md` (gaps G10–G15,
specifications S9–S14, phases LB1–LB6, numbering continued from the
gap-closure design) and this implementation plan with LB1 as the
controlling pass and LB2–LB4 module detail. Grounded against `main` on
2026-07-08: gate results are parsed from accepted `loopGate` payloads
(`LoopEvidenceProjector.swift:110`), the runner already inspects completion
payloads for routing (`LoopCompletionReviewRouting.swift`),
`WorkflowSessionFailureKind` (`RuntimeSession.swift:17`) and
`WorkflowRunEventType` (`WorkflowRunEvent.swift:3`) are closed enums,
event-triggered execution exists (`EventLiveServe.swift`), and the env-name
secret convention exists (`EventContracts.swift:341`). The motivating
incident is recorded in `design-incomplete-work-inventory.md` section 6.
**Tasks In Progress**: None; plan is in Planning status.
**Blockers**: None for LB1. LB2 differ work must check LA3 status at start;
LB1.3 tolerant decoding must check LA2 status at start (build-or-consume).
**Notes**: No workflows were run and no Swift sources were modified during
this authoring step.

### Session: 2026-07-10 LB1 implementation

**Tasks Completed**: Created branch `issue-39-loop-convergence-guard` and ran
`codex-design-and-implement-review-loop` through Riela for issue #39 intake
(`codex-design-and-implement-review-loop-session-1157`, intentionally stopped
at `--max-steps 2`). Implemented LB1 convergence metadata and validation,
shared `loopGate` payload parsing, `LoopFindingFingerprint`,
`LoopConvergenceTracker`, tolerant `WorkflowSessionFailureKind` raw decoding
with `loopNotConverging`, `loop_stall` workflow run events, live-persistence
event triggering, runner enforcement at gate publication boundaries, and a
minimal `LoopConvergenceEvidence` manifest section for non-converging
failures. Added focused tests for fingerprinting, convergence tracking,
metadata validation, tolerant failure-kind decoding, projector compatibility,
and runner fail/warn behavior.

**Verification**:

- `swift test --filter LoopFindingFingerprintTests` passed.
- `swift test --filter LoopConvergenceTrackerTests` passed.
- `swift test --filter WorkflowLoopValidationTests` passed.
- `swift test --filter RuntimeSessionTests` passed.
- `swift test --filter WorkflowRunnerLoopPolicyTests` passed.
- `swift test --filter LoopEvidenceProjectorTests` passed.
- `swift test --filter SQLiteWorkflowMessageLogTests` passed.
- `swift test --filter AutoActionTests` passed after the first full-suite
  run appeared to stop near that area.
- `swift test --filter CLIWorkflowSessionResolutionTests` passed after the
  second full-suite run stopped at
  `testLoadPersistedSessionPrefersProjectStoreWhenBothExist`.
- `swiftlint` exited 0; it reported existing warning-level findings plus a
  new synthesized-initializer warning that was fixed.

### Session: 2026-07-10 LB1 self-review

**Findings Fixed**: The initial implementation emitted `loop_stall` for warn
mode but did not project the required residual risk, could emit the same warn
on every subsequent identical gate visit, and projected only a minimal failure
summary instead of the S9 convergence evidence shape. It also preserved unknown
failure-kind values without adding the compatibility diagnostic to decoded
runtime snapshots, and left the LB1 module table/checklists stale.

**Improvements**: Project convergence state deterministically from gate
history, including per-gate visit counts, the first stall, action, bounded
fingerprints, and an accepted high residual risk for warn mode. Suppress repeat
stall events per gate while continuing to count rounds. Add skipped-reset,
single-warn, warn-evidence, residual-risk, and unknown-failure diagnostic tests;
update LB1 status to DONE.

**Verification**:

- Focused convergence, runner, evidence, and runtime-session suites passed (31
  tests, 0 failures).
- Full `swift test` passed (1,614 tests, 4 skipped, 0 failures).
- `swiftlint` exited 0 with 11 pre-existing warnings and no new violations.
- `git diff --check` passed.

### Session: 2026-07-10 LB1 Riela adversarial review

**Review Evidence**: Ran a one-node temporary Riela workflow using the
`codex-agent` backend and the packaged Step 7 adversarial-review contract.
Session `issue-39-lb1-adversarial-review-session-1` rejected the implementation
with three medium findings.

**Findings Fixed**:

- Preserve id-less blocking findings so `(filePath, message)` fallback
  fingerprints work instead of collapsing distinct findings to an empty set.
- Replay skipped gate executions as `.skipped` visits so they reset repeated
  rejection tracking in both runner enforcement and evidence projection.
- Apply required-gate acceptance policy in the shared parser before both
  convergence tracking and evidence projection, preventing raw\/projected gate
  disagreement.

**Regression Verification**: Added runner tests for changed id-less findings,
rejected → skipped → rejected, and policy-synthesized fingerprints, plus a
projector test for id-less findings. The focused runner and projector suites
passed (21 tests, 0 failures).

**Second Review Fix**: The first rerun confirmed the three findings above but
found one remaining medium edge case: role-only gate steps without explicit
`gateId` were omitted when skipped. The shared parser now tracks all gate step
ids and uses the step id as the same fallback key used by structured gate
payloads. Added runner and projector regression coverage for role-only skipped
gates. The focused runner and projector suites passed (23 tests, 0 failures),
and focused SwiftLint passed with zero violations.

**Final Review Result**: A third Riela adversarial-review run accepted commit
`151750c` with no high- or medium-severity findings. It confirmed the shared
parser behavior for id-less findings, explicit and role-only skipped visits,
and required-gate policy normalization. The reviewer retained two low risks:
role-only skipped replay is covered through parser/tracker/projector tests
rather than a dedicated async runner input-filter test, and ordinary CLI
thrown-run persistence still relies on the pre-existing live
event/finalization path.

- Final full `swift test` passed (1,620 tests, 4 skipped, 0 failures).
- Final `swiftlint lint --quiet` exited 0 with 11 pre-existing warnings and no
  new violations in the LB1 files.

**Tasks In Progress**: None for LB1. LB2-LB6 remain explicitly out of scope
for this pass.
**Blockers**: None.
**Notes**: The self-review pass fixed `loop_stall` emission to use the
runner's telemetry-aware event path, removed obsolete projector-local parser
helpers after extracting shared parsing, and corrected `maxGateVisits` to
fire only when the next visit exceeds the configured bound.

## Related Plans

- **Previous**: `impl-plans/active/loop-engineering-application-gap-closure.md`
  (LA1a implemented; LA1b+ pending — this plan's LB phases are additive to
  that roadmap and share the tolerant-decoding and differ modules).
- **Design**: `design-docs/specs/design-loop-engineering-convergence-and-operations.md`
- **Depends On**: `impl-plans/active/loop-engineering-first-line-tool.md`
  (module 8 self-evolution versioning, consumed by LB6 rationale flow),
  `design-docs/specs/design-riela-architecture-review.md` (summary-SQL and
  exit-code directions).
