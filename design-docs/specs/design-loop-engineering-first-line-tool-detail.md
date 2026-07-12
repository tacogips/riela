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
  public var workflowMutation: LoopWorkflowMutationEvidence?
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
- `workflowMutation`: optional self-improve or in-place auto-improve
  change-set, snapshot, apply, and restore evidence when the loop mutates a
  workflow bundle.
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

## Workflow Self-Evolution And Version Safety

Workflow self-improvement should use the same evidence and gate discipline as
code-changing loops. The current reviewed mutation path records backups and
reports, but a first-line loop tool needs bundle-wide versioning rather than a
single-file backup.

Add an optional self-evolution contract under workflow loop metadata:

```json
{
  "loop": {
    "selfEvolution": {
      "allowed": true,
      "defaultMode": "propose",
      "requiresReviewGate": true,
      "snapshotPolicy": "bundle-before-apply",
      "historyRoot": ".riela/workflow-history",
      "immutablePackageMutation": "deny",
      "requiredVerification": ["workflow validate", "mock-scenario"]
    }
  }
}
```

Add runtime models:

```swift
public struct LoopWorkflowMutationEvidence: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var mode: String
  public var changeSetId: String?
  public var snapshotId: String?
  public var restoreId: String?
  public var transactionId: String?
  public var target: WorkflowBundleIdentity
  public var beforeBundleDigest: String?
  public var afterBundleDigest: String?
  public var review: WorkflowChangeSetReviewEvidence?
  public var validation: [LoopVerificationEvidence]
  public var applied: Bool
  public var restored: Bool
  public var outcome: String
  public var diagnostics: [String]
}

public struct WorkflowChangeProposal: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var proposalId: String
  public var sourceSessionId: String
  public var sourceStepId: String?
  public var target: WorkflowBundleIdentity
  public var beforeBundleDigest: String
  public var operations: [WorkflowFileOperation]
  public var expectedAfterBundleDigest: String
  public var rationale: String
  public var validation: [LoopVerificationEvidence]
  public var rejectedAlternatives: [String]
  public var createdAt: Date
  public var proposalDigest: String
}

public struct WorkflowChangeSet: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var changeSetId: String
  public var proposal: WorkflowChangeProposal
  public var review: WorkflowChangeSetReviewEvidence
  public var finalizedAt: Date
  public var finalizedDigest: String
}

public struct WorkflowBundleSnapshotManifest: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var snapshotId: String
  public var target: WorkflowBundleIdentity
  public var createdBySessionId: String?
  public var createdBeforeChangeSetId: String?
  public var createdBeforeRestoreId: String?
  public var createdAt: Date
  public var bundleDigest: String
  public var files: [WorkflowBundleSnapshotFile]
  public var retentionClass: String
  public var redactionStatus: String
  public var integrityAlgorithm: String
  public var complete: Bool
}

public struct WorkflowRestoreRecord: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var restoreId: String
  public var target: WorkflowBundleIdentity
  public var sourceSnapshotId: String
  public var preRestoreSnapshotId: String
  public var requestedBundleDigest: String
  public var beforeBundleDigest: String
  public var resultBundleDigest: String?
  public var approved: Bool
  public var dirtyConflictPolicy: String
  public var observedDirtyConflicts: [String]
  public var restoredFiles: [String]
  public var skippedFiles: [String]
  public var validation: [LoopVerificationEvidence]
  public var transactionId: String
  public var startedAt: Date
  public var completedAt: Date?
  public var outcome: String
  public var diagnostics: [String]
}
```

The supporting value contracts are normative, not abbreviated aliases:

- `WorkflowBundleIdentity` contains workflow id, source scope, source kind,
  canonical workflow directory, canonical ownership root, canonical package
  directory when present, package name/version when present,
  `workflowContractVersion`, and source mutability. Equality requires every
  field to match; paths are normalized absolute paths resolved without a
  trailing separator.
- `WorkflowFileOperation` contains a normalized relative path, operation kind,
  expected before content digest and executable bit when a file exists, and
  expected after content digest, byte count, artifact kind, and executable bit
  when a file will exist. Create and delete encode the absent side as `nil`.
  An operation whose after side exists resolves its proposed bytes only through
  the immutable proposal object whose digest equals `expectedAfterContentDigest`;
  an operation never carries or accepts a mutable source path at apply time.
