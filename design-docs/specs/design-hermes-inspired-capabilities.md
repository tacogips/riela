# Hermes-Inspired Capabilities Intake

## Summary

Hermes Agent (`NousResearch/hermes-agent`, first released February 2026) is an
open-source autonomous agent that grew from ~40k to ~188k GitHub stars between
April and June 2026. Its reception centers on a small set of differentiating
subsystems: a self-improving skill-learning loop, cross-session episodic
memory, a single multi-platform messaging gateway, first-class scheduled
automations, background fan-out subagents with git-worktree parallelism, and a
pluggable multi-backend terminal (local / Docker / SSH / Daytona / Modal /
Singularity).

This document does two things. First, it records the concrete, mechanism-level
findings of a fact-checked deep-research pass over Hermes (sources and
confidence in "Research Basis"). Second, it maps each Hermes capability onto
Riela's existing architecture and proposes a prioritized set of adoptions that
fit Riela's identity as a *deterministic, evidence-gated workflow orchestration
engine for coding agents* — not a general chat assistant. Where a Hermes
feature is a poor fit, this document says so and why.

No implementation is proposed here beyond design. The companion plan is
`impl-plans/active/hermes-inspired-capabilities.md`.

This is a review request: the adoption set (A–E), the declines (F–H), and the
priority ordering are the decisions to confirm before any plan work starts.

## Research Basis

