# Riela as a First-Line Loop Engineering Tool

## Problem Statement

Riela already has many ingredients of an engineering-loop runtime: authored
workflows, Codex/agent worker nodes, session persistence, JSONL progress
records, rerun and resume entrypoints, package and event-source surfaces,
GraphQL manager controls, implementation-plan conventions, and auto-improve
scaffolding.

It is not yet a first-line loop engineering tool because the operator still has
to stitch these pieces together manually. Important engineering facts are
spread across prompts, stdout, session snapshots, markdown plans, temporary
artifacts, and human convention. A first-line tool needs one auditable loop
contract: what work is allowed, what evidence proves it happened, which gates
accepted or rejected it, how recovery works, and what risks remain.

Loop engineering means deliberately designing, running, observing, repairing,
and reusing repeated plan/work/review/fix cycles over a codebase or operational
system. The unit is not one prompt or one agent session. The unit is a bounded
workflow loop with typed inputs, explicit gates, durable evidence, resumable
state, scoped mutation, and lessons that can improve future workflows, prompts,
or implementation plans.

## Current-State Evidence

This design is based on the two debate artifacts:

- `tmp/loop-engineering-discussion/llm-a-product-architect.json`
- `tmp/loop-engineering-discussion/llm-b-systems-architect.json`

Both artifacts were present and parsed as JSON objects. LLM A argued from the
product/workflow-experience side. LLM B argued from runtime systems,
reliability, evidence, scoped mutation, and portability.

Repository evidence inspected for arbitration:

- `git status --short --branch` showed the work is on
  `design/loop-engineering-discussion`, with untracked target workflow and
  design-doc paths preserved.
- `.riela/workflows/loop-engineering-first-line-design/workflow.json` defines
  a step-addressed project workflow with LLM A, LLM B, arbitrator, and
  workflow-output steps. `workflow-output` reuses the arbitrator session and
  `defaults.maxLoopIterations` is `1`.
- `.riela/workflows/loop-engineering-first-line-design/nodes/*.json` use
  `executionBackend: "codex-agent"` and `model: "gpt-5.5"`.
- `.riela/workflows/loop-engineering-first-line-design/prompts/*.md` instruct
  LLM A and LLM B to write intermediate artifacts under
  `tmp/loop-engineering-discussion/`, and prohibit nested Riela workflow runs
  and nested Codex agent processes.
- `README.md` positions Riela around Swift-owned workflow execution, runtime
  records, session inspection, packages, event sources, hooks,
  GraphQL/server controls, `workflow run --auto-improve`, `workflow
  self-improve`, and JSONL progress events.
- `Sources/RielaCore/DeterministicWorkflowRunner.swift` includes bounded run
  controls such as `maxLoopIterations`, `maxSteps`, `resumeSessionId`,
  `rerunFromSessionId`, `rerunFromStepId`, and a workflow run event handler.
- `Sources/RielaCore/RuntimeSession.swift` and `Sources/RielaCore/RuntimeStore.swift`
  record sessions, step executions, accepted outputs, adapter metadata, failure
  reasons, workflow messages, and artifact refs.
