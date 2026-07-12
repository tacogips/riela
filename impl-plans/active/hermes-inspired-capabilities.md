# Hermes-Inspired Capabilities Implementation Plan

**Status**: Planning; design approved pending adoption-set confirmation. No code
written. **Explicitly deferred pending a user/product decision** (owner: the
user; trigger: confirmation of the H-A…H-E adoption set — this is a genuine
product decision, not an engineering blocker to unrelated work). Note
(2026-07-12 correction): workflow self-evolution versioning is no longer
"NOT_STARTED" — Section 8 of `loop-engineering-first-line-tool` is implemented
and accepted (plan now in `impl-plans/completed/`); Phase H-A should build on
that landed substrate rather than treating it as green-field.
**Design Reference**: `design-docs/specs/design-hermes-inspired-capabilities.md`
**Workflow Mode**: feature-intake
**Issue Reference**: #38 (tracking); #40 (H-A), #41 (H-B), #42 (H-C), #43 (H-D), #44 (H-E)
**Created**: 2026-07-08
**Last Updated**: 2026-07-08

## Summary

Port the differentiating, well-reviewed capabilities of Hermes Agent
(`NousResearch/hermes-agent`) into Riela, adapted to Riela's deterministic,
evidence-gated, coding-agent orchestration model. Five adoptions are planned
(A–E); three Hermes features are explicitly declined/deferred (F–H). See the
design doc for mechanism-level rationale and the gap analysis that justifies
each scope. This plan enumerates deliverables and interfaces only — no code.

## Source References

