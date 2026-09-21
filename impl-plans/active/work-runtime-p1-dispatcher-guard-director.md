# Work Runtime P1: Dispatcher, Guard, And Deterministic Director

**Status**: Implementing 2026-09-21  
**Workflow Mode**: issue-resolution  
**Design Reference**: `design-docs/specs/design-work-runtime-consolidation.md` sections 5-7, 10-13, 17  
**Created**: 2026-09-21  
**Riela Session**: `design-and-implement-review-loop-feature-plan-session-2`

## Goal

Make a stored `WorkTask` executable through one fenced attempt lifecycle,
replace the ad-hoc auto-improve driver with the deterministic director and
unified guard, and reject unavailable workflow backends before an attempt is
charged. Preserve P0 records and defer the P2-P7 folds.

## Accepted review findings

The Riela design loop found two blocking gaps, each repeated by its independent
self-review: the declared plan file did not exist, and the accepted design had
no durable P1 clarification. This plan and design section 17 close those gaps.
The workflow's read-only agent contract is intentional; repository mutations
are applied by the parent implementation session and reviewed on the next
loop pass.

## Scope boundaries

Included:

- atomic attempt/session reservation, one-live-attempt invariant, launch fence,
  explicit pre-launch recovery, and uncertain post-authorization handling;
- pure unified guard evaluation, typed violation evidence, total deterministic
  director, and one decision applier for policy and human decisions;
- local/worker backend capability model, declaration/probe merge, deterministic
  node and host placement, and placement evidence;
- `workflow validate --host`, strict-host diagnostics, usage backend
  requirements, `task run`, `task run --dry-run`, and `task decide`;
- deletion of workflow auto-improve flags, types, implementation, examples,
  and tests after equivalent dispatcher coverage exists;
- catalog, help, design status, examples, and package digest refresh required
  by those surfaces.

Deferred:

- P2 loop command/storage fold and self-improve proposals;
- P3 routine/specialist/event intake fold and long-lived `task serve`;
- P4 repository worktree adapter and Monja provider rewrite;
- P5 GraphQL, web, and desktop surfaces; P6 retrospective improvement; P7
  capability ceilings;
- migration or compatibility adapters for removed auto-improve state.

## Checklist

- [ ] P1-1 Store reservation and launch fencing
- [ ] P1-2 Unified guard and violation evidence
- [ ] P1-3 Deterministic director and decision applier
- [ ] P1-4 Backend capability probe, merge, and placement
- [ ] P1-5 Host-aware workflow validation and usage
- [ ] P1-6 `riela task run` and `riela task decide`
- [ ] P1-7 Remove workflow auto-improve and migrate its behavioral tests
- [ ] P1-8 Examples, surface parity, documentation, digests, and full verification

Check a box only after the progress log contains exact verification evidence.

## Work packages

### P1-1 Store reservation and launch fencing

Add launch metadata and the `work_leases` storage needed by the attempt fence.
Implement `reserveAttempt`, `authorizeAttemptLaunch`,
`markAttemptNodeStarted`, `recoverPreLaunchReservation`, and terminal
reconciliation on one SQLite connection. Reservation must atomically save the
`.created` `WorkflowRuntimePersistenceSnapshot`; no caller may launch before
the transaction returns. Tests cover racing reservations, stale task versions,
duplicate session identities, invalid tokens, pre/post-authorization crash
boundaries, and rollback injection.

### P1-2 Unified guard and violation evidence

Add `GuardViolation`, `BudgetDimension`, `GuardSnapshot`, and a pure
`WorkGuard.evaluate` in `RielaWork`. Lift inactivity semantics from
`monitorWorkflowStall`; keep heartbeat-ineligible backends exempt. Adapt runner
convergence and budget events into the snapshot rather than duplicating their
detectors. Persist each violation as `guardViolation` evidence before asking a
director. Tests pin boundary equality, multiple simultaneous violations,
cost aggregation, repeated-finding identity, and evidence causality.