- `Sources/RielaCore/RuntimePublication.swift` validates candidate outputs,
  records accepted outputs, and fails closed when output validation is rejected.
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` persists
  session snapshots, root output, diagnostics, and workflow messages, but does
  not expose a normalized loop evidence, gate, policy, command, or changed-file
  record model.
- `Sources/RielaCLI/SessionCommands.swift` implements status, health, logs,
  step-runs, rerun, and resume surfaces. These are useful recovery primitives
  but are not yet presented as a cohesive loop UX.
- `Sources/RielaGraphQL/GraphQLContracts.swift` exposes session, step
  execution, communication, continue-session, manager-message, replay, and
  retry contracts. It does not yet expose loop evidence or gate DTOs.
- `design-docs/specs/design-workflow-usage-discovery.md` defines a workflow
  usage surface for callable input/output contracts and compact workflow
  selection. It is the right entrypoint to extend with loop policy and evidence.
- `design-docs/specs/design-workflow-json.md` documents step-addressed
  workflows, output contracts, validation, loops, cross-workflow transitions,
  human input, and node output behavior.
- `examples/README.md` shows mature examples for workflow calls, review gates,
  event sources, mock scenarios, and expected outputs. It also documents loops
  that delegate to design/implementation workflows and rerun review until no
  blocking findings remain.
- `.riela/workflows/codex-design-and-implement-review-loop/EXPECTED_RESULTS.md`
  shows the repository already values deterministic expected results for complex
  first-party workflows.
- `impl-plans/README.md` shows an established implementation-plan culture with
  active/completed plan indexes and design references, but those plans are not
  yet runtime-owned loop artifacts.

Verification note: this arbitration intentionally did not run `riela workflow
run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or
`codex exec`, because the arbitrator prompt prohibited those commands. Workflow
validity and execution claims here are therefore inspection-based unless they
come from prior artifacts.

## Arbitrated Decisions

### 1. Productize loops, but only on top of evidence

Accept LLM A's thesis that Riela should become the default place engineers
start repeated plan/work/review/fix loops. Modify it with LLM B's constraint:
the product surface must not be a cosmetic alias. A loop is first-line only when
it creates evidence, declares mutation authority, records gates, and supports
auditable recovery.

Decision: add a `riela loop` UX only after loop contract and evidence-manifest
MVPs exist.

### 2. Keep workflows as the runtime model

Both LLMs reject a new orchestration engine. Existing workflow/session/message
primitives are strong enough. The missing layer is a loop contract and evidence
surface.

Decision: implement loop engineering as workflow metadata, runtime records,
session/GraphQL projections, CLI aliases, and package promotion rules.

### 3. Extend `workflow usage` into loop discovery

LLM A correctly emphasizes discoverability. LLM B correctly warns that agents
must not infer safety from prose or raw `workflow.json`.

Decision: extend `workflow usage` with loop kind, input/output contract,
mutation policy, scratch policy, process policy, gates, recovery points,
evidence expectations, verification requirements, and mock-scenario support.

### 4. Make evidence manifests runtime-owned

The most important systems decision is to create one durable manifest per loop
session. This converts scattered artifacts into an auditable engineering record.

Decision: add a `LoopEvidenceManifest` model persisted by the runtime and
projected through CLI and GraphQL.

### 5. Model gates explicitly

Review gates are currently mostly prompt conventions or workflow-specific
output fields. That is flexible, but not enough for first-line engineering.

Decision: represent gates as step metadata plus required output fields:
decision, severity counts, evidence refs, rerun policy, blocking findings, and
residual risks. Avoid a hard-coded workflow-type enum.

### 6. Link implementation plans without replacing markdown

LLM A is right that `impl-plans/` is part of Riela's engineering culture. LLM B
is right that markdown-only conventions cannot become runtime guarantees.

Decision: keep plan bodies in repository markdown, but add stable plan refs,
status, linked session ids, verification refs, and stale/completion checks to
the evidence manifest and workflow output contracts.

### 7. Make durable learning distilled, scoped, and revocable

Riela should learn from successful and failed loops, but raw transcripts are not
safe memory.

Decision: store only distilled lessons with source session, scope, expiry,
confidence, redaction status, and invalidation triggers. Do not store raw
prompts, stdout, stderr, or model responses as memory by default.

### 8. Treat nested workflows and nested agents as opt-in

Nested delegation can be useful, but it hides cost, auth, mutation, and failure
boundaries when used casually.

Decision: first-line loops should prefer visible step graphs and explicit
cross-workflow transitions. Nested Riela or Codex process starts must be
declared, policy-allowed, and recorded in evidence.

## Target User Workflows

### Design and Implement

An engineer chooses a design/implement/review loop from `workflow usage`,
passes an objective and constraints, watches plan, implementation, review, fix,
and verification stages, and receives final output with decisions, changed
files, verification, rejected alternatives, and residual risks.

### Review and Harden

