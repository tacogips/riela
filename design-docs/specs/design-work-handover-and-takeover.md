# Work handover and takeover: moving a stalled attempt to another worker

Status: proposed 2026-09-30, zero-based on the shipped Work Runtime P1
(`design-work-runtime-consolidation.md` §4–§8, §17) and the shipped
distributed workers (`design-distributed-workers.md`). No backward
compatibility: the session schema generation bumps, closed enums gain
cases, old stores are discarded as today. Plan:
`impl-plans/active/work-handover-and-takeover.md`. Open user decisions:
`design-docs/user-qa/qa-work-handover-and-takeover.md`.

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

public struct SuspendRecord: Codable, Equatable, Sendable {
  public var reason: HandoverReason
  public var stepId: String                 // step to re-enter
  public var stepExecutionId: String?       // execution that declared or was interrupted
  public var question: HandoverQuestion?    // S1
  public var presence: PresenceRequirement? // S2
  public var progressNote: String?          // agent-authored, ≤ 8 KiB
  public var suspendedAt: Date
  public var producer: EvidenceProducer     // stepExecution | runtime | human
}

// RielaWork — handover side

public enum HandoverReason: Codable, Equatable, Sendable {
  case userInputRequired(HandoverQuestion)
  case userPresenceRequired(PresenceRequirement)
  case ownerLost(OwnerLossEvidence)         // lease expired + fence bumped
  case inactivity(stepId: String, idleMs: Int)
  case operatorMove(reason: String)
}

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
  public var answer: HandoverAnswer?         // filled at takeover time when S1 was answered
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
  public var onInactivity: InactivityHandoverAction   // rerun (today) | handover | stop
  public var onWaitSignal: Bool                       // treat classified backend wait signals as S2 (default true)
  public var checkpoint: CheckpointPolicy             // none | stepBoundary (default) | everyMs(Int)
  public var sinks: [HandoverSinkConfig]              // in addition to the store
  public var publish: PublicationPolicy               // remote, branchTemplate, allowCreateBranch (default true for riela/*)
  public var notify: [LoopNotificationTarget]         // reuses LB4 targets
}
```

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
  `failed`. A crash between publication and the store row leaves the branch
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

  `normalizeOutputContractEnvelope` (`RuntimeOutputExtraction.swift`) strips
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
deterministic director's `inactivity-*` rule consults
`handover.onInactivity`: `rerun` keeps today's behavior, `handover` cancels
the attempt through the existing cancellation path and seals a packet with
`HandoverReason.inactivity`, `stop` keeps today's stop. The session is
`failed(.stalled)`, the failure kind the Work Runtime design promised.

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

Sinks are configured on the task (`handover.sinks`), on the workflow
(`workflow.json` top-level `handover`) and in configuration (`riela config`
profile, user scope), merged in that order. The kaiba sink requires the
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
  func snapshot(_ isolation: IsolationRef) async throws -> ChangeSnapshot   // reuses fanout change capture
}
```

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
- **At takeover** the successor calls `materialize`: fetch the branch,
  create `<root>/.riela/worktrees/<attemptId>` (or check out in place when
  the root is a dedicated clone), and record the new `IsolationRef`. If
  `state == .unpublished(lastKnown:)` the successor starts from
  `lastKnown` and the packet's `dirtyPaths` list is placed in the brief so
  the agent knows what was lost.
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
   attempt id, the lease (`fence`, `expiresAt`) and a heartbeat token.
3. The successor executes locally in its own session store. It heartbeats
   with `heartbeatAttempt(attemptId, token)` every `heartbeatMs`.
4. At terminal it calls `reportAttempt(attemptId, token, outcome,
   evidence: [Evidence], deliverables: [DeliverableRef], packet?: …)` with
   the ledger delta (bounded like a packet). The controller reconciles the
   attempt and runs verification and director exactly as for a local
   attempt. A successor that itself hands over reports a new packet in the
   same call.
5. A missed heartbeat expires the lease on the controller; the next
   takeover fences the successor as §11 describes.

`task serve --takeover [--traits userReachable,…]` on the successor host
polls `tasksAwaitingHandover(traits:)` and runs takeovers unattended; the
S2 case still requires the user to act on that host, so the poller only
takes tasks whose required traits it declares.

### 10.3 Placement and host traits

`HostCapabilitySnapshot` and `DistributedWorkerRegistration` gain
`traits: Set<HostTrait>`. They are declared, never probed: `worker.json`
`traits: ["userReachable"]`, or `riela config set host.traits
userReachable,interactive` for the local host. `BackendCapabilityPlacementResolver`
gains `requiredTraits` in its requirements and reports
`host-traits-unavailable: <list>` in the same failure shape as
`backend-unavailable:`. `riela doctor` shows traits with the backend
table; `riela task run --dry-run` shows the trait check.

### 10.4 Answering (S1)

`riela task answer <taskId> --question <id> (--answer-json|--answer-file
|--text <s>|--option <optionId>|--use-default)`:

- Validates the payload against `answerSchema` when present; `--option`
  produces `{ "option": "<id>" }`; `--text` produces `{ "text": "<s>" }`.
- Records `Decision.kind = .answer(...)`, `Evidence.kind = .handoverAnswer`,
  and enqueues a `PendingAttemptReservation` with `entry: .takeover`.
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

## 12. Surfaces

CLI (all under the existing `task` and `session` families; catalog rows
added for each):

| Command | Purpose |
| --- | --- |
| `task handover <taskId> [--reason] [--now] [--to host\|group] [--sink kind[,kind]]` | operator-initiated handover of a live attempt |
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
through the CLI parity commands):

```graphql
type Query {
  taskHandover(taskId: ID!, handoverId: ID): HandoverPacket
  tasksAwaitingHandover(traits: [HostTrait!]): [TaskHandoverSummary!]!
}
type Mutation {
  requestTaskHandover(input: RequestTaskHandoverInput!): TaskHandoverResult!
  answerTask(input: AnswerTaskInput!): TaskDecisionResult!
  takeoverTask(input: TakeoverTaskInput!): TakeoverReservation!
  heartbeatAttempt(attemptId: ID!, token: String!): LeaseState!
  reportAttempt(input: ReportAttemptInput!): AttemptReconciliation!
}
```

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
  `suspend: SuspendRecord?`. Schema generation 9.
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
  require the manager session bearer as `executeWorkflow` does; the
  successor's lease token is single-use per attempt and only its digest is
  stored. `--force-orphan` is a human decision recorded with the CLI
  principal.
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
| H2 triggers | envelope + `riela/handover-request`, wait-signal classifier, `onInactivity: handover`, `task handover`, `handover` run event and notification | H1 |
| H3 answers and history | `task answer`, answer injection, `RuntimeHistoryImport` from suspended/bundle, `session handover` adoption | H1 |
| H4 deliverables | `GitBranchWorkspaceRuntime` (branch, checkpoint, publish, materialize), `Attempt.isolation` populated, worker allowance, document deliverable collection, `riela/git-publish-branch` | H1 |
| H5 leases | heartbeat/expiry/fence, owner-side fence check, `--force-orphan`, `task reconcile`, superseded reconciliation | H1 |
| H6 sinks and cross-host | kaiba/gitRef/file/command sinks, host traits, placement traits, GraphQL fields over `/graphql`, remote takeover + heartbeat + report, `task serve --takeover` | H2–H5 |
| H7 rollout | examples (`task-handover-answer`, `task-handover-presence`, `task-handover-orphan`), skills, catalog rows, docs, `riela gc` | H6 |

H1 alone already lets a second process on the same host continue a task
that declared a handover, which is the smallest useful slice.

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
