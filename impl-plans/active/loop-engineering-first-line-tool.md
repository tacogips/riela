# Loop Engineering First-Line Tool Implementation Plan

**Status**: In Progress
**Design Reference**: `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
**Created**: 2026-06-25
**Last Updated**: 2026-06-25

---

## Design Document Reference

**Source**: `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`

### Summary

Implement first-line loop engineering as additive Swift workflow metadata,
runtime-owned evidence manifests, structured gate results, recovery lineage,
policy projections, CLI/GraphQL surfaces, and package-promotion checks.

### Scope

**Included**:

- Optional authored workflow and step loop metadata.
- Optional package loop promotion metadata.
- `LoopEvidenceManifest` MVP model and runtime persistence.
- Structured `LoopGateResult` model and gate extraction from accepted outputs.
- Recovery lineage for run/resume/rerun/retry/replay projections.
- Policy metadata validation, preflight posture, and evidence recording.
- CLI projection through workflow usage/inspect/run/session and new loop
  commands.
- GraphQL DTO/schema projection from persisted runtime records.
- Focused Swift tests by module.

**Excluded**:

- A new orchestration engine.
- Replacing existing workflow/session/message primitives.
- Automatic package promotion.
- Raw transcript memory.
- Broad network sandboxing.
- Commit/push automation by default.
- Running or validating workflows as part of this authoring step.

---

## Modules

### 1. Core Loop Metadata Models

#### `Sources/RielaCore/LoopEngineeringModels.swift`

**Status**: DONE

```swift
public struct WorkflowLoopMetadata: Codable, Equatable, Sendable {
  public var kind: String?
  public var required: Bool
  public var description: String?
  public var evidence: LoopEvidenceRequirements?
  public var policies: LoopPolicyDeclaration?
  public var gates: [LoopGateDeclaration]
  public var recovery: LoopRecoveryDeclaration?
  public var implementationPlan: LoopImplementationPlanRequirement?
}

public struct WorkflowStepLoopMetadata: Codable, Equatable, Sendable {
  public var role: String?
  public var gateId: String?
  public var evidenceTags: [String]
  public var recordsChangedFiles: Bool?
  public var recordsVerification: Bool?
}

public struct LoopGateDeclaration: Codable, Equatable, Sendable {
  public var id: String
  public var stepId: String
  public var required: Bool
  public var acceptWhen: LoopGateAcceptancePolicy
}
```

**Checklist**:

- [x] Add metadata structs with defaulted decoding for additive compatibility.
- [x] Keep `kind` open string, not enum.
- [x] Add policy, evidence, recovery, and plan requirement structs.
- [x] Add unit tests for decoding absent, partial, and complete metadata.

#### `Sources/RielaCore/WorkflowModel.swift`

**Status**: DONE

```swift
public struct AuthoredWorkflowJSON: Codable, Equatable, Sendable {
  public var loop: WorkflowLoopMetadata?
}

public struct WorkflowDefinition: Codable, Equatable, Sendable {
  public var loop: WorkflowLoopMetadata?
}