An engineer points Riela at a branch, diff, or recent change. Riela runs
security, reliability, portability, or compatibility review gates, produces
file/line findings, fixes approved issues, and preserves unrelated dirty
worktree changes.

### Recover a Failed Loop

An engineer inspects `loop status`, sees the failed gate and evidence, reruns
from a specific step or resumes a paused session, and retains source-session
history instead of losing the original trace.

### Package a Proven Loop

An engineer promotes a project workflow into a reusable package only after it
has usage metadata, input/output schemas, policy metadata, mock scenarios,
expected results, and package integrity checks.

### Operate Event-Driven Loops

An engineer binds events to workflows, inspects receipts, sessions,
communications, replies, retries, and memory writes, and uses GraphQL manager
controls for remote operation.

### Improve the Loop Itself

An engineer runs a workflow self-improve or retrospective loop that proposes
prompt/workflow/plan updates, records incidents and rejected alternatives, and
requires review before mutating durable project workflows.

### Restore a Workflow Version

An engineer sees that a self-improve or in-place auto-improve changed a
workflow badly. Riela shows the prior bundle snapshot, the applied change-set,
validation status, package provenance, and dependent skills. The engineer
restores the previous version without touching unrelated project files or
unrelated workflow packages.

## Capability Changes

Riela should add or harden these capabilities:

- Loop contract metadata for `loopKind`, callable input/output, evidence
  requirements, gates, recovery points, mutation policy, process policy,
  verification expectations, mock support, and package-promotion readiness.
- Runtime-owned `LoopEvidenceManifest` records linking workflow definition
  digest, workflow source, session id, variables digest, branch, base commit,
  dirty worktree summary, step evidence, gate results, artifact refs, changed
  files, verification commands, implementation-plan refs, and residual risks.
- Structured gate results in core/session/GraphQL DTOs.
- Step-level recovery history with source session id, source step id, entry
  mode, input reuse policy, and rerun/resume lineage.
- Policy metadata and adapter/runtime enforcement for allowed write paths,
  scratch root, commit/push permission, nested workflow permission, nested
  agent permission, network policy, and secret policy.
- First-party loop templates for design/implement/review, secure review,
  regression fix, package release, event-source verification, and
  workflow-self-improvement.
- Package promotion checks requiring usage contracts, mock scenarios, expected
  results, policy declarations, and output contracts.
- Distilled loop memory with provenance, redaction, scope, expiry, confidence,
  and invalidation.
- Workflow self-evolution as a reviewed change-set lifecycle, not an immediate
  source mutation: propose, snapshot, validate, review, apply, verify, and
  optionally restore.
- Bundle-wide workflow version records for mutable project/user workflows,
  separate from package metadata versions and execution session ids.

## Runtime, Workflow, and Agent UX Changes

### Runtime

- Persist loop evidence as normalized runtime data, not only session JSON or
  stdout.
- Add `LoopGateResult` and `LoopEvidenceManifest` projections to CLI and
  GraphQL.
- Record source-session links for rerun and resume, including input reuse
  semantics.
- Fail closed when required gate/output contracts are missing or invalid.
- Track workflow definition digest and reviewed-tree metadata for integrity.
- Treat workflow self-improvement as an auditable mutation transaction with a
  bundle snapshot, proposed patch, validation evidence, reviewer decision,
  apply result, and rollback metadata.
- Distinguish `workflowDefinitionDigest`, `workflowContractVersion`,
  `workflowSourceVersion`, and package `version`; do not use package metadata
  version as a substitute for workflow behavior versioning.

### Workflow Authoring

- Extend workflow and node payload schemas with loop metadata and policy
  fields.
- Require promoted first-party loops to include `EXPECTED_RESULTS.md` and
  deterministic mock scenarios.
- Prefer visible step graphs over hidden recursive dispatch.
- Keep prompt files workflow-relative and avoid host-absolute paths in portable
  workflows.
- Make final workflow outputs include decisions, roadmap, changed files,
  verification, rejected alternatives, and residual risks.
