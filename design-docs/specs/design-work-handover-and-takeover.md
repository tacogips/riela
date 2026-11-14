# Work handover and takeover: moving a stalled attempt to another worker

Status: implemented 2026-10-01 on `feat/work-handover-and-takeover`
(proposed 2026-09-30), zero-based on the shipped Work Runtime P1
(`design-work-runtime-consolidation.md` §4–§8, §17) and the shipped
distributed workers (`design-distributed-workers.md`). No backward
compatibility: the session schema generation bumps, closed enums gain
cases, old stores are discarded as today. Plan (implemented and
archived 2026-10-01): `impl-plans/completed/work-handover-and-takeover.md`;
user docs: `docs/work-handover.md`. Open user decisions:
`design-docs/user-qa/qa-work-handover-and-takeover.md`.

Revised 2026-09-30 (implementation intake): seam claims re-checked against
`feat/work-handover-and-takeover` `01b38f02`; contradictions with the
source are corrected in place and summarized in §21. No decision was
redesigned.

Revised 2026-10-01 (safety, user-qa Q10 default (a)): adoption of a plain
session no longer claims, commits or publishes the user's checkout; the
repository deliverable of an adopted attempt is `unpublished`, and
publication runs only for attempt-owned isolation (§9.1, §10.5, §21 R29).
Repository tests are hermetic (§15.1).

Revised 2026-10-01 (wh-20 reconcile intake): the §12 GraphQL block now
matches the accepted wh-12 contract, and the hermetic-test ceiling rule is
made exact (§21 R35). No decision changed.

Requirements source: user direction 2026-09-30 — when a riela worker
executes work and stalls mid-way because the user must confirm or do
something, and the user cannot reach that worker, another worker must be
able to continue the work: it inherits the workflow log, and deliverables
live in a git repository or in any document store (kaiba, monja, others).
This must be a builtin capability, not a per-workflow prompt convention.

## 1. Purpose

Today the answer to "can another worker continue a stalled run" is **no**,
for five separate reasons, each verified in §2:

| Gap | What happens today |
| --- | --- |
| No pause state | A run is `created`, `running`, `completed` or `failed`. An agent that needs the user either hangs (silence) or ends the run with a "blocked" output that is really a failure. |
| No portable work state | A new attempt of a task starts at a step with fresh input. Nothing carries accepted outputs, messages, variables, findings or the agent's own progress notes into it. History import exists only for `failed` sources, in one store. |
| No portable deliverables | The attempt's repository state is whatever is on disk on the worker. `IsolationRef` is never filled, no branch is created for an attempt, `riela/git-push` only fast-forwards an existing upstream, and git add-ons are denied on workers. |
| No answer channel | `task decide` accepts `--accept|--reject|--rerun|--cancel`; a human cannot send an answer payload. `send-manager-message` stores a message but wakes nothing. |
| No takeover of a dead owner | `work_leases` has no expiry or heartbeat. An attempt whose process dies after launch authorization fences its task forever; no command recovers it. |

This design adds one durable object, the **handover packet**, one new
attempt entry, **takeover**, one new session status, **suspended**, and
the sinks, leases, placement traits and surfaces that let a second worker,
on the same host or another, continue from the packet with the
deliverables in hand. It applies to Work Runtime tasks first and to plain
`workflow run` sessions through adoption (§10.5).

The scenarios it must cover, in decreasing frequency:

- **S1 answer needed.** The agent needs a decision or a piece of
  information (a secret's name, a product choice, approval to delete). The
  work can continue anywhere once the answer exists.
- **S2 presence needed.** The agent needs the user *on the machine*: an
  interactive login, a TCC permission dialog, a GUI step, a hardware key.
  The work must move to a host the user can reach.
- **S3 owner lost.** The worker died, lost network, or hangs with no
  signal. Nobody asked for a handover; another worker must be allowed to
  take the work after the owner is fenced out.
- **S4 operator move.** An operator moves work between hosts for capacity
  or cost reasons. Same mechanism, no stall.

## 2. Verified current state (2026-09-30)

Facts were read from the tree at `main` `49718e08`; line numbers move.

- **Session status.** `WorkflowSessionStatus` is `created | running |
  completed | failed` and `WorkflowStepExecutionStatus` is `running |
  completed | skipped | failed` (`Sources/RielaCore/RuntimeSession.swift:3-15`).
  Cancellation and timeouts are `failed` plus a `WorkflowSessionFailureKind`
  (`maxStepsExceeded, cancelled, adapterFailure, policyBlocked, nodeTimeout,
  internal, loopNotConverging, budgetExceeded`). The `stalled` kind promised
  by the Work Runtime design §7 does not exist. The ax-substrate adoption E
  (`suspended`, `SuspendRecord`, `session suspend|fork`) is unimplemented.
- **Resume rules.** `session resume` re-runs `currentStepId` in the same
  session; it refuses any `failed` session except `maxStepsExceeded`, or
  `adapterFailure|policyBlocked` with `--retry-failed-step`
  (`Sources/RielaCLI/SessionCommands.swift:658, 936-938`). It needs the same
  SQLite store (`--session-store`) and re-finds the bundle from
  `--working-dir`; `--endpoint` is rejected. `session rerun --preserve-history`
  imports accepted prefix executions and their messages only when the source
  is `failed` (`Sources/RielaCore/RuntimeHistoryImport.swift:27-34`,
  `docs/preserved-history-recovery.md`). There is no `session import`.
- **What a session records.** `workflow_messages` is a step-to-step payload
  log (`from_step_id`, `to_step_id`, `payload_json`, `lifecycle_status`), not
  a transcript. Per step, `WorkflowStepExecution` keeps `acceptedOutput`,
  `inputSnapshot`, `backendSessionId`, `backendWorkingDirectory`,
  `recentBackendEvents` (100 cap) and `streamedResponseText` (32 KiB cap)
  (`RuntimeSession.swift:221-245`, `RuntimeStore.swift:651, 825`). Vendor
  thread reuse (`sessionPolicy.mode: reuse`) is in-memory only
  (`AgentGatewayNodeAdapter.swift:106-108, 514`).
- **Asking the user.** `design-docs/user-qa/*.md` is a prompt convention
  the runtime never reads. Fable-family workflows end a run with
  `checkpoint_blocked` / `implementation_blocked` outputs carrying
  `resumeCriteria` and `nextStep`. `riela graphql send-manager-message`
  appends a `delivered` message to the stored snapshot; on the next resume
  `RuntimeMessageInputResolver` merges delivered messages addressed to the
  step into its input (`RuntimeMessageInputResolver.swift:47-70`). The typed
  manager actions of the GraphQL control-plane design (`retry-step`,
  optional-step decisions) are not implemented in Swift.
- **Stall signals.** The agent silence monitor emits `silence_warning`
  every `--agent-silence-warning-ms` (default 120000) and changes nothing
  (`DeterministicWorkflowRunner+ExecutionEvents.swift:117-177`).
  `WorkflowStepRef.stallTimeoutMs` is parsed and unused. The Work Runtime
  `InactivityGuard` yields `inactivity-rerun` or `inactivity-stop`
  (`Sources/RielaWork/DeterministicDirector.swift:78-88`) and skips official
  SDK backends (`WorkGuard.swift:170-177`). `SessionBackendActivityVerdict`
  (`active | quiet | stalled-suspect | unknown`) is computed on read. None of
  these distinguish "needs the user" from "hung".
- **Work Runtime.** `TaskState` has `waiting` and `needsDecision`;
  `WaitReason` has `human` and `clarification(question:)`; `AttemptEntry` is
  `start | resume | rerunFromStep | recoverFromGate | director`
  (`WorkModels.swift:340-605`, `WorkDecision.swift:60-151`). A rerun or
  recover decision enqueues a `PendingAttemptReservation`; the next `task
  run` starts a new session at the chosen step with no variables from the
  predecessor (`TaskDispatch.swift:266-275`). `AgentDirectorTaskView`
  (`AgentDirector.swift:6`) is the closest thing to a portable work summary.
  `IsolationRef {path, branch, baseRevision}` and `RepositoryContext` are
  data only; nothing constructs them. `task decide` has no answer payload;
  there is no GraphQL task API (`SurfaceCatalog+RowsCLI.swift:76-104`, P5).
- **Leases.** One live attempt per task is enforced by the partial unique
  index, `work_leases.task_id UNIQUE` and `reserveAttempt`
  (`WorkStore+Schema.swift:81-96`, `WorkStore+Reservation.swift:137`).
  `work_leases` has `acquired_at`, `updated_at` and no expiry or heartbeat;
  §17.2 states "lease expiry or missing heartbeat is not proof of
  non-execution". `recoverPreLaunchReservation` needs the launch token and
  has no production caller; an authorized attempt whose owner dies is
  unrecoverable. Loop leases, by contrast, take over a holder after 600 s
  (`SQLiteWorkflowRuntimePersistenceStore.swift:466-510`).
- **Workers.** Registration is `DistributedWorkerRegistration {workerId,
  incarnation, groups, capacity, capabilities, environment,
  addonExecutables}` (`DistributedWorkerModels.swift:19-40`); the
  controller's `work_hosts` snapshot is `HostCapabilitySnapshot {hostId,
  groups, capacity, live, backends, addonExecutables, environment}`
  (`BackendCapability.swift:88`). Jobs are per node, leased 30 s, fenced by
  incarnation and token, `.lost` on expiry with no replay
  (`DistributedNodeExecution.swift:109-110`). Placement is pinned after
  admission. Workspaces are operator-provisioned directories; nothing syncs
  them. `riela/git-commit` and `riela/git-push` are denied on workers
  (`DistributedWorkerNodeExecutor.swift:107-112`). `riela/git-push` refuses a
  branch without an existing live upstream and never creates one
  (`ProductionNodeAdapter+GitPush.swift:37-118`).
- **Stores.** kaiba is the only store reachable from every host; its
  add-ons are `kaiba/note-create|update|get|search|…|memory-consolidate|
  memory-recall` (`Sources/RielaAddons/RielaAddons.swift:55-75`), bound by
  `addon.config.kaibaInstanceId`. Riela memory and KV are SQLite files under
  the process cwd. Monja has no add-on; `examples/monja-typescript-sdk`
  reaches it through a command node. `session export` prints the status JSON
  without messages; `--artifact-root` mirrors the full snapshot to
  `<root>/<sessionId>/runtime-snapshot.json`.
- **Execution environment consolidation** (`WorkspaceDefinition`,
  `WorkspaceInstanceRef`, `ResolvedExecutionEnvironment`, `ChangeRuntime`)
  is design-only; its plan has no code written. This design must not wait
  for it and must not conflict with it (§20).
- **Module and file boundaries** (re-checked on `01b38f02`). One schema
  generation guard, `SQLiteWorkflowRuntimePersistenceStore.schemaGeneration
  = 8` (`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:115`),
  covers the session tables and the `work_*` tables in the same file; a
  mismatched store is discarded, no migration is registered.
  `RielaWork` depends on `RielaCore`, never the reverse (`Package.swift`), so
  every type a runner, adapter or `SuspendRecord` reads must live in
  `RielaCore`. `RielaGraphQL` depends on `RielaCore` only; its surfaces are
  DTO contracts plus a `…GraphQLProviding` protocol implemented elsewhere
  (`RoutineGraphQL.swift:227` → `RielaWorkflowRegistry/RoutineGraphQLProvider.swift`).
  `normalizeOutputContractEnvelope` is in `Sources/RielaCore/AdapterContracts.swift:335`;
  `DistributedWorkerNodeExecutor` (git add-on denial at line 108) is in
  `Sources/RielaCore`; `ServeWebHost` is in `Sources/RielaCLI`. The runner
  returns the `WorkflowRunResult` struct (`status`, `exitCode`), not an
  enum; `CLIExitCode` uses 0–4. `TaskCommandKind` is `show | list | run |
  decide`; there is no `task serve` and no `riela config` command. Local
  host capabilities come from the app profile state
  (`RielaAppDaemonWorkflowState.backends`, read by
  `HostCapabilityResolver.swift:125-143`); workers declare them in
  `worker.json`. `BackendCapabilityPlacementResolver` takes
  `requirements: [WorkflowBackendRequirement]`. `WorkflowFanoutChangeEvidence`
  is an internal actor of `RielaCore`. The git runner seam in `RielaCLI` is
  the internal `GitCommandRunning` protocol with `GitFinalizationStore`.
  The deterministic director already has `rerunOnInactivity`
  (`DeterministicDirector.swift:77-86`). Task rows live in
  `SurfaceCatalog.taskMutationRows` (`SurfaceCatalog+RowsCLI.swift:76-106`)
  with GraphQL `.blocked(P5)`; the checked-in SDL is
  `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`, rewritten by
  `scripts/surface-parity/generate-sdl.sh`.
- **Example parity.** `RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI`
  runs every example with a `mock-scenario.json` through plain `workflow
  run` and asserts exit `.success` and `status == .completed`
  (`expectedMockScenarioCount = 40`). Mock responses are chosen by
  per-node sequence index (`ScenarioNodeAdapter.swift:114-118`) and cannot
  branch on input. Task-level example flows are proven by harness tests
  (`TaskRuntimeExampleTests` with `TaskExampleHarness`, which sets
  `TaskDispatch.mockScenarioPath`; `task run` has no `--mock-scenario` flag).

## 3. Design decisions

1. **The task is the unit of handover.** A handover always produces a new
   `Attempt` of the same `WorkTask` with `entry: .takeover(...)`. The
   one-live-attempt fence, the evidence ledger, placement evidence and the
   guard budget all attach to the task already; a handover is one more
   attempt transition, not a parallel mechanism. A plain `workflow run`
   session is handed over by first adopting it into a task (§10.5).
2. **The packet is the contract between predecessor and successor.** A
   successor never needs the predecessor's process, host or SQLite file. It
   needs the `HandoverPacket`, the deliverable references inside it, and
   reachability of the stores those references name. The packet is built by
   the runtime from durable records, never by the agent alone; the agent
   contributes a bounded `progressNote` and the question.
3. **`suspended` is a real session status.** An attempt that needs the
   user stops between steps, or at a node boundary the adapter can end
   cleanly, with `status: .suspended` and a `SuspendRecord`. It is not
   `failed`. `session resume` accepts `suspended` and the takeover attempt
   imports its history. A step interrupted mid-node is re-executed by the
   successor from the step start; the node's own idempotency rules apply,
   exactly as `docs/preserved-history-recovery.md` states for reruns.
4. **Three triggers, one path.** Agent-declared (`handover` envelope in an
   accepted output or the `riela/handover-request` add-on), runtime-detected
   (backend wait signal or inactivity), and operator-initiated
   (`task handover`, `task takeover --force`) all produce the same
   `Decision.kind = .handover(HandoverReason)` and the same packet. Orphan
   takeover (S3) is the operator path with lease fencing.
5. **Deliverables are published before the packet is sealed.** For a
   repository context the runtime commits a checkpoint on the attempt's
   branch and pushes it; for document stores the packet lists the ids the
   attempt wrote (collected from add-on outputs); for local artifacts the
   packet carries a bounded bundle. A packet sealed without a successful
   publication says so (`deliverables[].state`), so a successor knows what
   was lost. Step-boundary auto-checkpoints bound the loss for S3.
6. **The packet's home is the work store; sinks are mirrors.** The
   canonical copy lives in `work_handovers` on the controller's store and is
   served over GraphQL. Configured sinks (kaiba note, git ref, file,
   command) receive the same bytes so a successor that cannot reach the
   controller, or a human, can still read it. A sink never replaces the
   store; the store row records every sink reference.
7. **Answers are decisions with payloads.** `DecisionKind.answer(...)` is
   recorded by a human or an agent director, validated against the
   question's `answerSchema`, and delivered to the successor both as a
   runtime variable and as a `delivered` message to the resume step through
   the existing message-input resolver. No new prompt-injection path.
8. **Placement understands hosts the user can touch.** A host declares
   `traits` (`userReachable`, `interactive`, `tccApproved`, …). An S2
   handover requires `userReachable`; the placement resolver treats traits
   like backends: no host satisfies them → `waiting(.handover)` with a
   decision and a notification, never a failed attempt.
9. **Leases expire and fence.** `work_leases` gains `heartbeat_at`,
   `expires_at` and `fence` (a monotonically increasing integer). The owning
   runner heartbeats on every snapshot save and checks its fence at every
   step boundary; a takeover of an expired lease increments the fence, so
   a late owner that is actually still alive aborts itself with
   `failureKind: .leaseLost` at its next boundary. This keeps §17.2's rule
   (expiry alone proves nothing) while making takeover safe: the fence, not
   the expiry, is what excludes the old owner.
10. **Cross-host takeover is pull-based.** The successor host runs
    `riela task takeover --endpoint <controller>` (or `task serve` polls),
    fetches the packet over GraphQL, executes locally, and reports its
    attempt back over GraphQL at terminal. The controller never pushes a
    whole task at a worker: the distributed job protocol stays per node, and
    the successor's own session store stays authoritative for its execution
    detail. This matches the "user's laptop picks up the work" case, which
    is the reason the feature exists.
11. **Forward-compatible with the environment consolidation.** The branch
    seam introduced here (`GitBranchWorkspaceRuntime`, §9) is the first
    concrete slice of the designed `ChangeRuntime`; when
    `WorkspaceInstanceRef` lands, `IsolationRef` is replaced by it and the
    packet's `deliverables.repository` maps 1:1 onto
    `WorkspaceRepositoryRef`. Nothing here adds a second workspace concept.
12. **No compatibility.** Session schema generation 8 → 9; closed enums
    gain cases and decode strictly; stores from earlier generations are
    discarded as today. Examples and packages that emit
    `checkpoint_blocked`-style outputs keep working unchanged (they are not
    handovers) and may opt in by emitting the envelope.

## 4. Domain model

Names are Swift; storage is JSONB records with generated columns as in
`WorkStore+Schema.swift`.

```swift
// RielaCore — session side