A `deep-research` pass (5 search angles, 23 sources, 112 extracted claims, 25
adversarially verified with a 3-vote refute gate) produced 16 confirmed claims.
The synthesis and nine verification votes aborted on a Fable 5 rate limit, so a
minority of detail-level claims are recorded here as *reported (unverified)*
rather than confirmed. Treat cadence numbers ("every 15 tool calls", "5+ tool
calls") and platform-count specifics as indicative, not load-bearing.

Primary sources (all `3-0` confirmed unless noted):

- `github.com/NousResearch/hermes-agent` — README: the learning loop, the
  single-process gateway, subagents + RPC tool-scripting.
- `github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/architecture.md`
  — 20 platform adapters; jobs-as-agent-tasks (`jobs.json`); 6 terminal
  backends.
- `hermes-agent.nousresearch.com/docs/` — agent-curated memory with periodic
  nudges; FTS5 cross-session recall + LLM summarization + Honcho user model;
  6 terminal backends with Daytona/Modal serverless persistence.
- `github.com/NousResearch/hermes-agent-self-evolution` — DSPy + GEPA prompt
  evolution over execution traces, no GPU training; candidate acceptance gated
  by full test-suite pass, size limits (skills ≤15KB, tool descriptions ≤500
  chars), caching compatibility, semantic preservation.
- `github.com/NousResearch/hermes-agent/releases` — v0.17.0 background/async
  subagents and "Automation Blueprints" (scheduling without cron syntax);
  v0.18.0 `/learn` (distill reusable skills), `/journey` (learning timeline),
  `/goal` completion contracts (verify work against evidence), background
  fan-out for delegated tasks.

Reported (unverified — vote aborted, not refuted): skill files are markdown +
YAML frontmatter mirroring Claude Code's format; the loop is a four-phase
Execute → Evaluate → Extract → Retrieve cycle; a `hermes curator` command
consolidates/archives skills; episodic memory is a three-layer
`MEMORY.md`/`USER.md` + FTS5 + Honcho stack.

One skeptical finding is load-bearing for Riela's design and is confirmed by an
independent risk analysis (`blog.pebblous.ai`): Hermes's self-evaluation is
optimistic — the agent "always thinks it did a good job", so failed tasks can
be recorded as successes and learned from, degrading the skill store over time.
Any Riela adoption of the learning loop must not inherit this failure mode.

## Hermes Feature Inventory (concrete mechanisms)

1. **Self-improving skill loop.** After completing complex tasks the agent
   distills a reusable *skill* artifact, refines it on later use, and nudges
   itself to persist knowledge. A separate self-evolution project uses GEPA
   (Genetic-Pareto reflective prompt evolution) to read *execution traces*,
   diagnose *why* runs failed, and propose targeted textual mutations to
   skills/prompts/tool-descriptions/code — accepted only if the mutated variant
   passes the full test suite and size/caching/semantics gates (~$2–10/run).
2. **Episodic memory.** SQLite FTS5 full-text recall over past sessions + LLM
   summarization for cross-session recall; agent-curated memory files; optional
   Honcho "dialectic" user model. Notably *not* a vector database.
3. **Multi-platform gateway.** One long-running process, 20 adapters, unified
   session routing, authorization via allowlists + DM pairing, slash-command
   dispatch, a hook system, cron ticking, background maintenance.
4. **Scheduled automations ("Automation Blueprints").** Jobs are first-class
   agent tasks (not shell cron): persisted in `jobs.json`, human-friendly
   schedule formats (no cron syntax required), can attach skills/scripts as
   execution-time context, deliver results to any gateway platform, and update
   `next_run` after each run.
5. **Subagents + fan-out.** Isolated subagents for parallel workstreams;
   background fan-out for delegated tasks; git-worktree parallelism (a branch
   per file group, isolated edits, per-branch tests) — independently rated the
   strongest capability for migrations and large multi-file refactors.
6. **Multi-backend terminal.** Six interchangeable execution backends: local,
   Docker, SSH, Daytona, Modal, Singularity; Daytona and Modal add serverless
   persistence. Sandbox choice is a first-class configuration axis.
7. **`/goal` completion contracts.** The agent verifies its work against
   evidence before declaring a goal done.

## Gap Analysis vs Riela

Each row: Hermes mechanism → Riela's current state (with file evidence) →
verdict.

### 1. Self-improving skill loop → **PARTIAL; strongest strategic fit**

Riela already records the raw material Hermes's loop needs and already has the
gate Hermes lacks. `LoopEvidenceManifest` / `LoopGateResult`
(`Sources/RielaCore/LoopEvidenceManifest.swift`,
`LoopEngineeringModels.swift`) capture per-loop decisions, findings, severity,
and recovery lineage; `workflow run --auto-improve` and the `self-improve`
GraphQL mutation already exist; the package manager can version and distribute
workflow bundles. What is missing is exactly the item Riela's own roadmap flags
as `NOT_STARTED`: "Workflow Self-Evolution Versioning"
(`impl-plans/active/loop-engineering-first-line-tool.md` §8) — i.e. distilling
a reusable artifact from accumulated loop evidence and versioning it.

Critically, Riela's evidence gates are the antidote to Hermes's documented
data-quality risk: Riela can accept a learned artifact *only* against objective
gate evidence (tests green, no unresolved findings), never against agent
self-evaluation.

### 2. Episodic memory → **PARTIAL; good fit**

`RielaMemory` (`Packages/RielaMemory/`) is SQLite-backed with tags, related
records, and file references, plus persona/chat/file memory adapters
(`Sources/RielaCLI/ProductionNodeAdapter+{PersonaMemory,ChatMemory,MemoryAddonCore}.swift`).
But recall is **regex/`matchPatterns` matching**
(`RielaMemory.swift` compiles regexes over `payloadJSON`), not full-text; there
is no FTS index, no cross-run summarization, and no automatic aggregation of
learnings across sessions. `RuntimeSession` persistence is per-run.
`RielaNote` provides the curated-notes substrate. Hermes's FTS5 + summarization
recall is the missing capability.

### 3. Multi-platform gateway → **STRONG already; do not chase breadth**

Riela's Chat SDK event sources already cover Slack, Discord, Telegram, Teams,
GChat, GitHub, Linear, WhatsApp, Messenger, Web, plus Matrix and generic
webhook (`design-chat-sdk-event-sources.md`, `Sources/RielaCLI/EventLiveServe*`,
`Sources/RielaEvents/`), with a `riela/chat-reply-worker` add-on and an
`events serve` HTTP gateway. The gap vs Hermes is *ergonomics*, not coverage:
Riela's model is event-triggered workflow runs, whereas Hermes offers
allowlist + DM-pairing authorization and slash-command dispatch on a persistent
conversational session. Chasing 20 adapters (WeChat/Feishu/DingTalk/SMS/…) is
low ROI for a coding-agent orchestrator.

### 4. Scheduled automations → **PARTIAL; adapt, don't rebuild**

A cron event source exists with schedule expression, timezone, jitter, and
missed-run handling (`event-listener-workflow-trigger/provider-source-types.md`,
`DeterministicWorkflowRunner+Events.swift`), and `scheduled-workflow-execution`
shipped. Gaps vs Hermes's Blueprints: it is single-process, requires a raw
schedule expression (no human-friendly format), has no `riela schedule
list/add/remove` management CLI, and no notion of attaching reusable
context/skills to a recurring job.

### 5. Subagents / fan-out → **DATA MODEL EXISTS, RUNTIME MISSING; high fit**

Cross-workflow dispatch (`toWorkflowId` + `resumeStepId`) and `extends`
inheritance work (`WorkflowCalleeResolution.swift`,
`DeterministicWorkflowRunner+CrossWorkflow.swift`). The fan-out *data model* is
already defined — `WorkflowStepFanout`, `fanoutConcurrency`,
`WorkflowFanoutWriteOwnership`, failure/order policies
(`WorkflowModel.swift`) — but the **live runner rejects fan-out transitions**
as an error-severity capability gap (`design-incomplete-work-inventory.md` §1;
`WorkflowRuntimeCapabilityGap.swift`), and `run.maxConcurrency` is reserved but
unimplemented. Hermes's git-worktree parallelism (the single most-praised
coding capability) has no Riela equivalent. This is a squarely-scoped runtime
gap Riela already knows about.