- Add optional authored `workflow.version` or `workflow.contractVersion` only
  for compatibility promises. Runtime source history should still be based on
  bundle digests and immutable snapshots, because many valid workflow changes
  are local and unreleased.

### Agent UX

- Inject runtime policy into agent prompts from workflow metadata rather than
  relying on every prompt author to repeat safety instructions manually.
- Display mutation, network, secret, commit/push, and nested-process policy
  before starting a loop.
- Show evidence as stages, decisions, artifacts, commands, changed files, and
  risks instead of only a raw execution graph.
- Add `riela loop start/status/evidence/rerun-step/promote` as thin,
  discoverable wrappers over workflow/session/package primitives after the
  evidence contract exists.

## Self-Evolution and Workflow Versioning

Current review found a gap between the self-improve product goal and the
mutation safety model. `workflow self-improve` has an explicit approval gate and
creates a backup/report, but the current shape is closer to a local patch
helper than durable workflow version management. The better model is:

- `workflow self-improve --dry-run` produces a `WorkflowChangeSet` only.
- `workflow self-improve --yes` first captures a bundle-wide snapshot, then
  applies a reviewed change-set atomically.
- A snapshot includes `workflow.json`, node files, prompts, nested workflow
  directories owned by the bundle, mock scenarios, expected results, package
  metadata when present, and a file manifest with digests and executable bits.
- A change-set records proposed file edits, rationale, source session id,
  reviewer gate, validation commands, expected-result updates, and rejected
  alternatives.
- Restore is a first-class operation that applies a snapshot back to the bundle
  root only after checking ownership, destination containment, dirty-file
  conflicts, and package mutability.

Version records should live outside ordinary scratch output:

```text
.riela/workflow-history/
  <workflow-id>/
    snapshots/<snapshot-id>/manifest.json
    snapshots/<snapshot-id>/bundle/
    changesets/<change-id>.json
    restores/<restore-id>.json
```

The history store is not a replacement for Git. It is a local safety layer for
Riela-managed workflow mutation. Git remains the durable repository history,
while Riela history explains which workflow session proposed a change, which
gate accepted it, what was applied, and how to restore it without guessing.

Required CLI surface:

- `riela workflow versions <workflow>` lists snapshots and applied change-sets.
- `riela workflow version show <workflow> <snapshot-id>` prints provenance,
  digests, validation, and restore safety.
- `riela workflow version diff <workflow> <from> <to>` shows bundle-level
  changes without reading raw secrets.
- `riela workflow restore <workflow> <snapshot-id> [--yes]` restores a
  snapshot with the same containment and dirty-worktree protections used by
  checkout/install mutation paths.
- `riela loop evidence <session-id>` links to workflow change-set ids and
  snapshot ids when a loop mutates workflow definitions.

Package semantics:

- Package `version` remains package metadata and distribution identity.
- Package `checksum` and integrity fields identify a published package payload.
- Workflow contract version identifies compatibility of callable input/output,
  loop policy, gate contracts, and evidence schema expectations.
- Mutable project/user workflow snapshots identify local source history.
- Installed package workflows are read-only unless an explicit update or
  overlay workflow is created; self-improve should refuse to mutate immutable
  package sources by default.

## Observability Requirements

- Every loop session gets a manifest with workflow source, definition digest,
  variables digest, session id, step ids, attempts, backend, model, elapsed
  time, accepted-output digest, artifacts, gates, commands, changed files, and
  final risks.
- Verification command evidence records command, cwd policy, exit code,
  bounded stdout/stderr digests, timestamps, and artifact refs.
- JSONL progress records should consistently include workflow id, session id,
  step id, attempt, status, elapsed time, and evidence refs.
- Default telemetry must be coarse and redacted: durations, statuses, retry
  counts, gate decisions, and error classes. Raw prompts, model outputs,
  stdout, stderr, and secrets are export-only.
- Swift-native telemetry claims should be reconciled with the current source:
  either implement the missing runtime telemetry surface or revise stale docs.

## Recovery Requirements