### P1-3 Deterministic director and decision applier

Implement the ordered table in design sections 6 and 17 as a pure
`DeterministicDirector.decide(TaskView)`. Add a `DecisionApplier` whose legal
transition table is shared by policy and human decisions. An accept decision
must carry a satisfied completion verdict; otherwise it fails closed. Tests
cover every table row, precedence, remaining attempt budget, invalid terminal
transitions, optimistic conflicts, and idempotent decision replay.

### P1-4 Backend capability and placement

Add backend/host capability records, declaration/probe merge rules, freshness,
workflow backend requirements, backend-policy resolution, and deterministic
host selection. Probe only documented, bounded version/auth commands and make
the process seam injectable. Record chosen host/backend/source/freshness as
placement evidence. No placement produces `wait(.capacity)` without an
attempt. Tests cover declared disable precedence, declared-unverified enable,
model overrides, pins, authored preference order, worker group constraints,
stale probes, and unavailable requirements.

### P1-5 Host-aware authoring surfaces

Extend validation with `--host` and `--strict-host`; normal host gaps warn and
strict gaps fail. Extend workflow usage with stable backend requirements for
reachable nodes and add-on/environment requirements. Update the workflow skill
and planner input contract to document the capability snapshot. Tests cover
unreachable nodes, pins versus policies, absent/unauthenticated states, JSON
output stability, help, and surface enumeration.

### P1-6 Task mutation CLI

Add `task run <task-id> [--dry-run]` and `task decide <task-id>` with exactly
one of `--accept`, `--reject <reason>`, `--rerun [step]`, or `--cancel` and an
explicit human principal. Dry-run performs dependency and placement resolution
without writes. Run uses the existing workflow-definition/session-store
resolution and dispatcher; decide only invokes `DecisionApplier`. Tests cover
parsing, structured failures, scope resolution, dry-run non-mutation, session
linkage, Ctrl-C cancellation, and replay safety.

### P1-7 Auto-improve removal

Move its inactivity and bounded-retry expectations to dispatcher tests, then
delete `WorkflowRunCommand+AutoImprove.swift`, policy/mutation/supervision
state, flags, remote request fields, obsolete examples, and docs. A plain
`workflow run` remains unchanged and task-free. Grep gates prove no shipped
surface still advertises a removed option.

### P1-8 Closure

Add task-repair examples for accept, recovery, guard stop, and unavailable
backend wait. Reconcile `SurfaceCatalog`, README matrices, active-plan index,
design status, and package digests. Run strict SwiftLint, focused suites,
`swift test`, CLI mock scenarios, and the Riela design/implementation review
loop; move this plan to completed only with all evidence recorded.

## Progress log

- 2026-09-21 — Riela planning workflow validated and started. Its first live
  resumed turn exposed an invalid top-level `--sandbox` argument on
  `codex exec resume`; fixed and verified in commit `b412be2` before rerunning
  the same workflow lineage.
- 2026-09-21 — Riela review recorded four high findings collapsing to the two
  accepted gaps above. Design section 17 and this dependency-ordered plan were
  added for the next review pass. Implementation begins with P1-1 through
  P1-3 because placement and CLI mutation depend on that core.
- 2026-09-21 — P1-2/P1-3 domain slice started: added typed guard snapshots and
  violations, stable budget/convergence/inactivity evaluation, the ordered
  deterministic director table, `wait(.human)`, and a shared fail-closed
  `DecisionApplier`. `arch -arm64 /bin/zsh -lc 'swift test --filter
  RielaWorkTests'` passed 80 tests with zero failures. Strict SwiftLint on the
  eight touched Swift files passed with zero violations. The repository-wide
  lint command remains red on 58 pre-existing violations outside this slice;
  none is in the touched files. P1-2 and P1-3 stay open until persistence and
  dispatcher integration land.