- `WorkflowChangeSetReviewEvidence` contains gate id, gate-result id, decision,
  reviewed proposal id, reviewed proposal digest, reviewed before bundle digest,
  reviewer step id, reviewer step-execution id, reviewed-at timestamp, and
  evidence references. Only an `accepted` decision whose proposal id, proposal
  digest, and before digest exactly match the immutable proposal authorizes
  finalization. Review evidence never names the not-yet-created change-set id.
- `WorkflowBundleSnapshotFile` contains normalized relative path, content
  digest, byte count, artifact kind, and executable bit. Snapshot content is
  addressed by this record and never by an unchecked path supplied by a user.

All history records use one pinned JSON representation: UTF-8, lexicographically
sorted object keys by Unicode scalar value, arrays in the canonical order
specified by the contract, RFC 3339 UTC timestamps with exactly three
fractional-second digits, lowercase hexadecimal SHA-256 digests, no escaped
solidus, and no insignificant whitespace or trailing newline. File operations
and snapshot files sort by normalized relative-path UTF-8 bytes; conflicts and
restored/skipped paths sort by normalized relative-path UTF-8 bytes; diagnostics
sort by diagnostic code then message; evidence references sort by type then id.
Required fields never receive decode defaults. The decoder rejects duplicate
normalized paths, duplicate ids, noncanonical ordering, unsupported schema
versions, unknown operation/outcome values, and any persisted digest that does
not match the canonical input defined below. Canonical re-encoding integrity is
checked against the SHA-256 of the exact persisted record bytes, not against an
unspecified in-memory model.

Snapshot semantics:

- Snapshot the whole workflow bundle before applying a reviewed mutation:
  `workflow.json`, node files, prompt files, nested workflow directories owned
  by the bundle, mock scenarios, `EXPECTED_RESULTS.md`, package metadata, and
  executable file bits.
- Store snapshots under `.riela/workflow-history/<workflow-id>/snapshots/` for
  project workflows and under the user data root for user-scope workflows.
  `<workflow-id>` is encoded as one safe path component; user input never
  becomes an unchecked history path.
- Treat installed package workflows as immutable by default. `workflow
  self-improve` should propose an overlay or package update instead of
  mutating the installed package directory unless an explicit update mode is
  implemented.
- Restore must check containment, ownership, and dirty destination files before
  writing. It fails closed unless the user supplies explicit restore approval.
- Package `version` is distribution metadata. Workflow behavior compatibility
  should use an authored `workflowContractVersion` plus bundle digests and
  snapshot ids.

### Bundle Identity, Ownership, And Snapshot Integrity

Version operations resolve the workflow through the same project, user, and
installed-package resolver as the other workflow commands. The resolved source
scope, canonical workflow directory, workflow id, package directory, package
name/version, and mutability are captured once and reused throughout the
operation. A later path lookup must not silently retarget the operation to a
different workflow with the same name.

The history store is outside the owned source bundle and is never itself part
of a snapshot. Every history read and write must pass both lexical containment
and symlink-resolved containment checks against the selected history root.
Snapshot ids and change-set ids are opaque, runtime-generated identifiers that
match a conservative safe-component grammar; they are not file paths, may not
contain separators or `..`, and must resolve to exactly one manifest in the
selected workflow's history.

Proposal ids use the same safe-component grammar and are stored beneath the
selected workflow history root with this fixed layout:

```text
proposals/<proposal-id>/proposal.json
proposals/<proposal-id>/proposal.sha256
proposals/<proposal-id>/objects/sha256/<first-two-hex>/<64-hex-digest>
```