- Resume preserves workflow identity, source scope, variables, policy, and
  evidence refs.
- Rerun creates linked history instead of mutating the source session in place.
- Gate rejection should point to a rerunnable step and list reusable inputs.
- Auto-improve records incidents, remediation attempts, target session ids,
  patch modes, budgets, policy, and final acceptance/rejection.
- Recovery surfaces must explain what will be reused, replaced, or revalidated.
- In-place workflow mutation must create a restorable bundle snapshot before
  applying any patch. Execution-copy auto-improve may record change proposals
  without mutating the source bundle.
- Rollback and restore must be evidence-producing operations with their own
  session or command record, not untracked file copies.

## Security Requirements

- Preserve unrelated dirty worktree changes by default.
- Require path allowlists for mutations and force scratch artifacts under a
  declared scratch root.
- Prohibit commit and push unless both workflow policy and user approval allow
  them.
- Make nested workflow and nested agent starts opt-in, visible, and auditable.
- Redact secrets and sensitive payloads from telemetry, memory, and exported
  evidence by default.
- Reject host-absolute references in portable workflow/package metadata unless
  explicitly marked local-only.

## Portability Requirements

- Keep workflow bundles valid under project, user, package, and direct
  workflow-definition-dir lookup modes.
- Keep paths workflow-relative or data-root-relative in packageable artifacts.
- Avoid repo-local command assumptions in reusable workflows.
- Require package workflows to declare environment, secret, network, scratch,
  mutation, and backend expectations.
- Provide deterministic mock scenarios for promoted first-party loops.

## Phased Roadmap

### P0: Loop Contracts and Policy Validation

- Define loop metadata schema for workflow usage.
- Add mutation, scratch, secret, network, commit/push, and nested-process policy
  fields.
- Validate first-party loop workflows for required input/output, gate, evidence,
  and policy metadata.
- Fail package promotion when contracts or expected results are missing.

### P1: Evidence Manifest MVP

- Add `LoopEvidenceManifest` and gate result models to core runtime records.
- Persist manifests through the SQLite runtime store.
- Add CLI JSON/text output for `session evidence` or `loop evidence`.
- Include workflow digest, branch, dirty summary, step evidence, gates,
  commands, changed files, plan refs, and residual risks.

### P2: Recovery Semantics

- Persist source-session and source-step links for rerun/resume.
- Document and surface input reuse/replace semantics.
- Add rerun-from-gate convenience UX.
- Project recovery history through GraphQL and CLI.

### P3: First-Party Loop Hardening

- Upgrade design/implement/review loops to structured gates and evidence.
- Add deterministic mocks and `EXPECTED_RESULTS.md` for promoted loops.
- Ban commit/push by default.
- Require final outputs to list decisions, roadmap, verification, rejected
  alternatives, and residual risks.

### P4: Workflow Self-Evolution Safety

- Add `WorkflowChangeSet` and bundle snapshot records.
- Upgrade `workflow self-improve` from single-file backup/report behavior to
  bundle-wide propose/review/apply/restore semantics.
- Add workflow version listing, diff, and restore commands.
- Refuse self-improve mutation against immutable package sources unless an
  explicit overlay/update path is selected.

### P5: Product Loop UX

- Add thin `riela loop` aliases over workflow/session/package primitives.
- Add RielaApp/WorkflowViewer evidence timelines.
- Show policy and evidence expectations before start.
- Add `loop promote` for package-readiness checks.

### P6: Durable Learning and Telemetry Reconciliation

- Store redacted, distilled loop lessons with source-session provenance,
  expiry, scope, confidence, and invalidation triggers.
- Reconcile Swift telemetry implementation with documentation.
- Add package metrics for loop success, gate failures, reruns, and
  verification stability.

## Rejected Alternatives

- Prompt-only loop guidance: rejected because it cannot provide deterministic
  recovery, queryable gates, or reusable evidence contracts.
- Alias-only `riela loop`: rejected until evidence and policy contracts exist.
- A new orchestration runtime separate from workflows: rejected because the
  existing workflow/session/message model is the right substrate.
