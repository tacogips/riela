# Work Handover and Takeover Implementation Plan

**Status**: Planning
**Workflow Mode**: feature
**Feature Fanout**: true — seven phases H0–H7; H0 and H1 first, then H2/H3/H4/H5 in parallel, then H6, then H7
**Design Reference**: `design-docs/specs/design-work-handover-and-takeover.md` (all sections)
**Created**: 2026-09-30
**Last Updated**: 2026-09-30 (no code written)

---

## Design Document Reference

**Source**: `design-docs/specs/design-work-handover-and-takeover.md`

### Summary

When an attempt of a Work Runtime task stalls because it needs the user (an
answer, or the user's presence on the host), or because its owner died, the
runtime seals a durable, digest-signed `HandoverPacket` (work state, bounded
history, deliverable locators, a rendered brief), publishes the attempt's
repository branch, and lets another worker, on the same host or another,
reserve a `takeover` attempt that materializes the branch, imports the
history, receives the answer, and continues from the resume step. Leases gain
heartbeat, expiry and a fence so a dead owner can be taken over safely and a
late owner fences itself out.

### Scope

**Included**: session `suspended` status and `SuspendRecord`; `stalled` and
`leaseLost` failure kinds; `HandoverPacket` model, builder, brief renderer,
`work_handovers` table; `AttemptEntry.takeover`, `DecisionKind.handover|answer|
takeover`, `WaitReason.handover`, evidence kinds `handover|handoverAnswer|
publication|leaseFence`; triggers (output envelope `handover`, add-on
`riela/handover-request@1`, backend wait-signal classifier, inactivity
policy, operator commands); answer channel and injection; history import
from suspended sessions and from a bundle; `GitBranchWorkspaceRuntime`
(branch, checkpoint, publish, materialize) and `riela/git-publish-branch@1`;
document deliverable collection and `output.projection.deliverables`;
lease heartbeat/expiry/fence and `task reconcile`; sinks (store, kaiba,
gitRef, file, command); host traits and trait-aware placement; GraphQL
handover fields over `/graphql`; remote takeover with heartbeat and report;
`task serve --takeover`; session adoption (`session handover`); examples,
skills, catalog rows, docs, `riela gc`.

**Excluded**: `cancelled` session status (cancellation stays
`failed(.cancelled)`); `session fork` and `idleSuspendMs`; the execution
environment consolidation's definition store, `WorkspaceDefinition`, policy
engine and model profiles; P3 chat intake and `MonjaTrackerAdapter`; the
full P5 GraphQL task API and task board beyond the handover fields; vendor
thread (`backendSessionId`) continuation across hosts; copying cwd-local
memory/KV into packets; force-push or publication outside `riela/task/*`.

---

## Applicable Prior Knowledge

- Closed enums decode strictly (`WorkModels.swift:4-5`); every new case
  must be added to the `Kind` mirror enums and their encode/decode switches,
  and tests must cover round-trips.
- `swift test`, `swiftlint` and debug binaries must run under an arm64
  shell: `arch -arm64 /bin/zsh -lc '…'`.
- Register every new example in `rielaExampleWorkflowNames()` and the mock
  count, and run `RielaCLITests`; add catalog rows for every new CLI/GraphQL
  surface and regenerate the SDL after DTO/catalog changes (control-surface
  parity gates).
- Loop lease heartbeat and stale takeover (`SQLiteWorkflowRuntimePersistenceStore.swift:466-600`)
  are the model for `work_leases` heartbeat; the incarnation/token fence in
  `DistributedJobController` is the model for the attempt fence.
- `RuntimeHistoryImport` (`docs/preserved-history-recovery.md`) defines
  what an imported execution may and may not carry; the packet's history
  bundle must be exactly that shape.
- Fanout change capture (`WorkflowFanoutChangeEvidence.swift`) is reused
  for `snapshot` and `dirtyPaths`; its bounds (512 paths, 8 MB/file, 64 MB)
  apply.

---

## Task Breakdown

| Phase | Tasks | Parallel with |
| --- | --- | --- |
| H0 | T0.1 session suspend model, T0.2 resume from suspended, T0.3 failure kinds | — |
| H1 | T1.1 handover models, T1.2 store table and queries, T1.3 packet builder + brief, T1.4 attempt/decision/evidence extensions, T1.5 same-store `task takeover` (no deliverables) | — |
| H2 | T2.1 envelope, T2.2 add-on, T2.3 wait-signal classifier, T2.4 inactivity policy, T2.5 `task handover`, T2.6 run event + notification | H3, H4, H5 |
| H3 | T3.1 `task answer`, T3.2 answer injection, T3.3 history import from suspended/bundle, T3.4 session adoption | H2, H4, H5 |
| H4 | T4.1 `GitBranchWorkspaceRuntime`, T4.2 attempt branch + `Attempt.isolation`, T4.3 checkpoints, T4.4 publish + `riela/git-publish-branch`, T4.5 materialize at takeover, T4.6 worker allowance, T4.7 document deliverables | H2, H3, H5 |
| H5 | T5.1 lease columns + heartbeat, T5.2 owner-side fence check, T5.3 `--force-orphan`, T5.4 `task reconcile`, T5.5 superseded reconciliation | H2, H3, H4 |
| H6 | T6.1 sinks, T6.2 host traits + placement, T6.3 GraphQL fields, T6.4 remote takeover/heartbeat/report, T6.5 `task serve --takeover` | after H2–H5 |
| H7 | T7.1 examples, T7.2 skills + docs, T7.3 catalog rows + SDL, T7.4 `riela gc`, T7.5 final verification | after H6 |

---

## Modules

### 1. Session suspend (H0)

#### Sources/RielaCore/RuntimeSession.swift

**Status**: NOT_STARTED

```swift
public enum WorkflowSessionStatus: String, Codable, Sendable, CaseIterable {
  case created, running, suspended, completed, failed
}
public enum WorkflowStepExecutionStatus: String, Codable, Sendable {
  case running, suspended, completed, skipped, failed
}
extension WorkflowSessionFailureKind {
  public static let stalled: WorkflowSessionFailureKind
  public static let leaseLost: WorkflowSessionFailureKind
}
public struct SuspendRecord: Codable, Equatable, Sendable {
  public var reason: HandoverReasonRecord   // Core-side mirror of RielaWork.HandoverReason (RielaCore never imports RielaWork)
  public var stepId: String
  public var stepExecutionId: String?
  public var question: HandoverQuestion?
  public var presence: PresenceRequirement?
  public var progressNote: String?          // ≤ 8 KiB
  public var suspendedAt: Date
  public var producer: SuspendProducer      // stepExecution(id) | runtime | human(principal)
}
extension WorkflowSession { public var suspend: SuspendRecord? }
```

`HandoverQuestion`, `HandoverOption`, `PresenceRequirement`, `HostTrait`
live in RielaCore (`Sources/RielaCore/HandoverContracts.swift`) because the
runner, adapters and RielaWork all read them.

**Checklist**:
- [ ] Add `suspended` to both status enums; audit every `switch` on them (runner, store, observability rendering, GraphQL projector, web DTOs)
- [ ] `SuspendRecord`, `HandoverQuestion`, `HandoverOption`, `PresenceRequirement`, `HostTrait` with strict Codable and round-trip tests
- [ ] `WorkflowSession.suspend`; generated `session_status` columns accept `suspended`
- [ ] Schema generation 8 → 9 in `SQLiteWorkflowRuntimePersistenceStore.swift:115`; discard-on-mismatch behavior unchanged
- [ ] `stalled` and `leaseLost` failure kinds; `LoopOutcome` mapping keeps `stalled` for `loopNotConverging` and adds nothing (outcome notifications get `handover` in T2.6)

#### Sources/RielaCore/DeterministicWorkflowRunner+Suspend.swift (new)

**Status**: NOT_STARTED

```swift
extension DeterministicWorkflowRunner {
  /// Ends the current step as `.suspended`, persists the session as `.suspended`
  /// with `record`, emits `WorkflowRunEvent.handover`, and returns without advancing.
  func suspendSession(_ record: SuspendRecord) async throws -> DeterministicWorkflowRunResult
}
```

**Checklist**:
- [ ] Persist order: step execution `.suspended` → session `.suspended` + `suspend` → run event
- [ ] `DeterministicWorkflowRunResult` gains `.suspended(SuspendRecord)`; CLI exit code for a suspended run is a new `CLIExitCode.suspended` (non-zero, distinct from failure)
- [ ] Unit tests with the in-memory store and the SQLite store

#### Sources/RielaCLI/SessionCommands.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] `blocksResume` returns false for `suspended`; resume re-enters `suspend.stepId`
- [ ] When `suspend.question` is set and no answer variable is supplied, print the question, options and the `riela task answer` hint (or `--variables handover.answer=…` for plain sessions) and exit `suspended` without running
- [ ] `session status|progress|health|export` render `suspend`
- [ ] Tests: resume-from-suspended happy path, refused-without-answer path

---

### 2. Handover model, store and builder (H1)

#### Sources/RielaWork/WorkHandover.swift (new)

**Status**: NOT_STARTED

```swift
public struct HandoverID: Hashable, Codable, Sendable { public var rawValue: String }
public enum HandoverReason: Codable, Equatable, Sendable {
  case userInputRequired(HandoverQuestion)
  case userPresenceRequired(PresenceRequirement)
  case ownerLost(OwnerLossEvidence)
  case inactivity(stepId: String, idleMs: Int)
  case operatorMove(reason: String)
}
public struct OwnerLossEvidence: Codable, Equatable, Sendable { attemptId, lastHeartbeatAt, expiredAt, fence, forcedBy }
public struct HandoverPacket: Codable, Equatable, Sendable { … as design §4 … }
public struct HandoverProgress, HandoverStepSummary, HandoverHistoryBundle, HandoverContinuationContract, HandoverAnswer, BudgetSnapshot
public enum DeliverableRef { repository(RepositoryDeliverable), document(DocumentDeliverable), artifactBundle(ArtifactBundleRef), localOnly(LocalOnlyDeliverable) }
public enum PublicationState: Codable, Equatable, Sendable { published, checkpointFailed(reason: String), unpublished(lastKnown: String?) }
public enum HandoverSinkKind: String { store, kaiba, gitRef, file, command }
public struct HandoverSinkRef { kind, locator, digest, writtenAt }
public struct HandoverPolicy: Codable, Equatable, Sendable { onInactivity, onWaitSignal, checkpoint, sinks, publish, notify }
public struct LeasePolicy: Codable, Equatable, Sendable { ttlMs: Int = 300_000, heartbeatMs: Int = 15_000 }
public struct HandoverBounds { static let acceptedOutputBytes = 32_768, responseExcerptBytes = 4_096, historyBytes = 2_097_152, variablesBytes = 262_144, briefBytes = 65_536, packetBytes = 4_194_304 }
```

**Checklist**:
- [ ] All enums with `Kind` mirrors and strict decode; round-trip tests for every case
- [ ] `HandoverPacket.canonicalJSON()` and `digest` via a new `JSONCanonical.swift` in RielaCore (sorted keys, ISO-8601, integers only); the environment consolidation reuses it
- [ ] `GuardPolicy` gains `lease: LeasePolicy` and `handover: HandoverPolicy` with defaults; existing fixtures decode with defaults only where the design allows (strict: fixtures are updated)

#### Sources/RielaWork/WorkModels.swift, WorkDecision.swift, WorkEvidence.swift

**Status**: NOT_STARTED

```swift
public enum AttemptEntry { …; case takeover(fromAttemptId: AttemptID, handoverId: HandoverID) }
public enum DecisionKind { …; case handover(HandoverReason); case answer(HandoverAnswer); case takeover(handoverId: HandoverID, placement: TakeoverPlacement) }
public enum WaitReason { …; case handover(HandoverID) }
public enum EvidenceKind { …; case handover, handoverAnswer, publication, leaseFence }
public struct TakeoverPlacement { hostId, requiredTraits: Set<HostTrait>, backend: NodeExecutionBackend?, model: String? }
public struct TakeoverLineage: Codable, Equatable, Sendable { fromAttemptId, handoverId, hops: Int }
extension Attempt { public var takeoverLineage: TakeoverLineage? }
extension WorkTask { public var fence: Int }
```

**Checklist**:
- [ ] Cases added to every `Kind` mirror, `CodingKeys`, encode and decode switch
- [ ] `TaskState.waiting` reason rendering in `task show` includes `handover(<id>)`
- [ ] `WorkStore.dispatchEligibleStates` unchanged; `reserveAttempt` accepts `.takeover` entries only when the task is `waiting(.handover)` or `scheduled` with a pending takeover reservation, and only when the lease is absent or expired (H5 adds the fence bump)
- [ ] Tests: reservation refuses takeover on a live lease; accepts on `waiting(.handover)`

#### Sources/RielaWork/WorkStore+Schema.swift, WorkStore+Handovers.swift (new)

**Status**: NOT_STARTED

```sql
CREATE TABLE IF NOT EXISTS work_handovers (
  handover_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  from_attempt_id TEXT NOT NULL,
  successor_attempt_id TEXT,
  reason_kind TEXT GENERATED ALWAYS AS (json_extract(record, '$.reason.kind')) STORED,
  digest TEXT NOT NULL,
  record BLOB NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_work_handovers_task ON work_handovers (task_id, created_at);
```

```swift
extension WorkStore {
  func saveHandover(_ packet: HandoverPacket) throws
  func loadHandover(id: HandoverID) throws -> HandoverPacket?
  func latestHandover(taskId: TaskID) throws -> HandoverPacket?
  func listHandovers(taskId: TaskID) throws -> [HandoverPacket]
  func attachSuccessor(handoverId: HandoverID, attemptId: AttemptID) throws
  func recordSinkRefs(handoverId: HandoverID, refs: [HandoverSinkRef]) throws
  func tasksAwaitingHandover(traits: Set<HostTrait>) throws -> [TaskHandoverSummary]
}
```

**Checklist**:
- [ ] Table added to the schema list (`WorkStore+Schema.swift:202-214`) and to the generation-9 creation path
- [ ] Insert of packet + decision + evidence + task state change in one transaction (`sealHandover`, below)
- [ ] Tests over SQLite: save/load digest equality, list order, successor attach idempotency

#### Sources/RielaWork/HandoverPacketBuilder.swift (new)

**Status**: NOT_STARTED

```swift
public protocol HandoverSessionSource: Sendable {                 // injected; RielaCLI implements over CLIWorkflowSessionStore
  func snapshot(sessionId: String) async throws -> WorkflowRuntimePersistenceSnapshot
  func messages(sessionId: String) async throws -> [WorkflowMessageRecord]
}
public struct HandoverPacketBuilderInput: Sendable {
  var task: WorkTask; var attempt: Attempt; var reason: HandoverReason
  var resumeStepId: String; var deliverables: [DeliverableRef]
  var hostId: String; var producer: EvidenceProducer; var now: Date
  var redaction: HandoverRedactionRules
}
public struct HandoverPacketBuilder: Sendable {
  public init(store: WorkStore, sessions: HandoverSessionSource, workflowGraph: WorkflowGraphReader)
  public func build(_ input: HandoverPacketBuilderInput) async throws -> HandoverPacket
}
public struct HandoverBriefRenderer { public static func render(_ packet: HandoverPacket) -> String }   // fixed Markdown template, ≤ 64 KiB
public struct HandoverRedactionRules { secretEnvNames: Set<String>; boundValues: Set<String> }           // from node env bindings and agent-environment redaction
```

**Checklist**:
- [ ] Accepted-step summaries, remaining steps from a graph walk (`WorkflowRequirements.successors` seam), latest gate results, open findings, evidence counts, remaining budget from the guard coordinator's accounting
- [ ] History bundle: accepted prefix executions stripped exactly as `RuntimeHistoryImport` strips (backend, backendSessionId, backendWorkingDirectory, usage, live events), messages addressed to `resumeStepId` and later, compatibility digests
- [ ] Redaction of `variables` and of message payload strings equal to bound secret values
- [ ] Bounds with truncation markers; `truncated: true` on history overflow
- [ ] Determinism test: two builds from the same inputs produce the same digest; golden brief fixture

#### Sources/RielaWork/HandoverCoordinator.swift (new)

**Status**: NOT_STARTED

```swift
public struct HandoverCoordinator: Sendable {
  /// Publish deliverables, build the packet, write the store row, decision and evidence,
  /// move the task to waiting(.handover) — one transaction for the store part.
  public func seal(task: WorkTask, attempt: Attempt, reason: HandoverReason, resumeStepId: String,
                   publisher: DeliverablePublisher?, sinks: [HandoverSink]) async throws -> HandoverPacket
  /// Reserve a takeover attempt for a packet on this host.
  public func reserveTakeover(handoverId: HandoverID, placement: TakeoverPlacement, producer: DecisionProducer) async throws -> AttemptReservation
}
```

**Checklist**:
- [ ] Order per design §5: publish → build → store row + decision(`.handover`) + evidence(`.handover`) + task `waiting(.handover)` → session `suspended`/`failed`
- [ ] Sink writes after the store transaction; failures recorded as `.publication` evidence, never fail the seal
- [ ] Budget carried: `HandoverContinuationContract.guardPolicy` and `BudgetSnapshot` computed from the ledger
- [ ] Tests: seal without publisher (H1), seal with a failing sink, reserveTakeover refused on a live lease

#### Sources/RielaCLI/TaskCommands.swift, TaskDispatch.swift (H1 slice)

**Status**: NOT_STARTED

```swift
public enum TaskCommandKind: String { case show, list, run, decide, handover, takeover, answer, handovers, reconcile }
struct TaskTakeoverOptions { taskId; packet: String?; endpoint: URL?; forceOrphan: Bool; cloneInto: String?; workingDirectory: String? }
```

**Checklist**:
- [ ] `task takeover` (same store): load packet → local placement → `reserveTakeover` → dispatch through the existing `TaskDispatch.run` path with `entryStepId = packet.contract.resumeStepId` and `AttemptEntry.takeover`
- [ ] `task handovers` list; `task show` gains `handovers`, `lease`, `suspend`
- [ ] Attempt variables: `handover` (packet minus history), `handover.brief`
- [ ] Tests: `TaskDispatcherIntegrationTests` takeover from a sealed packet with no deliverables continues at the resume step; evidence lineage A → B

---

### 3. Triggers (H2)

#### Sources/RielaCore/RuntimeOutputExtraction.swift, HandoverEnvelope.swift (new)

**Status**: NOT_STARTED

```swift
public struct HandoverEnvelope: Codable, Equatable, Sendable {
  public var reason: HandoverEnvelopeReason          // userInputRequired | userPresenceRequired
  public var question: HandoverQuestion?
  public var presence: PresenceRequirement?
  public var progressNote: String?
  public var resumeStepId: String?
  public static let jsonSchema: JSONObject
}
public struct OutputEnvelopeNormalization { public var payload: JSONObject; public var handover: HandoverEnvelope? }
```

**Checklist**:
- [ ] `normalizeOutputContractEnvelope` extracts and validates `handover` before business validation; malformed → `validationRejected`
- [ ] `handover` becomes a reserved key in validate-time diagnostics (`riela workflow validate` rejects an `output.jsonSchema` that declares a `handover` property)
- [ ] Runner: accepted output with an envelope → accept business payload (when `resumeStepId` names a downstream step) or mark the step `suspended` (default) → `suspendSession`
- [ ] Outside a task: suspend and print the `riela session handover` hint; inside a task: `HandoverCoordinator.seal`
- [ ] Tests: envelope on a state-2 node, on a state-3 node, malformed envelope, downstream `resumeStepId`

#### Sources/RielaCLI/ProductionNodeAdapter+HandoverRequestAddon.swift (new), Sources/RielaAddons/RielaAddons.swift

**Status**: NOT_STARTED

```swift
// riela/handover-request@1  config/inputs: reason, question, presence, progressNote, resumeStepId
// output: { status: "handover-requested", addon, stepId, handoverId }
```

**Checklist**:
- [ ] Catalog entry, validation of config, `policyBlocked` outside a task attempt
- [ ] Runner treats the accepted output as a handover request identical to the envelope path
- [ ] Tests: validate/inspect, mock execution, non-task refusal

#### Sources/RielaAdapters/BackendWaitSignalClassifier.swift (new)

**Status**: NOT_STARTED

```swift
public struct BackendWaitSignal: Equatable, Sendable { public var presence: PresenceRequirement; public var eventType: String; public var observedAt: Date }
public protocol BackendWaitSignalClassifier: Sendable { func classify(_ event: WorkflowBackendEvent, backend: NodeExecutionBackend) -> BackendWaitSignal? }
public struct TableBackendWaitSignalClassifier: BackendWaitSignalClassifier { public init(table: [NodeExecutionBackend: [String: PresenceRequirement]]) }
```

**Checklist**:
- [ ] Per-adapter table filled from each adapter's event enum (codex, claude, cursor); official SDK backends map to nothing
- [ ] Runner: classified signal + no progress for `stallTimeoutMs` (now honored from `WorkflowStepRef.stallTimeoutMs`, else `guard.inactivity`) → cancel node → `seal(reason: .userPresenceRequired)`
- [ ] `SessionBackendActivityVerdict` gains `awaiting-user` for observability
- [ ] Tests with recorded event fixtures per adapter; unclassified events fall through to inactivity

#### Sources/RielaWork/DeterministicDirector.swift, TaskGuardCoordinator.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] `inactivity-*` rule reads `handover.onInactivity`: `rerun` (unchanged) | `handover` → `Decision.handover(.inactivity)` | `stop`
- [ ] Session persisted `failed(.stalled)` on the handover branch
- [ ] Tests for the three actions

#### Sources/RielaCLI/TaskCommands.swift (`task handover`), TaskRunCancellation.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] `task handover <taskId> --reason … [--now] [--to …] [--sink …]` records a durable `HandoverRequest` row (`work_handover_requests`, same shape as cancellation requests)
- [ ] The owner's `TaskRunCancellation` observer sees the request at the next step boundary (or immediately with `--now`) and calls `seal(reason: .operatorMove)`
- [ ] Tests: cooperative boundary handover, `--now` interruption

#### Sources/RielaCore/WorkflowRunEvent.swift, Sources/RielaCLI/LoopNotificationDispatcher.swift

**Status**: NOT_STARTED

```swift
case handover = "handover"
case handover(SessionEnvelope, HandoverEventPayload)   // handoverId, reason kind, question text, locators, brief head (2 KiB)
```

**Checklist**:
- [ ] Event emitted at seal; JSONL recorder and `session progress --follow` render it
- [ ] `LoopOutcome` gains `handover`; dispatcher sends at seal time with the same targets
- [ ] Tests: event ordering, notification payload

---

### 4. Answers, history import, adoption (H3)

#### Sources/RielaCLI/TaskCommands.swift (`task answer`), Sources/RielaWork/WorkStore+Decisions.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] Payload from `--answer-json|--answer-file|--text|--option|--use-default`; validated against `answerSchema` with `DefaultWorkflowOutputValidator`
- [ ] `Decision.answer` + `Evidence.handoverAnswer` + pending reservation with `entry: .takeover`; task `waiting(.handover)` → `scheduled`
- [ ] Agent director: `answer` allowed only when `director.agentWorkflow` policy lists it; `TaskView` gains `pendingQuestion`
- [ ] Tests: schema-rejected answer, option answer, default answer, director answer

#### Sources/RielaCLI/TaskDispatch.swift (answer injection)

**Status**: NOT_STARTED

**Checklist**:
- [ ] Takeover attempt receives `handover.answer` variable and a `delivered` message `{ "handover": { "answer": … } }` to `resumeStepId` before the first step runs (through the existing message log + `RuntimeMessageInputResolver`)
- [ ] Plain session resume accepts `--variables handover.answer=…` equivalently
- [ ] Tests: the resume step's `inputSnapshot` contains the answer

#### Sources/RielaCore/RuntimeHistoryImport.swift

**Status**: NOT_STARTED

```swift
public struct WorkflowHistoryImportInput { …; public var source: HistoryImportSource }   // .session(id) | .bundle(HandoverHistoryBundle)
```

**Checklist**:
- [ ] Accept sources with status `suspended`, `failed(.stalled)`, `failed(.leaseLost)` in addition to `failed`
- [ ] Bundle source: same invariants (accepted prefix, one communication per accepted step, compatibility digests) evaluated against the bundle, not the live store
- [ ] `importedFrom` records `handoverId` beside source session/execution ids
- [ ] Tests: import from suspended session; import from bundle; digest mismatch refused; truncated bundle refused with a diagnostic naming the store

#### Sources/RielaCLI/SessionCommands.swift (`session handover`), Sources/RielaWork/TaskAdoption.swift (new)

**Status**: NOT_STARTED

```swift
public struct TaskAdoption { public func adopt(session: WorkflowSession, workflow: WorkflowReference, workingDirectory: String, principal: String) throws -> (Intent, WorkTask, Attempt) }
```

**Checklist**:
- [ ] Creates intent + task + terminal attempt pointing at the existing session in one transaction; `contextSnapshot` evidence `adoptedFromSession`
- [ ] `session handover` = adopt + `seal`
- [ ] Refuses sessions that are `completed`, or `running` with a live execution lock
- [ ] Tests: adopt a suspended plain session, then `task takeover` continues it

---

### 5. Deliverables (H4)

#### Sources/RielaCLI/GitBranchWorkspaceRuntime.swift (new), Sources/RielaWork/WorkspaceHandoverRuntime.swift (protocol, new)

**Status**: NOT_STARTED

```swift
public protocol WorkspaceHandoverRuntime: Sendable {
  func ensureBranch(root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?, isolation: RepositoryIsolation, template: String) async throws -> IsolationRef
  func checkpoint(_ isolation: IsolationRef, message: String, trailer: String, paths: [String]?) async throws -> RevisionRef?
  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool, branchAllowlist: String) async throws -> PublishedRef
  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool, attempt: AttemptID) async throws -> IsolationRef
  func snapshot(_ isolation: IsolationRef, writeScopes: [String]) async throws -> ChangeSnapshot
}
public struct RevisionRef { sha: String }; public struct PublishedRef { remote: String; branch: String; sha: String; created: Bool }
public actor GitBranchWorkspaceRuntime: WorkspaceHandoverRuntime { init(git: GitCommandRunner, finalizationStore: GitFinalizationStore) }
```

**Checklist**:
- [ ] `ensureBranch`: in-place `checkout -b` (shared) or `worktree add -b` under `<root>/.riela/worktrees/<attemptId>` (worktree); refuses a dirty shared root unless `--allow-dirty`
- [ ] `checkpoint`: stage tracked + untracked within write scopes, commit with trailer `Riela-Checkpoint: <attemptId>/<stepExecutionId>`, journaled through `GitFinalizationStore`; returns nil on nothing-to-commit
- [ ] `publish`: `push --set-upstream <remote> HEAD:<branch>` only when `branch` matches the allowlist glob; never `--force`; refuses when behind
- [ ] `materialize`: `fetch <remote> <branch>`, worktree or in-place checkout, records `IsolationRef`
- [ ] `snapshot` reuses `WorkflowFanoutChangeEvidence.capture`
- [ ] Tests against temporary git repositories with a bare remote: create, checkpoint, publish-create, publish-refuse-behind, materialize on a second clone

#### Sources/RielaCLI/TaskDispatch.swift (branch + checkpoints), Sources/RielaWork/TaskDispatcher.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] At attempt start with `ContextBinding.repository`: `ensureBranch` → `Attempt.isolation` set in the reservation transaction's follow-up update; `placement` evidence gains the branch
- [ ] `handover.checkpoint: stepBoundary` hook on accepted step boundary; `everyMs` timer; both no-ops when the runtime reports nothing to commit
- [ ] `DeliverablePublisher` (RielaCLI) implements checkpoint → publish → `RepositoryDeliverable` with `state`; on failure `checkpointFailed(reason)`; when the owner is gone, `unpublished(lastKnown:)` + `dirtyPaths` from the last snapshot
- [ ] Publish re-checks the lease fence before pushing (H5 seam; stub in H4)
- [ ] Tests: attempt creates branch; two checkpoints; handover publishes; `task show` labels checkpoint commits

#### Sources/RielaCLI/ProductionNodeAdapter+GitPublishBranch.swift (new), Sources/RielaCLI/DistributedWorkerNodeExecutor.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] `riela/git-publish-branch@1`: config `allowCreateBranch`, `branchAllowlist` (default `riela/task/*`), `remote`; same runtime-identity requirement as `riela/git-push`; output `payload.git {operation:"publish", status, pushedRemote, pushedBranch, created}`
- [ ] Worker denial list: allow `riela/git-publish-branch` and runtime checkpoints; keep `riela/git-commit` and `riela/git-push` denied
- [ ] Tests: allowlist refusal, worker execution allowed

#### Sources/RielaCore/WorkflowNodeContracts.swift (`output.projection.deliverables`), Sources/RielaWork/DeliverableCollector.swift (new)

**Status**: NOT_STARTED

```swift
public struct WorkflowDeliverableProjection: Codable, Equatable, Sendable { public var store: String; public var instanceField: String?; public var idFields: [String] }
extension NodeOutputContract { public var deliverables: WorkflowDeliverableProjection? }
public struct DeliverableCollector { func collect(session: WorkflowRuntimePersistenceSnapshot) -> [DeliverableRef] }
```

**Checklist**:
- [ ] Builtin mappings for `kaiba/*` outputs (`noteId`, `notebookId`, instance) and gateway add-on outputs
- [ ] `localOnly` entries for `riela/memory-*` and `riela/kv-*` outputs (database paths)
- [ ] `riela workflow validate` warning when a task-eligible workflow uses memory/KV without a kaiba step
- [ ] Tests: collection from a mixed snapshot; validate warning

---

### 6. Leases and fencing (H5)

#### Sources/RielaWork/WorkStore+Schema.swift, WorkStore+Reservation.swift, WorkStore+Leases.swift (new)

**Status**: NOT_STARTED

```sql
ALTER work_leases: + heartbeat_at TEXT NOT NULL, expires_at TEXT NOT NULL, fence INTEGER NOT NULL DEFAULT 1, host_id TEXT NOT NULL
```

```swift
public struct AttemptLease: Codable, Equatable, Sendable { attemptId, taskId, sessionId, tokenDigest, fence, heartbeatAt, expiresAt, hostId }
extension WorkStore {
  func heartbeat(attemptId: AttemptID, fence: Int, now: Date, ttlMs: Int) throws -> Bool          // false = fenced out
  func expiredLeases(now: Date) throws -> [AttemptLease]
  func fenceLease(taskId: TaskID, expectedFence: Int, now: Date, producer: DecisionProducer) throws -> (AttemptLease, OwnerLossEvidence)   // fence + 1, refuses unexpired
}
```

**Checklist**:
- [ ] Reservation writes `fence = task.fence + 1`, `host_id`, `expires_at = now + ttl`; `WorkTask.fence` updated in the same transaction
- [ ] Heartbeat is `UPDATE … WHERE attempt_id = ? AND fence = ?`; zero rows = fenced
- [ ] Tests: heartbeat extends; fenced heartbeat returns false; `fenceLease` refuses an unexpired lease

#### Sources/RielaCLI/TaskRunCancellation.swift, WorkflowRunLivePersistence.swift

**Status**: NOT_STARTED

**Checklist**:
- [ ] Owner heartbeats on every snapshot save and on a `heartbeatMs` timer while a node runs
- [ ] Fenced → cancel the running node, persist `failed(.leaseLost)`, exit with the failure code; publication and checkpoint refuse after a fence loss
- [ ] Tests: simulated fence loss mid-node and at a boundary

#### Sources/RielaCLI/TaskCommands.swift (`--force-orphan`, `task reconcile`), Sources/RielaWork/WorkStore+Reservation.swift (superseded)

**Status**: NOT_STARTED

**Checklist**:
- [ ] `task takeover --force-orphan`: refuses unexpired; `fenceLease` → `leaseFence` evidence → seal from the last snapshot with `reason: .ownerLost` and `unpublished` deliverables → reserve takeover on this host
- [ ] `task reconcile [--expired-leases] [--dry-run]`: seal packets for every expired lease, task → `waiting(.handover)`, notifications fire, no successor chosen
- [ ] Late terminal snapshot from a fenced attempt reconciles as `superseded` (attempt outcome kept, not judged); `task show` labels it
- [ ] Tests: orphan takeover end to end; reconcile dry-run; superseded late arrival

---

### 7. Sinks, traits, GraphQL, remote takeover (H6)

#### Sources/RielaWork/HandoverSink.swift (protocol), Sources/RielaCLI/HandoverSinks/*.swift (new)

**Status**: NOT_STARTED

```swift
public protocol HandoverSink: Sendable {
  var kind: HandoverSinkKind { get }
  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef
  func read(_ ref: HandoverSinkRef) async throws -> Data
}
// StoreHandoverSink (always), KaibaHandoverSink (kaiba/note-create + attachment, tags riela-handover, task:<id>),
// GitRefHandoverSink (blob under refs/riela/handovers/<taskId>/<handoverId>, pushed with the branch),
// FileHandoverSink (<root>/handovers/<taskId>/<handoverId>.{json,md}), CommandHandoverSink (stdin packet, stdout id; --read <id>)
public struct HandoverSinkConfig: Codable { kind; kaibaInstanceId?; notebookId?; remote?; path?; command?: [String] }
```

**Checklist**:
- [ ] Config merge order task → workflow `handover` block → user config profile
- [ ] Locator parsing `kind:locator` and digest verification on read
- [ ] `task takeover --packet <locator|path>` reads through the matching sink
- [ ] Tests: each sink round-trips bytes and digest; kaiba sink uses the mock gateway; command sink with a fixture script

#### Sources/RielaCore/BackendCapability.swift, DistributedWorkerModels.swift, Sources/RielaWork/BackendCapabilityPlacement.swift, Sources/RielaCLI/HostCapabilityResolver.swift

**Status**: NOT_STARTED

```swift
extension HostCapabilitySnapshot { public var traits: Set<HostTrait> }
extension DistributedWorkerRegistration { public var traits: Set<HostTrait> }
extension BackendPlacementRequirements { public var requiredTraits: Set<HostTrait> }
// failure: "host-traits-unavailable: <list>"
```

**Checklist**:
- [ ] `worker.json` `traits`, `riela config set host.traits …`; declared only, never probed
- [ ] `riela doctor` and `task run --dry-run` show traits; `taskTopology` carries them
- [ ] Takeover placement requires `packet.reason`'s traits; S1 requires none
- [ ] Tests: resolver picks the reachable host; reports the failure shape

#### Sources/RielaGraphQL/TaskHandoverGraphQL.swift (new), GraphQLContractProjector+Schema.swift, Sources/RielaServer/ServeWebHost.swift

**Status**: NOT_STARTED

```graphql
type Query { taskHandover(taskId: ID!, handoverId: ID): HandoverPacket  tasksAwaitingHandover(traits: [HostTrait!]): [TaskHandoverSummary!]! }
type Mutation {
  requestTaskHandover(input: RequestTaskHandoverInput!): TaskHandoverResult!
  answerTask(input: AnswerTaskInput!): TaskDecisionResult!
  takeoverTask(input: TakeoverTaskInput!): TakeoverReservation!        # attemptId, fence, expiresAt, heartbeatToken
  heartbeatAttempt(attemptId: ID!, token: String!): LeaseState!
  reportAttempt(input: ReportAttemptInput!): AttemptReconciliation!    # outcome, evidence[], deliverables[], packet?
}
```

**Checklist**:
- [ ] Executable over `/graphql` in `riela serve` under the manager-session bearer (`WorkflowExecutionAuthorizationWrapper` pattern), not only via CLI parity commands
- [ ] `reportAttempt` bounded like a packet (4 MiB); reconciles through `TaskDispatch.reconcileTerminal` + guard/director as a local attempt
- [ ] Regenerate SDL; catalog rows; parity gates
- [ ] Tests: resolver tests per field; auth refusal; report reconciliation runs the director

#### Sources/RielaCLI/TaskCommands.swift (`--endpoint`), TaskServeTakeover.swift (new)

**Status**: NOT_STARTED

**Checklist**:
- [ ] `task takeover --endpoint`: fetch packet → `takeoverTask` → local session store execution → heartbeat loop → `reportAttempt` at terminal (or a new packet when the successor hands over)
- [ ] `task serve --takeover [--traits …] [--endpoint URL] [--poll-interval-ms]`: polls `tasksAwaitingHandover(traits:)`, takes tasks whose required traits it declares, one at a time
- [ ] Missed heartbeats expire the controller lease; a later takeover fences the successor
- [ ] Tests: two-store integration test (controller store + successor store) driven through the in-process GraphQL executor

---

### 8. Rollout (H7)

#### examples/task-handover-answer, examples/task-handover-presence, examples/task-handover-orphan

**Status**: NOT_STARTED

**Checklist**:
- [ ] Deterministic mock scenarios: envelope handover → `task answer` → takeover continues; presence handover refused locally, accepted with `--traits userReachable`; orphan takeover after simulated expiry
- [ ] Registered in `rielaExampleWorkflowNames()` and the mock count; `EXPECTED_RESULTS.md` per example

#### Skills, docs, catalog

**Status**: NOT_STARTED

**Checklist**:
- [ ] `riela-workflow-run`, `riela-workflow`, `riela-troubleshooting`, `riela-manager-control`, `riela-node-addons` updated (envelope, add-on, commands, statuses, mutations)
- [ ] `docs/work-handover.md` (operator guide: answer on the server, take over on the laptop, orphan recovery); `docs/distributed-workers.md` traits and worker git allowance
- [ ] Catalog rows for every CLI/GraphQL surface; SDL regenerated; parity gates green
- [ ] `riela gc` sweeps `handovers/` files and `refs/riela/handovers` for terminal tasks

---

## Module Status

| Module | File Path | Status | Tests |
| --- | --- | --- | --- |
| Session suspend | `Sources/RielaCore/RuntimeSession.swift`, `DeterministicWorkflowRunner+Suspend.swift`, `SessionCommands.swift` | NOT_STARTED | - |
| Handover models | `Sources/RielaWork/WorkHandover.swift`, `WorkModels.swift`, `WorkDecision.swift`, `WorkEvidence.swift` | NOT_STARTED | - |
| Handover store | `Sources/RielaWork/WorkStore+Schema.swift`, `WorkStore+Handovers.swift` | NOT_STARTED | - |
| Packet builder + brief | `Sources/RielaWork/HandoverPacketBuilder.swift`, `Sources/RielaCore/JSONCanonical.swift` | NOT_STARTED | - |
| Coordinator + same-store takeover | `Sources/RielaWork/HandoverCoordinator.swift`, `Sources/RielaCLI/TaskCommands.swift`, `TaskDispatch.swift` | NOT_STARTED | - |
| Triggers | `RuntimeOutputExtraction.swift`, `HandoverEnvelope.swift`, `ProductionNodeAdapter+HandoverRequestAddon.swift`, `BackendWaitSignalClassifier.swift`, `DeterministicDirector.swift`, `WorkflowRunEvent.swift`, `LoopNotificationDispatcher.swift` | NOT_STARTED | - |
| Answers + history + adoption | `TaskCommands.swift`, `TaskDispatch.swift`, `RuntimeHistoryImport.swift`, `TaskAdoption.swift`, `SessionCommands.swift` | NOT_STARTED | - |
| Deliverables | `GitBranchWorkspaceRuntime.swift`, `WorkspaceHandoverRuntime.swift`, `ProductionNodeAdapter+GitPublishBranch.swift`, `DistributedWorkerNodeExecutor.swift`, `DeliverableCollector.swift`, `WorkflowNodeContracts.swift` | NOT_STARTED | - |
| Leases | `WorkStore+Leases.swift`, `WorkStore+Reservation.swift`, `TaskRunCancellation.swift`, `WorkflowRunLivePersistence.swift` | NOT_STARTED | - |
| Sinks + traits + GraphQL + remote | `HandoverSink.swift`, `HandoverSinks/*.swift`, `BackendCapability.swift`, `BackendCapabilityPlacement.swift`, `TaskHandoverGraphQL.swift`, `TaskServeTakeover.swift` | NOT_STARTED | - |
| Rollout | `examples/task-handover-*`, skills, `docs/work-handover.md`, catalog, `riela gc` | NOT_STARTED | - |

## Dependencies

| Feature | Depends On | Status |
| --- | --- | --- |
| H0 | Work Runtime P1 (shipped), session schema generation 8 | Available |
| H1 | H0 | Planned |
| H2, H3, H4, H5 | H1 | Planned |
| H4 publish on workers | distributed workers (shipped) | Available |
| H6 GraphQL | NRE-01 auth wrapper (shipped) | Available |
| H6 kaiba sink | kaiba instances (shipped) | Available |
| Execution environment E2 | this plan's `GitBranchWorkspaceRuntime`, `refs/riela/handovers`, `riela/task/*` names | This plan lands first |
| Work Runtime P5 task API | this plan's handover GraphQL fields | This plan lands first |

## Verification

Run under an arm64 shell: `arch -arm64 /bin/zsh -lc '<command>'`.

- Build: `swift build`.
- Focused per phase: `swift test --filter RielaWorkTests`, `--filter RielaCoreTests/RuntimeHistoryImport`, `--filter RielaCLITests/TaskDispatcherIntegrationTests`, `--filter RielaCLITests/TaskCommandTests`, `--filter RielaAdaptersTests/BackendWaitSignal`, `--filter RielaGraphQLTests/TaskHandover`, `--filter RielaServerTests`.
- Git runtime tests use temporary repositories with a bare remote; no network.
- Examples: `riela workflow validate` for every bundle; `riela workflow run --mock-scenario` for the three examples; `RielaCLITests` example registry test.
- Parity: catalog gates, SDL regeneration diff empty, skills parity gate.
- Full: `swift test` serial; compare failures against the current baseline and classify.
- Lint: `swiftlint --strict` on touched files.
- Live check (manual, recorded under `tmp/work-handover/`): a task on host A hands over with the envelope; `task answer` on A; `task takeover --endpoint` on host B continues and reports; `task show` on A shows lineage A → B and the branch.

## Completion Criteria

- [ ] A task attempt that emits the `handover` envelope ends `suspended`, seals a packet with a stable digest, and `task show` lists it
- [ ] `task answer` + `task takeover` (same store) continues at the resume step with the answer in the step input and the history imported
- [ ] A repository task publishes `riela/task/<id>/g<n>` at handover; a takeover on a second clone materializes it and continues
- [ ] An attempt whose owner is killed is taken over with `--force-orphan` after expiry; the killed owner, if revived, fails with `leaseLost`
- [ ] A presence handover is refused on a host without `userReachable` and accepted on one with it
- [ ] Remote takeover over `/graphql` heartbeats and reports; the controller runs verification and director on the reported outcome
- [ ] kaiba, gitRef, file and command sinks round-trip the packet with digest verification
- [ ] Three examples pass in mock mode; skills, docs, catalog rows and SDL updated; full `swift test` has no new failures against baseline

## Progress Log

### Session: 2026-09-30
**Tasks Completed**: Design and plan authored; no code written
**Tasks In Progress**: None
**Blockers**: Open user decisions in `design-docs/user-qa/qa-work-handover-and-takeover.md` (defaults stated; implementation may proceed on the defaults)
**Notes**: Verified current-state facts are recorded in the design §2

## Related Plans

- **Previous**: `impl-plans/active/work-runtime-p1-*.md` (shipped P1 dispatcher, reservation, guard, director)
- **Next**: Work Runtime P4 (`ChangeRuntime` beyond the branch slice), P5 (full GraphQL task API and board)
- **Depends On**: `impl-plans/completed/distributed-workers.md`, `impl-plans/completed/native-remote-0{1,2,3}-*.md`
- **Aligns With**: `impl-plans/active/execution-environment-consolidation.md` (E2 adopts this plan's branch and ref names)