public struct WorkflowStepRef: Codable, Equatable, Sendable {
  public var loop: WorkflowStepLoopMetadata?
}
```

**Checklist**:

- [x] Add optional `loop` to authored and normalized workflow models.
- [x] Add optional `loop` to step refs.
- [x] Update materialization so authored metadata reaches `WorkflowDefinition`.
- [x] Preserve existing workflows without metadata.

#### `Sources/RielaCore/WorkflowValidation.swift`

**Status**: DONE

Validation helpers are split into
`Sources/RielaCore/WorkflowLoopValidation.swift` to keep the existing validator
focused and under SwiftLint length limits.

**Checklist**:

- [x] Add `loop` to top-level raw validation handling.
- [x] Add `loop` to allowed step keys.
- [x] Validate safe relative paths in policy roots and implementation-plan
  patterns.
- [x] Validate non-empty gate ids and step references.
- [x] Validate supported policy values: `allow`, `deny`, `prompt`,
  `inherit-command`, `runtime-owned`.
- [x] Fail validation for loop gates that point at unknown steps.

### 2. Evidence, Gate, And Recovery Runtime Models

#### `Sources/RielaCore/LoopEvidenceManifest.swift`

**Status**: DONE

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

**Checklist**:

- [x] Add MVP value types with stable Codable names.
- [x] Use optional digest fields until digest computation is implemented.
- [x] Include redaction status on artifacts, commands, and manifest summary.
- [x] Add deterministic JSON encoding tests.

#### `Sources/RielaCore/LoopGateResult.swift`

**Status**: DONE

```swift
public enum LoopGateDecision: String, Codable, Sendable {
  case accepted
  case rejected
  case needsWork = "needs_work"
  case skipped
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

**Checklist**:

- [x] Add gate result and finding count types.
- [x] Add acceptance evaluator for decision/high/medium thresholds.
- [x] Keep severity strings extensible for findings while counts stay typed.
- [x] Add tests for accepted and missing-required rejected gate payloads.

#### `Sources/RielaCore/LoopRecoveryLineage.swift`

**Status**: DONE

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

**Checklist**:

- [x] Model run/resume/rerun/retry/replay lineage.
- [x] Preserve terminal-session resume semantics.
- [x] Add source and child session references without rewriting old sessions.

### 3. Runtime Projection And Persistence

#### `Sources/RielaCore/LoopEvidenceProjector.swift`

**Status**: DONE

```swift
public struct LoopEvidenceProjectionInput: Sendable {
  public var workflow: WorkflowDefinition
  public var session: WorkflowSession
  public var workflowMessages: [WorkflowMessageRecord]
  public var workflowSource: LoopWorkflowSource
  public var variables: JSONObject
  public var recovery: LoopRecoveryLineage?
  public var policy: LoopPolicyEvidence
  public var includeWorkflowWithoutLoopMetadata: Bool
}

public protocol LoopEvidenceProjecting: Sendable {
  func project(_ input: LoopEvidenceProjectionInput) throws -> LoopEvidenceManifest?
}
```

**Checklist**:

- [x] Project manifests when loop metadata exists.
- [x] Project manifests when explicit loop output is requested without authored
  loop metadata.
- [x] Build step evidence from `WorkflowStepExecution`.
- [x] Extract gate results from accepted output `loopGate` payloads.
- [x] Attach diagnostics instead of fabricating missing digests.
- [x] Fail closed only for required loops with missing required gates.

#### `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift`

**Status**: DONE

```swift
public struct WorkflowRuntimePersistenceSnapshot: Codable, Equatable, Sendable {
  public var loopEvidence: LoopEvidenceManifest?
}
```

**Checklist**:

- [x] Add optional `loopEvidence`.
- [x] Update initializer default to `nil`.
- [x] Update projector to accept optional loop evidence.
- [x] Preserve decode compatibility with old snapshots.

#### `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`

**Status**: DONE

**Checklist**:

- [x] Add nullable `loop_evidence_json` JSONB column.
- [x] Migrate existing SQLite DBs with `ALTER TABLE` when column is absent.
- [x] Round-trip `loopEvidence` in save/load/loadAll.
- [x] Preserve read-only loading of pre-migration databases by projecting `loopEvidence: nil`.

#### `Sources/RielaCore/RuntimeStore.swift` and `RuntimeSession.swift`

**Status**: DONE

**Checklist**:

- [x] Avoid widening hot store APIs until projector needs it.
- [x] Add only optional provenance fields if step evidence cannot be projected
  from existing executions.
- [x] Keep accepted output and adapter metadata unchanged for old consumers.

### 4. Policy Enforcement Foundation

#### `Sources/RielaCore/LoopPolicyEvaluator.swift`

**Status**: DONE

```swift
public protocol LoopPolicyEvaluating: Sendable {
  func preflight(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) -> LoopPolicyEvidence
  func evaluateStep(step: WorkflowStepRef, node: AgentNodePayload) -> LoopPolicyStepDecision
}
```

**Checklist**:

- [x] Validate required `codex-agent` and `gpt-5.5` for first-line worker
  policies.
- [x] Detect denied command/container process policy before stdio execution.
- [x] Record nested Riela/Codex policy as enforced when runtime can control the
  boundary and as declared-only when it cannot parse arbitrary shell scripts.
- [x] Record commit/push default deny in evidence.
- [x] Add path-policy helpers for mutation roots and scratch root.

#### `Sources/RielaCore/DeterministicWorkflowRunner.swift`

**Status**: DONE

**Checklist**:

- [x] Accept optional loop policy/projector dependencies in the run request or
  runner initializer.
- [x] Evaluate policy before the first step for required loops.
- [x] Emit policy denial as deterministic runner error.
- [x] Carry recovery lineage for `resumeSessionId` and `rerunFromSessionId`.

#### `Sources/RielaCore/WorkflowStdioNodeExecution.swift`

**Status**: DONE

**Checklist**:

- [x] Add optional policy context to stdio execution input.
- [x] Block command/container execution when effective process policy denies it.
- [x] Record command evidence without raw stdout/stderr by default.

### 5. CLI Surfaces

#### `Sources/RielaCLI/RielaCommand.swift`

**Status**: DONE

```swift
public enum RielaCommand: Equatable, Sendable {
  case loop(LoopCommand)
}

public enum LoopCommand: Equatable, Sendable {
  case status(CLICommandOptions)
  case evidence(CLICommandOptions)
  case gates(CLICommandOptions)
  case recover(LoopRecoverOptions)
}
```

**Checklist**:

- [x] Parse `riela loop status/evidence/gates <session-id>`.
- [x] Parse `riela loop recover <session-id> --from-step <step-id>`.
- [x] Keep existing `session rerun` and `session resume` unchanged.

#### `Sources/RielaCLI/LoopCommands.swift`

**Status**: DONE

**Checklist**:

- [x] Load persisted snapshots through the same session store path as
  `SessionInspectionCommand`.
- [x] Render text summaries and full JSON/JSONL evidence.
- [x] Implement `recover` as a thin alias over `SessionRerunCommand`.
- [x] Report `loopEvidence: null`/not recorded for legacy sessions.

#### `Sources/RielaCLI/WorkflowCommands.swift`

**Status**: DONE

**Checklist**:

- [x] Add loop metadata to `WorkflowInspectionSummary`.
- [x] Add loop usage fields to `workflow usage`.
- [x] Attach `loopEvidence` summary to final run result when available.
- [x] Persist projected evidence at live and final persistence points.
- [x] Keep JSONL progress backward compatible by leaving progress records unchanged.

#### `Sources/RielaCLI/SessionCommands.swift`

**Status**: DONE

**Checklist**:

- [x] Add optional loop summary to session status/health/export results.
- [x] Add lineage fields to rerun/resume structured output.
- [x] Do not mutate unrelated persisted sessions during rerun/resume.

### 6. GraphQL Surfaces

#### `Sources/RielaGraphQL/GraphQLContracts.swift`

**Status**: DONE

```swift
public struct GraphQLWorkflowSessionDTO: Codable, Equatable, Sendable {
  public var loopEvidence: GraphQLLoopEvidenceManifestDTO?
  public var loopGates: [GraphQLLoopGateResultDTO]
  public var loopRecovery: GraphQLLoopRecoveryLineageDTO?
}
```

**Checklist**:

- [x] Add DTOs for loop evidence, gate result, finding counts, and recovery.
- [x] Add optional fields to schema contract.
- [x] Add `loopEvidence(workflowId:sessionId:)` query contract.
- [x] Project from persisted runtime snapshot, not GraphQL-only inference.

#### `Sources/RielaGraphQL/RielaGraphQL.swift`

**Status**: DONE

**Checklist**:

- [x] Wire loop evidence query to control-plane service abstraction.
- [x] Preserve existing manager mutations and session query shape.

### 7. Package Promotion

#### `Sources/RielaAddons/WorkflowPackageManifest.swift`

**Status**: DONE

```swift
public struct WorkflowPackageLoopMetadata: Codable, Equatable, Sendable {
  public var promotionReady: Bool
  public var usageContract: Bool
  public var requiredMockScenarios: [String]
  public var expectedResults: [String]
  public var requiredGates: [String]
  public var requiredPolicies: [String]
  public var minimumEvidenceSchemaVersion: Int?
}
```

**Checklist**:

- [x] Add optional `loop` to package manifest coding keys.
- [x] Validate safe relative paths for mock scenarios and expected results.
- [x] Validate required lists when `promotionReady == true`.
- [x] Require `minimumEvidenceSchemaVersion` when `promotionReady == true`.
- [x] Validate required mock scenario and expected-results artifacts exist
  under the package root during loader validation.
- [x] Preserve manifest rejection of unknown unrelated keys.

#### `Sources/RielaCLI/WorkflowPackageParityCommands.swift`

**Status**: DONE

**Checklist**:

- [x] Extend publish dry-run result with loop promotion readiness diagnostics.
- [x] Preserve explicit approval for write mode as today.
- [x] Check package manifest usage contract, gates, mock scenarios, expected
  results, and policies for promotion-ready packages.

### 8. Tests

#### `Tests/RielaCoreTests/LoopEngineeringModelsTests.swift` and `WorkflowLoopMetadataCodableTests.swift`

**Status**: DONE

**Checklist**:

- [x] Decode existing workflow JSON without loop metadata.
- [x] Decode full workflow and step loop metadata.
- [x] Reject invalid gate step references and unsafe policy paths.
- [x] Encode evidence manifest deterministically.

Validation coverage lives in
`Tests/RielaCoreTests/WorkflowLoopValidationTests.swift`.

#### `Tests/RielaCoreTests/LoopEvidenceProjectorTests.swift`

**Status**: DONE

**Checklist**:

- [x] Project manifest from a completed session.
- [x] Project explicit runtime evidence for workflows without authored loop metadata.
- [x] Extract accepted gate with zero high/medium findings.
- [x] Fail required gate when output lacks structured gate data.
- [x] Preserve rerun lineage and failure evidence refs.

#### `Tests/RielaCoreTests/RuntimeStoreTests.swift` and `RuntimeSessionTests.swift`

**Status**: DONE

**Checklist**:

- [x] Round-trip `loopEvidence` through file snapshot.
- [x] Round-trip `loopEvidence` through SQLite snapshot.
- [x] Decode pre-loop legacy snapshots.

#### `Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift`

**Status**: DONE

**Checklist**:

- [x] `workflow run` persists projected loop evidence to the canonical SQLite session store.
- [x] `workflow run` persists projected loop evidence to `--artifact-root` file snapshots.
- [x] Existing JSONL live persistence still records sessions before start records.
- [x] Explicit `loop evidence/gates` can synthesize legacy runtime evidence
  without mutating stored snapshots.

#### `Tests/RielaCLITests/WorkflowCommandTests.swift`

**Status**: DONE

**Checklist**:

- [x] `workflow usage --output json` includes authored loop metadata.
- [x] `workflow inspect --output json` includes loop policy/gate summary.
- [x] `workflow run --mock-scenario` persists loop evidence without raw logs.
- [x] JSONL final result includes optional loop evidence summary.

#### `Tests/RielaCLITests/CommandParsingTests.swift`

**Status**: DONE

**Checklist**:

- [x] Parse loop status/evidence/gates commands.
- [x] Parse loop recover command.
- [x] Preserve existing workflow/session parsing.

#### `Tests/RielaCLITests/WorkflowCommandLivePersistenceTests.swift`

**Status**: DONE

**Checklist**:

- [x] Live persistence writes loop evidence during run progress.
- [x] Legacy live persistence records still load.

#### `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`

**Status**: DONE

**Checklist**:

- [x] Project loop evidence/gates/recovery into DTOs.
- [x] Schema contract includes loop fields and query.
- [x] Existing session DTO tests remain green.

#### `Tests/RielaAddonsTests/WorkflowPackageManifestTests.swift`

**Status**: DONE

**Checklist**:

- [x] Validate package loop promotion metadata.
- [x] Reject promotion-ready package missing `EXPECTED_RESULTS.md`.
- [x] Reject promotion-ready package with missing mock scenario.
- [x] Dry-run publish reports loop readiness diagnostics.

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Loop metadata models | `Sources/RielaCore/LoopEngineeringModels.swift` | DONE | `LoopEngineeringModelsTests`, `WorkflowLoopMetadataCodableTests` |
| Workflow model integration | `Sources/RielaCore/WorkflowModel.swift` | DONE | `WorkflowModelTests`, `WorkflowLoopMetadataCodableTests` |
| Workflow validation | `Sources/RielaCore/WorkflowValidation.swift`, `Sources/RielaCore/WorkflowLoopValidation.swift` | DONE | `WorkflowLoopValidationTests` |
| Evidence manifest | `Sources/RielaCore/LoopEvidenceManifest.swift` | DONE | `LoopEngineeringModelsTests` |
| Gate result | `Sources/RielaCore/LoopGateResult.swift` | DONE | `LoopEngineeringModelsTests`, `LoopEvidenceProjectorTests` |
| Recovery lineage | `Sources/RielaCore/LoopRecoveryLineage.swift` | DONE | `LoopEngineeringModelsTests` |
| Evidence projector | `Sources/RielaCore/LoopEvidenceProjector.swift` | DONE | `LoopEvidenceProjectorTests` |
| Snapshot persistence | `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift` | DONE | `RuntimeStoreTests` |
| SQLite persistence | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | DONE | `SQLiteWorkflowMessageLogTests` |
| Policy evaluator | `Sources/RielaCore/LoopPolicyEvaluator.swift` | DONE | `LoopPolicyEvaluatorTests` |
| Runner integration | `Sources/RielaCore/DeterministicWorkflowRunner.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` | DONE | `DeterministicWorkflowRunnerTests`, `WorkflowRunnerLoopPolicyTests` |
| Stdio policy/evidence execution | `Sources/RielaCore/WorkflowStdioNodeExecution.swift`, `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift` | DONE | `WorkflowStdioNodeExecutorTests`, `WorkflowRunnerLoopPolicyTests` |
| CLI parser | `Sources/RielaCLI/RielaCommand.swift` | DONE | `CommandParsingTests` |
| CLI loop commands | `Sources/RielaCLI/LoopCommands.swift` | DONE | `WorkflowCommandLivePersistenceTests` |
| CLI workflow projection | `Sources/RielaCLI/WorkflowCommands.swift` | DONE | `WorkflowCommandTests`, `WorkflowCommandLivePersistenceTests` |
| CLI session projection | `Sources/RielaCLI/SessionCommands.swift` | DONE | `WorkflowCommandTests`, `WorkflowCommandLivePersistenceTests` |
| GraphQL DTOs and query service | `Sources/RielaGraphQL/GraphQLContracts.swift`, `Sources/RielaGraphQL/RielaGraphQL.swift` | DONE | `GraphQLContractsTests` |
| Package manifest metadata | `Sources/RielaAddons/WorkflowPackageManifest.swift`, `Sources/RielaAddons/WorkflowPackagePromotionArtifacts.swift` | DONE | `WorkflowPackageManifestTests` |
| Package publish readiness | `Sources/RielaCLI/WorkflowPackageParityCommands.swift`, `Sources/RielaCLI/WorkflowPackageLoopReadiness.swift` | DONE | `WorkflowCommandTests` |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Workflow loop metadata | Existing workflow model and validation | Available |
| Evidence manifest model | Workflow/session model | Available |
| Snapshot persistence | Evidence manifest model | Available |
| CLI workflow/session projection | Snapshot persistence and projector | Available |
| GraphQL projection | Snapshot persistence and DTO models | Available |
| Gate enforcement | Gate model, projector, policy evaluator | Available |
| Package promotion checks | Workflow loop metadata and package loop metadata | Available |
| First-party loop template updates | Gate enforcement and usage projection | Available |

## Dependency Ordering

1. Add core models and compatibility tests.
2. Add workflow/step/package metadata decoding and validation.
3. Add evidence manifest, gate result, recovery lineage, and projector tests.
4. Add snapshot/file/SQLite persistence.
5. Add CLI inspection, usage, run, and session projections.
6. Add `riela loop` commands.
7. Add GraphQL DTO/schema projections.
8. Add policy preflight and required gate enforcement.
9. Add package promotion readiness checks.
10. Update first-party workflows only after runtime and tests are stable.

## Test Plan By Module

- Core model tests: `swift test --filter LoopEngineeringModelTests`
- Evidence projector tests: `swift test --filter LoopEvidenceProjectorTests`
- Runtime persistence tests: `swift test --filter RuntimeStoreTests`
- Runner recovery/policy tests:
  `swift test --filter DeterministicWorkflowRunnerTests`
- CLI parsing tests: `swift test --filter CommandParsingTests`
- CLI workflow/session tests: `swift test --filter WorkflowCommandTests`
- CLI live persistence tests:
  `swift test --filter WorkflowCommandLivePersistenceTests`
- GraphQL contract tests: `swift test --filter GraphQLContractsTests`
- Package command tests: `swift test --filter WorkflowCommandTests`
- Final acceptance after all slices: `swift test`

Latest validation slice ran focused validation tests, SwiftLint, and the full
Swift package test suite.

## Completion Criteria

- [x] Existing workflows without loop metadata still validate, run, inspect,
  rerun, and resume.
- [x] Loop metadata is projected by `workflow usage` and `workflow inspect`.
- [x] Loop evidence manifests persist through file and SQLite stores.
- [x] Gate results are structured and required review gates fail closed.
- [x] The first-line review gate accepts only with no high or medium findings.
- [x] Rerun/resume lineage is visible through CLI and GraphQL.
- [x] Process/mutation policy decisions are recorded, with required-loop
  preflight blocking unsupported configurations.
- [x] Package promotion readiness validates loop metadata, mock scenarios,
  expected results, gates, and usage contracts.
- [x] CLI, GraphQL, runtime, and package tests pass.
- [x] No unrelated dirty worktree changes are reverted.

## Migration And Backward-Compatibility Notes

- Optional fields must decode from absent data with nil/empty defaults.
- Existing SQLite runtime stores need in-place nullable-column migration.
- Existing `workflow usage`, `workflow inspect`, `workflow run`, and session
  JSON consumers must tolerate only additive optional fields.
- Package manifest loop metadata cannot be authored until
  `WorkflowPackageManifest` adds the key because manifest decoding currently
  rejects unsupported top-level keys.
- Existing workflows should not fail because loop metadata is absent.
- Required gate/policy fail-closed behavior applies only when authored loop
  metadata explicitly requires it.

## Progress Log

The detailed session log was split into [loop-engineering-first-line-tool-progress.md](loop-engineering-first-line-tool-progress.md) so this active implementation plan remains below 1000 lines.

## Related Plans

- **Previous**: `design-docs/specs/design-loop-engineering-first-line-tool.md`
- **Next**: implementation slices should be created from this active plan.
- **Depends On**: `design-docs/specs/design-workflow-usage-discovery.md`,
  `design-docs/specs/design-workflow-json.md`