### 6. Multi-backend terminal → **LOCAL-ONLY; medium-high fit**

`NodeExecutionBackend` enumerates CLI agents (`codex-agent`,
`claude-code-agent`, `cursor-cli-agent`) and official SDKs (OpenAI / Anthropic /
Gemini / Cursor); `NodeType.container` provides local podman/docker
containerization. There is **no SSH (remote) backend and no serverless /
ephemeral sandbox** (Modal/Daytona-style). The
`distributed-registry-container-node-roadmap` design anticipates this
direction. Hermes's 6-backend abstraction is the target shape.

### 7. `/goal` completion contracts → **PARTIAL; folds into A**

Riela's loop gates already model decision/severity/rerun policy over findings,
which is a stronger, evidence-based version of "verify against evidence". No
separate work is needed; the completion-contract framing is folded into the
learning-loop adoption (A) as the acceptance gate.

## Proposed Adoptions (prioritized)

Priority ordering weighs fit-to-Riela, leverage of existing subsystems, and
independent praise. Each item is a design direction; deliverables are in the
plan.

### A. Evidence-gated workflow self-evolution *(P0 — highest fit)*

Turn accumulated `LoopEvidenceManifest` traces into reusable, versioned
artifacts, accepted only through Riela's existing gates. Mechanism, mapped onto
Riela primitives:

- **Distill.** When a loop converges, a distillation step reads the loop's
  evidence manifest and proposes a reusable artifact — a prompt fragment, a
  node payload, or an extracted called-workflow — analogous to Hermes `/learn`.
