# Loop Engineering First-Line Tool Implementation Plan

**Status**: In Progress
**Design Reference**: `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`
**Created**: 2026-06-25
**Last Updated**: 2026-07-11

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

### 8. Workflow Self-Evolution Versioning

**Status**: IMPLEMENTED — ROUND 7 ADVERSARIAL FINDINGS RESOLVED

**Source of truth**:

- `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`,
  especially **Workflow Self-Evolution And Version Safety**, **Bundle Identity,
  Ownership, And Snapshot Integrity**, **Apply And Restore Transaction
  Protocol**, **Reviewed Change-Set And Apply Contract**, and **Version Command
  Contract**.
- `issueReference`: `null`; no issue mapping is invented.
- `codexAgentReferences`: `[]`; no Codex-agent or Cursor CLI behavior is being
  ported. Runtime-owned identity, review binding, validation, history,
  transaction, mutation, and restore behavior is intentional.

#### Task 8.1: Core history contracts and canonical persistence

**Write scope**: `Sources/RielaCore/WorkflowHistoryModels.swift`, new focused
RielaCore history/canonical-coding files, and corresponding
`Tests/RielaCoreTests` files.

**Deliverables**:

- [x] Add the complete normative contracts for `WorkflowBundleIdentity`,
  `WorkflowFileOperation`, `WorkflowChangeProposal`,
  `WorkflowChangeSetReviewEvidence`, `WorkflowChangeSet`,
  `WorkflowBundleSnapshotFile`, `WorkflowBundleSnapshotManifest`,
  `WorkflowRestoreRecord`, and `LoopWorkflowMutationEvidence`.
- [x] Implement the pinned canonical JSON representation, canonical ordering,
  safe-component/path validation, schema-version rejection, duplicate
  rejection, enum/outcome validation, and exact persisted-byte integrity
  checks specified by the design.
- [x] Implement the distinct content, bundle, proposal, proposal-file,
  finalized, manifest, audit, and transaction digest inputs without merging
  their meanings.
- [x] Preserve decoding of runtime snapshots with absent `workflowMutation`;
  legacy single-file backups remain display-only and cannot become restore
  targets.
- [x] Add deterministic Codable, canonical byte fixture, digest, invalid order,
  duplicate path/id, unsupported schema, and legacy compatibility tests.
- [x] Pin independent canonical byte/digest fixtures plus missing-required-field,
  unknown-enum, Unicode scalar key-order, and digest-input exclusion coverage.

#### Task 8.2: Identity, owned-file inventory, proposal, and snapshot stores

**Depends on**: Task 8.1.

**Write scope**: new focused files under `Sources/RielaCLI` for workflow
identity/inventory and history storage, plus corresponding `Tests/RielaCLITests`
files. Keep `WorkflowSelfImproveVersioning.swift` as orchestration rather than
allowing it to exceed 1000 lines.

**Deliverables**:

- [x] Resolve and pin project, user, and installed-package identity through the
  existing workflow resolver, including canonical ownership/package roots,
  contract version, provenance, and mutability.
- [x] Discover the deterministic owned-file set, including declared nested
  workflows, package metadata only inside the ownership root, mock scenarios,
  `EXPECTED_RESULTS.md`, content metadata, and executable bits; reject missing,
  duplicate, escaping, symlink-escaping, special, or unowned artifacts.
- [x] Implement contained history-root selection and the fixed immutable
  proposal/snapshot layouts. Derive object paths only from validated SHA-256
  values and reject links, non-regular objects, corrupt bytes, partial records,
  and unsafe identifiers.
- [x] Publish proposal and snapshot directories atomically from temporary
  siblings only after object, byte-count, canonical record, sidecar, bundle
  digest, fsync, and completeness checks pass. Never overwrite or repair an
  immutable published id in place.
- [x] Exclude history storage from the owned bundle and prevent collection of
  records still referenced by change sets, audits, transactions, or retention.
- [x] Resolve and pin the transitive supported `nodeRef` dependency graph into
  bundle inventory/digest, snapshot objects, drift checks, and isolated staged
  resolution; shared dependencies remain evidence, not restore destinations.
- [x] Publish immutable snapshot/proposal/change-set directories with a
  filesystem no-replace rename so concurrent same-id publication cannot
  overwrite or mix canonical records and sidecars.
- [x] Pin the canonical history-root descriptor and traverse/create history
  components with descriptor-relative no-follow operations; publish records,
  snapshots, proposals, change sets, sidecars, fsyncs, and unlinks through
  pinned descriptors so ancestor replacement cannot redirect publication.

#### Task 8.3: Recoverable apply/restore directory transaction