- Hard-coded workflow-type gate enums: rejected because they would overfit the
  first few loop templates. Use step metadata plus required output fields.
- Raw transcript memory: rejected because it risks leaking secrets and
  preserving stale reasoning.
- Fully autonomous mutation, commit, or push by default: rejected because a
  first-line engineering tool must keep operator control clear.
- Nested Riela/Codex recursion as the primary strategy: rejected because it
  hides cost, state, auth, mutation, and recovery boundaries.
- Treating self-improve backups as `workflow.json`-only copies: rejected
  because workflow behavior also lives in nodes, prompts, mocks, expected
  results, nested workflow directories, and package metadata.
- Treating package `version` as workflow version control: rejected because a
  package metadata version does not identify local mutable workflow history or
  callable-contract compatibility by itself.

## Open Questions

- Should loop evidence live as normalized SQLite tables, exported JSON beside
  session snapshots, or both?
- Should gates be represented as step metadata only, a new gate result model,
  or a restricted node subtype?
- How much should `riela loop` remain command alias sugar versus a first-class
  domain object with independent ids?
- What is the minimal plan reference schema that links markdown implementation
  plans to sessions without imposing this repository's exact conventions on
  every user?
- Which policy checks can Riela enforce at runtime, and which must remain
  adapter/tool audit records?
- What are the first three first-party loop templates worth promoting before
  broad package publication?
- Should workflow history be stored only in project `.riela/workflow-history`,
  or should user-scope workflows use `~/.riela/workflow-history` with
  project-local restore records?
- What retention policy should apply to bundle snapshots that may contain
  proprietary prompts or sensitive examples?

## Risks

- Workflow validation and execution were not rerun by this arbitrator due the
  explicit no-`riela`/no-`codex` constraint.
- Evidence manifests can become too heavy or leak sensitive data unless they
  default to digests, bounded summaries, redaction, and local-only raw logs.
- Runtime enforcement of nested-process bans may be incomplete if implemented
  only as prompt text.
- Gate schemas could overfit this repository's implementation-plan culture
  unless the core fields stay small and optional extensions carry local detail.
- A product-first loop command could make dangerous workflows feel too casual
  unless mutation and process policy are shown before start.
- Durable learning can preserve stale conclusions unless lessons have expiry,
  invalidation triggers, and source-session provenance.
- Workflow history can leak prompt or mock-scenario content if snapshots are
  copied carelessly. Snapshot manifests should support redaction flags,
  retention classes, and explicit export controls.
- Restore can overwrite valuable local edits if it ignores dirty state.
  Restore must fail closed on conflicts unless the user supplies explicit
  path-scoped overwrite approval.

## Next Implementation-Plan Candidates

1. `loop-contract-policy-schema`: extend workflow usage and node metadata with
   loop kind, evidence, gate, mutation, scratch, secret, network, commit/push,
   and nested-process policy fields.
2. `loop-evidence-manifest-mvp`: implement runtime-owned evidence manifests,
   persisted gate results, and CLI JSON/text evidence output.
3. `loop-recovery-lineage`: persist rerun/resume source-session links and
   expose input reuse semantics in CLI and GraphQL.
4. `first-party-loop-template-hardening`: upgrade the design/implement/review
   loops with structured gates, mock scenarios, expected results, and safe
   mutation defaults.
5. `loop-command-surface`: add `riela loop start/status/evidence/rerun-step`
   wrappers after evidence manifests are available.
6. `loop-promotion-readiness`: add package promotion checks for usage
   contracts, policy declarations, expected results, mock scenarios, and output
   schemas.
7. `distilled-loop-memory`: add scoped, redacted, provenance-linked loop
   lessons with expiry and invalidation.
8. `viewer-loop-evidence-timeline`: add a stage-oriented evidence timeline to
   RielaApp/WorkflowViewer.
9. `workflow-self-evolution-versioning`: add bundle snapshots, reviewed
   change-sets, workflow version listing/diff/restore commands, and
   self-improve integration.