`proposal.json` contains the exact canonical `WorkflowChangeProposal` bytes.
`proposal.sha256` contains the lowercase SHA-256 of those exact bytes followed
by one newline. This persisted-file digest is distinct from the internal
`proposalDigest`, which is recomputed with its own field omitted under the
digest rule below; both checks must pass. For every create or update operation,
the object path is derived only from the validated expected-after content
digest and contains exactly the raw
proposed file bytes as a regular, non-symlink file. Delete and executable-bit-
only operations have no new content object. Proposal creation writes all
objects and metadata to a temporary sibling directory, verifies raw-byte
digests and byte counts, reconstructs and verifies the expected-after bundle
from the current before bundle plus those objects, fsyncs, and atomically
publishes the directory. Before exclusive publication, every payload, digest
sidecar, and content object is made non-writable and every directory is made
non-writable; every later read descriptor-verifies those modes as part of
integrity. Publication makes the proposal directory immutable;
an existing proposal id is never overwritten or repaired in place.

Review, finalization, and apply each reread `proposal.json`, verify
`proposal.sha256`, require canonical re-encoding to reproduce the exact bytes,
derive every object path from its digest, reject links or non-regular objects,
and verify every object's raw-byte digest and byte count. Apply materializes
only these verified object bytes; it does not regenerate output from prompts,
the current worktree, or validation logs. Finalized change sets retain the
proposal id and digest binding, and proposal objects may not be collected while
referenced by a finalized change set, audit record, transaction, or retention
policy. Missing, extra, mutable, or corrupt required objects invalidate review,
finalization, and apply before source mutation.

The owned-file set is deterministic and explicit:

- include the resolved `workflow.json` and every regular file referenced by
  its node, prompt-template, shared-node, add-on, mock-scenario, or nested
  workflow declarations;
- include bundle-level `EXPECTED_RESULTS.md` and package metadata only when
  they are inside the resolved ownership root;
- recursively include a declared nested workflow directory, applying the same
  containment and symlink rules;
- reject missing required files, paths outside the ownership root, symlinks
  that escape it, duplicate canonical paths, sockets/devices, and any file
  whose ownership cannot be established;
- sort normalized relative paths before digesting or encoding manifests; and
- record for every file its normalized relative path, content digest, byte
  count, artifact kind, and executable-bit state. The bundle digest is derived
  from this canonical ordered metadata and content, so chmod-only changes are
  observable.

For an authored workflow that uses `nodeRef`, the supported transitive
shared-node graph is also a pinned bundle input. Inventory records the selected
shared workflow declarations, referenced node payloads, and payload-referenced
prompt/script/source files under a reserved virtual relative-path namespace.
Those entries participate in the bundle digest and snapshot objects, but are
dependency evidence rather than restore destinations. Staged validation builds
an isolated resolution layout containing the staged target plus those exact
pinned dependency bytes. Missing, changed, cyclic, escaping, or ambiguous
shared-node dependencies fail proposal, snapshot, staging, apply, and restore
preflight closed.

Each snapshot has this fixed layout beneath the selected, contained history
root:

```text
snapshots/<snapshot-id>/manifest.json
snapshots/<snapshot-id>/manifest.sha256
snapshots/<snapshot-id>/objects/sha256/<first-two-hex>/<64-hex-digest>
```

`manifest.json` is the canonical `WorkflowBundleSnapshotManifest`. Each file
record names a content digest; lookup derives the object path only from the
validated 64-character lowercase hexadecimal digest. Objects contain exactly
the raw file bytes and are regular, non-symlink files. Identical content may be
hard-linked or copied within a snapshot, but restore behavior does not depend
on global deduplication. Executable state exists only in the manifest and is
reapplied after object bytes are materialized. `manifest.sha256` contains the
lowercase SHA-256 of the exact `manifest.json` bytes followed by one newline.

The following persisted digest inputs are exhaustive:

- `contentDigest` = SHA-256 of the exact raw file bytes.
- `bundleDigest` = SHA-256 of canonical JSON for an object containing
  `schemaVersion`, canonical target identity fields that affect ownership,
  `workflowContractVersion`, and `files`; each sorted file entry contains only
  normalized relative path, content digest, byte count, artifact kind, and
  executable bit. Snapshot ids, proposal/change-set ids, sessions, timestamps,
  retention, and redaction fields are excluded.
- `proposalDigest` = SHA-256 of canonical JSON for the complete
  `WorkflowChangeProposal` with only `proposalDigest` omitted. Proposal id,
  target identity, before/expected-after bundle digests, operations, rationale,
  validation, source references, rejected alternatives, and creation timestamp
  are included.