**Depends on**: Tasks 8.1 and 8.2.

**Write scope**: new focused transaction/coordinator files under
`Sources/RielaCLI` and corresponding focused `Tests/RielaCLITests` files.

**Deliverables**:

- [x] Implement exclusive per-target locking, nonterminal transaction markers,
  same-filesystem sibling staging/rollback paths, durable phase transitions,
  fsync boundaries, and refusal by workflow resolution/version/run entry
  points while a target has a nonterminal marker.
- [x] Stage the complete ownership root, preserve and inventory unowned regular
  files, reject unowned symlinks/special files, validate staged owned content,
  and recheck unowned entries immediately before commit.
- [x] Implement the ordered `preparing`, `prepared`, `committing`, `live_moved`,
  `published`, and `committed` protocol and append durable mutation, restore,
  failure, rollback, and recovery audit records.
- [x] Implement the design's exhaustive phase-aware recovery matrices exactly;
  verify identity, inventories, modes, containment, and digests before any
  recovery rename or deletion, and fail closed on every unspecified or
  ambiguous state.
- [x] Treat the pre-operation snapshot as rollback authority; never substitute
  the sibling rollback tree or legacy single-file backup metadata for it.
- [x] Invoke phase-aware recovery from the shared workflow resolver before
  resolution, version inspection/restore, and run operations, using stable
  target metadata even when the canonical live tree is absent.
- [x] Keep phase in gap-free immutable transaction generations, each publishing
  its canonical record and SHA-256 sidecar through one directory rename; select
  only a complete canonical generation chain and fail closed on ambiguity or
  tampering. Keep the stable active pointer id-only, retain legacy adjacent
  monotonic split-write reconciliation, and order terminal cleanup so either
  the stable marker or active pointer can still drive safe completion.
- [x] Derive the advisory lock only from canonical ownership target, independent
  of history root and working directory, and acquire it descriptor-safely before
  transaction-state resolution or mutation.
- [x] Under the target lock securely enumerate and validate every durable
  transaction record, recover a lone orphan record without `active.json`, and
  fail closed on multiple or pointer-ambiguous nonterminal records.
- [x] Treat transaction recovery failures as terminal during auto-scope
  candidate resolution so a corrupt project target cannot retarget to user
  scope.
- [x] Require exact deterministic canonical equality for pre-existing
  transaction/mutation/restore audits, including kind, snapshot/change-set/
  review bindings, digests, verification, diagnostics, and restored-file sets.

#### Task 8.4: Reviewed self-improve proposal/finalize/apply lifecycle

**Depends on**: Tasks 8.1 through 8.3 and the existing gate/evidence runtime.

**Write scope**: `Sources/RielaCLI/WorkflowSelfImproveVersioning.swift`, focused
support files under `Sources/RielaCLI`, required loop-evidence integration under
`Sources/RielaCore`, and corresponding focused tests.

**Deliverables**:

- [x] Make `workflow self-improve --dry-run` a non-mutating proposal phase that
  durably stores canonical immutable proposal bytes and verified content
  objects; the proposal contains no review evidence.
- [x] Bind review to the exact proposal id, proposal digest, and before-bundle
  digest. Finalize only accepted review evidence into an immutable change set;
  rejection produces no apply artifact.
- [x] Make `workflow self-improve --yes` accept only a finalized change-set id
  and expected finalized digest, reread every persisted artifact/object, and
  reject identity drift, stale digest/review, broadened operations, dirty
  conflict, immutable package source, containment failure, or snapshot failure.
- [x] Capture and verify the complete pre-mutation snapshot, stage only verified
  proposal objects, run required validation and mock scenarios against staging,
  then commit through Task 8.3 while preserving reviewed modes and unowned
  files.
- [x] Persist `LoopWorkflowMutationEvidence` binding change set, snapshot,
  transaction, before/after digests, reviewer gate, validation, and truthful
  outcome. Replace rollback references with snapshot ids.
- [x] Deny installed-package mutation. A future explicit overlay/update mode
  must create a distinct mutable target; this task does not add an implicit
  exception.
- [x] Derive proposal bytes only after a descriptor-relative no-follow reread
  exactly matches the inventoried workflow bytes, digest, size, and mode.

#### Task 8.5: Version inspection and restore commands

**Depends on**: Tasks 8.1 through 8.3. May proceed in parallel with Task 8.4
after the shared APIs from Tasks 8.1 through 8.3 are stable because its write
scope is disjoint.

**Write scope**: `Sources/RielaCLI/WorkflowVersionCommands.swift`, command parser
and dispatch integration, and dedicated parser/command tests.

**Deliverables**:

- [x] Add `riela workflow versions <workflow>`, newest complete snapshots first,
  with stable human output and structured JSON.
- [x] Add `riela workflow version show <workflow> <snapshot-id>` with full
  manifest/object integrity verification and mutation/restore references.
- [x] Add `riela workflow version diff <workflow> <from> <to>`, supporting the
  explicit `current` token only for a resolved mutable bundle and reporting
  add/remove/content/mode-only changes without source materialization.
- [x] Make `riela workflow restore <workflow> <snapshot-id>` a write-free dry
  run that verifies integrity/identity and reports the exact restore set,
  conflicts, and required validation.
- [x] Make `riela workflow restore <workflow> <snapshot-id> --yes` the only
  mutating form. Recheck identity, containment, ownership, mutability, package
  source, approval, and dirty conflicts; capture a fresh pre-restore snapshot;
  stage/validate/commit through Task 8.3; restore executable bits; verify the
  final digest; and persist a truthful `WorkflowRestoreRecord` referencing both
  source and pre-restore snapshots.
- [x] Never prompt for approval, rewrite history, repair malformed snapshots,
  or claim `restored == true` after a failed restore.

#### Task 8.6: Focused adversarial and success verification

**Depends on**: Tasks 8.1 through 8.5.

**Deliverables**:

- [x] Add success coverage for deterministic model round trips, proposal review
  and finalization, complete snapshot creation, reviewed project-workflow apply,
  list/show/diff, dry-run restore, approved restore, executable-bit-only diff
  and restoration, audit/evidence binding, and interruption recovery.
- [x] Add negative coverage for lexical traversal, symlink escape, wrong
  ownership, unsafe ids, immutable package sources, stale identity/review/
  digest, missing/extra/mutable/corrupt proposal objects, incomplete/corrupt
  snapshots, the verified same-device sibling staging boundary (without
  claiming a synthetic cross-device mount test), nonterminal transactions, missing approval,
  dirty conflicts, validation failure, unowned-file drift, special files, and
  every fail-closed transaction recovery matrix row.
- [x] Cover all eight `committing` and all eight `live_moved` path-existence
  rows, including verified rollback/commit outcomes and fail-closed evidence
  preservation for every unspecified row.
- [x] Cover durable audit failure followed by recovery completion, advisory
  lock crash release with a stale lock pathname, verified pre-operation
  snapshot mismatch, and configured history-root active-marker refusal.
- [x] Verify snapshot and proposal exact-file enumeration rejects symbolic
  links on the original enumerated URL before any canonicalization.
- [x] Inject interruption after every transaction record, marker, rename,
  audit, rollback unlink, and marker unlink boundary; recover each state through
  the public `workflow validate` command surface, including live-absent state.
- [x] Read history records, digest sidecars, immutable objects, declarations,
  and inventory content with descriptor-relative `openat(O_NOFOLLOW)` plus
  `fstat`, and cover deterministic leaf-swap races.
- [x] Run required staged mock scenarios through agent, stdio, and add-on
  scenario wiring; reject missing entries and unconsumed required responses.
- [x] Run SwiftLint and split every modified Swift file over 1000 lines by
  responsibility before handoff.
- [x] Assert every durability boundary leaves a terminal record, matching
  operation/transaction audits, cleared active/stable markers, and no bypass
  by a second transaction while unresolved.
- [x] Cover orphan/multiple transaction records, project-to-user fallback
  refusal, concurrent same-id publication, shared-node mutation/drift/snapshot/
  staging, secure proposal leaf swap, and adversarial audit-field mismatches.
- [x] Inject faults between transaction payload and sidecar construction for
  every durable phase and recover through public validation, including the
  live-absent rename window; cover same-target/different-history-root lock
  refusal and deterministic history/target ancestor replacement for records,
  snapshots, proposals, and locks.
- [x] Make every transaction generation payload and sidecar non-writable before
  publication, make the published generation directory non-writable, verify
  type/mode on every read, and constrain verification/diagnostic evolution
  field by field without dropping either field from transition comparison.
- [x] Descriptor-enumerate the complete snapshot, proposal, and finalized
  change-set topology; require exactly canonical directories/files and reject
  independent FIFO, Unix-socket, unexpected-directory, link, and device-style
  entries.
- [x] Durably publish an idempotent preflight-attempt operation record before
  mutability, digest, lock, existing-transaction, snapshot-authority, or locked
  inventory checks; finalize preflight failures without claiming mutation and
  fail closed when initial or failure-audit persistence fails.

#### Task 8.7: Plan synchronization and progress evidence

**Depends on**: Task 8.6.

**Deliverables**:

- [x] Update each Task 8.1-8.6 checkbox and module status only from verified
  evidence; do not mark a slice complete because code merely exists.
- [x] Append dated progress-log entries to
  `impl-plans/active/loop-engineering-first-line-tool-progress.md` containing
  changed paths, behavior completed, exact verification commands/results,
  remaining work, failures, and any accepted divergence from the design.
- [x] Keep `design-docs/specs/design-incomplete-work-inventory.md` synchronized
  with the verified implementation state and preserve unrelated worktree edits.

### 9. Tests

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
| Workflow self-evolution versioning | `Sources/RielaCore/WorkflowHistoryModels.swift`, `Sources/RielaCLI/WorkflowSelfImproveVersioning.swift`, `Sources/RielaCLI/WorkflowVersionCommands.swift` | IMPLEMENTED — ROUND 7 REVIEW FINDINGS RESOLVED | focused model, immutable-generation, exact-topology, preflight-attempt, transaction, self-improve, version-command, recovery-matrix, audit-failure, staged-mock, and special-file tests |

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
| Workflow self-evolution models and storage | Evidence manifest, workflow resolver, package provenance/mutability, canonical SHA-256 support | Implemented |
| Recoverable bundle transaction | Canonical identity, owned-file inventory, snapshots, filesystem locking/fsync/rename support | Implemented |
| Reviewed self-improve apply | History models/store, gate evidence, recoverable transaction, existing self-improve command surface | Implemented |
| Version inspection and restore | History models/store, resolver, snapshot verifier, recoverable transaction | Implemented |

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
11. Add canonical workflow history models and compatibility tests.
12. Add pinned identity, owned-file inventory, proposal/snapshot stores, and
    integrity tests.
13. Add the recoverable directory transaction and exhaustive phase recovery
    tests.
14. After shared APIs stabilize, implement reviewed self-improve apply and
    version/restore commands in parallel only where write scopes remain
    disjoint.
15. Run the complete success/adversarial matrix, synchronize the inventory and
    plan, and record exact evidence in the progress log.

## Parallelizable Work

- Task 8.1 is not parallelizable with dependent production work because its
  canonical contracts and digest rules define every later persisted artifact.
- After Task 8.1 contracts stabilize, independent test-fixture preparation for
  model coding and invalid canonical inputs may proceed alongside Task 8.2 only
  when the files are disjoint.
- Task 8.3 begins only after Task 8.2 storage/identity APIs stabilize.
- Tasks 8.4 and 8.5 may proceed in parallel after Task 8.3, provided Task 8.4
  owns self-improve/evidence files and Task 8.5 owns version-command/parser
  files; shared support files require serialized ownership.
- Task 8.6 may partition core model tests, self-improve tests, version-command
  tests, and transaction recovery tests only when each partition has disjoint
  test files and does not edit shared fixtures.
- Task 8.7 is serialized after verification so plan state reflects evidence.

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
- Workflow history model tests:
  `swift test --filter WorkflowHistoryModelsTests`
- Workflow self-improve versioning tests:
  `swift test --filter WorkflowSelfImproveVersioningTests`
- Workflow version command tests:
  `swift test --filter WorkflowVersionCommandsTests`
- Workflow directory transaction/recovery tests:
  `swift test --filter WorkflowDirectoryTransactionTests`
- Modified Swift file size check:
  `git diff --name-only --diff-filter=ACMR -- '*.swift' | xargs -r wc -l`
- SwiftLint for repository-local configuration: `swiftlint lint --strict`
- Diff hygiene for the complete Section 8 scope:
  `git --no-optional-locks diff --no-ext-diff --no-textconv --check`
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
- [x] Workflow self-improve captures bundle-wide snapshots, records reviewed
  change-sets, and supports list/show/diff/restore version commands.
- [x] Canonical history bytes, sidecars, ids, object paths, ownership,
  containment, file modes, and every specified digest input are deterministic
  and fail closed when invalid.
- [x] Dry-run proposal and restore paths perform no source/history mutation
  except the design-authorized immutable proposal publication for self-improve
  dry run; restore dry run remains entirely write-free.
- [x] Apply and restore mutate only mutable non-package targets after exact
  review/approval binding, complete verified snapshots, staged validation, and
  recoverable transaction commit.
- [x] Phase-aware recovery passes every specified normal matrix row and leaves
  every ambiguous or unverifiable row untouched with auditable diagnostics.
- [x] Success and negative tests cover all accepted-design cases, SwiftLint is
  clean, no modified Swift file exceeds 1000 lines, the full Swift suite passes,
  and the plan/incomplete-work inventory match verified reality.

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
