# Loop Engineering First-Line Tool Detailed Design

Status: detailed design, ready for implementation planning

Source design: `design-docs/specs/design-loop-engineering-first-line-tool.md`

Created: 2026-06-25

## Summary

Riela should make repeated engineering loops auditable without introducing a
second orchestration engine. The runtime remains the workflow/session/message
system already implemented in Swift. The new layer is an additive loop contract:
authored loop metadata on workflows and steps, runtime-owned evidence
manifests, structured gate results, policy checks, and first-class recovery
lineage exposed through CLI, GraphQL, and package-promotion surfaces.

The MVP makes a loop session answer these questions in one durable record:

- what workflow and definition digest ran
- what work was allowed
- which workers and gates executed
- what files, artifacts, commands, verification, and risks were reported
- which gate accepted or rejected the result
- how resume/rerun/retry attempts relate to prior sessions
- which redaction and policy decisions shaped the record

## Grounding In Current Swift Runtime

Current source inspection shows the implementation should extend these existing
contracts rather than bypass them:

- `Sources/RielaCore/WorkflowModel.swift` owns authored workflow, step, node,
  transition, and session-policy models. Raw validation already rejects
  unsupported step/node fields, so step-level loop metadata requires typed
  schema additions.
- `Sources/RielaCore/RuntimeSession.swift` owns `WorkflowSession`,
  `WorkflowStepExecution`, accepted output, adapter metadata, and workflow
  message records.
- `Sources/RielaCore/RuntimeStore.swift` owns runtime store creation, execution
  updates, and message append APIs.
- `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift` and
  `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` persist
  session snapshots, root output, diagnostics, and workflow messages.
- `Sources/RielaCore/DeterministicWorkflowRunner.swift` already supports
  `resumeSessionId`, `rerunFromSessionId`, `rerunFromStepId`, progress events,
  bounded steps, and bounded loop iterations.
- `Sources/RielaCLI/WorkflowCommands.swift` owns validate, inspect, usage,
  run, JSONL progress, persistence, auto-improve, package lookup, and package
  run surfaces.
- `Sources/RielaCLI/SessionCommands.swift` owns session status, logs, health,
  rerun, and resume.
- `Sources/RielaGraphQL/GraphQLContracts.swift` projects sessions,
  communications, manager controls, continue, replay, and retry contracts.
- `Sources/RielaAddons/WorkflowPackageManifest.swift` validates package
  manifests with a closed coding key set, so package-promotion metadata must be
  explicitly modeled before it can appear in `riela-package.json`.

## Compatibility And Migration Strategy

All schema changes are additive and optional in phase 1.

Existing workflows without loop metadata continue to validate, run, persist,
inspect, rerun, and resume unchanged. Existing session records decode because
new fields default to `nil` or empty arrays. Existing package manifests remain
valid because package loop metadata is optional, and unsupported manifest keys
are only introduced after the manifest model and validator know them.

Migration rules:

- Do not introduce a `workflowType` enum. Loop behavior is metadata and policy
  on ordinary workflows.
- Keep `workflow run`, `session rerun`, and `session resume` semantics intact.
  Add loop projections to their structured output only after the persistence
  snapshot can store them.
- Preserve `workflow usage` and `workflow inspect` fields; add optional
  `loop` sections rather than changing existing field meanings.
- Persist evidence alongside snapshots as a new optional `loopEvidence`
  member first. Add normalized SQLite tables only after DTO and CLI tests lock
  the model.
- Treat legacy sessions as `loopEvidence: nil`. CLI and GraphQL should report
  "not recorded" instead of fabricating manifests.
- Gate enforcement starts in warn-only/inspect-only mode for existing
  workflows and fail-closed only when `loop.required == true` or a promoted
  loop package declares the gate/policy as required.

## Loop Metadata And Workflow Usage Contract

Add optional loop metadata to authored workflow JSON:

```json
{
  "loop": {
    "kind": "design-implement-review",
    "required": true,
    "description": "Plan, implement, review, fix, and verify a bounded code change.",
    "evidence": {
      "required": true,
      "artifactRootPolicy": "runtime-owned",
      "requiredSections": ["changedFiles", "verification", "residualRisks"]
    },
    "policies": {
      "mutation": {
        "allowedWriteRoots": ["Sources", "Tests", "design-docs", "impl-plans", "tmp"],
        "scratchRoot": "tmp",
        "commit": "deny",
        "push": "deny"
      },
      "process": {
        "nestedRiela": "deny",
        "nestedCodex": "deny",
        "allowedBackends": ["codex-agent"],
        "requiredWorkerModel": "gpt-5.5"
      },
      "network": {
        "mode": "inherit-command"
      },
      "redaction": {
        "secretPolicy": "redact-known-patterns",
        "storeRawStdout": false,
        "storeRawStderr": false
      }
    },
    "gates": [
      {
        "id": "implementation-review",
        "stepId": "step7-adversarial-review",
        "required": true,
        "acceptWhen": {
          "decision": "accepted",
          "maxHighFindings": 0,
          "maxMediumFindings": 0
        }
      }
    ],
    "recovery": {
      "resume": "preserve-session",
      "rerun": "new-child-session",
      "retry": "same-communication-or-step-attempt"
    },
    "implementationPlan": {
      "required": true,
      "pathPattern": "impl-plans/active/*.md"
    }
  }
}
```

Add optional step-level metadata:

```json
{
  "id": "step7-adversarial-review",
  "nodeId": "adversarial-review",
  "loop": {
    "role": "gate",
    "gateId": "implementation-review",
    "evidenceTags": ["review", "blocking-findings"],
    "recordsChangedFiles": false,
    "recordsVerification": true
  }
}
```

`workflow usage` and `workflow inspect` should project:

- `loop.kind`
- `loop.required`
- `loop.description`
- `loop.policies` summary, never raw secrets
- `loop.gates` with id, step id, required flag, and acceptance thresholds
- `loop.evidence.requiredSections`
- `loop.recovery` semantics
- `loop.implementationPlan` requirements

The usage surface remains compact and AI-facing. It must not infer loop safety
from prompt prose. It only reports authored metadata and runtime-known defaults.

## LoopEvidenceManifest MVP

Add a runtime-owned manifest model in `RielaCore`, projected through CLI and
GraphQL:

```swift
public struct LoopEvidenceManifest: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var manifestId: String
  public var workflowId: String
  public var sessionId: String
  public var workflowSource: LoopWorkflowSource
  public var workflowDefinitionDigest: String?
  public var variablesDigest: String?
  public var worktree: LoopWorktreeSummary?
  public var policy: LoopPolicyEvidence
  public var recovery: LoopRecoveryLineage?
  public var steps: [LoopStepEvidence]
  public var gates: [LoopGateResult]
  public var artifacts: [LoopArtifactRef]
  public var changedFiles: [LoopChangedFile]
  public var commands: [LoopCommandEvidence]
  public var verification: [LoopVerificationEvidence]
  public var implementationPlans: [LoopImplementationPlanRef]
  public var residualRisks: [LoopResidualRisk]
  public var redaction: LoopRedactionSummary
  public var createdAt: Date
  public var updatedAt: Date
}
```

MVP field semantics:

- `workflowSource`: source scope, source kind, workflow directory, package name,
  package version, package directory, and mutability.
- `workflowDefinitionDigest`: stable digest over the resolved workflow bundle
  inputs used for the run. If digesting is deferred, set `nil` and emit a
  diagnostic rather than inventing a value.
- `variablesDigest`: digest of runtime variables after secret redaction.
- `worktree`: branch, base commit, head commit, dirty summary, and whether
  unrelated dirty files were present before the loop.
- `policy`: declared policy, effective policy, decisions, and denials.
- `recovery`: entry mode, source session id, source step id, parent/child
  session ids, reason, and input reuse policy.
- `steps`: one record per `WorkflowStepExecution`, with step id, node id,
  execution id, backend, model, status, artifact refs, accepted output summary,
  and evidence tags.
- `gates`: structured gate results, described below.
- `artifacts`: runtime-owned refs only; path, kind, digest when available,
  producer step execution id, redaction status, and retention class.
- `changedFiles`: path, change kind, producer step execution id, digest when
  available, and whether the path was within allowed mutation roots.
- `commands`: command summaries only by default; command id, argv redaction
  status, working directory policy status, exit code, duration, stdout/stderr
  storage policy, and evidence refs.
- `verification`: command/evidence refs, outcome, and diagnostic summary.
- `implementationPlans`: plan path, status, linked session id, stale flag,
  completion checks, and verification refs.
- `residualRisks`: severity, message, evidence refs, owner if known, and
  accepted/unaccepted status.
- `redaction`: policy name, redacted field count, unredacted exceptions, and
  warnings.

The manifest is produced by the runtime. Workers may propose evidence in their
structured outputs, but runtime code attaches session ids, step execution ids,
artifact refs, policy status, digests, and redaction status.

## Structured Gate Result Model

Gate results should be typed records, not prompt-only conventions:

```swift
public enum LoopGateDecision: String, Codable, Sendable {
  case accepted
  case rejected
  case needsWork = "needs_work"
  case skipped
}

public struct LoopFindingSeverityCounts: Codable, Equatable, Sendable {
  public var high: Int
  public var medium: Int
  public var low: Int
  public var informational: Int
}

public struct LoopBlockingFinding: Codable, Equatable, Sendable {
  public var id: String
  public var severity: String
  public var filePath: String?
  public var line: Int?
  public var message: String
  public var evidenceRefs: [String]
}

public struct LoopGateResult: Codable, Equatable, Sendable {
  public var gateId: String
  public var stepId: String
  public var stepExecutionId: String
  public var decision: LoopGateDecision
  public var severityCounts: LoopFindingSeverityCounts
  public var blockingFindings: [LoopBlockingFinding]
  public var evidenceRefs: [String]
  public var rerunPolicy: String?
  public var residualRisks: [LoopResidualRisk]
  public var acceptedAt: Date?
  public var diagnostics: [String]
}
```

A gate passes when its authored `acceptWhen` conditions are satisfied. For the
first-line design/implement/review loop, the review gate is accepted only when
the structured gate result has `decision == accepted`, `high == 0`, and
`medium == 0`.

Gate output extraction uses this order:

1. Read the accepted output payload from the gate step.
2. Prefer a `loopGate` object if present.
3. Fall back to configured JSON pointer paths in gate metadata.
4. If required gate data is absent or invalid and `loop.required == true`, fail
   closed with a policy/gate diagnostic.

## Recovery Lineage And Rerun/Resume Semantics

Current runner entry modes remain authoritative:

- normal run creates a new session from `workflow.entryStepId`
- resume reuses the existing non-terminal session
- rerun creates a child session from a valid step id in the source session
- replay/retry GraphQL manager controls remain separate communication delivery
  controls

Add explicit lineage:

```swift
public enum LoopEntryMode: String, Codable, Sendable {
  case run
  case resume
  case rerun
  case retry
  case replay
}

public struct LoopRecoveryLineage: Codable, Equatable, Sendable {
  public var entryMode: LoopEntryMode
  public var sourceSessionId: String?
  public var sourceStepId: String?
  public var sourceStepExecutionId: String?
  public var parentSessionId: String?
  public var childSessionIds: [String]
  public var reason: String?
  public var inputReusePolicy: String
  public var preservedFailureEvidenceRefs: [String]
}
```

Resume preserves the session id and appends evidence updates. Rerun creates a
new child session and records both parent and child manifests. Retry and replay
record the source communication or step attempt but do not erase the original
failure evidence. Terminal sessions are not mutated by resume; the current
runner behavior of returning the terminal result remains compatible.

## Mutation And Process Policy Enforcement

The MVP enforcement posture is staged:

- Authoring validation: validate policy shapes and safe paths. Reject absolute
  paths, `..`, unsupported policy values, and empty gate ids.
- Preflight: compute effective policy before run. For required loops, reject
  unsupported backends, forbidden nested process policies, and missing gates
  before worker execution.
- Runtime: record policy decisions at session start and step completion.
  Enforce command/container process policy before stdio execution.
- Adapter boundary: pass policy context to CLI-agent adapters and record
  backend/model evidence. For MVP, detect configured `codex-agent` and required
  model from node payloads; do not parse arbitrary shell scripts for nested
  process starts.
- Post-run: mark changed files outside allowed roots as policy violations in
  evidence. Required loops fail closed when violations are blocking.

Default first-line policy:

- `commit` and `push` denied unless explicitly allowed by the workflow command.
- scratch files must stay under the declared scratch root, normally `tmp/`.
- nested Riela workflow process starts and nested Codex process starts are
  denied by default.
- worker nodes in first-party first-line loops use `codex-agent` with model
  `gpt-5.5`.
- network policy is explicit and recorded, but broad network blocking is not
  part of the MVP unless a command/container executor already exposes an
  enforceable hook.

## CLI Surfaces

Add after core persistence lands:

- `riela loop status <session-id> [--output jsonl|json|text]`
- `riela loop evidence <session-id> [--output jsonl|json|text]`
- `riela loop gates <session-id> [--output jsonl|json|text]`
- `riela loop recover <session-id> --from-step <step-id>` as a discoverable
  alias over `session rerun`

Do not remove existing commands. Add optional loop fields to:

- `workflow usage`
- `workflow inspect`
- `workflow run` final `run_result`
- JSONL progress records when a manifest is available
- `session status`, `session health`, `session logs`, and `session export`
- `session rerun` and `session resume` results