- `proposalFileDigest` = the value stored in `proposal.sha256` and equals
  SHA-256 of the exact canonical `proposal.json` bytes, including the persisted
  `proposalDigest`. It is a sidecar integrity value, not a model field.
- `finalizedDigest` = SHA-256 of canonical JSON for the complete
  `WorkflowChangeSet` with only `finalizedDigest` omitted. It therefore binds
  the immutable proposal value and its content-object digests, accepted review
  evidence, change-set id, and finalization timestamp.
- `manifestDigest` is the value stored in `manifest.sha256` and equals SHA-256
  of the exact canonical `manifest.json` bytes, including `snapshotId` and all
  manifest metadata. It is not the bundle digest.
- audit and transaction record digests, when persisted, equal SHA-256 of their
  exact canonical record bytes with only their own digest field omitted.

Snapshot creation writes objects and the manifest to a temporary directory
under the history root, verifies each object's raw-byte digest and byte count,
verifies the reconstructed bundle digest and executable-bit metadata, writes
and verifies `manifest.sha256`, fsyncs, then atomically publishes the immutable
snapshot directory. Read, list, show, diff, and restore first verify the
manifest byte digest, decode and canonically re-encode to the identical bytes,
validate every derived object path, and verify all referenced object bytes.
Snapshot, proposal, and finalized change-set reads descriptor-enumerate the
complete directory topology. They require exactly the canonical directories
and files, reject every unexpected directory or entry, and reject links plus
all non-regular/non-directory types including FIFOs, sockets, and devices.
A partial snapshot is never eligible for use. Retention cleanup may only remove
complete snapshots not referenced by an in-progress mutation or restore record.
The final immutable-directory publication uses a filesystem no-replace rename;
check-then-rename is not sufficient. The canonical record, sidecar, and objects
therefore become visible as one directory, and concurrent publishers of the
same opaque id cannot replace or mix one another's bytes.

### Apply And Restore Transaction Protocol

Multi-file atomicity means Riela readers observe either the complete before
bundle or the complete verified after bundle; it does not claim that arbitrary
external processes are covered by one portable filesystem syscall. Apply and
restore use the same recoverable directory transaction. All Riela
resolution/version/run entry points first invoke phase-aware recovery from the
stable target metadata and selected history root, including when the live tree
is absent; they refuse the target only when recovery cannot prove and complete
a safe terminal state.

The transaction coordinator performs these ordered phases:

1. Before any fallible mutation preflight, durably publish a canonical
   preflight-attempt operation record binding operation kind, target, expected
   before/after digests, snapshot authority, and transaction id. A failed
   preflight finalizes that record as failed with diagnostics and explicitly
   records that no mutation occurred. Attempt persistence and transitions are
   idempotent only for exact immutable intent; an audit write failure stops the
   operation before mutation and fails closed.
2. Acquire an exclusive per-canonical-target lock whose pathname is derived
   only from the canonical ownership target and lives in a descriptor-pinned,
   owner-only system lock namespace; the lock is independent of configured
   history root and working directory and does not modify the target tree.
   Open it through a pinned parent descriptor with `O_NOFOLLOW`, before reading
   or mutating any transaction state. Re-resolve identity,
   ownership, mutability, current digest, dirty conflicts, and review/approval.
   Refuse cross-device staging and any pre-existing nonterminal transaction.
3. Publish each transaction phase as an immutable generation directory under
   the history root. A generation contains the canonical record and its exact
   SHA-256 sidecar, is fully written and fsynced while private, and becomes
   non-writable before becoming visible through one exclusive
   descriptor-relative directory rename. Every read verifies the generation
   directory, payload, and sidecar type and non-writable mode. The
   generation record binds id, operation kind, target identity, reviewed
   change-set or restore ids, before/expected-after digests, pre-operation
   snapshot id, staging path, rollback path, and phase. Recovery accepts only
   a gap-free, canonically named, digest-valid generation chain with identical
   immutable fields and allowed phase transitions; incomplete, extra,
   ambiguous, or tampered generations fail closed. The active history marker
   is only a stable transaction-id pointer and does not duplicate mutable
   phase. Readers of legacy split-written records reconcile only adjacent
   monotonic phase states whose immutable transaction fields match exactly.