public enum WorkflowSessionStatus: String, Codable, Sendable, CaseIterable {
  case created, running, suspended, completed, failed          // + suspended
}

public enum WorkflowStepExecutionStatus: String, Codable, Sendable {
  case running, suspended, completed, skipped, failed          // + suspended
}

extension WorkflowSessionFailureKind {
  public static let stalled   = WorkflowSessionFailureKind(rawValue: "stalled")     // inactivity with no wait signal
  public static let leaseLost = WorkflowSessionFailureKind(rawValue: "leaseLost")   // fenced out by a takeover
}

// RielaCore cannot import RielaWork, so the suspend record carries a
// Core-side reason kind; the full HandoverReason lives on the packet.
public struct SuspendRecord: Codable, Equatable, Sendable {
  public var reasonKind: SuspendReasonKind  // userInputRequired | userPresenceRequired | operatorMove
  public var stepId: String                 // step to re-enter (= resumeStepId)
  public var stepExecutionId: String?       // execution that declared or was interrupted
  public var question: HandoverQuestion?    // S1
  public var presence: PresenceRequirement? // S2
  public var progressNote: String?          // agent-authored, ≤ 8 KiB
  public var suspendedAt: Date
  public var producer: SuspendProducer      // stepExecution(id) | runtime | human(principal)
}
// S3 and inactivity end the session failed(.leaseLost | .stalled), never suspended.

// RielaCore/HandoverContracts.swift — read by the runner, adapters and RielaWork
// (HandoverQuestion, HandoverOption, PresenceRequirement, HostTrait below)

public struct HandoverQuestion: Codable, Equatable, Sendable {
  public var id: String                     // stable per question; answers reference it
  public var text: String
  public var options: [HandoverOption]      // may be empty (free-form)
  public var answerSchema: JSONObject?      // JSON Schema for the answer payload
  public var defaultAnswer: JSONObject?     // used only with an explicit --use-default
  public var impact: String?
}

public struct HandoverOption: Codable, Equatable, Sendable {
  public var id: String; public var label: String; public var description: String?
}

public struct PresenceRequirement: Codable, Equatable, Sendable {
  public var traits: Set<HostTrait>         // e.g. [.userReachable, .interactive]
  public var instructions: String           // what the user must do on the host
}

public enum HostTrait: String, Codable, CaseIterable, Sendable {
  case userReachable, interactive, tccApproved, hardwareKey, gui
}

// RielaWork — handover side

public enum HandoverReason: Codable, Equatable, Sendable {
  case userInputRequired(HandoverQuestion)
  case userPresenceRequired(PresenceRequirement)
  case ownerLost(OwnerLossEvidence)         // lease expired + fence bumped
  case inactivity(stepId: String, idleMs: Int)
  case operatorMove(reason: String)
}

public struct OwnerLossEvidence: Codable, Equatable, Sendable {
  public var attemptId: AttemptID
  public var lastHeartbeatAt: Date?
  public var expiredAt: Date
  public var fence: Int                     // the fence value that excluded the owner
  public var forcedBy: DecisionProducer
}

public struct HandoverPacket: Codable, Equatable, Sendable {
  public var id: HandoverID
  public var version: Int                   // packet schema version, starts at 1
  public var taskId: TaskID
  public var intentId: IntentID
  public var fromAttemptId: AttemptID
  public var fromSessionId: String
  public var generation: Int
  public var reason: HandoverReason
  public var workflow: HandoverWorkflowRef  // id, scope, definition digest, entryStepId, resumeStepId
  public var progress: HandoverProgress     // accepted steps, remaining steps, gate results, open findings
  public var history: HandoverHistoryBundle // bounded subset of RuntimeHistoryImport input
  public var variables: JSONObject          // runtime variables at suspend (secrets redacted, §14)
  public var deliverables: [DeliverableRef]
  public var contract: HandoverContinuationContract
  public var brief: String                  // rendered Markdown, ≤ 64 KiB
  public var sinks: [HandoverSinkRef]       // where copies were written
  public var producedBy: EvidenceProducer
  public var producedOn: String             // hostId
  public var createdAt: Date
  public var digest: String                 // SHA-256 of the canonical JSON without `sinks` and `digest`
}

public struct HandoverProgress: Codable, Equatable, Sendable {
  public var acceptedSteps: [HandoverStepSummary]   // stepId, executionId, acceptedOutput (bounded), summary
  public var remainingSteps: [String]               // graph walk from resumeStepId
  public var latestGateResults: [LoopGateResult]
  public var openFindings: [Finding]
  public var evidenceSummary: [EvidenceKind: Int]
  public var remainingBudget: BudgetSnapshot        // attempts, tokens, wallClockMs
}

public struct HandoverStepSummary: Codable, Equatable, Sendable {
  public var stepId: String
  public var stepExecutionId: String
  public var status: WorkflowStepExecutionStatus
  public var acceptedOutput: JSONObject?            // ≤ 32 KiB, else truncated with marker
  public var responseExcerpt: String?               // tail of streamedResponseText, ≤ 4 KiB
  public var backend: String?
}

public struct HandoverHistoryBundle: Codable, Equatable, Sendable {
  public var executions: [WorkflowStepExecution]    // accepted prefix, stripped as RuntimeHistoryImport strips
  public var messages: [WorkflowMessageRecord]      // messages addressed to resumeStepId and later
  public var compatibilityDigests: [String: String] // per step, as invocation snapshots record them
  public var truncated: Bool
}

public enum DeliverableRef: Codable, Equatable, Sendable {
  case repository(RepositoryDeliverable)
  case document(DocumentDeliverable)
  case artifactBundle(ArtifactBundleRef)
  case localOnly(LocalOnlyDeliverable)      // memory/KV/files that could not be published
}

public struct RepositoryDeliverable: Codable, Equatable, Sendable {
  public var root: String                   // on the predecessor host, informational
  public var remote: String                 // fetch URL or remote name resolved to URL
  public var branch: String                 // riela/task/<taskId>/g<generation>
  public var baseRevision: String
  public var headCommit: String?            // last published commit
  public var state: PublicationState        // published | checkpointFailed(reason) | unpublished(lastKnown:)
  public var dirtyPaths: [String]           // paths changed but not in headCommit (S3 only, from last snapshot)
}

public struct DocumentDeliverable: Codable, Equatable, Sendable {
  public var store: String                  // "kaiba", "monja", "google-docs", "wrike", …
  public var instance: String?              // kaibaInstanceId, monja base URL, …
  public var ids: [String]                  // noteIds, task/comment ids, document ids
  public var producedByStepIds: [String]
}

public struct ArtifactBundleRef: Codable, Equatable, Sendable {
  public var files: [ArtifactFileRef]       // path, sha256, bytes; bounded 16 files / 512 KiB, as job exports
  public var location: HandoverSinkRef      // where the bundle bytes are
}

public struct HandoverContinuationContract: Codable, Equatable, Sendable {
  public var resumeStepId: String
  public var completion: CompletionContract  // lifted from the task
  public var verification: [VerificationRequirement]
  public var guardPolicy: GuardPolicy
  // No answer field (R19): the answer is Decision.answer, delivered at takeover.
}

public struct HandoverAnswer: Codable, Equatable, Sendable {
  public var questionId: String
  public var payload: JSONObject
  public var answeredBy: DecisionProducer
  public var answeredAt: Date
}