- **Gate (the anti-regression guard).** A proposed artifact is accepted only if
  a verification run passes the same `LoopGateResult` criteria that governed the
  original loop (tests green, no unresolved findings) plus size limits
  (mirroring Hermes's ≤15KB skill / ≤500-char bounds). This is Riela's answer
  to Hermes's "agent always thinks it did well" data-quality risk: acceptance
  is objective, never self-reported.
- **Version + promote.** Accepted artifacts get lineage (which session/evidence
  produced them, parent version) and can be promoted into a workflow package
  via the existing package manager. This *is* the `NOT_STARTED` "Workflow
  Self-Evolution Versioning" (`loop-engineering-first-line-tool.md` §8), now
  specified.
- **GEPA-style trace reflection (optional, later).** A reflective step that
  reads *why* a loop failed (not just that it did) and proposes a targeted
  workflow/prompt mutation, still gate-accepted. Kept as a follow-on so the
  core distill→gate→version path can land first.

### B. Cross-session episodic memory with FTS recall + summarization *(P1)*

Extend `RielaMemory` from regex matching to full-text recall and add cross-run
aggregation:

- Add a **SQLite FTS5** index over memory records and (opt-in) session
  transcript/output text, exposed through the existing memory add-ons as a
  recall query — replacing/augmenting the current `matchPatterns` regex path.
- Add an **LLM summarization** step that condenses prior sessions for a
  workflow/project into a compact recallable digest (a `RielaNote`-backed
  curated memory file), refreshed by a runtime hook — Hermes's agent-curated
  memory with persistence nudges, but triggered deterministically by Riela's
  hook system rather than by an autonomous self-nudge.
- Deliberately **no vector DB** (matches Hermes and keeps the dependency
  surface small). User-model/persona learning stays out of scope initially.

### C. Remote & serverless execution backends *(P1)*

Add execution targets to `NodeExecutionBackend` / node execution beyond local:

- **SSH backend** — run a node's agent/command on a remote host over SSH.
- **Ephemeral serverless/remote sandbox** — a Modal/Daytona-style backend that
  provisions a throwaway environment per node, aligned with the
  `distributed-registry-container-node-roadmap`.
- Sandbox choice becomes a first-class per-node axis, as in Hermes. Backend
  selection must stay compatible with the existing container node type and
  env-isolation contract.

### D. Live fan-out subagents with git-worktree isolation *(P1 — most-praised coding capability)*

Implement the fan-out that Riela already models but cannot run:

- Make the **live runner execute `fanout` transitions** (remove the
  error-severity capability gap) and honor `run.maxConcurrency` /
  `fanoutConcurrency`.
- Add **git-worktree isolation** per fan-out branch (a worktree per parallel
  workstream, isolated edits, join on completion), honoring
  `WorkflowFanoutWriteOwnership` for conflict-free merges — the concrete form
  of Hermes's worktree parallelism, and a natural fit for coding workflows.
- Closes `design-incomplete-work-inventory.md` §1's top gap.

### E. Automation Blueprints + schedule management CLI *(P2 — adapt existing cron)*

Layer a Blueprint abstraction over the existing cron event source:

- A **named recurring workflow run** with a human-friendly schedule, attached
  default inputs and (optionally) an attached skill/context bundle, and a
  delivery target (reuse `chat-reply-worker`).
- A **`riela schedule list/add/remove/show`** management surface (the missing
  CLI), persisting blueprints alongside the scheduled event pool.
- Explicitly reuse the existing cron adapter, timezone/jitter/missed-run
  handling, and single-process scheduler; do not build a distributed
  scheduler.

## Explicitly Declined / Deferred

- **F. Multi-platform gateway breadth (20 adapters).** Declined. Riela already
  covers the platforms that matter for a coding-agent orchestrator; adding
  WeChat/Feishu/DingTalk/SMS/etc. is low ROI. *Optional small enhancement*
  (not in the P0–P2 plan): add allowlist + DM-pairing authorization and
  slash-command dispatch to existing chat event sources, since those are the
  genuinely useful gateway ergonomics Riela lacks.
- **G. RPC tool-scripting (Python scripts calling tools at zero context
  cost).** Declined. It is foreign to Riela's deterministic step model; the
  Riela-native equivalent is a `command` node or an add-on. No adoption.
- **H. Standalone DSPy/GEPA self-evolution service.** Deferred. The reflective
  trace-analysis *idea* is folded into adoption A as an optional later step; a
  separate prompt-evolution service/repo is out of scope.
- **Autonomous self-nudge / heartbeat.** Declined as an autonomous mechanism.
  Riela's persistence and summarization nudges (B) should fire from the
  deterministic hook/runtime layer, not from an agent nudging itself, to keep
  runs reproducible.

## Risks & Open Questions

- **Learned-artifact quality (A).** The gate is the whole defense against
  Hermes's degradation failure mode. Open question: should promotion require a
  human accept step, or is passing the loop gate + size bound sufficient for
  auto-promotion? Recommendation: gate auto-accepts into a session-local
  candidate store; package promotion stays human-confirmed initially.
- **FTS scope (B).** Indexing full session transcripts could be large and may
  contain secrets. Open question: index memory records only, or opt-in
  transcript text with redaction? Recommendation: memory records by default,
  transcript indexing opt-in per workflow.
- **Fan-out determinism (D).** Riela's core promise is deterministic replay.
  Fan-out ordering, worktree cleanup on failure, and merge-conflict handling
  must preserve reproducible evidence. `WorkflowFanoutResultOrder` already
  exists; the runner must enforce a stable order.
- **Remote backend security (C).** SSH/serverless backends widen the trust and
  credential surface; must reuse the existing container env-isolation contract
  and the seatbelt-sandbox design where applicable.
- **Research confidence.** Synthesis aborted on a rate limit; nine detail votes
  abstained. The seven capability *categories* are well-sourced from primary
  Hermes docs/releases; exact cadences and adapter counts are indicative only
  and should not drive interface decisions.