4. Build a sibling staging directory on the target filesystem. Materialize a
   complete copy of the ownership root, including unowned regular files that
   are inside it, then change only reviewed owned paths. Unowned files are
   inventoried by path, type, digest, and mode; symlinks and special files fail
   closed. Recheck that every unowned entry is unchanged before commit.
5. Validate the staged owned bundle, verify its expected digest and modes, and
   fsync staged files/directories. Set and fsync phase `prepared`. No live path
   has changed before this point.
6. Set and fsync phase `committing`; rename the live ownership root to the
   reserved sibling rollback path; set and fsync `live_moved`; rename the
   staged root to the canonical live path; fsync the parent; then set and fsync
   `published`. These two same-filesystem directory renames are the commit
   boundary. The lock and nonterminal marker prevent Riela from observing the
   transient path state.
7. Re-resolve the published tree, verify identity, owned and unowned files,
   bundle digest, and executable bits. Append the mutation or restore audit
   record, set and fsync `committed`, then remove the rollback tree. Cleanup
   never precedes durable audit completion.

At startup and before any operation on the target, recovery reads the durable
transaction directory under the target lock. It securely enumerates and
canonically validates every complete transaction generation, recovers the one
nonterminal record even when `active.json` was not yet published, and fails
closed if multiple records are nonterminal or the pointer and records are
ambiguous. A transaction-presence or recovery-integrity failure for a selected
project candidate is terminal candidate-resolution state; `auto` scope must not
fall through to a same-named user workflow. Recovery verifies any tree used in
a decision against the record's before or
expected-after inventory, including unowned entries. `preparing` or `prepared`
removes staging only after proving live is the before tree and rollback is
absent. Recovery is phase-aware: it never applies a later phase's matrix to an
earlier durable phase. `published` verifies live as the expected-after tree and
rollback as the before tree, then completes audit and commit; a mismatch stops
fail-closed without deleting either tree.

For durable phase `committing`, only two path states are normal because the
second rename is forbidden until `live_moved` has been fsynced:

| L | R | S | Required `committing` recovery decision |
|---|---|---|---|
| present | absent | present | This is the pre-first-rename window: require L to equal before and S to equal expected after, remove S, fsync, and append a rolled-back recovery record. |
| absent | present | present | The first rename completed before `live_moved` was persisted: require R to equal before and S to equal expected after, rename R to L, fsync, remove S, fsync, and append a rolled-back recovery record. |

Every other `committing` existence state fails closed without deletion or
rename because it cannot result from the phase's permitted operations. In
particular, recovery does not reinterpret `L=present, R=absent, S=present` as a
`live_moved` state and does not require rollback evidence before the first
rename. A rolled-back record binds the transaction id, observed durable phase,
verified before and expected-after inventories, path state, and recovery time.

For `live_moved`, recovery uses this exhaustive existence matrix, where L is
the canonical live path, R the reserved rollback path, and S the staging path:

| L | R | S | Required recovery decision |
|---|---|---|---|
| absent | absent | absent | Fail closed; neither before nor after tree exists. |
| absent | absent | present | Fail closed; the verified before tree is missing. |
| absent | present | absent | Verify R as before, rename R to L, fsync, record rolled back. |
| absent | present | present | Verify R as before and S as expected after; rename R to L, fsync, then remove S and record rolled back. |
| present | absent | absent | Fail closed; rollback evidence is missing even if L verifies. |
| present | absent | present | Fail closed; rollback evidence is missing and state is ambiguous. |
| present | present | absent | This is the normal second-rename-completed window: require L to equal expected after and R to equal before, advance durably to `published`, then verify/audit/commit. |
| present | present | present | Fail closed; all three names cannot result from the specified rename sequence. |

In every row, a failed identity, inventory, content, mode, containment, or
digest check changes the decision to fail closed. Recovery never treats mere
path presence as integrity evidence. Every recovery transition and parent
directory rename is fsynced and appended to the audit record. Manual repair is
required for fail-closed rows, and recovery never guesses or deletes evidence.