public enum HandoverSinkKind: String, Codable, CaseIterable, Sendable {
  case store, kaiba, gitRef, file, command
}

public struct HandoverSinkRef: Codable, Equatable, Sendable {
  public var kind: HandoverSinkKind
  public var locator: String                // store: "<hostId>/<taskId>/<handoverId>"; kaiba: "<instance>/<noteId>";
                                            // gitRef: "<remote> refs/riela/handovers/<taskId>/<handoverId>";
                                            // file: absolute path; command: opaque id the command returned
  public var digest: String
  public var writtenAt: Date
}

// Attempt / decision / evidence extensions

public enum AttemptEntry {
  case start, resume, rerunFromStep(String?), recoverFromGate(String), director
  case takeover(fromAttemptId: AttemptID, handoverId: HandoverID)          // new
}

public enum DecisionKind {
  …
  case handover(HandoverReason)                                            // new: seal a packet, suspend/fence the attempt
  case answer(HandoverAnswer)                                              // new: S1 answer
  case takeover(handoverId: HandoverID, placement: TakeoverPlacement)     // new: reserve a takeover attempt
}

public enum WaitReason {
  case capacity, dependency, human, clarification(question: String), until(Date)
  case handover(HandoverID)                                                // new: packet sealed, no successor yet
}

public enum EvidenceKind {
  …, case handover, handoverAnswer, publication, leaseFence                // new
}

public struct TakeoverPlacement: Codable, Equatable, Sendable {
  public var hostId: String
  public var requiredTraits: Set<HostTrait>
  public var backend: NodeExecutionBackend?; public var model: String?
}

// Lease

public struct AttemptLease: Codable, Equatable, Sendable {
  public var attemptId: AttemptID; public var taskId: TaskID; public var sessionId: String
  public var tokenDigest: String
  public var fence: Int                     // starts at 1; incremented by every takeover
  public var heartbeatAt: Date
  public var expiresAt: Date                // heartbeatAt + task.guardPolicy.lease.ttlMs (default 300000)
  public var hostId: String
}
```

`GuardPolicy` gains `lease: LeasePolicy { ttlMs: Int, heartbeatMs: Int }`
(defaults 300000 / 15000) and `handover: HandoverPolicy`:

```swift
public struct HandoverPolicy: Codable, Equatable, Sendable {
  public var onWaitSignal: Bool                       // treat classified backend wait signals as S2 (default true)
  public var checkpoint: CheckpointPolicy             // none | stepBoundary (default) | everyMs(Int)
  public var sinks: [HandoverSinkConfig]              // in addition to the store
  public var publish: PublicationPolicy               // remote, branchTemplate, allowCreateBranch (default true for riela/*)
  // No notify field (R14): workflow loop.notifications with on: ["handover"].
}
```

The inactivity choice is a director rule, not a guard field:
`DeterministicDirectorRules` gains `handoverOnInactivity: Bool` (default
`false`), evaluated before the existing `rerunOnInactivity` (§6.3).

A suspended run returns `WorkflowRunResult` with `status: .suspended`,
`session.suspend` set, and the new exit code `CLIExitCode.suspended = 5`
(non-zero, distinct from `failure`).

## 5. Lifecycle

```
running attempt A (host X)
   │ trigger: agent envelope | wait signal | inactivity | operator | lease expiry
   ▼
publish deliverables ──▶ build packet ──▶ write store row ──▶ mirror to sinks
   │                                            │
   ▼                                            ▼
session A: suspended (S1/S2/S4)          Decision.handover(reason), Evidence.handover
   or failed(stalled | leaseLost) (S3)
   │
   ▼
attempt A: terminal → reconciled (lease deleted; fence kept on task)
task: waiting(.handover(id))  ──notify──▶ user / operator
   │
   ├── S1: Decision.answer(...)  (task answer | GraphQL answerTask | agent director)
   │         task: scheduled; pending reservation entry = .takeover
   │
   ├── S2/S4: successor host with required traits runs `task takeover` (pull)
   │
   └── S3: `task takeover --force-orphan` fences A (fence+1), then as above
   │
   ▼
reserveAttempt(entry: .takeover(from: A, handover: H))  ──▶ attempt B (host Y)
   │  materialize repository (fetch + worktree on branch)
   │  import history bundle into session B (created → running)
   │  deliver answer as variable `handover.answer` + delivered message to resumeStepId
   ▼