- Design: `design-docs/specs/design-hermes-inspired-capabilities.md`
- Existing gap the plan closes: `design-docs/specs/design-incomplete-work-inventory.md` §1 (fan-out), §2 (self-evolution versioning)
- Loop evidence substrate: `Sources/RielaCore/LoopEvidenceManifest.swift`, `LoopEngineeringModels.swift`, `LoopGateResult`
- Self-evolution substrate (implemented + accepted): `impl-plans/completed/loop-engineering-first-line-tool.md` §8
- Memory substrate: `Packages/RielaMemory/Sources/RielaMemory/{RielaMemory,MemoryModels}.swift`; `Sources/RielaCLI/ProductionNodeAdapter+{PersonaMemory,ChatMemory,MemoryAddonCore}.swift`
- Fan-out data model: `Sources/RielaCore/WorkflowModel.swift` (`WorkflowStepFanout`, `fanoutConcurrency`, `WorkflowFanoutWriteOwnership`, `WorkflowFanoutResultOrder`, `WorkflowFanoutFailurePolicy`); `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
- Backend enum: `Sources/RielaCore/WorkflowModel.swift` (`NodeExecutionBackend`, `NodeType.container`); `design-docs/specs/design-distributed-registry-container-node-roadmap.md`; `design-riela-seatbelt-sandbox.md`
- Scheduling: `design-docs/specs/design-event-listener-workflow-trigger.md`; `impl-plans/completed/scheduled-workflow-execution.md`; `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`

## Scope

**Included:** A. evidence-gated workflow self-evolution (P0); B. cross-session
episodic memory with FTS recall + summarization (P1); C. remote/serverless
execution backends (P1); D. live fan-out with git-worktree isolation (P1);
E. Automation Blueprints + schedule CLI (P2).

**Excluded:** F. 20-adapter gateway breadth (optional allowlist/DM-pairing/
slash-command ergonomics tracked separately, not here); G. RPC tool-scripting;
H. standalone DSPy/GEPA evolution service; autonomous self-nudge/heartbeat;
persona/user-model learning; vector-DB memory.

## Priority & Dependencies

| Phase | Adoption | Priority | Depends On |
| ----- | -------- | -------- | ---------- |
| H-A | Evidence-gated self-evolution | P0 | Existing loop evidence + gates + package manager |
| H-B | Episodic memory (FTS + summarization) | P1 | RielaMemory, RielaNote, hook system |
| H-C | Remote/serverless backends | P1 | NodeExecutionBackend, container env-isolation, seatbelt sandbox |
| H-D | Live fan-out + worktree isolation | P1 | Fan-out data model, capability-gap validator |
| H-E | Automation Blueprints + CLI | P2 | Cron event source, chat-reply-worker |

H-A, H-C, H-D are independent and can proceed concurrently. H-B is independent.
H-E depends only on the existing cron source. No phase blocks another.

## Deliverables

### Phase H-A — Evidence-gated workflow self-evolution (P0)

Builds on the implemented-and-accepted "Workflow Self-Evolution Versioning"
(`impl-plans/completed/loop-engineering-first-line-tool.md` §8).

- **A1. Distillation step.** A runner capability that, on loop convergence,
  reads the `LoopEvidenceManifest` and emits a candidate reusable artifact
  (prompt fragment | node payload | extracted called-workflow). Define the
  candidate model (`LearnedArtifact`: kind, body, source session id, source
  evidence ref, size).
- **A2. Acceptance gate.** Reuse `LoopGateResult` criteria to verify a candidate
  (verification run: tests green, no unresolved findings) and enforce size
  bounds (skill/body ≤ configurable limit, default mirroring Hermes ≤15KB).
  Acceptance MUST be gate-evidence-based, never agent self-report (design doc
  risk note).
- **A3. Versioned candidate store.** Persist accepted artifacts with lineage
  (parent version, producing session/evidence) in a session-local candidate
  store; expose via a `learned` query surface.
- **A4. Package promotion path.** A command/mutation to promote an accepted
  candidate into a workflow package via the existing package manager. Default
  human-confirmed (see open question in design doc).
- **A5. GraphQL + CLI surface.** `learned list/show`, `learned promote`; extend
  the `self-improve` contract to reference produced artifacts.
- **A6. (Follow-on, optional) GEPA-style trace reflection.** A step that
  diagnoses *why* a loop failed and proposes a targeted mutation, still
  gate-accepted. Land after A1–A5.

### Phase H-B — Cross-session episodic memory (P1)

- **B1. FTS5 recall.** Add a SQLite FTS5 index over `RielaMemory` records;
  add an FTS recall query alongside the existing `matchPatterns` path in
  `RielaMemory.swift`. Keep regex path for back-compat.
- **B2. Session-text indexing (opt-in).** Optional per-workflow indexing of
  session transcript/output text with redaction; default off (secrets risk).
- **B3. Cross-run summarization.** A summarization step that condenses prior
  sessions for a workflow/project into a curated digest stored as a
  `RielaNote`; refreshed via a runtime hook (deterministic trigger, not
  self-nudge).
- **B4. Recall injection.** Surface the digest + top FTS hits into agent node
  context through the existing memory add-ons.
- **B5. CLI/GraphQL.** `memory recall <query>` and digest inspection.

### Phase H-C — Remote & serverless execution backends (P1)

- **C1. SSH backend.** Add `ssh` execution target: run a node's agent/command
  on a remote host; config (host, credentials ref, working dir). Reuse the
  container env-isolation contract for env/secret handling.
- **C2. Ephemeral serverless sandbox.** Add a Modal/Daytona-style backend that
  provisions a throwaway environment per node; align with
  `distributed-registry-container-node-roadmap`.
- **C3. Backend selection axis.** Extend `NodeExecutionBackend` (or a parallel
  sandbox axis) so backend is first-class per node, compatible with existing
  CLI/SDK backends and `NodeType.container`.
- **C4. Validation + security.** Capability-gap diagnostics for unsupported
  backend combos; apply seatbelt-sandbox constraints where applicable.

### Phase H-D — Live fan-out with git-worktree isolation (P1)

Closes `design-incomplete-work-inventory.md` §1.

- **D1. Live fan-out execution.** Make the runner execute `fanout` transitions;
  remove the error-severity gap in `WorkflowRuntimeCapabilityGap.swift`; honor
  `fanoutConcurrency` / `run.maxConcurrency`.
- **D2. Git-worktree isolation.** Provision a git worktree per fan-out branch,
  isolate edits, join on completion; honor `WorkflowFanoutWriteOwnership` for
  conflict-free merges.
- **D3. Deterministic join.** Enforce `WorkflowFanoutResultOrder` for stable,
  replayable evidence; define worktree cleanup on success/failure.
- **D4. Failure policy.** Wire `WorkflowFanoutFailurePolicy` into the runner.
- **D5. Validation + example.** Turn the mock-only fan-out example into a
  live-runnable example with `EXPECTED_RESULTS.md`.

### Phase H-E — Automation Blueprints + schedule CLI (P2)

- **E1. Blueprint model.** A named recurring workflow run: human-friendly
  schedule, attached default inputs + optional context/skill bundle, delivery
  target (reuse `chat-reply-worker`). Persist alongside the scheduled event
  pool.
- **E2. Schedule management CLI.** `riela schedule list/add/remove/show` — the
  missing management surface over the existing cron source.
- **E3. Human-friendly schedule parsing.** Accept plain formats (e.g. "every
  weekday at 9am") in addition to raw cron/schedule expressions.
- **E4. Reuse.** Explicitly reuse the existing cron adapter, timezone/jitter/
  missed-run handling, and single-process scheduler; no distributed scheduler.

## Tests

- H-A: distillation from a fixture evidence manifest; gate rejects a candidate
  when the verification run has unresolved findings or exceeds size bound;
  lineage/versioning round-trip; promotion path.
- H-B: FTS recall returns expected records; summarization digest round-trip;
  opt-in transcript indexing respects redaction; regex path unchanged.
- H-C: SSH backend executes a command node against a local sshd fixture;
  serverless backend provisions/tears down; capability-gap diagnostics for
  invalid combos.
- H-D: live fan-out executes N branches under concurrency cap; worktree
  isolation prevents cross-branch writes; deterministic join order; cleanup on
  failure; the converted example passes `EXPECTED_RESULTS.md`.
- H-E: `schedule add/list/remove` round-trip; human-friendly schedule parses to
  the same next-run as the equivalent expression; blueprint fires and delivers.

## Verification Commands

To be filled per phase during implementation (each phase: focused suite +
`swift build -c release` + relevant example run). No live-API-gated test is a
completion blocker (see `design-incomplete-work-inventory.md` §5).

## Open Questions

Carried from the design doc: (A) auto-promote vs human-confirm on gate pass;
(B) memory-records-only vs opt-in transcript indexing; (D) worktree cleanup and
merge-conflict semantics under deterministic replay; (C) trust/credential
surface for remote backends. Resolve before the corresponding phase starts.