The selected history root is pinned by descriptor before writes begin. All
history component traversal/creation uses `openat`/`mkdirat` with `O_NOFOLLOW`
and `fstat`; record writes, sidecar writes, fsync, unlink, and immutable
snapshot/proposal/change-set publication use descriptor-relative operations
through that pinned root. Replacing an absolute ancestor therefore cannot
redirect publication outside the selected history tree.

The pre-operation snapshot remains the durable rollback authority. The sibling
rollback tree exists only for interruption recovery at the commit boundary.
Both apply and restore record attempted, committed, recovered, or failed
outcomes, and a record may claim success only after post-publish verification.

### Reviewed Change-Set And Apply Contract

`workflow self-improve --dry-run` is the mandatory proposal phase. It performs
no source-bundle mutation and emits and durably stores immutable canonical
`WorkflowChangeProposal` bytes containing target identity, before bundle
digest, normalized proposed operations, expected after digests and executable
bits, rationale, validation evidence, source references, and proposal digest.
The proposal contains no review evidence. Proposed operations are limited to
create, update, delete, and executable-bit change within the owned workflow
root.

Proposal generation consumes `workflow.json` through a descriptor-relative
`O_NOFOLLOW` open and verifies the bytes, byte count, digest, and executable
state against the already-secured inventory entry before deriving proposed
bytes. It never performs a later path-based `Data(contentsOf:)` reread.

Recovery retries accept an existing transaction, mutation, or restore audit
only when the complete canonical value equals the deterministic retry intent.
This equality binds kind, target, snapshot/change-set/review identifiers,
before/result digests, verification, diagnostics, and restored/skipped/conflict
sets. The pre-existing completion timestamp may be reused solely to reproduce
the same restore value; it cannot weaken comparison of any other field.

The lifecycle is one-way and non-circular:

1. Proposal creation assigns `proposalId`, canonicalizes once, computes
   `proposalDigest` with that field omitted, stores the exact bytes, and makes
   them immutable.
2. The review gate reads those exact stored bytes, independently recomputes the
   proposal digest, and accepts or rejects that `proposalId` and digest. Its
   signed/structured result also binds the before bundle digest. Review cannot
   rewrite or enrich the proposal.
3. Only an accepted gate result may create a `WorkflowChangeSet`. Finalization
   embeds the exact proposal value and review result, assigns `changeSetId` and
   `finalizedAt`, computes `finalizedDigest`, writes immutable canonical bytes,
   and verifies both digests by reread. Rejection creates no apply artifact.
4. Apply accepts only a finalized change-set identifier plus its expected
   finalized digest. It rereads the immutable bytes and verifies proposal,
   review binding, finalized digest, gate policy, and current before digest.

Thus the gate approves immutable proposal bytes through `proposalDigest`; it
does not approve a mutable filename or a change-set that already contains the
gate's own result. Any byte change creates a different proposal digest and
requires a new review.

`workflow self-improve --yes` does not regenerate or broaden the proposal. It
applies the finalized reviewed change set only after re-resolving the target
and proving that its canonical identity, mutability, owned-file set, and
current digest still match the proposal. It then:

1. captures and verifies the complete pre-mutation snapshot;
2. stages the proposed result without changing the source;
3. runs the required workflow validation and configured mock-scenario checks
   against the staged bundle;
4. commits the staged ownership-root tree with the recoverable directory
   transaction, preserving reviewed executable bits and every unowned file;
   and
5. records mutation evidence that binds the change-set id, snapshot id,
   before/after digests, reviewer gate, validation evidence, and outcome.

Any identity drift, dirty conflict, digest mismatch, unreviewed operation,
failed verification, immutable package source, containment failure, or
snapshot failure aborts before source mutation. If a failure occurs after the
write phase begins, recovery uses the verified pre-mutation snapshot and
records the failed apply and recovery outcome; it never relies on mutable
single-file backup metadata.

Installed-package workflows remain readable by version commands but are not
valid mutation or restore destinations. An eventual overlay or package-update
mode must create or install a distinct mutable target and must not weaken this
rule implicitly.

### Version Command Contract

All commands return structured results in JSON mode and stable human-readable
summaries otherwise. They use the resolved workflow identity and selected
history root, and fail closed on malformed manifests, unknown snapshot ids,
workflow-id mismatch, source-scope mismatch, containment failure, or digest
failure.