attempt B runs from resumeStepId ──▶ terminal ──▶ verifying ──▶ director (unchanged)
```

Rules the runtime enforces regardless of trigger:

- A handover is recorded **before** the predecessor stops. Order: publish
  deliverables, seal packet (digest), insert `work_handovers`, record the
  decision and evidence, then persist the session as `suspended` or
  `failed`. Handovers that interrupt a running node are the exception
  (§21 R26): the runner's single terminal write, carrying the cause, comes
  first, and the seal follows it. A crash between publication and the store row leaves the branch
  on the remote and no packet; `task reconcile` rebuilds a packet from the
  session snapshot with `deliverables[].state = .unpublished(lastKnown:)`
  for anything it cannot prove was pushed.
- A takeover attempt is reserved through the existing `reserveAttempt`
  fence, in the same transaction as the lease row with `fence = previous
  fence + 1` and the `WorkflowSession(status: .created)` row. One live
  attempt per task remains the invariant; a takeover of a task with a live,
  non-expired lease is refused.
- A takeover attempt's guard budget is the task's remaining budget from the
  packet, not a fresh budget. Attempts, tokens and wall clock spent by the
  predecessor count.
- `Attempt.lineage` records `takeover` lineage the way `LoopRecoveryLineage`
  records rerun lineage, so `task show` and the ledger can walk A → B → C.
- The successor session's `importedFrom` pointers (as in
  `RuntimeHistoryImport`) name the predecessor session; imported executions
  carry no new backend events or usage.
- A task may be handed over at most `guardPolicy.budget.maxAttempts` times
  in total; handovers are attempts.

## 6. Triggers

### 6.1 Agent-declared (S1, S2)

Two equivalent forms, so both contract-bearing and contract-less nodes can
declare a handover:

- **Envelope key.** An accepted output object may carry a reserved
  top-level key `handover`:

  ```json
  {
    "handover": {
      "reason": "userInputRequired",
      "question": { "id": "q-deploy-target", "text": "...", "options": [...], "answerSchema": {...} },
      "progressNote": "Implemented A and B; C blocked on which staging environment to target.",
      "resumeStepId": "step4-implement"
    },
    "...": "the rest of the business payload, validated as today"
  }
  ```

  `normalizeOutputContractEnvelope` (`AdapterContracts.swift`) strips
  and validates the block against a fixed `HandoverEnvelope` schema before
  the business payload is validated against the node's `output.jsonSchema`.
  A malformed `handover` block is a `validationRejected` attempt like any
  other contract violation. `resumeStepId` defaults to the declaring step
  (re-execute it with the answer). It may name a downstream step when the
  declaring step's own work is complete and accepted.
- **Add-on.** `riela/handover-request@1` (worker-only, like every add-on)
  takes the same fields as `config`/`inputs` and returns `{status:
  "handover-requested", handoverId}`. It exists so command-only and
  script-driven workflows can hand over without an agent node.

In both forms the step's execution ends `suspended` (envelope) or
`completed` (add-on, whose output is the request), the runner stops
advancing, and the Work Runtime seals the packet. Outside a task (plain
`workflow run`), the envelope suspends the session and prints the adoption
hint (§10.5); the add-on fails with `policyBlocked` unless the run is a
task attempt.

### 6.2 Backend wait signal (S2)

Each CLI-agent adapter already relays backend events into
`recentBackendEvents` (`eventType`, `channel`, `content`, `toolName`). A
new `BackendWaitSignalClassifier` maps adapter-specific event vocabularies
to `PresenceRequirement`s: approval and permission prompts, interactive
login prompts, and "waiting for input" markers. The table is per adapter and
is filled at implementation time from each adapter's event enum; the
classifier never pattern-matches free text. A classified signal followed by
`handover.onWaitSignal == true` and no progress for `guard.inactivity.
stallTimeoutMs` produces `HandoverReason.userPresenceRequired` with
`traits: [.userReachable, .interactive]`. Unclassified silence stays the
inactivity path (§6.3). Official SDK backends have no interactive prompts and
are exempt, as they are for the inactivity guard today.

### 6.3 Inactivity (S3 without a signal)

`InactivityGuard` already fires `GuardViolation.inactivity`. The
deterministic director's inactivity branch checks
`director.deterministic.handoverOnInactivity` first: when true (and the
attempt budget allows) it returns `Decision.handover(.inactivity)` with rule
`inactivity-handover`, cancels the attempt through the existing
cancellation path and seals a packet; otherwise today's
`inactivity-rerun` / `inactivity-stop` rules apply unchanged. On the
handover branch the session is `failed(.stalled)`, the failure kind the
Work Runtime design promised. The runner writes that as its single terminal
write, and the seal follows it without a second session save (§21 R26).

### 6.4 Operator (S4, and S3 recovery)

- `riela task handover <taskId> --reason "<text>" [--to <host|group>]
  [--sink …]` asks a live attempt to hand over at its next step boundary
  (a cooperative request recorded like a cancellation request and observed
  by the owner's `TaskRunCancellation` loop). `--now` cancels the running
  node instead of waiting for the boundary.
- `riela task takeover <taskId> --force-orphan` is the S3 path: refused
  unless the lease is expired; bumps the fence; seals a packet from the last
  snapshot; then reserves the takeover attempt on the calling host.
- `riela task reconcile [--expired-leases]` seals packets for every task
  whose lease expired without deciding who takes them; the tasks go to
  `waiting(.handover)` and notifications fire. This is the `session
  reconcile` P4 of the cancellation design, restated for tasks.

## 7. The packet

### 7.1 Build

`HandoverPacketBuilder` (RielaWork, injected with a read-only session view
and the ledger) reads, in order: the task and attempt rows; the persisted
`WorkflowRuntimePersistenceSnapshot` of the attempt's session (accepted
executions, messages, variables, loop evidence); the ledger's gate results,
findings and evidence counts; the deliverable publication results (§9); and
the `SuspendRecord` or the guard violation that triggered the handover. It
produces the packet, renders `brief`, computes `digest`, and hands the
bytes to the sink writers. The builder is deterministic: the same inputs
produce the same digest, and the plan's tests assert it.

### 7.2 Bounds

The packet is meant to be read by an agent as prompt input and stored in a
note. Hard bounds, all enforced by the builder with truncation markers:

| Field | Bound |
| --- | --- |
| `progress.acceptedSteps[].acceptedOutput` | 32 KiB each |
| `progress.acceptedSteps[].responseExcerpt` | 4 KiB tail |
| `history` | 2 MiB total, else `truncated: true` and the successor must reach the store |
| `variables` | 256 KiB after redaction |
| `brief` | 64 KiB |
| `artifactBundle` | 16 files, 512 KiB, the distributed job export limits |
| whole packet | 4 MiB |

### 7.3 Brief

`brief` is Markdown rendered from the packet by a fixed template (no
model call): intent and task titles, why the handover happened, the
question or presence instructions, what was accepted (one line per step),
what remains, deliverable locations with exact fetch commands, open
findings, remaining budget, and the agent's `progressNote` verbatim. It is
what a human reads in a kaiba note and what the successor's first prompt
receives as `{{handover.brief}}`.

## 8. Sinks and locators

`HandoverSink` is a protocol in RielaWork with builtin implementations in
RielaCLI:

| Kind | Writes | Reads back | Reachable from other hosts |
| --- | --- | --- | --- |
| `store` (always) | `work_handovers` row | `WorkStore.loadHandover`, GraphQL `taskHandover` | only through the controller's GraphQL |
| `kaiba` | `kaiba/note-create` with `bodyMarkdown = brief`, packet JSON as an attachment, tags `riela-handover`, `task:<taskId>` | `kaiba/note-get` by noteId, or `note-search` by tag | yes, if the instance is reachable |
| `gitRef` | blob under `refs/riela/handovers/<taskId>/<handoverId>` on the deliverable branch's remote | `git fetch <remote> refs/riela/handovers/…` | yes, with repository access |
| `file` | `<artifact-root or session-store>/handovers/<taskId>/<handoverId>.json` + `.md` | path | only on shared filesystems |
| `command` | runs a configured executable with the packet on stdin, records the id it prints | the same executable with `--read <id>` | as the executable allows; this is how monja is a sink today (`examples/monja-typescript-sdk` command shape) |

A **locator** is a `HandoverSinkRef` serialized as `kind:locator`. `task
takeover --packet <locator|path>` resolves it; without `--packet` the
command asks the store (local or `--endpoint`). The digest in the locator
is verified against the bytes read; a mismatch refuses the takeover.

Sinks are configured on the task (`guard.handover.sinks`) and on the
workflow (`workflow.json` top-level `handover.sinks`), merged task first,
plus any `--sink` given to `task handover` / `session handover`. There is
no user-profile sink configuration (no `riela config` command exists; Q2
default is store only). The kaiba sink requires the
instance to pass the same startup check every kaiba add-on needs; a
handover whose sink write fails still succeeds (the store row is the
contract) and records `Evidence.kind = .publication` with the failure.

## 9. Deliverables

### 9.1 Repository

The first concrete slice of the designed `ChangeRuntime`, named
`GitBranchWorkspaceRuntime` (RielaCLI, git binary), with exactly the
operations handover needs:

```swift
public protocol WorkspaceHandoverRuntime: Sendable {
  func ensureBranch(root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?) async throws -> IsolationRef
  func checkpoint(_ isolation: IsolationRef, message: String, paths: [String]?) async throws -> RevisionRef?   // nil = nothing to commit
  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool) async throws -> PublishedRef
  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool) async throws -> IsolationRef
  func dirtyPaths(_ isolation: IsolationRef) async throws -> [String]   // `git status --porcelain=v1 -z`, ≤ 512 paths
}
```

`GitBranchWorkspaceRuntime` runs git through the existing internal
`GitCommandRunning` seam and journals checkpoints through
`GitFinalizationStore`, so it stays in `RielaCLI`. The fanout change
capture actor is internal to `RielaCore` and is not reused; `dirtyPaths`
only needs path names.

Behavior:

- **At attempt start** for a task with `ContextBinding.repository`, the
  dispatcher calls `ensureBranch`: branch `riela/task/<taskId>/g<generation>`
  (template configurable) from `baseRevision` or `HEAD`, created in place
  (`isolation: .shared`) or as `<root>/.riela/worktrees/<attemptId>`
  (`isolation: .worktree`, which becomes real here for tasks; `loop start
  --isolate` and fanout `isolated-workspace` stay unchanged). `Attempt.
  isolation` is finally populated. The `riela/git-commit` requirement that
  HEAD be a named branch is satisfied by construction.
- **Checkpoints.** `handover.checkpoint: stepBoundary` commits all tracked
  changes and untracked files inside `writeScopes` (or the whole tree when
  scopes are empty) at every accepted step boundary with message
  `riela: checkpoint <taskId> <stepId>` and trailer
  `Riela-Checkpoint: <attemptId>/<stepExecutionId>`. Checkpoints use the
  finalization store journal so a crash mid-commit is recoverable, exactly
  as `riela/git-commit` does. `everyMs` adds a timer. They are not
  finalization: the director's `accept` still runs the existing
  finalization path, and the plan's `task show` output distinguishes
  checkpoint commits by the trailer.
- **At handover** the runtime runs `checkpoint` then `publish`. `publish`
  pushes `HEAD:<branch>` with `--set-upstream` when the branch has no
  upstream, allowed only for branches matching `handover.publish.
  branchTemplate` (default `riela/task/*`), never force, never to a branch
  that is behind. This is a new capability of the git integration, kept
  out of `riela/git-push` (whose contract stays "fast-forward an existing
  upstream") and exposed only to the handover runtime and to a new
  `riela/git-publish-branch@1` add-on with the same restrictions.
- **Workers.** Checkpoint and publish are the two git operations a worker
  may perform, because they act only on the attempt's own `riela/task/*`
  branch and never on the operator's branches. `DistributedWorkerNodeExecutor`'s
  denial list is narrowed accordingly; `riela/git-commit` and
  `riela/git-push` stay denied on workers.
- **Ownership (user-qa Q10, §21 R29).** Checkpoint and publish run only for
  an attempt-owned isolation: an attempt that holds a lease, whose
  `isolation.branch` matches `handover.publish.branchAllowlist` and is the
  branch checked out at `isolation.path` (the dispatcher's `ensureBranch`
  or `materialize` result). Anything else gets no git write from the
  handover runtime: an adopted attempt records `.unpublished(lastKnown:
  HEAD)`, and a leased attempt whose isolation fails the check records
  `.checkpointFailed(reason)` with no commit and no push.
- **At takeover** the successor calls `materialize`: fetch the branch,
  create `<root>/.riela/worktrees/<attemptId>` (or check out in place when
  the root is a dedicated clone), and record the new `IsolationRef`. If
  `state == .unpublished(lastKnown:)` the successor starts from
  `lastKnown` and the packet's `dirtyPaths` list is placed in the brief so
  the agent knows what was lost. A `.checkpointFailed(reason:)` deliverable
  is refused before any attempt is reserved (§21 R28, user-qa Q9).
- **Root on the successor.** `--working-dir` as today; when absent and
  `RepositoryDeliverable.remote` names a URL, `task takeover --clone-into
  <dir>` clones. No automatic cloning without a flag.

### 9.2 Documents

The runtime collects `DocumentDeliverable`s from accepted add-on outputs:
`kaiba/*` outputs carry `noteId`/`notebookId` and the instance; gateway
add-ons carry their ids; command nodes may declare
`output.projection.deliverables` (a new projection kind) naming the
output fields that hold ids and the store name, which is how a monja
command node reports the task/comment ids it wrote. These are references,
not copies; the successor reaches them through the same add-ons.

### 9.3 Local-only state

Riela memory and KV files under the predecessor's cwd, and files outside
`writeScopes`, cannot be published. They are listed as `localOnly` with
paths and sizes so the successor and the user know. A task whose plan
depends on cwd-local memory across a handover is a workflow-authoring
problem; `riela workflow validate` warns when a task-eligible workflow
uses `riela/memory-*` or `riela/kv-*` without a kaiba mirror step.

## 10. Takeover

### 10.1 Same store (same host, or a shared session store)

`riela task takeover <taskId>` with no `--endpoint`:

1. Load the packet from `work_handovers`; verify the task is
   `waiting(.handover)` (or an expired lease with `--force-orphan`).
2. Resolve placement locally: required traits against the local host's
   declared traits; backend and model as `task run` does.
3. `reserveAttempt(entry: .takeover(...))`, fence + 1.
4. `materialize` the repository deliverable when present.
5. Create session B and import the history bundle (`RuntimeHistoryImport`
   extended to accept `suspended` and `failed(.stalled | .leaseLost)`
   sources and to accept a bundle instead of a live source session).
6. Inject the answer, when present, as variable `handover.answer` and as a
   `delivered` message `{ "handover": { "answer": … } }` to `resumeStepId`.
7. Run from `resumeStepId` through the existing task dispatch path; every
   later step is unchanged.

### 10.2 Another host

`riela task takeover <taskId> --endpoint https://controller/graphql`:

1. `taskHandover(taskId:)` returns the packet (bearer-authenticated manager
   session, as `executeWorkflow` is).
2. `takeoverTask(input: {taskId, handoverId, hostId, traits, backend,
   model})` reserves the attempt on the controller's store and returns the
   attempt id, the lease (`fence`, `expiresAt`) and a heartbeat token. The
   heartbeat token is the lease credential that launch authorization mints
   (§14, R31), not the consumed launch token. For an S1 packet it also
   returns the bound answer, and it refuses an unanswered S1 packet before
   reserving (§21 R34).
3. The successor executes locally in its own session store. For an S1
   packet it delivers the returned answer as §10.1 step 6 does (§21 R34).
   It heartbeats
   with `heartbeatAttempt(attemptId, token)` every `heartbeatMs`.
4. At terminal it calls `reportAttempt(attemptId, token, outcome,
   evidence: [Evidence], deliverables: [DeliverableRef], packet?: …)` with
   the ledger delta (bounded like a packet). The controller reconciles the
   attempt and runs verification and director exactly as for a local
   attempt. A successor that itself hands over reports a new packet in the
   same call. Each lease credential authorizes at most one report, even
   when two reports race (§14, R32).
5. A missed heartbeat expires the lease on the controller; the next
   takeover fences the successor as §11 describes.

`task serve --takeover [--traits userReachable,…]` on the successor host
polls `tasksAwaitingHandover(traits:)` and runs takeovers unattended.
`task serve` does not exist yet; H6 adds it with `--takeover` as its only
mode (invoking it without `--takeover` is a usage error until P3). The
S2 case still requires the user to act on that host, so the poller only
takes tasks whose required traits it declares.

### 10.3 Placement and host traits

`HostCapabilitySnapshot` and `DistributedWorkerRegistration` gain
`traits: Set<HostTrait>`. They are declared, never probed: `worker.json`
`traits: ["userReachable"]` for a worker, and for the local host the app
profile state that already declares backends
(`RielaAppDaemonWorkflowState.hostTraits`, read by `HostCapabilityResolver`
where it builds the `local` snapshot). `task takeover` and `task serve
--takeover` accept `--traits a,b` to declare traits for that invocation
only (the user at the keyboard is the evidence); it is recorded in the
takeover's placement evidence. `BackendCapabilityPlacementResolver` gains a
`requiredTraits: Set<HostTrait>` parameter beside `requirements:
[WorkflowBackendRequirement]` and reports `host-traits-unavailable: <list>`
in the same failure shape as `backend-unavailable:`. `riela doctor` shows traits with the backend
table; `riela task run --dry-run` shows the trait check.

### 10.4 Answering (S1)

`riela task answer <taskId> --question <id> (--answer-json|--answer-file
|--text <s>|--option <optionId>|--use-default)`:

- Validates the payload against `answerSchema` when present; `--option`
  produces `{ "option": "<id>" }`; `--text` produces `{ "text": "<s>" }`.
- Records `Decision.kind = .answer(...)`, `Evidence.kind = .handoverAnswer`,
  and enqueues a `PendingAttemptReservation` with `entry: .takeover`.
  §21 R25 defines how an answer is bound to its handover.
- The task moves `waiting(.handover)` → `scheduled`; a local `task run` or
  a remote `task takeover` consumes it. When the packet's reason was S1 and
  no traits are required, the controller host may run it itself
  (`task run`), which is the common "answer on the phone, the server
  continues" case.

The agent director may answer when its allowed decision kinds include
`answer`; it receives the question in `TaskView`. The default policy does
not allow it.

### 10.5 Plain sessions: adoption

`riela session handover <sessionId> [--reason …]` and the envelope
outside a task both go through **adoption**: create an `Intent` (origin
`cli`, instruction from the workflow's description and the run's input) and
a `WorkTask` with `plan: .workflow(<the session's workflow reference>)`,
`context: .repository(<working dir>)` when it is a git repository, default
guard and director policies, then an `Attempt` row that points at the
existing session with `entry: .start` and `state: .terminal`, then the
handover as for any attempt. Adoption is recorded as `Evidence.kind =
.contextSnapshot` with `adoptedFromSession`. `session resume` keeps working
for a suspended plain session on the same store when the user does not want
a task; adoption is only for handover.

An adopted session ran in a checkout the attempt does not own (the user's
own branch, possibly dirty), so adoption never switches branches, commits,
creates refs or pushes there (§21 R29, user-qa Q10 default (a)). It only
reads the repository: it resolves the top level, refuses an unborn `HEAD`,
checks that the successor branch name is valid and unused, and records the
adopted attempt's `isolation` as `{path: <top level>, branch: <successor
branch, not created>, baseRevision: <HEAD>}`. The seal records the
repository deliverable as `.unpublished(lastKnown: HEAD)` with the
checkout's `dirtyPaths`, which the brief lists. The user's files stay where
they are; a takeover starts from `HEAD` (R28) under the task's isolation,
so uncommitted adopted work is not carried unless the user commits it
before handing over. An explicit publish opt-in (Q10 (b)) is not part of
this design.

## 11. Leases and fencing

- `work_leases` gains `heartbeat_at`, `expires_at`, `fence INTEGER NOT
  NULL DEFAULT 1`, `host_id`. `work_tasks` gains a generated `fence` column
  from the record (`WorkTask.fence`, the last fence issued for the task).
- The owner heartbeats in `touchLoopConcurrencyLease`'s position: on every
  runtime snapshot save and on a 15 s timer while a node runs. Heartbeats
  are `UPDATE … WHERE attempt_id = ? AND fence = ?`; zero rows updated
  means fenced out → the runner raises `leaseLost` at the next step
  boundary (or immediately if the timer detects it) and persists
  `failed(.leaseLost)`. Remote successors heartbeat over GraphQL.
- `task takeover --force-orphan` and `task reconcile` refuse a lease whose
  `expires_at` is in the future. On an expired lease they `UPDATE
  work_leases SET fence = fence + 1` and record `Evidence.kind = .leaseFence`
  with `OwnerLossEvidence`; the old owner's next heartbeat fails.
- An expired lease whose owner is later shown to have completed (its
  terminal snapshot arrives after the fence) is reconciled as `superseded`:
  the attempt's evidence is kept, its outcome is not judged, and `task show`
  labels it. This is the race §17.2 warns about; the fence makes it
  observable instead of silent.
- Guard evaluation of a later attempt (terminal guard, cumulative wall
  clock) takes a fenced predecessor's result from its work-store record,
  not from its session. The owner may have died before launch or before
  any terminal write, so it may have no terminal session (§21 R33).

## 12. Surfaces

CLI (all under the existing `task` and `session` families; catalog rows
added for each):

| Command | Purpose |
| --- | --- |
| `task handover <taskId> --reason <text> [--now] [--to host\|group] [--sink kind[,kind]]` | operator-initiated handover of a live attempt (the reason is required; it is the operator decision's reason) |
| `task takeover <taskId> [--packet <locator\|path>] [--endpoint URL] [--force-orphan] [--clone-into DIR] [--working-dir DIR]` | become the successor |
| `task answer <taskId> --question ID (--answer-json\|--answer-file\|--text\|--option\|--use-default)` | S1 answer |
| `task handovers <taskId> [--output json]` | list packets with sinks, digests, successors |
| `task reconcile [--expired-leases] [--dry-run]` | seal packets for expired leases |
| `task serve --takeover [--traits …] [--endpoint URL]` | unattended successor loop |
| `session handover <sessionId> [--reason]` | adopt a plain session into a task and hand it over |
| `session resume <sessionId>` | now accepts `suspended` (same store); prints the question and the `task answer` hint when the suspend reason is S1 and no answer is stored |
| `task show` | gains `handovers`, `lease {fence, expiresAt, hostId}`, `suspend` |
| `doctor` | shows host traits |

GraphQL (first fields of the P5 task API, under manager-session
authentication, executable over `/graphql` in `riela serve`, not only
through the CLI parity commands). Module split, following the routine
surface: `Sources/RielaGraphQL/TaskHandoverGraphQL.swift` holds the DTOs
(the packet travels as its canonical JSON object plus `digest`), the field
executor and a `TaskHandoverGraphQLProviding` protocol, because
`RielaGraphQL` cannot import `RielaWork`; the provider over `WorkStore`,
`HandoverCoordinator` and `TaskDispatch` is
`Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`, wired in
`Sources/RielaCLI/ServeWebHost.swift` behind
`WorkflowExecutionAuthorizationWrapper`. Catalog rows extend
`SurfaceCatalog.taskMutationRows`; the new rows bind their GraphQL column
to these fields instead of `.blocked(P5)`, and the SDL is regenerated with
`scripts/surface-parity/generate-sdl.sh`.

```graphql
type Query {
  taskHandover(taskId: String!, handoverId: String): TaskHandoverPayload!
  tasksAwaitingHandover(traits: [String!]): TasksAwaitingHandoverPayload!
}
type Mutation {
  requestTaskHandover(input: RequestTaskHandoverInput!): TaskHandoverMutationPayload!
  answerTask(input: AnswerTaskInput!): TaskHandoverMutationPayload!
  takeoverTask(input: TakeoverTaskInput!): TakeoverTaskPayload!
  heartbeatAttempt(attemptId: String!, token: String!): LeaseStatePayload!
  reportAttempt(input: ReportAttemptInput!): ReportAttemptPayload!
}
```

These are the accepted wh-12 signatures (§21 R35). Every payload carries
`errors: [TaskHandoverGraphQLError!]!`; traits travel as strings and an
unknown trait is `invalid_input`. The object and input types are the
`taskHandoverGraphQLSchemaTypes` block in `TaskHandoverGraphQL.swift`,
including R34's `HandoverAnswerPayload`. The generated SDL registers the
seven root fields and that block unchanged.

The CLI table above lists the options that define behavior. Each
`SurfaceCatalog` row lists every option its shipped parser accepts,
including the shared store options (`--scope`, `--working-dir`,
`--session-store`, `--output`, `--principal`) and the remote options
(`--auth-token`, `--auth-token-env`, `--manager-session-id`). Read the
options from the parser, not from this table.

Events and notifications: a new `WorkflowRunEvent.handover(SessionEnvelope,
HandoverPayload)` (`handover` in the JSONL stream) at seal time; the LB4
`LoopNotificationDispatcher` gains the `handover` outcome with the brief's
first 2 KiB, the question, and the locators, sent at seal time, not only at
run end. Chat event sources that already reply (`riela/chat-reply-worker`)
may render the question; the reply path into `task answer` is P3 chat
intake and is not built here.

Skills: `riela-workflow-run` (takeover and answer recipes),
`riela-workflow` (the `handover` envelope and add-on), `riela-troubleshooting`
(`suspended`, `stalled`, `leaseLost`), `riela-manager-control` (the new
mutations). The catalog parity gates cover every new row.

## 13. Storage

- `work_handovers(handover_id PK, task_id, from_attempt_id, successor_attempt_id NULL, reason_kind GENERATED, digest, record JSONB, created_at)`,
  index on `task_id`.
- `work_leases` columns as §11; `work_tasks.fence` generated.
- `cli_workflow_sessions` / `workflow_runtime_snapshots`: `session_status`
  generated columns accept `suspended`; `WorkflowSession` gains
  `suspend: SuspendRecord?`. Schema generation 9 is the single
  `SQLiteWorkflowRuntimePersistenceStore.schemaGeneration` bump; it also
  covers `work_handovers`, `work_handover_requests` and the new
  `work_leases` columns (same file, same guard, no migration registered).
- `distributed/jobs.json` snapshot and `work_hosts` records gain `traits`.
- Sink files under `<session-store>/handovers/`; git refs under
  `refs/riela/handovers/`; `riela gc` learns both, keeping packets whose
  task is not terminal.
- Packet JSON is canonical (sorted keys, ISO-8601 dates, no floats) so the
  digest is stable across hosts; the canonicalizer is the one the
  environment consolidation plans for `DefinitionVersion` and is introduced
  here first.

## 14. Security

- **Redaction.** `variables` and `history` are filtered through the
  existing agent-environment redaction rules plus the node `env` bindings'
  names: any variable whose key matches a binding marked secret, or any
  value equal to a bound environment value at suspend time, is replaced by
  `"<redacted:ENV_NAME>"`. The brief never contains raw variables.
- **Sinks are outbound.** Writing a packet to kaiba, a git remote or a
  command publishes it; the packet therefore contains references and
  bounded excerpts, never full transcripts. `handover.sinks` is explicit
  opt-in per task/workflow/config; the store sink alone publishes nothing.
- **Takeover authority.** `takeoverTask`, `answerTask` and `reportAttempt`
  require the manager session bearer as `executeWorkflow` does. An attempt
  has two credentials in sequence, and the store keeps only the digest of
  the current one (`attempt.launch.tokenDigest` = `work_leases.token_digest`):
  - the **launch token**, minted by reservation and consumed exactly once by
    `authorizeAttemptLaunch`; a replay fails because its digest is gone and
    the launch phase is no longer `reserved`;
  - the **lease credential**, a fresh random value that
    `authorizeAttemptLaunch` mints when it consumes the launch token and
    returns to its caller. `heartbeatAttempt` and `reportAttempt` verify it
    against the stored digest. `takeoverTask` returns it as
    `heartbeatToken`; local runs discard it. The stored digest must never be
    derivable from public ids (no `consumed:<attemptId>:<sessionId>`
    digest), the credential is never logged or persisted in clear, and a
    later rotation (the director child relaunch) invalidates it.
  - **Report claim.** `reportAttempt` first validates its input read-only
    (snapshot decode, session match), then claims the report with one
    compare-and-swap write transaction: it rotates `work_leases.token_digest`
    (and `attempt.launch.tokenDigest` with it) from the presented
    credential's digest to the digest of a fresh random value that is never
    returned, and proceeds only when exactly one row changed. The lease row,
    its fence and its `expires_at` stay, so a reconciliation that fails after
    the claim leaves the attempt recoverable through `--force-orphan` once
    the lease expires. Of two concurrent reports with the same credential,
    exactly one claims and reconciles; the other gets `unauthorized` and
    changes no task, attempt, decision or evidence row. A replay after
    reconciliation also gets `unauthorized` (Q11 default (a)).
  `--force-orphan` is a human decision recorded with the CLI principal.
- **Fencing beats trust.** A successor cannot be blocked by a dead owner,
  and a live owner cannot silently continue after a takeover; the fence is
  checked on the owner's side too.
- **Branch scope.** Publication is restricted to `riela/task/*` (template)
  branches and never force-pushes; the operator's branches are untouched.

## 15. Phases

| Phase | Delivers | Depends on |
| --- | --- | --- |
| H0 session suspend | `suspended` status, `SuspendRecord`, `stalled`/`leaseLost` kinds, resume from suspended, schema gen 9 | — |
| H1 packet and takeover entry | `HandoverPacket` + builder + brief, `work_handovers`, `AttemptEntry.takeover`, `DecisionKind.handover/answer/takeover`, `WaitReason.handover`, evidence kinds, same-store `task takeover` without deliverables | H0 |
| H2 triggers | envelope + `riela/handover-request`, wait-signal classifier, `handoverOnInactivity` director rule, `task handover`, `handover` run event and notification | H1 |
| H3 answers and history | `task answer`, answer injection, `RuntimeHistoryImport` from suspended/bundle, `session handover` adoption | H1 |
| H4 deliverables | `GitBranchWorkspaceRuntime` (branch, checkpoint, publish, materialize), `Attempt.isolation` populated, worker allowance, document deliverable collection, `riela/git-publish-branch` | H1 |
| H5 leases | heartbeat/expiry/fence, owner-side fence check, `--force-orphan`, `task reconcile`, superseded reconciliation | H1 |
| H6 sinks and cross-host | kaiba/gitRef/file/command sinks, host traits, placement traits, GraphQL fields over `/graphql`, remote takeover + heartbeat + report, `task serve --takeover` | H2–H5 |
| H7 rollout | examples (`task-handover-answer`, `task-handover-presence`, `task-handover-orphan`), skills, catalog rows, docs, `riela gc` | H6 |

H1 alone already lets a second process on the same host continue a task
that declared a handover, which is the smallest useful slice.

### 15.1 Example and end-to-end verification contract

"Passes in mock mode" means both of the following, because the generic
example parity loop only runs plain `workflow run` and mock responses
cannot branch on input (§2):

- **Generic parity loop.** Each of the three examples ships a
  `mock-scenario.json`, is listed in `rielaExampleWorkflowNames()`, and
  `expectedMockScenarioCount` rises 40 → 43. The loop gains one explicit
  set, `ExampleCatalog.expectedSuspendedMockScenarioExamples =
  ["task-handover-answer", "task-handover-presence"]`, for which it asserts
  exit `.suspended`, `status == .suspended` and a non-nil
  `session.suspend`; every other example keeps the `.success` /
  `.completed` assertion. `task-handover-orphan`'s plain run completes.
- **Harness flow tests.** `Tests/RielaCLITests/TaskHandoverExampleTests.swift`
  drives each example through `TaskExampleHarness` (the
  `TaskRuntimeExampleTests` precedent): answer — `task run` suspends and
  seals a packet with a stable digest, `task answer`, `task takeover`
  completes with the answer in the resume step's `inputSnapshot` and the
  history imported; presence — takeover refused without `userReachable`,
  accepted with `--traits userReachable`; orphan — owner stopped after
  launch, injected clock past `expiresAt`, `task takeover --force-orphan`
  completes, the revived owner's heartbeat returns fenced and it persists
  `failed(.leaseLost)`.
- **Deterministic mock takeover.** The answer and presence examples
  declare the handover from a step whose business output is accepted and
  set `resumeStepId` to the next step, so the successor never re-runs the
  declaring node and the per-node mock sequence cannot re-emit the
  envelope.
- **Multi-clone and cross-host.** Second-clone materialization is proven
  with temporary repositories sharing a bare remote (no network); remote
  takeover is proven by a two-store test (controller store + successor
  store) through the in-process GraphQL executor with the authorization
  wrapper. A live two-host check is optional operator evidence under
  `tmp/work-handover/`, not a completion criterion.
- **Hermetic repository tests (2026-10-01).** Every test that runs git
  creates its own temporary repository and local bare remote, passes that
  root explicitly, and asserts that the resolved top level is inside its
  temporary directory. A "non-repository" fixture bounds git discovery with
  `GIT_CEILING_DIRECTORIES` so it cannot reach an enclosing checkout. The
  ceiling must be a proper ancestor of the directory git starts in, such as
  the fixture's parent or the resolved temporary root. Git ignores a ceiling
  equal to its start directory. The ceiling must reach the git child through
  `CLIRuntimeEnvironment.mergedProcessEnvironment()`, not only the process
  environment (§21 R35). No
  test resolves the process working directory's repository, switches its
  branch, commits to it or pushes to its `origin`. Q10 regressions: adopting
  a session in a dirty checkout leaves branch, `HEAD`, index, working tree
  and remote refs unchanged; the publisher refuses an isolation it does not
  own (§21 R29).
- **Baseline.** Full serial `swift test` is recorded on base commit
  `01b38f02` before implementation; every failure afterwards is classified
  against it.

## 16. Rejected alternatives

- **Pause inside the node (keep the agent process alive and stream the
  answer in).** Vendor CLIs cannot be attached to from another host, and a
  paused process holds the lease, the workspace and the budget. Rejected;
  the step re-executes with the answer, and idempotency is the node's
  problem as it already is for reruns.
- **Snapshot the process or container.** Declined by the ax-substrate
  intake (§7) and by this design: the durable state is the store and git.
- **Make the packet the agent's job (prompt convention only).** This is
  what fable-family workflows do today with `checkpoint_blocked`, and it is
  why the feature does not exist: the agent forgets, truncates, or
  invents; deliverables are not published; the successor has no locator.
  The agent contributes a note and a question; the runtime builds the rest.
- **Push takeovers from the controller through the distributed job
  queue.** Jobs are per node with 1 MiB results and 30 s leases; a task
  attempt is minutes to hours and needs a whole session store. The
  successor pulls and reports; the controller stays the ledger.
- **A separate "handover service".** The Work Runtime is already the
  place where attempts, leases, evidence and placement live; a second store
  would duplicate the fence.
- **Force-push or push to the user's branch.** Never; publication is
  confined to `riela/task/*`.
- **Timeout-based takeover without a fence.** §17.2 is right that expiry
  proves nothing; the fence is what makes takeover safe.
- **Copy cwd-local memory/KV into the packet.** Unbounded and
  semantically wrong (they are keyed by workflow id and path). Listed as
  `localOnly` and warned at validate time instead.

## 17. Risks

- **Mid-node interruption loses work.** S3 and `--now` interrupt a node;
  the step re-runs. Step-boundary checkpoints bound the repository loss to
  one step; document writes rely on add-on idempotency. Stated in the
  brief so the successor agent checks before redoing.
- **Wait-signal classification is adapter-specific and will drift with
  vendor CLIs.** The table is data, tested per adapter with recorded event
  fixtures, and unclassified events fall back to inactivity, which is
  today's behavior.
- **Schema generation bump discards existing session stores.** Consistent
  with every previous generation; stated in the rollout notes.
- **Publication needs a remote.** A repository with no remote can only be
  handed over on the same host or shared filesystem; the packet says so
  (`state: .checkpointFailed("no remote")`) and the takeover command refuses
  a `--endpoint` takeover of such a task.
- **The fence race window.** Between expiry and the owner's next heartbeat
  the owner may still write to its branch. Publication from a fenced owner
  is refused (the publish step re-checks the fence), so the branch cannot
  diverge after a takeover; local dirty files on the old host are lost and
  listed.
- **Adopted uncommitted work is not carried.** Under Q10 (a) an adopted
  session's dirty files stay in the user's checkout and are only listed in
  the packet; the successor starts from `HEAD`. This trades continuity for
  never pushing a user's unrelated changes.
- **Budget accounting across hosts** depends on `reportAttempt` carrying
  costs; a successor that never reports leaves the task with an expired
  lease and no outcome, which `task reconcile` turns into another packet.

## 18. Resolved questions

- *Is the packet the session export?* No. Export is the status JSON;
  the packet is a bounded, redacted, digest-sealed continuation record with
  deliverable locators. Export stays as is.
- *Does a takeover keep the vendor thread (`backendSessionId`)?* No.
  Thread reuse is in-memory and host-local; the successor starts a new
  thread with the brief. Recording the predecessor's `backendSessionId` in
  the packet is informational.
- *Do handovers count against `maxAttempts`?* Yes; they are attempts.
  A task that hands over forever is a guard violation.
- *Can a successor be on a different backend?* Yes, subject to the node's
  `executionBackend` pin or `backendPolicy` as for any attempt; the packet
  does not pin the predecessor's backend.
- *Where does monja fit?* As a document deliverable (ids reported through
  `output.projection.deliverables`) and as a `command` sink. A native monja
  add-on is P3's `MonjaTrackerAdapter`, not this design.

## 19. Open questions (with recommendations)

Recorded in `design-docs/user-qa/qa-work-handover-and-takeover.md`:

The file also holds Q6 (automatic adoption), Q7 (per-invocation
`--traits`), Q8 (sink configuration scope), Q9 (takeover of a
`checkpointFailed` repository deliverable) and Q10 (publishing from a
checkout the attempt does not own); all proceed on their defaults.

1. Branch template default `riela/task/<taskId>/g<generation>` and whether
   checkpoints should be squashed at accept-time finalization.
   Recommendation: keep checkpoints; finalization squashes only when the
   task's `completion` asks for a single commit.
2. Default sinks when none are configured: store only (recommended) or
   store + kaiba when a default instance exists.
3. Whether `task serve --takeover` should exist in H6 or wait for P3's
   `task serve`. Recommendation: ship the `--takeover` poller as its own
   loop in H6 and fold it into `task serve` when P3 lands.
4. Lease TTL default 300 s and heartbeat 15 s.
5. Whether the envelope key is `handover` or namespaced `riela.handover`.
   Recommendation: `handover`, reserved by validation like other envelope
   keys.

## 20. Existing features to align

- `design-cancellation-and-orphan-session-resilience.md` P4 (`session
  reconcile`) is delivered for tasks by `task reconcile`; P1 (`cancelled`
  status) stays out of scope, cancellation remains `failed(.cancelled)`.
- `design-ax-substrate-inspired-capabilities.md` adoption E: `suspended`
  and `SuspendRecord` land here; `session fork` and `idleSuspendMs` do not.
- `design-execution-environment-consolidation.md` E2: `GitBranchWorkspaceRuntime`
  is the branch/publication slice its §21 finding 8 deferred to "a future
  joint spec"; `IsolationRef` → `WorkspaceInstanceRef` is a rename when E2
  lands; `refs/riela/handovers` and `riela/task/*` are the names E2 adopts.
- `design-work-runtime-consolidation.md` §7 `stalled` failure kind lands
  here; P4 `ChangeRuntime` gains its first implementation; P5 GraphQL task
  API starts with the handover fields.
- `design-loop-engineering-convergence-and-operations.md` LB4
  notifications gain the `handover` outcome.
- `design-graphql-manager-control-plane.md` typed manager actions: `answer`
  is the first typed action implemented in Swift.
- `design-agent-node-output-contract.md` D2: the `handover` envelope key is
  validated before the business payload, as envelope normalization already
  does for its existing keys.

## 21. Source reconciliation (2026-09-30)

Corrections made when the design was checked against `01b38f02` before
implementation. Each replaces a statement that contradicted the source;
none changes a §3 decision.

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R1 | `SuspendRecord.reason: HandoverReason`, `producer: EvidenceProducer` | `reasonKind: SuspendReasonKind`, `producer: SuspendProducer`; question/presence/trait types in `RielaCore/HandoverContracts.swift` | `RielaWork` depends on `RielaCore`, not the reverse (`Package.swift`) |
| R2 | envelope normalization in `RuntimeOutputExtraction.swift` | `AdapterContracts.swift:335` | grep |
| R3 | runner result gains `.suspended(SuspendRecord)` | `WorkflowRunResult.status == .suspended` + `session.suspend`; `CLIExitCode.suspended = 5` | `WorkflowRunResult.swift:3`, `RielaCommand.swift:10-19` |
| R4 | `HandoverPolicy.onInactivity: rerun\|handover\|stop` | `DeterministicDirectorRules.handoverOnInactivity: Bool` before `rerunOnInactivity` | avoids two knobs for one rule (`DeterministicDirector.swift:77-86`) |
| R5 | `riela config set host.traits` | profile state `hostTraits` + worker.json `traits` + per-invocation `--traits` | no `config` command; local snapshot built from `RielaAppDaemonWorkflowState` |
| R6 | sink config merged task → workflow → `riela config` profile | task → workflow, plus `--sink` | no `config` command |
| R7 | `snapshot` reuses fanout change capture | `dirtyPaths` via `git status --porcelain=v1 -z` | `WorkflowFanoutChangeEvidence` is internal to `RielaCore` |
| R8 | GraphQL resolvers in `RielaGraphQL` over RielaWork types | DTOs + `TaskHandoverGraphQLProviding` in `RielaGraphQL`; provider in `RielaCLI`; host wiring in `RielaCLI/ServeWebHost.swift` | `RielaGraphQL` depends on `RielaCore` only; `ServeWebHost` is in `RielaCLI` |
| R9 | worker git allowance edits a `RielaCLI` executor | `Sources/RielaCore/DistributedWorkerNodeExecutor.swift:108` | grep |
| R10 | placement "requirements gain `requiredTraits`" | new `requiredTraits` parameter beside `[WorkflowBackendRequirement]` | `BackendCapabilityPlacement.swift:52-76` |
| R11 | `task serve --takeover` extends an existing command | `task serve` is new, `--takeover` only | `TaskCommandKind` = show/list/run/decide |
| R12 | "examples pass in mock mode" undefined | §15.1 contract (suspended set in the parity loop + harness flow tests) | `RielaExampleParityTests.swift:245-347` asserts `.completed` |

Refinements made while decomposing the implementation plan (same date):

| # | Was | Now | Reason |
| --- | --- | --- | --- |
| R13 | skills `riela-workflow`, `riela-troubleshooting`, `riela-manager-control`, `riela-node-addons` updated | in-repo `Resources/skills/riela-workflow-run` and `riela-workflow-reference` updated; the other four live in the riela-packages repository and are a recorded follow-up | only two skills are in this repository (`SurfaceParitySkillTests.skillsRoot`) |
| R14 | `HandoverPolicy.notify: [LoopNotificationTarget]` | no `notify` field; handover notifications use the workflow's `loop.notifications` channels when `on` contains `handover` | one channel declaration, LB4 dispatcher reused as is |
| R15 | `output.projection.deliverables` | `output.deliverables` (`NodeOutputContract.deliverables`) | `WorkflowOutputProjection` is a single-`kind` struct |
| R16 | a remote successor that hands over "reports a new packet" | it reports its suspended snapshot and deliverables; the controller seals the packet | only the controller holds the task, ledger and store |
| R17 | canonical JSON "no floats" | integers verbatim, other numbers as Swift shortest round-trip `Double.description`, dates UTC ISO-8601 with milliseconds (rounded), sets encoded as sorted arrays; the digest is recomputed from a canonical re-encoding with `sinks = []`, `digest = ""` | accepted outputs legitimately contain decimals; re-encoding must be byte-stable |
| R18 | checkpoints journaled through the finalization store | checkpoints rely on git's atomic commit and ref update; a crash leaves staged changes that the next checkpoint or the successor's `dirtyPaths` reports | the finalization journal is keyed to add-on executions |
| R19 | `HandoverContinuationContract.answer` filled at takeover time | removed; the answer is `Decision.answer` and reaches the successor as variable `handover.answer` and a delivered message | a sealed packet is immutable (digest) |
| R20 | S2 and S4 always end `suspended` | boundary handovers (envelope, add-on, cooperative `task handover`) end `suspended`; handovers that interrupt a running node end `failed` with `.stalled` (inactivity, wait signal), `.cancelled` (`task handover --now`) or `.leaseLost` (fence) | a cancelled node cannot be recorded as a clean suspend; history import accepts all of these sources |
| R21 | `riela/handover-request` resume step defaults | `resumeStepId` is required in its config and must be the add-on step's selected next step | re-running the add-on would request again |
| R22 | cooperative `task handover` "observed by the owner's `TaskRunCancellation` loop" | the loop records the request; the runner consults a boundary-handover hook on `DeterministicWorkflowRunRequest` after each accepted step and suspends before the next step | only the runner knows the step boundary |

Reconciliation at `c0a138b9` (before finishing wh-10, same date):

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R23 | `traits: Set<HostTrait>` / `requiredTraits: Set<HostTrait>` (§4, §10.3) | `[HostTrait]` deduplicated and sorted at init, strict decode (unknown value fails); placement compares as sets | accepted wh-01 source: `HandoverContracts.swift:34-42`, `DistributedWorkerModels.swift:28-67`, `WorkHandover.swift:187,248`, `BackendCapabilityPlacement.swift:64,209`; R17 already encodes sets as sorted arrays |
| R24 | worker traits reach registration and the controller-side `HostCapabilitySnapshot` only | `DistributedWorkerStatus` also gains `traits: [HostTrait]` (strict decode), filled from the stored registration in `DistributedJobController.workerStatuses`, so `workers()`/`inspectWorkers()` expose declared worker traits; `doctor` keeps showing the local host's traits only | `DistributedWorkerModels.swift:72-98` has no `traits`; `DistributedJobController.swift:398-410` builds status from the registration; wh-10 scope amendment |

Reconciliation at `9cb176a4` (wh-14 resume, 2026-10-01):

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R25 | §10.4 left open how a stored `Decision.answer` is tied to the handover it answers | An answer belongs to handover H only when all of these hold: the decision is on H's task, `decision.attemptId == H.fromAttemptId`, the reason names `H.id` (the `recordAnswer` convention), `answer.questionId` equals H's question id, and it was recorded no earlier than the seal. "No earlier than the seal" compares the store columns `work_decisions.created_at >= work_handovers.created_at`. Both are written by `WorkStore.timestamp`, which is UTC ISO-8601 with milliseconds, so the strings sort in time order. The comparison never uses dates decoded from records. `WorkStore.latestAnswer(handoverId:)` is the only lookup. `requestTakeover`, takeover dispatch and the answer injection (variable and delivered message) all use it; there is no second filter in `RielaCLI`. | Decision records are encoded with `.iso8601`, which drops fractional seconds (`WorkStore.swift:488-498`). Packets use canonical milliseconds (R17, `JSONCanonical.swift:7-10`). An answer recorded within the same second as the seal decodes to an earlier date, so `decision.createdAt >= packet.createdAt` (`WorkStore+Takeover.swift:215`) rejects it (`tmp/work-handover/wh-14-task-dispatch-runtime/step6-implement-resume-3/dispatch-answer-db-diagnostic.log`). `TaskDispatch+Handover.swift:402-416` has a second lookup that has no attempt or time check. |

Reconciliation at `76e9ea43` (wh-14 terminal persistence, 2026-10-01):

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R26 | §5 orders every handover as "seal, then persist the session", and §6.3/§11 say an interrupting handover "cancels the attempt through the existing cancellation path" and then ends `failed(.stalled)` / `failed(.leaseLost)` | An interrupting handover (R20: inactivity, wait signal, fence loss, `task handover --now`) has exactly **one** terminal session write, done by the runner, and its `failureKind` is the trigger's cause. (1) `DeterministicWorkflowRunRequest` gains `cancellationCause: (@Sendable () -> WorkflowSessionFailureKind?)?`, next to `boundaryHandover` (R22). When the runner ends on `CancellationError`, it asks this closure. `nil` keeps today's `.cancelled` and `"workflow run cancelled"`. A non-nil value can only be `.stalled`, `.leaseLost` or `.cancelled`, and it becomes the failure kind of the single `markSessionFailed` / live-persistence write. The task dispatch path supplies the closure from `TaskRunHandoverTriggerState`, where the first recorded trigger wins. The trigger is recorded before `execution.cancel()`. (2) The terminal-write guard in `SQLiteWorkflowRuntimePersistenceStore` stays as it is: a terminal status never changes to a different terminal status (`terminalSnapshotConflict`). It gains one extra case for a pending `work_cancellations` row: it accepts `failed(.stalled)` when the row's `decision_id` joins a `work_decisions` row with `kind = 'handover'` for the same attempt. It still accepts `failed(.cancelled)` for any pending row, and rejects everything else with `cancellationPending`. (3) The seal of an interrupting handover comes **after** that terminal write and never writes a session snapshot again. It reads the terminal snapshot, acknowledges the director's pending `.handover` cancellation row with the guarded `WorkStore` method (`terminal_status = failed`), and seals. `TaskRunCancellation` skips `persistJoinedCancellation` / `saveCancellationSession` for that row. (4) A fenced owner (revived, or still running after `--force-orphan` / `task reconcile`) writes its terminal `failed(.leaseLost)` and does **not** seal: the fencing side already sealed the packet from the last snapshot. Each attempt is sealed at most once. (5) Crash window: a session that is `failed(.stalled \| .leaseLost)` with no packet is sealed from its terminal snapshot by `task reconcile` / `adoptAndSeal`. That is the same recovery §5 already gives the publish-before-seal crash. Boundary handovers (envelope, add-on, cooperative `task handover`) keep the §5 order and end `suspended`. | The runner maps every `CancellationError` to `.cancelled` (`DeterministicWorkflowRunner+Cancellation.swift:4-6,54-57`) and writes the terminal snapshot itself. A later `.stalled` save then hits `terminalSnapshotConflict` (`SQLiteWorkflowRuntimePersistenceStore.swift:778-786`). While the director's row is pending, the pending-cancellation guard accepts only `failed(.cancelled)` (`:766-772`). The director `.handover` decision writes a pending `work_cancellations` row (`WorkStore+Decisions.swift:147-190`). The fence-loss and wait-signal triggers write none (`TaskRunCancellation.swift:137-161`). `work_decisions.kind` is a stored generated column (`WorkStore+Schema.swift:164-172`). Regression: `TaskHandoverDispatchTests` director-inactivity case (commit `80e82d5d`). |

Reconciliation at `076652a0` (wh-14 resume, adopted-session takeover, 2026-10-01):

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R27 (items 2 claim, 3 and 4 superseded by R29) | §10.5 adopts a plain session with `context: .repository(<working dir>)` "when it is a git repository" and then hands it over "as for any attempt", without saying where the adopted attempt's branch and `isolation` come from | (1) `adoptAndSeal` passes a repository root to `TaskAdoption.adopt` only when `git rev-parse --show-toplevel` succeeds in the working directory, and it passes that top-level path. Otherwise the task has no context and the packet has no repository deliverable. (2) For a repository, **before** `TaskAdoption.adopt` writes any row, and while the `SessionExecutionLock` is held, `adoptAndSeal` preflights every refusable claim condition. `git rev-parse --verify HEAD^{commit}` must succeed (an unborn `HEAD` is refused, because `baseRevision` needs a commit). The branch name computed from the task's `PublicationPolicy.branchTemplate`, using the generation the adoption will assign (1 for a new task, the task's next generation for an existing task), must pass `git check-ref-format --branch`. `refs/heads/<branch>` must not exist (`git show-ref --verify --quiet`). Any failed check refuses the adoption with no row written and no packet sealed, so the session stays adoptable once the condition is fixed. After adoption and before sealing, and while the lock is still held, adoption **claims the checkout**. It creates that branch in place at the current `HEAD` with `git switch -c`, so the working tree and index are carried unchanged. The claim does not refuse a dirty tree, because that tree is the adopted work. `ensureBranch(.shared)` keeps its clean-tree refusal for dispatch starts and is not used here. The only remaining post-adoption failure is `git switch -c` itself failing after a passed preflight (for example, a concurrent external ref write or an index lock), which is a residual edge case. The preflight and the claim run git through the existing `GitCommandRunning` seam. (3) The adopted attempt's stored record gets `isolation = {path: <top-level>, branch, baseRevision: <HEAD sha before the claim>}`. That attempt is already `terminal`, and it is the only terminal attempt whose `isolation` may be set once, from null. The prepared/running update stays as is for dispatch. (4) Adoption seals as a live owner (`ownerAlive: true`), so the publisher checkpoints (trailer `Riela-Checkpoint: <attemptId>/handover`) and publishes, and the deliverable is `.published` with `headCommit`. An adopted attempt holds no lease, so the publisher is given no reservation fence and skips the lease-fence comparison. The held `SessionExecutionLock` provides exclusivity. Every leased attempt keeps the comparison, and a leased attempt with a missing or different fence still yields `checkpointFailed("fenced")`. | `TaskHandoverRuntime.adoptAndSeal` passes `repositoryRoot: workingDirectory` unconditionally and seals with the default `ownerAlive: false` (`TaskHandoverRuntime.swift:73-125,209-266`). `TaskAdoption.adopt` builds the attempt with no `isolation` (`TaskAdoption.swift:21-23`). `TaskDeliverablePublisher.publish` then emits `.checkpointFailed("attempt isolation is unavailable")` with `branch: ""` (`TaskHandoverSupport.swift:53-60`), and the takeover dispatch rejects it with "takeover repository deliverable is not published" (`TaskDispatch+Handover.swift:124-135`). `updateAttemptIsolation` only matches `prepared`/`running` (`WorkStore+Isolation.swift:9-20`). The publisher's fence check compares `loadLease(...)?.fence` with `reservationFence`, which is `-1` for a lease-less attempt (`TaskHandoverSupport.swift:63-69`, `TaskHandoverRuntime.swift:255-259`). This is the open failure in the `076652a0` commit message. `WorkStore.adoptSession` refuses a second adoption of the same session (`WorkStore+Adoption.swift:9-11`). |
| R28 | §9.1 says a successor starts from `lastKnown` for `.unpublished`, but the takeover dispatch accepts only `.published` and does not say what happens to `.checkpointFailed` | A takeover handles the packet's repository deliverable by its state. `.published`: `materialize` at `headCommit` (unchanged). `.unpublished(lastKnown:)`: `materialize` from `lastKnown` when that commit exists locally, else from `baseRevision`. The packet's `dirtyPaths` are already in the brief. This is the `ownerLost` (orphan/reconcile) path for repository tasks. `.checkpointFailed(reason:)`: refused **before** any attempt is reserved, with `takeover repository deliverable checkpoint failed: <reason>`. The task stays `waiting(.handover)`, and no attempt, lease or fence is created. The refusal is made where the unanswered-question refusal is made (`WorkStore.requestTakeover`), and the dispatch repeats the same check before `reserveAttempt`. Recovery is an operator decision (user-qa Q9, default: refuse). | `TaskDispatch+Handover.swift:133-135` throws for every non-`.published` state after reservation. `GitBranchWorkspaceRuntime.materialize` already implements `.unpublished` and throws for `.checkpointFailed` (`GitBranchWorkspaceRuntime.swift:154-172`). `sealOrphan` seals with `ownerAlive: false`, which yields `.unpublished(lastKnown: nil)` (`TaskHandoverSupport.swift:92-97`). |
| R29 | R27 (2)–(4): adoption claims the checkout with `git switch -c <branch>` (carrying a dirty tree), then seals as a live owner, which checkpoints (commits everything) and publishes (pushes) the branch | User-qa Q10 default (a). (1) R27 (1) is unchanged: the repository root is the `git rev-parse --show-toplevel` result, and a non-repository working directory gives a task with no context and a packet with no repository deliverable. (2) The R27 (2) preflight stays and stays read-only: `HEAD^{commit}` must resolve (an unborn `HEAD` is refused), and the successor branch name from `PublicationPolicy.branchTemplate` must pass `git check-ref-format --branch` and must not exist under `refs/heads/`. A failed check writes no row. (3) Adoption runs no git command that writes: no `switch`, `checkout`, `add`, `commit`, `stash`, `reset`, branch or ref creation, and no `push`. Only `rev-parse`, `check-ref-format`, `show-ref` and `status --porcelain` run. (4) The adopted attempt's `isolation` is still recorded once, from null (`recordAdoptedAttemptIsolation`), as `{path: <top level>, branch: <successor branch>, baseRevision: <HEAD sha>}`; the branch is the name a successor will materialize, and adoption does not create it. (5) The adopted attempt is sealed in the publisher's adopted, lease-less mode (the existing `adoptedWithoutLease` seam). In that mode the publisher never checkpoints or publishes; it emits `.repository(root: <top level>, remote: policy.remote, branch: <successor branch>, baseRevision: <HEAD>, headCommit: nil, state: .unpublished(lastKnown: <HEAD>), dirtyPaths: <read-only status, ≤ 512, excluding .riela>)`. (6) For every other seal the publisher checks ownership before any git write. `isolation.branch` must match `policy.branchAllowlist`, otherwise the deliverable is `.checkpointFailed("isolation branch is not attempt-owned")`. `checkpoint` keeps its existing refusal when the branch checked out at `isolation.path` is not `isolation.branch`, which also ends as `.checkpointFailed(reason)`. The lease-fence comparison stays for leased attempts. None of these paths commits or pushes. (7) Takeover of an adopted task follows R28 for `.unpublished` (materialize from `lastKnown` when it exists locally, else `baseRevision`) and the task's isolation (`.shared` from `TaskAdoption`, which is unchanged). A shared materialize refuses a dirty root. On a clean root, the takeover attempt that the operator started in that working directory creates and owns its branch, as any shared repository task start does. A successor on another clone needs `HEAD` reachable from its remote. (8) There is no `--publish` opt-in (Q10 (b)). | `TaskHandoverRuntime.adoptAndSeal` runs `git switch -c` in the resolved checkout and seals with `ownerAlive: true, adoptedWithoutLease: true` (`TaskHandoverRuntime.swift:144-155,186`). `TaskDeliverablePublisher.publish` runs `checkpoint`, which does `git add -A` and commit, and then `publish` for every live owner whose fence check passes or is skipped (`TaskHandoverSupport.swift:62-86`). `publish` checks the allowlist only after the checkpoint commit (`GitBranchWorkspaceRuntime.swift:100-108`). Run session-8 incident: a test resolved the real worktree, and the publisher committed its uncommitted work (6bd80077) and pushed `riela/task/task-adopted-adopted-handover-session/g1` to `origin` (wh-14 plan, STOP-FIRST section). |

Reconciliation at `ffec37fc` (wh-15 resume, 2026-10-01):

| # | Was | Now | Source evidence |
| --- | --- | --- | --- |
| R30 | §12 lists `task handover … [--reason]` as optional | `--reason <text>` is required for `task handover`; `session handover` keeps `[--reason]` | accepted `impl-plans/active/wh-15-task-commands.md:57` and the wh-15 WIP (`TaskHandoverCommands.swift:321`, commit `33d05e75`) require it; an operator handover is recorded as a `Decision`, whose reason is mandatory |
| R31 | §14 "the successor's lease token is single-use per attempt"; §10.2 returns "a heartbeat token" without saying which | the launch token stays one-use; `authorizeAttemptLaunch` mints a random lease credential, stores only its digest in place of the launch digest, and returns it; `takeoverTask` returns it as `heartbeatToken`, which `heartbeatAttempt` and `reportAttempt` (completed and suspended) verify. No new column and no schema-generation bump | at `09953552`, `authorizeAttemptLaunch` (`WorkStore+Reservation.swift:342-356`) replaces the lease digest with `SHA256("consumed:<attemptId>:<sessionId>")`, so the returned launch token fails `verifyLeaseToken` (`WorkStore+Leases.swift:39-45`; wh-16 focused 40/41). Returning that consumed value instead would make the credential derivable from public ids. A separate heartbeat digest column would need a schema change the single-digest form avoids. `markAttemptNodeStarted` and the director child rotation (`WorkStore+Director.swift:46-58`) already match the lease row on `attempt.launch.tokenDigest`, so they keep working |
| R32 | §14 said `reportAttempt` verifies the lease credential but not when it is consumed; the wh-16 amendment asked for the check "inside the same write transaction that reconciles the report" | `reportAttempt` claims the report with a compare-and-swap that rotates the lease digest to an unreturned random value before any side effect (§14 "Report claim"); the loser of a race gets `unauthorized` with no row changed. The row is rotated, not deleted, so orphan recovery still finds it. No new column and no schema-generation bump | at `3f9bcea2`, the provider calls the read-only `verifyLeaseToken` (`TaskHandoverGraphQLProvider.swift:242`, `WorkStore+Leases.swift:39-45`) and then `reconcileExternalTerminal` (`TaskDispatch+Handover.swift:419-477`), which saves the snapshot, resolves the bundle and awaits `sealSuspended` or `reconcileTerminal` across several transactions, so no single transaction spans verification and reconciliation. The lease row is deleted only at the end (`WorkStore+Reservation.swift:755`, `WorkStore+Handovers.swift:172`, `WorkStore+Decisions.swift:173`), so two reports can both pass verification. `fenceOrphan` refuses a task with no lease row (`WorkStore+Takeover.swift:33-42`) and `reconcileExpired` finds candidates only through `expiredLeases` (`TaskHandoverRuntime.swift:54`, `WorkStore+Leases.swift:47`), so deleting the row at claim time would strand an attempt whose reconciliation then fails |
| R33 | §11 says `--force-orphan` / `task reconcile` fence an expired lease so a successor can take over, but does not say how the successor's terminal guard evaluation reads a fenced predecessor that never persisted a terminal session | During terminal guard evaluation, for each attempt of the task, (1) an attempt with `state == .reconciled`, `supersededByFence != nil` and `outcome == failed(.leaseLost)` is **fenced**. Its outcome comes from the work-store record that `fenceOrphan` wrote in the fence transaction. Its session is not required to be terminal. If a runtime snapshot exists, it adds `updatedAt − createdAt` of that snapshot to the cumulative wall clock, whatever its status. If none exists (`notFound`: the owner died before launch), it adds 0 ms. (2) Every other attempt keeps today's rule: a missing or non-terminal session throws "task attempt has no durable terminal session for guard evaluation". The same fenced rule (1) and strict rule (2) apply to the two other wall-clock sums over reconciled attempts, the director budget (`TaskDispatch+Director.swift` `validateDirectorWallClockBudget`) and the agent budget (`WorkStore+Reservation.swift` `requireAgentWallClockBudget`). Each keeps its own error message. (3) Guard evaluation only reads. It never writes, repairs or finalizes the fenced predecessor's session, so the single terminal write (R26) still belongs to the owner's runner. A revived owner still fails its next fenced heartbeat (`UPDATE … WHERE fence = ?` updates 0 rows), raises `leaseLost` and writes its own `failed(.leaseLost)` without sealing (R26 item 4). A later terminal write from that owner is not judged: `reconcileAttempt` already returns a fenced attempt unchanged. (4) Regressions: a runtime test that runs guard evaluation over a fenced, never-launched predecessor (no snapshot) and a fenced, launched predecessor (non-terminal snapshot). Also the wh-17 `task-handover-orphan` end-to-end test: the successor succeeds with a real session, and the predecessor's old-fence heartbeat returns `false`. | The loop at `TaskDispatch.swift:432-439` loads `loadStrictReadOnly(sessionId:)` for every prior attempt and requires `completed`/`failed`/`suspended`. `fenceOrphan` accepts a `prepared`/`running`/`terminal` predecessor and marks it `reconciled`, `failed(.leaseLost)`, `supersededByFence`, `launch.phase = .fenced` with no session write (`WorkStore+Takeover.swift:43-58`). `reconcileAttempt` short-circuits a fenced attempt (`WorkStore+Reservation.swift:724-726`). The director and agent budget loops (`TaskDispatch+Director.swift:536-553`, `WorkStore+Reservation.swift:916-935`) make the same strict check over every `reconciled` attempt whenever `maxWallClockMs` is set. Failure: `tmp/work-handover/wh-17-examples/orphan-after-review.log` (`testOrphanExampleFencesNeverLaunchedOwner`: "task attempt has no durable terminal session for guard evaluation", task left `verifying`) |
| R34 | §10.2 says `takeoverTask` returns the packet, lease and heartbeat token, but not how an S1 answer reaches a successor on another host. The packet is sealed before the answer exists (R19), so it can never carry it | **Contract.** `TakeoverTaskPayload` gains a nullable `answer: HandoverAnswerPayload`, a new output type `{ questionId: String!, payload: JSONObject!, answeredBy: JSONObject!, answeredAt: String! }`. `answeredBy` is the `DecisionProducer` JSON encoding. `answeredAt` uses the same millisecond UTC ISO-8601 form as `expiresAt`. `answer` is non-null exactly when the packet reason is `userInputRequired`; it is null for every other reason. `TakeoverTaskInput`, `taskHandover` and `HandoverPacket` do not change: the answer is bound at reservation time, not stored in the sealed packet. **Controller.** `takeoverTask` reads the answer only through `WorkStore.latestAnswer(handoverId:)` (R25). When the packet is S1 and that returns nil, it fails with code `conflict` and the message `handover <handoverId> needs an answer: riela task answer <taskId> --question <questionId> …` **before** `requestTakeover` or any reservation, so no attempt, lease or fence is created and the task stays `waiting(.handover)`. `requestTakeover` keeps its own check. **Successor.** `TaskRemoteTakeover` delivers a non-null `answer` exactly as the local path (`TaskDispatch+Handover.swift`) does: `handover.answer = answer.payload` in the `handover` variable, `delivered = { "handover": { "answer": payload } }` in the variables, and a `delivered` `WorkflowMessageRecord` to `packet.contract.resumeStepId` in the imported session, with communication id `handover-answer-<handoverId>-<attemptId>`, the last imported execution as `sourceStepExecutionId`, the next `createdOrder`, and `createdAt = answeredAt`. When the packet is S1 and the payload has no `answer`, the successor fails before launching the workflow. **SDL.** The two schema changes (the new type and the new field) are recorded in the wh-18 progress log. wh-20 step 3 registers them with the other handover types and regenerates the SDL. **Tests.** A `TaskHandoverGraphQLProviderTests` case calls the provider directly and checks two things: an answered S1 reservation returns the bound answer, and an unanswered S1 reservation is refused with `conflict` and leaves the attempt list unchanged. A `TaskRemoteTakeoverTests` case is provider-backed: it uses a `task-handover-answer` controller harness plus `answerTask`, and asserts the resume step's `inputSnapshot` holds the answer, the delivered message exists, and the controller task has `succeeded`. Until wh-20 step 3 it takes the same strict `isPendingSchemaRegistration` branch as the other signal-6 tests, and wh-20 removes all three branches. A `TaskHandoverGraphQLTests` case round-trips the payload with and without `answer` | at `3d75d601`, `GraphQLTakeoverTaskPayload` (`TaskHandoverGraphQL.swift:102-110`) has no answer field. `TaskRemoteTakeover` sets `handover` to the raw packet JSON only (`TaskRemoteTakeover.swift:153-156`) and adds no delivered message. The local path injects both the variable and the message (`TaskDispatch+Handover.swift:221-235`, `:393-406`). The provider calls `requestTakeover` (`TaskHandoverGraphQLProvider.swift:134`), whose unanswered-S1 `WorkStoreError` (`WorkStore+Takeover.swift:180-183`) reaches the client only as the generic `internal` "task handover provider failed" (`TaskHandoverGraphQL.swift:274`). Accepted amendment: `impl-plans/active/wh-18-remote-takeover.md` "Answer delivery amendment" |
| R35 (2026-10-01, wh-20 intake) | (a) The §12 GraphQL block used draft names: `ID` arguments, `[HostTrait!]` traits, and the return types `HandoverPacket`, `TaskHandoverResult`, `TaskDecisionResult`, `TakeoverReservation`, `LeaseState` and `AttemptReconciliation`. That also contradicted R34, which names `TakeoverTaskPayload`. (b) §15.1 said only that a non-repository fixture is bounded by `GIT_CEILING_DIRECTORIES`. It did not say what the value must be. | (a) §12 now shows the accepted wh-12 signatures. The generated SDL registers exactly these seven root fields and the `taskHandoverGraphQLSchemaTypes` block (wh-20 step 3). (b) A ceiling must be a proper ancestor of the directory git starts in. Git ignores a ceiling equal to that directory. Production adoption and publication (`TaskHandoverRuntime.gitEnvironment`) set no ceiling of their own. The environment they pass to git is `CLIRuntimeEnvironment.mergedProcessEnvironment()`: the process environment plus the CLI application's environment overrides. It is not raw `ProcessInfo.processInfo.environment`. It carries `GIT_CEILING_DIRECTORIES` unchanged and adds no ceiling of its own, so R27 item 1 still resolves the enclosing top level of the working directory, and a hermetic test's ceiling reaches the git child process. This applies to adoption (`runAdoptionGit`) and to publication and materialization (the `GitBranchWorkspaceRuntime` environments built in `TaskHandoverRuntime.swift` and `TaskDispatch+Handover.swift:125,167`). CLI tests inject the ceiling through `RielaCLIApplication().run(..., environment:)`, and only the merged environment sees it. Regression: a CLI test that passes a proper-ancestor ceiling through the application `environment:` must see that value in the git child process. `TaskDeliverablePublisher.reservationFence` stays `Int?`: `nil` means only the lease-less adopted attempt (R27 item 4, R29), and a leased attempt with a missing lease still compares against `-1` and yields `checkpointFailed("fenced")`. | (a) `impl-plans/active/wh-12-graphql-contracts.md:41-49`; `TaskHandoverGraphQL.swift:233-244,370-390`; `TaskServeTakeover.swift:71` queries `[String!]`. (b) `TaskHandoverRuntime.swift:317,329-343` sets the ceiling to the start directory itself (`workingURL` or `attempt.isolation.path`), which is a no-op, and overwrites any inherited value. The tests set a proper ancestor instead (`TaskHandoverCommandTests.swift:245,264`, `HandoverSinkTests.swift:242`). Low findings from the wh-14 acceptance (commit message "three low findings left for wh-20"): the stale progress-log entries are plan text only (wh-20 closure), the ceiling is resolved as described here, and `reservationFence Int?` stays as documented here. |