Text output can summarize. JSON/JSONL output must carry typed fields.

## GraphQL Surfaces

Extend `GraphQLWorkflowSessionDTO` with optional loop projections:

- `loopEvidence`
- `loopGates`
- `loopRecovery`

Extend the schema with:

```graphql
type LoopEvidenceManifest { schemaVersion: Int!, manifestId: String!, workflowId: String!, sessionId: String!, ... }
type LoopGateResult { gateId: String!, stepId: String!, stepExecutionId: String!, decision: String!, severityCounts: LoopFindingSeverityCounts!, ... }
type LoopRecoveryLineage { entryMode: String!, sourceSessionId: String, sourceStepId: String, parentSessionId: String, childSessionIds: [String!]! }
type Query { loopEvidence(workflowId: String!, sessionId: String!): LoopEvidenceManifest }
```

GraphQL must project from the same persisted runtime records as CLI. No
GraphQL-only manifest reconstruction.

## Runtime Persistence

Phase 1 stores evidence inside `WorkflowRuntimePersistenceSnapshot`:

```swift
public var loopEvidence: LoopEvidenceManifest?
```

`FileWorkflowRuntimePersistenceStore` writes it in `runtime-snapshot.json`.
`SQLiteWorkflowRuntimePersistenceStore` stores it in a nullable JSONB column
`loop_evidence_json`.

Phase 2 may add normalized SQLite tables after the model stabilizes:

- `loop_evidence_manifests`
- `loop_gate_results`
- `loop_step_evidence`
- `loop_artifacts`
- `loop_recovery_lineage`

The projector is the single place that assembles a manifest from session,
messages, run options, workflow source, policy context, and optional worker
evidence.

## Package Promotion Surface

Package promotion must require loop metadata only for packages that claim
first-line loop readiness. Add optional manifest metadata:

```json
{
  "loop": {
    "promotionReady": true,
    "usageContract": true,
    "requiredMockScenarios": ["mock-scenario.json"],
    "expectedResults": ["EXPECTED_RESULTS.md"],
    "requiredGates": ["implementation-review"],
    "requiredPolicies": ["mutation", "process", "redaction"],
    "minimumEvidenceSchemaVersion": 1
  }
}
```

Promotion checks:

- workflow usage metadata exists
- input/output contracts exist for the callable step
- loop policy metadata validates
- required gates map to authored steps
- deterministic mock scenarios are present
- `EXPECTED_RESULTS.md` is present
- package integrity/checksum fields validate
- package publish remains dry-run unless explicit write approval is supplied

## Security And Redaction Defaults

Default evidence is safe-by-default:

- Do not store raw prompts, model responses, stdout, stderr, or environment by
  default.
- Store digests, summaries, exit codes, artifact refs, and redaction status.
- Redact known secret patterns and `RIELA_*TOKEN*`, `*_KEY`, `*_SECRET`,
  `*_PASSWORD` values.
- Mark unknown redaction coverage as `unverified`, not `clean`.
- Use workflow-relative or repository-relative paths where possible.
- Reject host-absolute paths in portable workflow/package metadata.
- Record dirty-worktree summaries without overwriting unrelated user changes.

## Phased Rollout

Phase 1: schema and persistence foundation.

- Add loop metadata models and validation.
- Add `LoopEvidenceManifest`, `LoopGateResult`, and recovery lineage models.
- Add optional snapshot persistence and file/SQLite round trips.
- Add projector tests without changing execution behavior.

Phase 2: CLI and GraphQL projection.

- Add loop fields to inspect/usage/session/run outputs.
- Add `riela loop status/evidence/gates` commands.
- Add GraphQL DTOs/schema projection.

Phase 3: gate extraction and policy preflight.

- Extract gate results from accepted step outputs.
- Enforce required gates.
- Preflight process/mutation policy for required loops.
- Record policy denials and diagnostics.

Phase 4: package promotion readiness.

- Add package manifest loop metadata.
- Validate mock scenarios, expected results, policies, gates, and usage
  contracts for promotion-ready packages.

Phase 5: first-party loop templates.

- Update first-party design/implement/review, secure review, package release,
  event-source verification, and self-improve workflows with loop metadata.

## Explicit Non-Goals

- No new orchestration engine.
- No replacement of workflow/session primitives.
- No hard-coded workflow-type enum.
- No automatic package promotion.
- No durable raw transcript memory.
- No broad live network sandboxing in the MVP.
- No commit or push automation by default.
- No cosmetic loop UX before evidence, gate, recovery, and policy records
  exist.
- No attempt to infer contracts from prompt text.