- `riela workflow versions <workflow>` lists complete snapshots newest first,
  with snapshot id, creation time, source scope/kind, package provenance,
  contract version, bundle digest, creating session/change-set ids, retention,
  and integrity status. It does not mutate or repair history.
- `riela workflow version show <workflow> <snapshot-id>` verifies and returns
  the manifest plus its ordered file metadata and mutation/restore references.
- `riela workflow version diff <workflow> <from> <to>` accepts snapshot ids;
  the explicit token `current` may represent the currently resolved mutable
  bundle. It reports added, removed, content-modified, and executable-bit-only
  changes using normalized relative paths. It never materializes files into
  the source bundle.
- `riela workflow restore <workflow> <snapshot-id>` is a dry run. It verifies
  snapshot integrity and destination identity, computes the exact restore
  change set, reports dirty conflicts and validation work, and performs no
  source or history write.
- `riela workflow restore <workflow> <snapshot-id> --yes` is the only mutating
  restore form. Approval is non-interactive and explicit; omission never
  prompts or implies consent. Before writing, it requires a mutable non-package
  destination, rechecks containment and ownership, rejects dirty destination
  paths that differ from both the current manifest and proposed restore set,
  and captures a fresh pre-restore snapshot. It stages and validates the
  restored bundle, commits it through the recoverable directory transaction,
  restores executable bits, verifies the resulting bundle digest, and writes a
  `WorkflowRestoreRecord` referencing both the source snapshot and pre-restore
  snapshot.

Restore does not erase or rewrite prior snapshots. `WorkflowRestoreRecord`
captures a generated restore id, workflow identity, source snapshot id,
pre-restore snapshot id, requested/current/result digests, approval, dirty
conflict policy and observed conflicts, restored/skipped files, validation
evidence, timestamps, outcome, and diagnostics. A failed restore record is
auditable but never claims `restored == true`.

### Design Traceability And Open Questions

- `issueReference`: `null`. No GitHub URL, repository-plus-number, or other
  issue mapping was supplied, so this design does not invent one.
- `riskLevel`: `null`. No explicit risk classification was supplied. The
  unresolved classification does not relax the fail-closed controls or the
  required adversarial tests in this section.
- `codexAgentReferences`: `[]`. There is no Codex-agent reference repository
  behavior to port. Cursor CLI mapping is intentionally empty: no Cursor CLI
  command or Codex-agent adapter behavior is added; runtime code owns identity,
  validation, review binding, snapshot, transaction, mutation, and restore.

### Compatibility And Rollout Constraints

- New history models use explicit schema versions, deterministic encoding, and
  decode defaults only for fields that are genuinely optional. Unknown future
  schema versions fail closed for mutation and restore.
- Existing runtime snapshots without `workflowMutation` continue to decode;
  absence means no recorded workflow mutation, not an empty successful one.
- Existing single-file self-improve backup/report data may be displayed as
  legacy evidence but is not accepted as a bundle snapshot or restore target.
- The versioning feature lands behind the existing workflow command surface;
  no Cursor CLI behavior or Codex-agent adapter behavior is introduced. Agent
  output may propose changes, while identity resolution, review binding,
  snapshotting, validation, mutation, and restore remain runtime-owned.
- Implementation is complete only with deterministic model round trips,
  success tests, and negative tests for traversal/symlink escape, wrong
  ownership, immutable package sources, stale review/digest, incomplete or
  corrupt snapshots, missing approval, dirty conflicts, and executable-bit
  restoration.

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

Phase 5: workflow self-evolution safety.

- Add `WorkflowChangeSet` and `WorkflowBundleSnapshotManifest`.
- Upgrade `workflow self-improve` to propose/review/apply/restore semantics.
- Add workflow version listing, diff, and restore CLI commands.
- Link self-improve and in-place auto-improve mutations into loop evidence.

Phase 6: first-party loop templates.

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
- No claim that package metadata version alone is workflow version control.
- No `workflow.json`-only backup for workflow self-evolution; bundle behavior
  is defined by workflow JSON, nodes, prompts, mocks, expected results, and
  package metadata together.
