# Work Runtime: consolidating auto-improve, loop engineering, supervision, and routines

Status: accepted 2026-09-20 with the three section-16 questions resolved by the user. **P0 implemented; P1 incomplete. P1-7b accepted and committed at `a8516ec7e44d57f9717b2403510cfb7d6b84fec1` (2026-09-25), per the current runtime intake. P1-7a and parent P1 remain open.** The latest serial broad gate remains **FAILED**, exit 1, with 18 classified non-P1-7b assertions. Section 17.10 is the current P1-7a design proposal, pending independent review; historical execution scopes and completion statements below do not expand this slice. Applicable accepted behavioral contracts remain in force.
Accepted P0 deltas (2026-09-21, spelling only, no redesign): §4 `Task` is Swift `WorkTask` with `guardPolicy` under CodingKey `"guard"`; §4 `FindingSeverity`/`FindingStatus` are typealiases of the existing `WorkflowReviewFindingSeverity`/`WorkflowReviewFindingStatus`, which §3.8 already names as the surviving scale; the gate payload `acceptance` object is decoded by `RielaWork` itself (the internal `LoopGatePayloadParser` is untouched); the shared `user_version` is `SQLiteWorkflowRuntimePersistenceStore.schemaGeneration` 4→5, and because §16 forbids `RielaCore` importing `RielaWork`, it is `WorkStore.prepareSchema` that calls the core generation guard, not the reverse; the §8 projector returns evidence, findings **and** decisions, because a `LoopRecoveryLineage` projects to a `Decision`. Details: the plan's "Accepted Deltas" section.
Date: 2026-09-20

## 1. Purpose

Riela today has five separate answers to one question: *how does a long-lived
piece of work get driven to completion when a single workflow run is not
enough?*

| Subsystem | Answer it gives | Maturity in the Swift tree |
| --- | --- | --- |
| `workflow run --auto-improve` | retry the session on failure or inactivity, up to a budget | thin: untyped JSON record, no SQLite, no GraphQL, no nested supervisor session, patch budget recorded but never applied |
| loop engineering (`riela loop`) | gates inside the workflow graph judge progress; convergence, budget, baseline, lease, notifications, analytics | mature: typed evidence manifest, SQLite columns, GraphQL, CI verdict, self-improve history root |
| specialist task supervisor (`riela specialist serve`) | a durable task claimed by an owner, dispatched as a child session, monitored, delivered | mature store: 12 SQLite tables, fenced launch, lease, recovery |
| routines (`riela routine`) | a scheduled task with natural-language completion criteria judged by the tick workflow | small: one table, cron gate, add-ons |
| monja project-task orchestrator (Bun example) | a tracker task is planned into a temporary workflow, executed, verified, regenerated on merge | example only, outside core |

They duplicate stall detection, budgets, leases, findings ledgers, completion
judges, recovery lineage, child-session monitoring, and cancellation. This
document replaces them with one **Work Runtime**: a domain-neutral lifecycle
for *intents* and *tasks* whose attempts are ordinary workflow sessions, whose
progress is judged by gates and evidence, and whose next step is chosen by one
*director* seam that can be a policy, an agent workflow, or a human.

The runtime is domain-neutral on purpose. Code changes in a repository and
recurring operational work are the same shape: an intent, tasks with completion
contracts, attempts that produce evidence, decisions that accept or redirect.
Repository specifics (worktrees, diffs, tests) live in one *context adapter*,
not in the lifecycle.

Out of scope, by decision: Jujutsu. Git worktrees are the only isolation
mechanism proposed. A `ChangeRuntime` seam is defined so a second VCS could be
added later, but nothing in this design depends on it.

## 2. Verified current state

Facts below were read directly from the tree on 2026-09-20.

**Auto-improve.** `WorkflowAutoImprovePolicy` lives in `RielaCLI`
(`Sources/RielaCLI/RielaCommand.swift:431`), not in core. The supervision
result is `WorkflowRunResult.supervision: JSONObject?`
(`Sources/RielaCore/DeterministicWorkflowRunner.swift:108`), persisted only as
`<runtime-store-root>/<sessionId>/supervision-record.json`. Incidents are
`failure` or `stall`; the only remediation action is `rerun-workflow` (plain or
targeted step rerun). `maxWorkflowPatches` and `workflowMutationMode` are
echoed into the record and never consumed. `--nested-supervisor` is echoed,
forwarded to remote execution, and rejected on `session rerun`; no nested
session is created. The `riela/start-workflow` add-on the example supervisor
bundle relies on has no Swift implementation. GraphQL exposes nothing about
supervision.

**Loop engineering.** A loop is a workflow whose `workflow.json` carries a
`loop` object (`WorkflowLoopMetadata`: `required`, `evidence`, `policies`,
`convergence`, `budget`, `concurrency`, `notifications`, `gates`, `recovery`,
`implementationPlan`, `selfEvolution`). `loop start` re-parses into
`workflow run`; iteration is the workflow graph routing back from a gate step.
The continue/stop decision is the agent's `loopGate` payload, normalized by
`LoopGatePayloadParser` and overridden by deterministic policy
(`LoopConvergenceTracker`, budget enforcement at step boundaries, default guard
with a terminal corridor). Evidence is `LoopEvidenceManifest`, stored as JSONB
columns on `workflow_runtime_snapshots`; `loop_baselines` and
`loop_concurrency_leases` are separate tables. GraphQL has `loopEvidence`,
`loopSessions`, `loopWorkflowStats`, `loopEvidenceDiff`. `loop start --isolate`
throws "not yet supported" (LA6). `workflow self-improve` writes its change
sets under `loop.selfEvolution.historyRoot`, so self-improve is already owned by
loop engineering.

**Specialist supervisor.** `SpecialistSupervisorStore` owns tables for
requests, tasks, routing, classification rounds, dispatches, nested
invocations, outbox, delivery receipts, service lease, provider cursors, and
reconciliation audit. `SpecialistTaskState` is `queued`, `unclaimed`,
`capacity_wait`, `running`, `recovery_required`, `needs_clarification`,
`succeeded`, `failed`, `cancel_requested`, `cancelled` with an explicit
transition table. `reserveDispatch` writes a `WorkflowSession(status: .created)`
into the runtime persistence store in the same transaction. Launch is fenced by
`SpecialistDispatchLaunchPhase`. The chat classifier returns `claim`,
`decline`, `clarification`, or `status`.

**Routines.** `RoutineRecord` carries `task`, `schedule`, `workflowName`,
`completionCriteria`, `status`. The cron dispatch path consults the SQLite
status before every tick (`routineDispatchGate` in
`Sources/RielaCLI/EventLiveServe+Cron.swift`). Completion is judged by the tick
workflow's agent step returning `conditionMet`, wired to the
`riela/routine-complete` add-on.

**Review findings.** `WorkflowReviewFinding` (severity `high`/`mid`/`low`,
status `open`/`addressed`/`superseded`) is stored on the session and replayed
into rerun variables. Loop gates use a second finding type,
`LoopBlockingFinding`, with `LoopFindingFingerprint` as identity.

**Shared contracts already in place.** `WorkflowSessionFailureKind` is an
open raw-value type with `loopNotConverging` and `budgetExceeded`. Fanout
shared-workspace change evidence and the git finalization store exist in core.
The web UI has no view for supervision, loops, or routines; the desktop app
only routes routine GraphQL.

## 3. Design decisions

1. **One lifecycle.** A `Task` is the unit of work. An `Attempt` is one
   workflow session executed for that task. Workflow session success never
   equals task success; the task's `CompletionContract` decides.
2. **Loop engineering is the base, auto-improve is dissolved.** Gates,
   convergence, budgets, evidence, baselines, leases, notifications, analytics
   and self-improve are kept and lifted from "loop" to "task". The auto-improve
   flags, `WorkflowAutoImprovePolicy`, `supervision-record.json`, and the
   `supervision` field on `WorkflowRunResult` are deleted. Their one real
   behavior, inactivity-based stall with bounded rerun, becomes one detector in
   the unified guard.
3. **The specialist store is the seed of the task store.** Its state machine,
   fenced dispatch, lease, outbox, and recovery are generalized. Chat intake and
   specialist classification become one *intake source* and one *director*
   among others, not the owner of the lifecycle.
4. **Routines are scheduled tasks.** A routine is a task with a
   `schedule` trigger and a natural-language acceptance criterion. `RoutineStore`
   is deleted; `riela routine` becomes sugar over `riela task`.
5. **The monja pattern becomes core.** Planning a task into a temporary
   workflow, executing it, requiring a verification gate, and regenerating on
   merge are runtime behaviors, not example code. The example is rewritten to
   call them.
6. **One director seam, three implementations.** Every "what happens next"
   decision is a typed `Decision` produced by a `Director`: the deterministic
   policy director (always present), an agent director workflow (optional,
   replaces the nested supervisor), or a human (GraphQL mutation or CLI).
   Directors never execute; the runtime applies decisions.
7. **One guard.** Inactivity stall, non-convergence, and budget exhaustion are
   three detectors feeding one `GuardViolation` record and one decision path.
   Stall is no longer two unrelated concepts.
8. **One evidence ledger with causality.** The task-level ledger replaces
   `LoopEvidenceManifest`; SARIF export, diffs, baselines, and stats are
   rewritten to read the ledger, and the manifest type is deleted. Every
   record has `producedBy` and `causedBy`. `WorkflowReviewFinding` and
   `LoopBlockingFinding` merge into one `Finding` with the fingerprint identity.
9. **Domain neutrality.** Nothing in `Task`, `Attempt`, `Decision`,
   `Evidence`, or `Guard` mentions repositories, files, tests, mail, or
   trackers. Domain facts enter through a `ContextBinding` whose adapter
   contributes evidence kinds, verification commands, and isolation.
10. **Repository context uses git worktrees, not Jujutsu.** `ChangeRuntime`
    is a protocol with one implementation, `GitWorktreeChangeRuntime`. It reuses
    the git finalization store for commit and push and closes the LA6 stub.
11. **Improvement is a decision, then a reviewed change set.** A director may
    return `proposeWorkflowChange`; the runtime records it as a proposal and
    routes it through the existing `workflow self-improve` review gate. No
    silent in-place patching. `maxWorkflowPatches` becomes a budget on
    proposals.
12. **No backward compatibility.** No aliases, no deprecation period, no
    legacy import, no schema migration, no tolerant decoding of old records.
    Removed commands, flags, tables, and files are simply gone; a store whose
    schema generation does not match is discarded and recreated. Existing
    routine, specialist, loop, and supervision data is not carried over.

## 4. Domain model

Names are Swift; storage is JSONB records with generated columns, following
`RoutineStore` and the runtime snapshot store.

```swift
public struct Intent: Codable, Sendable {
  public var id: IntentID
  public var title: String
  public var instruction: String
  public var constraints: IntentConstraints       // capability ceilings, allowed contexts
  public var acceptance: [AcceptanceCriterion]    // natural language + optional gate refs
  public var origin: WorkOrigin                   // cli | chat | tracker | schedule | api
  public var state: IntentState                   // open | fulfilled | abandoned
}

public struct Task: Codable, Sendable {
  public var id: TaskID
  public var intentId: IntentID
  public var parentId: TaskID?
  public var dependsOn: [TaskID]
  public var title: String
  public var instruction: String
  public var plan: TaskPlan?                      // workflow reference or generated temp workflow
  public var context: ContextBinding?             // repository | none | future kinds
  public var completion: CompletionContract
  public var guard: GuardPolicy
  public var director: DirectorPolicy
  public var trigger: TaskTrigger                 // manual | schedule(cron) | event(bindingId) | dependency
  public var owner: OwnerAssignment?              // specialist/agent/human identity + capacity lane
  public var state: TaskState
  public var version: Int                         // optimistic concurrency, as in specialist tasks
}

public enum TaskState: String, Codable {
  case draft, ready, scheduled, waiting            // waiting: capacity | dependency | clarification | human
  case running, verifying, needsDecision
  case succeeded, failed, cancelled, superseded
}

public struct Attempt: Codable, Sendable {
  public var id: AttemptID
  public var taskId: TaskID
  public var generation: Int                      // monja generation; bumps on replan/merge
  public var sessionId: String                    // ordinary workflow session
  public var entry: AttemptEntry                  // start | resume | rerunFromStep | recoverFromGate
  public var lineage: AttemptLineage?             // LoopRecoveryLineage, lifted
  public var isolation: IsolationRef?             // worktree path, branch, base revision
  public var state: AttemptState                  // prepared | running | terminal | reconciled
  public var outcome: AttemptOutcome?             // sessionStatus, failureKind, gateResults, costs
}

public struct CompletionContract: Codable, Sendable {
  public var gates: [GateDeclaration]             // LoopGateDeclaration, lifted: id, stepId, required, acceptWhen
  public var verification: [VerificationRequirement] // commands or evidence kinds that must be present and passing
  public var acceptance: [AcceptanceCriterion]    // evaluated by a director, never by the runtime alone
  public var requiresHumanAccept: Bool
}

public struct GuardPolicy: Codable, Sendable {
  public var inactivity: InactivityGuard?         // stallTimeoutMs, monitorIntervalMs, heartbeat backends
  public var convergence: ConvergenceGuard?       // maxGateVisits, maxRepeatedFindingRounds
  public var budget: BudgetGuard?                 // maxAttempts, maxTotalTokens, maxWallClockMs, maxProposals
  public var onViolation: ViolationAction         // fail | warn | askDirector
}

public struct DirectorPolicy: Codable, Sendable {
  public var deterministic: DeterministicDirectorRules   // default rerun/recover table
  public var agentWorkflow: WorkflowReference?           // optional director workflow
  public var humanEscalation: EscalationPolicy           // when to stop and wait
}

public struct Decision: Codable, Sendable {
  public var id: DecisionID
  public var taskId: TaskID
  public var attemptId: AttemptID?
  public var producer: DecisionProducer           // policy(rule) | agent(sessionId) | human(principal)
  public var kind: DecisionKind
  public var reason: String
  public var causedBy: [EvidenceID]
}

public enum DecisionKind: Codable, Sendable {
  case start, resume
  case rerun(fromStepId: String?)
  case recover(fromGateId: String)
  case replan(instruction: String)                // new generation with a new plan
  case wait(WaitReason)                           // capacity | dependency | clarification(question) | until(Date)
  case proposeWorkflowChange(ProposalRef)         // routed to self-improve
  case accept, reject(reason: String)
  case cancel, stop(GuardViolationRef)
}

public struct Evidence: Codable, Sendable {
  public var id: EvidenceID
  public var taskId: TaskID
  public var attemptId: AttemptID?
  public var kind: EvidenceKind                   // gate | finding | verification | command | changedFile | artifact | cost | guardViolation | decision | delivery | contextSnapshot
  public var producedBy: EvidenceProducer         // step execution, addon, runtime, director, human, context adapter
  public var causedBy: [EvidenceID]
  public var payloadRef: PayloadReference         // inline small JSON or artifact path under the runtime store
  public var createdAt: Date
}

public struct Finding: Codable, Sendable {        // merges WorkflowReviewFinding + LoopBlockingFinding
  public var id: String                           // authored id or LoopFindingFingerprint
  public var severity: FindingSeverity            // high | mid | low, same aliases as today
  public var status: FindingStatus                // open | addressed | superseded
  public var gateId: String?
  public var sourceStepExecutionId: String
  public var targetStepId: String?
  public var filePath: String?
  public var line: Int?
  public var message: String
  public var feedback: String?
}
```

`ContextBinding` is an enum with one case at first:

```swift
public enum ContextBinding: Codable, Sendable {
  case repository(RepositoryContext)   // root, baseRevision, isolation: shared | worktree, writeScopes
}
```

Adapters implement:

```swift
public protocol WorkContextAdapter: Sendable {
  func prepare(attempt: Attempt, task: Task) async throws -> IsolationRef?
  func collectEvidence(after attempt: Attempt) async throws -> [Evidence]
  func verify(_ requirements: [VerificationRequirement], in attempt: Attempt) async throws -> [Evidence]
  func finalize(decision: Decision, attempt: Attempt) async throws     // accept → commit/push via finalization store
  func discard(attempt: Attempt) async throws                          // reject/supersede → remove worktree
}
```

`ChangeRuntime` is the repository adapter's internal seam:

```swift
public protocol ChangeRuntime: Sendable {
  func createIsolation(base: RevisionRef, for attempt: AttemptID) async throws -> IsolationRef
  func snapshot(_ isolation: IsolationRef) async throws -> ChangeSnapshot   // changed files + digests, reuses fanout snapshot code
  func diff(_ isolation: IsolationRef, against: RevisionRef) async throws -> ChangeDiff
  func finalize(_ isolation: IsolationRef, message: String, paths: [String]) async throws -> RevisionRef
  func discard(_ isolation: IsolationRef) async throws
}
public actor GitWorktreeChangeRuntime: ChangeRuntime {}
```

## 5. Lifecycle

```
Intent ──creates──▶ Task(draft)
                      │ plan present or planner ran
                      ▼
                   ready ──trigger──▶ scheduled/waiting ──dispatch──▶ running
                                                                        │ attempt terminal
                                                                        ▼
                                                                    verifying  (context adapter verify + gate reconciliation)
                                                                        │
                                              ┌──────────── director decision ────────────┐
                                              ▼                    ▼                      ▼
                                          succeeded          running (rerun/recover/   needsDecision
                                         (accept)             replan → new attempt)    (human)
```

Rules the runtime enforces regardless of director:

- A task cannot enter `succeeded` unless every required gate's latest result is
  `accepted`, every verification requirement has passing evidence in the
  accepting attempt, and no `open` finding with blocking severity remains.
  This lifts the monja verifier and the loop CI verdict into one check.
- A guard violation always produces evidence first, then a decision. With
  `onViolation: fail` the runtime records `stop` itself. With `askDirector` the
  agent director gets one round; if it also fails, the task enters
  `needsDecision`.
- Every dispatch is fenced exactly as `SpecialistDispatchLaunchPhase` fences
  it today; the attempt's `WorkflowSession(status: .created)` row is written in
  the same transaction as the attempt row.
- One task has at most one live attempt. Parallel work is modeled as sibling
  tasks under one parent, each with its own isolation; this replaces the
  "parallel node = divergent change" idea from the earlier discussion and
  matches the existing fanout dependency-wave design.
- Cancellation is one path: `cancel` decision → attempt cancellation through
  the existing runner cancellation → attempt `reconciled` → task `cancelled`.
  A cancelled session is persisted before acknowledgment, as fixed in `43edf93`.

## 5a. Backend availability and placement

**Current state.** A workflow pins each agent node to one of seven
`executionBackend` values (`codex-agent`, `claude-code-agent`,
`cursor-cli-agent`, four `official/*-sdk`) and usually a model. Nothing in
Riela knows before execution whether that backend exists on the machine:
`riela doctor` probes container runtimes and tool binaries, not agent CLIs
or their authentication; `WorkflowRuntimeCapabilityGap` reports runner
features, not host capabilities; a distributed worker registers only
`workerId`, `groups`, and `capacity`; placement selects by name and never
falls back. A missing or unauthenticated backend surfaces as an
`adapterFailure` on the first attempt, which under the guard counts against
the attempt budget.

**Design.** Availability becomes data the dispatcher reads before it
reserves an attempt.

- **Capability probe.** `BackendCapability { backend, available,
  authenticated, models: [String], version: String?, probedAt }` per host.
  The local host is probed by `riela doctor` (extended) and on `task serve`
  start; a distributed worker probes itself and includes the list in
  `DistributedWorkerRegistration.capabilities`. Probes are cheap
  (`--version` plus each backend's own auth status command) and cached in a
  `work_hosts` table with a freshness bound.
- **Declared capabilities in config.** Probing is not the only source. A
  host's capabilities may be declared in configuration: the local
  configuration store (`riela config`, the same profile configuration
  GraphQL already manages) and the distributed worker's `worker.json` gain a
  `backends` section, for example `{ "codex-agent": { "enabled": true,
  "models": ["gpt-5.6-luna"] }, "claude-code-agent": { "enabled": false,
  "reason": "no Anthropic account on this host" } }`. Merge rule: a declared
  `enabled: false` always wins, so an operator can forbid a backend that is
  installed; a declared `enabled: true` without a successful probe is
  recorded as `declared, unverified` and still used for placement; a probe
  result with no declaration is used as observed. Declared models override
  probed model lists. The merged table is what every consumer below reads,
  and the declaration source is recorded on the `placement` evidence.
- **Node backend policy.** A node payload may declare a policy instead of a
  pin: `backendPolicy: { allowed: ["codex-agent", "claude-code-agent"],
  preferred: ["codex-agent"], modelByBackend: {...} }`. A bare
  `executionBackend` remains a pin. The dispatcher resolves the policy
  against the target host's capabilities and records the choice as a
  `placement` evidence record on the attempt, so two attempts of one task on
  two machines are distinguishable.
- **Placement resolution.** Before reserving an attempt the dispatcher
  computes the set of backends the plan's reachable nodes need and picks the
  first host, local or a worker group, whose capabilities cover it. No host
  covers it: the task enters `waiting(.capacity)` with reason
  `backend-unavailable: <list>` and a decision record, not a failed attempt.
  Explicit step placement keeps today's rule: it never falls back.
- **Planner input.** When `plan.generate` is used, the planner workflow
  receives the capability snapshot of the intended host as a variable and
  must emit only nodes whose backend is available; validation rejects the
  generated workflow otherwise, through a host-aware extension of
  `WorkflowRuntimeCapabilityGap` ("node X requires backend Y, host Z lacks
  it").
- **Surfaces.** `riela doctor` shows the backend table; `riela task run
  --dry-run` prints the resolved host and per-node backend choice; the task
  board shows the placement evidence.

**Authoring time, not only dispatch time.** The same capability table is
an input to everyone who writes a workflow, because a node pinned to a
backend the target host lacks is wrong at the moment it is written:

- **Workflow Studio.** The node settings backend and model pickers read the
  host capability table through GraphQL (`hostCapabilities(host:)`) and
  show each backend as available, unauthenticated, or absent on the
  selected host, with the probed model list; an absent backend can still be
  chosen, marked as such, because a workflow may be authored on one machine
  for another. Today the studio's node settings edit only the prompt and a
  free-text model field and have no backend picker at all.
- **`riela workflow validate --host <local|workerId|group>`** adds
  host-aware diagnostics next to the runner-feature gaps: "step X pins
  backend Y, host Z lacks it" as a warning, or an error with `--strict-host`.
  `riela workflow usage` includes the backend requirements of a workflow so
  an agent choosing a workflow can compare them with the table.
- **Add-ons and packages.** The probe covers add-on executables and package
  `requiredEnvironment` the same way, so `riela node list` and the studio's
  add-on picker mark add-ons whose CLI or environment is missing. `riela
  doctor` already reads package environment requirements; the probe
  generalizes that into the capability table.
- **Agents that author workflows.** The `riela-workflow` skill and the
  planner prompt receive the capability snapshot as a variable and are
  instructed to pin only available backends or to declare a `backendPolicy`
  covering the available ones. The parity gate for skills checks that the
  snapshot variable is documented.

**What this does not do.** It does not translate prompts between backends
or promise that a workflow authored for Codex behaves identically on Claude
Code. A policy with two allowed backends is the author's statement that the
node's prompt and output contract were written for both.

## 6. Director seam

Deterministic director rules (the default, replacing auto-improve behavior):

| Trigger | Default decision |
| --- | --- |
| attempt failed, failureKind `adapterFailure` or `nodeTimeout`, attempts < budget | `rerun(fromStepId: failedStep)` |
| inactivity guard fired on a heartbeat-capable backend | `rerun(fromStepId: stalledStep)` |
| gate rejected with open findings, convergence not violated | `recover(fromGateId:)` (findings replayed as today) |
| convergence violated | `stop` or `askDirector` per policy |
| budget exhausted | `stop` |
| all gates accepted, verification passing, `requiresHumanAccept` | `wait(.human)` |
| all gates accepted, verification passing, no human required | `accept` |

Agent director: an ordinary workflow declared as `director.agentWorkflow`.
It receives a `TaskView` variable (task, latest attempt outcome, guard state,
open findings, evidence summary, remaining budget) and must return a `Decision`
payload validated by an authored output contract. Its allowed decision kinds
are declared on the task, in the same spirit as
`directAnswerPolicy.allowedDecisionKinds` in the chat dispatcher profile. It
runs as a child session of the task, recorded as an attempt with
`entry: .director`, so its cost counts against the budget. This replaces the
never-implemented nested supervisor and the specialist classifier round: a
specialist is an agent director whose allowed kinds are `claim`, `decline`,
`clarification`, `status`, mapped to `start`, `reject`, `wait(.clarification)`,
and a read-only status reply.

Human director: `riela task decide <taskId> --accept|--reject|--rerun|--cancel`
and the GraphQL `decideTask` mutation, both under the existing manager-session
authentication.

## 7. Guard

```swift
public enum GuardViolation: Codable, Sendable {
  case inactivity(stepId: String, idleMs: Int)
  case gateVisitsExceeded(gateId: String, visits: Int)
  case repeatedFindings(gateId: String, rounds: Int)
  case budget(BudgetDimension, used: Int, limit: Int)   // attempts | tokens | wallClock | proposals
}
```

Detectors keep their current implementations and are re-homed:
`monitorWorkflowStall` becomes the inactivity detector running in the task
dispatcher instead of the CLI run command; `LoopConvergenceTracker` and the
step-boundary budget enforcement stay in the runner and report violations to
the task via the existing run event handler. Failure kinds stay
`loopNotConverging` and `budgetExceeded`; a new `stalled` kind is added for
inactivity, replacing the ad-hoc "marked failed" path.

## 8. Evidence ledger

The task ledger is the only evidence store. `LoopEvidenceManifest`, the
`loop_evidence_json` and `loop_summary_json` columns, and
`DefaultLoopEvidenceProjector` are deleted; SARIF export, diffs, baselines,
and stats are rewritten over ledger queries. Existing producers are mapped
into ledger kinds at attempt terminal:

| Existing record | Ledger kind | causedBy |
| --- | --- | --- |
| `LoopGateResult` | `gate` | step execution evidence |
| `WorkflowReviewFinding`, `LoopBlockingFinding` | `finding` | gate |
| `LoopVerificationEvidence`, `LoopCommandEvidence` | `verification`, `command` | attempt |
| `LoopChangedFile`, fanout change snapshots, git finalization journal | `changedFile`, `contextSnapshot` | attempt, decision(accept) |
| `LoopCostEvidence` | `cost` | attempt |
| supervision incidents/remediations | `guardViolation`, `decision` | attempt |
| specialist outbox/delivery receipts | `delivery` | decision |

Line-level causality is not attempted. File-plus-attempt granularity is enough
to answer "which attempt, which gate, which finding led to this change".

## 9. Domain contexts

**Repository context (first).** `RepositoryContext` carries root, base
revision, `isolation: shared | worktree`, and write scopes. `worktree` creates
`<root>/.riela/worktrees/<attemptId>` from the base revision, runs the attempt
there, snapshots on terminal, and on `accept` commits and pushes through the
existing finalization store; on `reject` or `supersede` it removes the
worktree. `shared` keeps today's cooperative shared-workspace behavior. This
closes LA6, Hermes adoption D, and the "parallel tasks need disjoint scopes or
isolated worktrees" clause of the monja design.

**Operational work (same lifecycle, no adapter).** A routine such as "check
the inbox every 30 minutes until the vendor replies" is a task with
`trigger: .schedule`, no context, `completion.acceptance` holding the
criterion, and the deterministic director accepting when the tick workflow's
gate says `conditionMet`. Nothing else changes, which is the point of the
neutral core.

**Monja tracker integration (P3, intake and human director).** Monja is
the sibling chat, task, and work-contract application. Its work contract
(`design-human-ai-work-hub.md`, HUB-01, implemented) already holds what this
design calls the completion contract's human half: instructions, acceptance
criteria, a reviewer, evidence links, and the `accept` / `request_changes`
decision. Monja's plan 30 had proposed building its own agent execution
runtime with leases, heartbeats, checkpoints, and budgets. That scope is
reduced by the companion Monja design
`design-docs/specs/design-riela-execution-integration.md`: Riela owns
execution, Monja owns the agreement and the review. The rule of thumb across
the two products: Monja automates Monja, request-scoped and without a
server-side model; Riela executes autonomously, whether the work is code or
operations. A recurring in-product chore is therefore a Riela scheduled task
calling Monja's API, not a Monja feature. The division on the Riela side:

- **Transport.** Riela subscribes; Monja does not call Riela. Riela's bot
  API key opens Monja's WebSocket task stream (`GET /api/v1/events/tasks`,
  protocol `monja.events.v2`) from the host PC and receives
  `work_contract.*` events there. Monja has no GraphQL subscriptions, and its
  webhook egress only delivers to public allow-listed HTTPS hosts, so a
  webhook binding is an option for a server-deployed Riela, never the
  primary path. This is a new `monja-realtime` event source in
  `RielaEvents`, shaped like the existing chat gateway sources: one outbound
  socket, a persisted cursor, reconnect with REST reconciliation. The socket
  is the existing WebSocket protocol, not a GraphQL subscription, which Monja
  does not offer; Riela has no WebSocket client today, so this source adds
  one on `URLSessionWebSocketTask`. Correctness never depends on the socket:
  the REST reconciliation loop alone is sufficient, the socket only lowers
  latency.
- **Intake.** A `work_contract.assigned` event whose worker is Riela's bot
  creates an intent from the contract's `instructions` and a task whose
  `acceptance` is the contract's `acceptanceCriteria`, with `trigger:
  .event(bindingId)` and `origin: .tracker`. The task binds the contract
  through Monja's `bind` transition, recording Riela's task id and the served
  task page URL as the contract's executor reference. On every socket
  (re)connect and on a slow periodic cadence Riela lists contracts assigned
  to its bot worker and creates any task it missed.
- **Attempt mirroring.** Attempt start sends the contract `start` transition.
  When the task reaches `verifying` and `CompletionEvaluator` is satisfied,
  Riela sends `submit` with the evidence ledger summary and evidence links to
  the served task and attempt pages. Riela never sends `accept`; its bot key
  holds `tasks:write` only and the reviewer must be a human session.
- **Human director.** `work_contract.accepted` becomes a human `accept`
  decision and finalizes the attempt. `work_contract.changes_requested`
  becomes a human `reject` decision whose note is replayed as prior review
  feedback into a `recover(fromGateId:)` attempt. `work_contract.cancelled`
  cancels the task. A task entering `needsDecision` posts a task comment on
  the Monja task and waits; Monja's attention inbox surfaces it.
- **Delivery.** Progress goes through Monja's idempotent message and task
  comment APIs with keys derived from the attempt id and event, replacing the
  three separate Monja glue layers in today's Bun examples with one
  `MonjaTrackerAdapter` in `RielaWork`.
- **Approval alignment.** Monja's planned approved actions and Riela's
  `Decision` share one shape, an approval bound to a payload digest, source
  versions, and a principal, so a code publish approval and an external send
  approval are the same kind of record across the two systems.

**Operating scenario: a Monja task implemented by Riela.** Three layers,
two of them Riela built-ins; no public webhook endpoint, no Jujutsu, no
execution runtime in Monja.

1. A person creates a task in Monja and a work contract on it, with Riela's
   bot user as worker and a human as reviewer. The contract's `instructions`
   and `acceptanceCriteria` are the whole specification; nobody writes a
   prompt.
2. Riela's `monja-realtime` event source (built-in, shaped like the Discord
   gateway source) holds the bot key, receives `work_contract.assigned`, and
   dispatches it through a `task-dispatch` binding. The binding's
   configuration maps Monja projects and directories to a repository root,
   write scopes, and a default plan workflow, the role today's
   `fixtures/project.json` plays in the Bun example. The intent and task are
   created and the contract is bound with Riela's task id and page URL.
3. `riela task serve` reserves an attempt and runs the plan workflow in a
   worktree. On terminal, the repository adapter runs verification, the
   ledger receives gates, findings, and commands, and `CompletionEvaluator`
   judges. If satisfied, `MonjaTrackerAdapter` sends `submit` with the ledger
   summary and evidence links; progress along the way goes to task comments
   with idempotency keys derived from the attempt id.
4. The reviewer accepts or requests changes in Monja. `accepted` becomes a
   human `accept` decision and the worktree is committed and pushed through
   the finalization store; `changes_requested` becomes a `reject` whose note
   is replayed as review feedback into a recovery attempt; `cancelled`
   cancels. A task that needs a human mid-way enters `needsDecision` and
   posts a comment; Monja's inbox surfaces it.

Optional third layer: `riela/monja-*` node add-ons over the shared gateway
GraphQL engine (contract read, task comment, message send) for workflows that
publish their own progress; the runtime bridge does not depend on them.

**The same scenario for non-development work.** Nothing above is specific
to code except the repository context. A research or investigation contract
("compare three vendors' SLAs and recommend one, with sources") runs
identically: the task has no `context` or a future `documents` context, the
plan workflow is a research workflow such as the kaiba document intake or a
retrieval example, gates are its review steps, `verification` lists required
evidence kinds (an `artifact` of kind report, a `command` that ran the source
check) instead of test commands, and acceptance is judged from the gate
payload's `acceptance` field. `submit` carries the report link (a Monja
document written by an add-on, or a Riela artifact page); `accept` closes
the contract with nothing to commit. The weaker part is verification: there
is no test suite, so the review gate and the human accept carry the weight,
and the task should declare `requiresHumanAccept: true` by default. Recurring
investigations ("weekly competitor digest") are the same task with a
`schedule` trigger. This is the concrete form of the claim that development
and operational work share one lifecycle.

Other adapters (mailbox, documents, other trackers) are explicitly not
designed here; the protocol is sized so they only add evidence kinds and
verification.

## 10. Surfaces

Every operation below is a row in the surface catalog of
`design-control-surface-parity.md` before it is implemented, and the parity
gate holds CLI and GraphQL to ship together or declare `blocked`.

CLI (`Sources/RielaCLI`):

- `riela intent create|show|list|close`
- `riela task create|plan|run|list|show|evidence|findings|gates|diff|baseline|regress|stats|decide|cancel|recover`
- `riela task serve` replaces `riela specialist serve` and the routine tick
  path inside `events serve`; event bindings dispatch into the task store.
- `riela routine ...` stays as sugar creating scheduled tasks.
- `riela workflow run` loses `--auto-improve`, `--max-supervised-attempts`,
  `--max-workflow-patches`, `--monitor-interval-ms`, `--stall-timeout-ms`,
  `--workflow-mutation-mode`, `--nested-supervisor`. A plain run is one attempt
  of an implicit task only when `--task` is given; otherwise behavior is
  unchanged.
- `riela loop *` is deleted.

GraphQL: `task`, `tasks`, `intent`, `taskEvidence`, `taskDecisions`,
`decideTask`, `cancelTask`, `createTask`, `runTask`, `taskStats`,
`taskEvidenceDiff`. The `loopEvidence`, `loopSessions`, `loopWorkflowStats`,
and `loopEvidenceDiff` queries are deleted. Supervision types are not added;
they never existed.

Web and desktop: a Task board (list, kanban by state, detail with attempts,
gates, findings, evidence timeline, diff for repository context, decision
buttons). The web tree has no loop, supervision, or routine view today, so this
is additive. The existing run trace and execution graph views are linked from
an attempt.

Events: `EventExecutionMode` gains `task-dispatch`; `supervisor-dispatch` and
`schedule-registration` map onto it. Chat intake writes an intent and a task
instead of a specialist request. Monja work-contract events arrive through
the `monja-realtime` event source as one `task-dispatch` binding; the
contract lifecycle mapping is in section 9.

## 11. Storage

Tables live in the runtime records database (the one that already holds
`workflow_runtime_snapshots`, `loop_baselines`, `loop_concurrency_leases`), so
attempt reservation and session creation stay in one transaction, as
`reserveDispatch` does today.

`work_intents`, `work_tasks`, `work_attempts`, `work_decisions`,
`work_evidence`, `work_findings`, `work_leases`, `work_outbox`,
`work_delivery_receipts`, `work_intake_cursors`. Each is a JSONB record with
generated columns for the filterable fields and a schema generation guard;
a mismatched generation discards the store, there is no migration path.
`loop_baselines`, `loop_concurrency_leases`, the `loop_*_json` snapshot
columns, `routines.sqlite`, and the specialist database are deleted, not
imported.

## 12. What is removed

- `WorkflowAutoImprovePolicy`, `WorkflowMutationMode`,
  `WorkflowRunCommand+AutoImprove.swift`, `SupervisedScenarioNodeAdapter`,
  `supervision-record.json`, `WorkflowRunResult.supervision`, remote
  `input.autoImprove` and `input.nestedSuperviser`.
- `examples/auto-improve`, `examples/default-superviser`,
  `examples/supervised-mock-retry`; replaced by `examples/task-repair-loop`
  showing the deterministic director and `examples/task-agent-director`.
- `RoutineStore`, `RoutineService`, routine GraphQL provider; routine add-ons
  become `riela/task-*` add-ons and the `riela/routine-*` names are gone.
- `SpecialistSupervisorStore` and the 13 specialist CLI files; the chat
  adapter, classifier prompt, and Wrike tracker projection survive as an
  intake source and a delivery channel of the task store.
- `LoopCommandKind`, `LoopStartCommand`, `LoopEvidenceManifest`,
  `LoopEvidenceProjector`, `LoopEvidenceDiff`, `LoopSessionOverview`,
  `LoopWorkflowStats`, and the `GraphQLLoop*` DTOs; their features return as
  task-ledger implementations.
- `WorkflowReviewFinding` replay keeps working, backed by `work_findings`.
- The monja Bun example's `store.ts`, `scheduler.ts`, `executor.ts`; the
  example keeps only the Monja/Wrike provider glue and calls `riela task`.

## 13. Phases

Each phase ends with `swift test` green, the affected examples' mock runs
matching `EXPECTED_RESULTS.md`, and a design-doc status update.

- **P0 Model and store.** `RielaWork` module: types in section 4, store,
  and the projector that turns a terminal session snapshot into
  `work_evidence` and `work_findings` rows. `riela task show` and `list` over
  a fixture snapshot prove the projection.
- **P1 Dispatcher, guard, deterministic director.** Attempt reservation with
  fenced launch (lifted from the specialist store), unified guard, default
  director table, backend capability probe and placement resolution
  (section 5a), `riela workflow validate --host` and the `workflow usage`
  backend requirements. `workflow run --auto-improve` is deleted here; its tests
  become task dispatcher tests. `riela task run` and `decide` land.
- **P2 Loop fold.** `riela loop *`, the manifest, and the loop GraphQL
  queries are deleted; baselines, leases, notifications, stats, SARIF, and
  diff are reimplemented over the task ledger. Self-improve proposals become
  `proposeWorkflowChange` decisions.
- **P3 Intake fold.** Routines become scheduled tasks; specialist serve becomes
  `task serve` with the chat intake and agent director; `events serve`
  dispatches tasks. `MonjaTrackerAdapter` lands here
  against the Monja-side design `design-riela-execution-integration.md`,
  with the monja examples rewritten onto it.
- **P4 Repository context.** `ChangeRuntime`, `GitWorktreeChangeRuntime`,
  worktree isolation, snapshot and diff evidence, accept-time finalization
  through the existing store. Monja example rewritten onto `riela task`.
- **P5 Surfaces.** GraphQL task API, web and desktop Task board, attempt links
  to run trace, `hostCapabilities` query and host-aware backend and add-on
  pickers in Workflow Studio.
- **P6 Improvement loop.** Lessons as evidence, retrospective director
  workflow, proposal budget, promotion readiness lifted from `loop promote`.
- **P7 Capability ceilings.** `IntentConstraints` mapped to Seatbelt for
  command nodes and to backend permission modes for agent nodes, with the
  unmapped remainder recorded as a diagnostic, in the style of
  `WorkflowRuntimeCapabilityGap`.

## 14. Rejected alternatives

- **Keep auto-improve and add a task layer above it.** Rejected: auto-improve
  has no durable state and one action; keeping it means a fourth loop driver.
- **Make the task store a separate SQLite file.** Rejected: attempt reservation
  and session creation must be atomic, which the specialist store already
  proved needs one database.
- **Jujutsu as change runtime.** Rejected by the user; git worktrees cover
  isolation, and the finalization store already covers commit and push.
- **Line-level causal graph.** Deferred; file-plus-attempt granularity answers
  the operator questions at a fraction of the cost.
- **A new orchestration engine or a shell.** Rejected, as in every prior
  design: the workflow runner stays the only executor.

## 15. Risks

- The specialist store's fencing and recovery semantics are subtle; lifting
  them without their tests loses the guarantees. The tests move with the code.
- The default director table changes auto-improve's observable behavior for
  `official*SDK` backends, which today are never treated as stalled. The
  inactivity detector keeps that exclusion.
- Chat intake currently never creates work from an ambiguous message. The
  agent director for chat must keep `wait(.clarification)` as the ambiguous
  outcome; the allowed-kinds declaration enforces it.
- Worktree isolation interacts with agents that run `git` themselves. The
  attempt's working directory is the worktree, and the finalization store's
  repository identity checks are run against the worktree, not the main tree.

## 16. Resolved questions

Decided 2026-09-20 with the user; each follows the recommendation, and the
reason is recorded so later work does not reopen it without new facts.

**A plain `workflow run` does not create a task. `--task <id>` opts in.**
Reason: most runs are fixture checks, mock-scenario tests, and one-shot
automation ticks, and the test suites run hundreds of them. An implicit task
per run would put a row, a lease, and a projection pass on every one of them,
slow the suites, and fill the task board with noise that no director will ever
act on. A task is a promise to drive work to completion; creating one should be
an explicit act. Event bindings, routines, chat intake, and `riela task run`
all create tasks explicitly, so the opt-in costs nothing on the paths that
need it.

**Acceptance criteria are judged from a gate payload field, by the
deterministic director.** The gate payload gains an optional `acceptance`
object: `{ "met": true|false, "note": "..." }`. The deterministic director
treats `met: true` as satisfying the task's natural-language criteria, and
anything else, including absence, as not met. Reason: the runtime cannot
evaluate natural language itself and must not pretend to. Putting the judgment
in the gate payload keeps it where the evidence is produced, inside the
attempt, validated by the authored output contract, and visible in the
evidence ledger. Routines already work this way with `conditionMet`, and the
"not certain means not met" rule has proven safe there: a hallucinated
completion cannot close a task, only an explicit affirmative can. A separate
LLM judge would add a second model call, a second prompt to maintain, and a
second place for disagreement.

**`RielaWork` depends on `RielaCore`; `RielaCore` never imports
`RielaWork`.** Reason: the runner must stay usable without the task layer, for
plain runs, tests, and library callers. All information the task layer needs
from a run already crosses the existing run event handler and the persisted
snapshot: gate results, findings, convergence violations, budget violations,
terminal status. The dispatcher subscribes to those; the runner does not call
up. This also keeps the guard detectors where they are, which is the cheapest
lift: convergence and budget stay in the runner and are reported, inactivity
moves from the CLI run command into the dispatcher, and neither needs a new
core dependency. A reverse import would also make `RielaCore` depend on the
task store schema, which would force every schema generation bump to rebuild
the core test target.

## 17. P1 implementation clarification

Accepted 2026-09-21 after running the Riela
`design-and-implement-review-loop-feature-plan` workflow against the current
tree. This section fixes the executable boundary of P1 without changing the
domain model or moving work from P2-P7 into P1.

- **Reservation is the commit point.** `WorkStore.reserveAttempt` performs one
  `BEGIN IMMEDIATE` transaction which reloads the task, checks its expected
  version and dispatch eligibility, rejects any live attempt, inserts the
  prepared attempt and its `.created` workflow snapshot, records the `start`,
  `resume`, `rerun`, or `recover` decision, and advances the task to `running`.
  It returns an opaque launch token stored only as a digest. A launcher must
  exchange that token through `authorizeAttemptLaunch` before entering the
  workflow runner. A process that dies before authorization may be fenced and
  explicitly re-reserved; a process that dies after authorization is
  uncertain and is never silently relaunched.
- **The dispatcher owns orchestration, not execution.** `TaskDispatcher`
  resolves dependencies and host placement, reserves through `WorkStore`, and
  then calls the existing workflow run path. `RielaCore` remains unaware of
  `RielaWork`. Terminal snapshots flow back through the existing persistence
  and projection seams.
- **Guard input is a snapshot.** The unified guard consumes attempt count,
  accumulated cost, elapsed wall time, latest heartbeat age, gate-visit
  counts, and repeated-finding rounds. It emits zero or more typed
  `GuardViolation` values. Every emitted violation is persisted as evidence
  before a director may choose `stop`, `rerun`, or escalation.
- **The policy director is total and ordered.** Budget exhaustion wins over
  convergence, which wins over inactivity, which wins over recoverable
  terminal failure, which wins over completion. If no rule applies it emits
  `wait(.human)` rather than guessing. This ordering makes one input snapshot
  produce one stable decision.
- **Human decisions share the same applier.** `riela task decide` creates a
  human-produced `Decision`; it does not mutate task or attempt rows directly.
  `DecisionApplier` validates and applies policy and human decisions with the
  same optimistic task-version check. `accept` must pass
  `CompletionEvaluator`; `rerun` and `recover` create a reservation request;
  `cancel`, `reject`, and `stop` reconcile any live attempt before changing
  the task terminal state.
- **Placement fails before reservation.** Backend capability declarations and
  probes merge into one host snapshot. A declared disable wins; an enabled but
  unprobed backend is usable and marked unverified; otherwise observed probe
  state wins. A pin never falls back. A policy chooses the first preferred,
  then allowed, available backend in authored order. No matching host records
  a capacity wait decision and consumes no attempt budget.
- **Authoring and placement use the same reachable-node requirements.**
  `workflow usage` emits a stable, deduplicated requirement set for nodes that
  are reachable from the selected entry only; unreachable nodes do not block a
  run. `workflow validate --host` compares that set with one merged capability
  snapshot and reports unavailable, unauthenticated, unverified, and stale
  capabilities without changing workflow or host state. Host gaps are warnings
  unless `--strict-host` is present, when they are validation failures. Dispatch
  rechecks freshness and placement against one snapshot before reservation so a
  validation result cannot authorize a later stale launch.
- **Task mutation is explicit and replay-safe.** `task run` resolves the stored
  task, workflow definition, dependencies, and placement before reserving; its
  dry-run form performs the same resolution but writes no task, attempt,
  session, decision, lease, or evidence row. A successful run links exactly one
  reserved attempt to exactly one workflow session. Interrupt cancellation is
  routed through the shared decision applier and runner cancellation path.
  `task decide` requires exactly one authored action and a human principal;
  duplicate delivery of an already-applied decision is idempotent, while a
  conflicting replay or stale task version fails closed.
- **CLI migration is one cut.** `task run` and `task decide` become available
  only after the dispatcher path is usable. In that same change the
  auto-improve flags and implementation are removed from `workflow run`; plain
  workflow runs remain task-free as decided in section 16. Host-aware
  validation and usage output ship with the placement types, before dispatch
  depends on them.
- **Canonical authoring nodes own their writes.** The checked-in
  `codex-design-and-implement-review-loop` node definitions for Step 6
  implementation and Step 8 documentation refresh run `codex-agent` with
  workspace-write access. Their prompts retain the accepted-plan and
  accepted-review boundaries, and runtime workspace ownership still limits
  writes to the selected worktree. Read-only intake and review nodes remain
  read-only. This is a permanent workflow-definition correction; launchers do
  not patch node payloads per run.
- **P1 closes only on recorded evidence.** Auto-improve removal follows, rather
  than precedes, equivalent dispatcher coverage. P1-0 through P1-8 remain open
  until the active plan records the exact passing command, exit status, and
  complete log path for each gate, including independent adversarial review
  with no unresolved high- or mid-severity finding. P0 behavior remains
  preserved and P2-P7 remain deferred throughout this rollout.

### 17.1 Prior intake, ownership, and phase boundary (historical execution context)

The authoritative issue is
`workflow-input:Complete the Work Runtime P1 dependency DAG (issue URL/number unavailable)`,
from Step 1 communication `comm-000002` in
`codex-design-and-implement-review-loop-session-1`, mode `issue-resolution`.
There is no GitHub URL, repository-plus-number, or external Codex-reference
input. Preserve `comm-000002`, intake execution
`step1-issue-intake-attempt-1-exec-2`, and design step
`step2-design-doc-update`; downstream reviews record their actual execution IDs.
Intake review decision is `accepted-for-single-design-author`, with
`reviewMode: adversarial` and `requiresAdversarialReview: true`;
design remains single-author. Step 3 has not
reviewed this resumed revision. Earlier acceptance/progress references belong
to the prior run and do not certify this revision or the checkpoint code.
No Step 3 or Step 5 revision feedback was supplied for this turn.

Execution uses the runner-resolved immutable user-scope
`codex-design-and-implement-review-loop` package **0.3.14**. Runtime provenance
and effective `workflowInput` are authoritative and contain no concrete
contradiction. Resolution and integrity are runner preflight responsibilities;
this node does not repeat them. Do not edit the installation or start a
project-scope or replacement workflow. Stay on
`feat/remaining-impl-plans` in
`/Users/taco/gits/tacogips/riela-worktrees/remaining-impl-plans`; create no
worktree. Preserve unrelated work, including all Monja tenant-sharding-d48 work.
The current workflow input explicitly authorizes commit and push of accepted
P1 changes and narrowly necessary documentation/index updates. Older no-push language, wherever retained as history, does not
override this authorization. Finalization remains a later
workflow gate; this design turn does not commit, push, or authorize base-branch
integration.

This execution covers **P1-0 through P1-8**, including all six existing plans:
sandbox, reservation, lifecycle, capabilities, dispatch, and serial finalization.
Their exact identities, paths, dependencies, and ownership are in §17.6.
Retained source is input to reconciliation, not accepted implementation.
The dispatcher remains blocked until all four predecessors have accepted
implementation, behavioral evidence, and integration review. Step 4 must
reconcile every plan's metadata with this scope before native dispatch;
neither an external-readiness label nor an empty dependency list may bypass it.
Do not implement loop-engineering, agent-node-output-contract,
workflow-defect detection, Tauri, note plans, or non-P1 plans. Preserve existing
workflow-defect documents and other sessions. Use native dependency-ready Riela
waves only after design/plan acceptance; serialize all shared-file edits.
Astra owns single-author design, single-author planning, and the final
combined-tree integration review. Terra owns implementation and reconciliation;
Sol owns gates and the single material adversarial review. Implementation and
verification may delegate independent work, with one owner per overlapping
file. This Step 2 turn performs no design/planning fanout.

The wider sections 3-12 describe the eventual consolidation. P1 adds only
reservation/leases, guards, director/application, capability placement and its
authoring inputs, task run/decide, and auto-improve replacement. Existing loop,
routine, specialist, event dispatch, and their stores remain until P2/P3;
repository-context worktrees and finalization remain P4; GraphQL task/host APIs,
Studio pickers and Task boards remain P5; proposals and capability ceilings
remain P6/P7. Surface catalog entries explicitly mark those counterparts
deferred rather than expanding this phase to satisfy the general parity rule
in section 10. `task serve` is P3: P1 refreshes local capabilities on `doctor`
and task dispatch. The bounded agent-director path needed by the replacement
example is in P1; specialist classification and long-lived supervision are not.

### 17.2 Reservation, reconciliation, and decision causality

- Resolve the stored plan, selected entry, dependency satisfaction, and host
  requirements before reservation. Missing plans, invalid entries, invalid
  policies, and missing dependency IDs are errors; unmet existing dependencies
  yield `wait(.dependency)`. Capacity gaps yield `wait(.capacity)`. Neither wait
  creates a session, launch lease, or attempt. Recheck the task version and
  dependency satisfaction at the reservation commit point.
- Attempt, unique session identity, lease, dispatch decision, placement
  evidence, and task-version advancement commit together on the shared SQLite
  connection. Duplicate attempt/session identities reject rather than update
  an existing runtime snapshot. Any failure rolls everything back. Prepared,
  running, and terminal-but-unreconciled attempts hold the one-live-attempt
  fence. The runner must execute the reserved session ID, never create a second
  independent session for the same attempt.
- Launch authorization consumes the opaque token once, bound to the exact
  attempt/session. Persist only its digest, never include the token in evidence
  or diagnostics. Fence a provably unauthorized reservation before explicitly
  replacing it. Authorization or node-start uncertainty retains the fence and
  requires reconciliation; lease expiry or missing heartbeat is not proof of
  non-execution. A stale launcher cannot write terminal state for a replacement.
- The dispatcher projects terminal evidence before evaluating completion. For
  every decision, `causedBy` identifies existing evidence from this task and
  the relevant attempt: guard records, failure/terminal records, rejected gate
  and findings, or completion evidence. Missing, foreign, or stale evidence
  cannot authorize a decision. Store-side application checks the current task
  version and relevant attempt; a caller-supplied completion verdict alone is
  not authority to accept.
- Acceptance uses the latest accepting attempt's required gates and passing
  verification, applicable unresolved blocking findings, and affirmative
  acceptance payload when criteria exist. Old passing evidence cannot mask a
  newer failure. Human acceptance satisfies only `requiresHumanAccept`; it
  cannot waive failed gates, missing verification, or open blocking findings.
- Decision identity is a caller-stable `decisionId`. An identical replay
  returns its recorded application outcome without advancing versions, emitting
  evidence again, or scheduling another attempt. Reuse with changed action,
  task/attempt, principal, reason, or causal payload is a conflict; a fresh
  decision with a stale expected task version is rejected. Server timestamps
  are retained from first application, not regenerated as user intent.
- A rerun/recover application durably records one pending reservation request.
  Reservation consumes that request once and links the existing decision to its
  new attempt; it must not insert a conflicting duplicate decision or silently
  lose the request between application and launch. A replay may reconcile the
  same pending request, never create a second request. Retain consumed requests
  as replay evidence while allowing a later distinct decision to enqueue the
  next request after reconciliation; uniqueness applies to the unconsumed
  request per task, not all historical requests. Start/resume use the same
  reservation fence and decision identity rules.
- Cancel, stop, reject, and inactivity-triggered rerun first request runner
  cancellation when execution is live. Persist the request, retain the fence,
  and wait for durable terminal acknowledgment before reconciliation, terminal
  task state, or a replacement launch. A caller outcome alone is insufficient:
  require the reserved runtime snapshot to durably record the matching cancelled
  failure; a created snapshot, mismatched outcome, or non-cancellation failure
  cannot acknowledge cancellation. If acknowledgment is uncertain, expose
  that state for an explicit decision; do not merely mark an active attempt
  reconciled in the store. Process interruption follows this same path.

### 17.3 Guard and director evaluation boundary

Persist the complete guard batch before either policy or human application;
persistence failure prevents the dependent decision. Snapshot replay must not
duplicate observations or charge cumulative token totals twice. Gate visits
violate at `visits > limit`; repeated findings, token/wall-clock budgets, and
inactivity violate at `used >= limit`, matching the retained detectors. Attempt
budget limits admission of another attempt; reserving the last permitted
attempt must not cancel it solely because the count now equals the limit.
Completion of that attempt is still evaluated; a next reservation is refused.
Repeated-finding identity uses the existing fingerprint. Inactivity applies
only to configured heartbeat-capable backends; `official/*-sdk` stays exempt.

For actionable violations, use budget, convergence, inactivity, recoverable
terminal failure/gate rejection, completion, then `wait(.human)` priority.
Within a category use stable budget-dimension and gate/step identity ordering.
Every rerun or gate recovery must have remaining attempt budget. Budget limits
cannot be bypassed by `warn`, human action, or agent output. For other guard
violations, `warn` records evidence without a forced guard action; `fail`
records stop; `askDirector` uses the ordered policy table, with one bounded
agent round for an escalation when configured, otherwise `wait(.human)`.

The agent-director example uses an ordinary child workflow and typed output
validation. Reconcile the work attempt before reserving `entry: .director`, so
the same task never has two live attempts. Record the child session and charge
its cost/attempt budget once. Its `TaskView` retains the work attempt being
judged, not the director child's own successful status. Restrict output to the
task's allowed decision kinds and the P1 actions the applier supports; route it
through the same causality, completion, and version checks. Invalid, forbidden,
failed, or budget-blocked output records evidence and requires human decision.
Do not recursively invoke a director to repair a director failure. P1 does not
implement workflow-change proposals, replanning machinery, or specialist chat
classification just to support this example.

### 17.4 Reachability, capabilities, and deterministic placement

- Requirements start at the selected start/resume/rerun/recovery entry. Follow
  every statically possible transition and called-workflow entry; visit cycles
  once. Reused prefix results are inputs, not newly executed requirements.
  Unreachable nodes contribute nothing. An unresolved executable target is a
  resolution diagnostic, not silently omitted. Stable output retains node/step
  provenance while deduplicating backend, add-on executable, and required
  environment requirements. Environment evidence records names/presence only.
- A node declares a pin or a policy, never both. `allowed` is nonempty and
  duplicate-free; `preferred` is an ordered subset, and `modelByBackend` keys
  must be allowed. Reject unknown backends and ambiguous model declarations.
  Try preferred entries in authored order, then remaining allowed entries in
  authored order. A pin never falls back; a selected model must match a known
  nonempty model list. An absent model list is unknown, not proof that every
  model is supported; report it as unverified for an explicit model request.
- Use the existing placement topology: explicit worker/step assignments and
  worker-group constraints are authoritative. Unassigned execution prefers a
  matching local host, then matching registered workers sorted by worker ID;
  group candidates use that same stable order and must have available capacity.
  For each candidate require all nodes assigned to it to fit; do not bypass an
  explicit assignment by selecting another host. Record per-node host/backend
  choices, capability source, observation time, and snapshot freshness.
- Section 5a's declaration merge is intentional: disable always wins; explicit
  enable without a successful probe remains usable but unverified, including a
  failed auth probe. Preserve that failure in diagnostics, never relabel it
  authenticated. Without explicit enable, absent, unauthenticated, or unknown
  capability cannot satisfy dispatch. Declared models override observed lists.
  A declaration does not prove worker liveness or create worker capacity.
  Backend enablement also does not waive a missing required add-on executable
  or environment name on its assigned host.
- Use one merged snapshot per placement evaluation, with a finite configured
  freshness bound and bounded probe timeout. Equality with the freshness bound
  is stale. Refresh stale observations before real reservation; failed refresh
  cannot reuse stale observed success. Explicit declarations remain labelled
  unverified when observations cannot establish availability. Adapter-owned
  version/auth probes perform no login, credential mutation, or model inference;
  unsupported auth probes return unknown. SDK backends use their existing
  adapter configuration/credential checks, not invented CLI auth commands.
- `workflow validate --host` and `workflow usage` share this projection. Host
  absence, auth failure, stale or unverified capability are warnings by default;
  `--strict-host` turns them into validation failures and requires `--host`.
  Structural workflow/policy errors always fail. Group validation succeeds only
  if a complete legal placement exists. Validation is read-only and does not
  refresh persisted host state. Dispatch makes its own freshness check; prior
  validation never acts as a launch token. Planner variables carry the intended
  host snapshot and generated plans undergo the same requirement resolution.

### 17.5 Command, rollout, and review acceptance

`task run <task-id>` uses canonical store/definition resolution and exposes its
attempt/session IDs or dependency/capacity wait reason. `--dry-run` performs the
same resolution and returns prospective per-node placement without creating,
migrating, resetting, checkpointing, or writing runtime databases or host cache.
It opens existing state read-only; missing or incompatible state is a diagnostic.
Fresh probes, if needed, stay in memory. Verification compares database bytes
and all affected rows before/after, including `work_hosts`; it also compares
SQLite WAL/SHM sidecars, host-profile configuration and other affected files.
An absent store must remain absent. Corrupt host-profile input is diagnostic
only: do not quarantine, rewrite, or repair it during dry-run.

#### P1-6c bounded amendment (2026-09-24)

**Scope and status.** Issue `Work Runtime P1-6c` (no GitHub issue URL or
number supplied), mode `issue-resolution`, intake `comm-000002` from
`step1-issue-intake`, execution `codex-design-and-implement-review-loop-session-1`.
This amendment and its implementation plan were accepted at checkpoint
`0a74a070670a5cb73f6cd18e035adf61732a0b07` on `feat/remaining-impl-plans`.
The current intake, “Repair P1-6c selected-host late-cancellation regression
exposed on capable host”, preserves that design and implementation WIP, including
checkpoint `ce703014c3d78113897d640f85825f5115ae0376`. The repair amendment below
supersedes prior evidence-readiness statements; it does not replace the accepted
arbitration contract.
Preserve all checkpoints and helper merge `b06295d5c3fbc42528d0382014ded0e9118dfa88`
on `feat/remaining-impl-plans`. The subprocess wait helper repair is already
merged; this slice does not reopen it. The prior high-severity late-cancellation
finding motivated the arbitration contract below. P1-6c was accepted after
the later source-matched host verification and formal reviews recorded in
`impl-plans/progress/p1-dispatch.md`. The earlier failed regression and
pending-review statements in this amendment describe the intake history.
P1-6d, P1-7a/b and parent P1 remain open.

**Selected-host regression repair amendment (current intake).** The complete
`tmp/work-runtime-p1-6c-final-host/selected-host.log` records one executed
`testLateSelectedHostCancellationAfterObservationRetriesWithStopProof` test and
three assertion failures at fixture lines 340, 275 and 276: canonical state was
already terminal at injection, failure kind was `adapterFailure`, and no
`AttemptCancellationRecord` existed. Intake reports host exit 1. Step 2 read the
complete log and verified SHA-256
`4dc832737ba4ace589f4bcf26ea0aa76d141a7cdb92a4673b3f28d6343a857b2`.
Before editing this document, the check of
`tmp/work-runtime-p1-6c-after-helper-review-20260924-9fbcc7126181/final-source-after-retry.sha256`
exited 0 with 973/973 entries; its digest is
`dc6cec7251a8607b20b65ccaddb775606352b7556556209e6985bf1328409cd6`.
The check log is `tmp/p1-6c-design-repair/intake-manifest-check.log`.
The older 136-test pass and 2,057-test/19-assertion aggregate below are historical,
not acceptance of this failed source or its future repair. The broad gate remains
failed. This is a capable-host regression, not a listener-denial result.

**Ordering diagnosis and bounded repair decision.** The current fixture in
`Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift` uses
`/bin/true` on the selected worker and throws from `beforeTerminalPersistence`.
`FailClosedSQLiteWorkflowRuntimeStore.swift` marks that hook as run before calling
it; a throw prevents that write, not every later terminal write.
`WorkflowRunCommand.swift` also has final persistence. In
`TaskRunCancellation.swift`, `afterCancellationObservation` runs only after
execution and observer join and the first pending-request/stop-proof check.
Thus the fixture's single throw does not establish a nonterminal canonical
session at the late injection boundary. The log proves that precondition failed;
source ordering suggests a subsequent error/final save, but the exact winning
writer must be identified before claiming root cause or changing production.

The serial owner must trace the reserved session through the initial terminal
candidate, injected error, subsequent live/final saves, observer join, first
cancellation observation, request commit and joined-cancellation persistence.
Record canonical state, request presence and selected-job completion at those
boundaries using existing seams or minimal test-only instrumentation. No sleeps
or synthetic terminal rows establish this ordering. If the request was attempted
after an ordinary terminal commit, retain terminal-first rejection, including
ordinary failure; never reinterpret `adapterFailure` as cancellation or overwrite
that winner. Repair the fixture's control of terminal writes so the named late
regression reaches its intended nonterminal window. If a real request-first
write is bypassed by any terminal writer, repair that existing arbitration seam
as well. Do not remove persistence-failure coverage to hide a production defect.

For this named regression the required sequence is: selected execution finishes
and is joined; the canonical session remains nonterminal with no request; the
initial cancellation observation finds no request; a separate store connection
commits the exact attempt's cancellation; joined persistence discovers that
selected-host stop proof is still required; the owner obtains matching worker
completion proof and retries persistence; dispatch acknowledges the exact
cancelled snapshot. A succeeded remote `/bin/true` job can prove stopped work
without making the workflow session terminal first. Demonstrate entry into the
proof-required retry, rather than relying only on final cancelled state. Retain
all existing assertions and strengthen ordering evidence as necessary. Preserve
the separate running-worker cancellation test's leader/child stop checks and
uncertain-stop fence retention. A hook must not bypass the transaction guard or
change ordinary production behavior when unset. No new schema, transport,
coordinator or adapter is justified.

**Current acceptance and planning handoff.** Step 4 updates the complete batch
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` in native
dependency-ready Riela waves: ordering diagnosis precedes serial repair, then
verification, independent test-integrity and single adversarial review, serial
reconciliation and Astra exact combined-tree acceptance. Existing accepted plan
history and WIP remain preserved. Run the following selected regression first
on repaired source on a listener-capable host, followed by the affected focused
suite and serial aggregate in the repaired-source command contract below:

```bash
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests/testLateSelectedHostCancellationAfterObservationRetriesWithStopProof'
```

The selected regression and affected focused tests require positive test counts
and exit 0. Capture all command arguments, complete logs, actual terminal exits,
counts and a matching source/build-input manifest before and after tests under a
fresh repository-root `tmp/` evidence directory. The serial aggregate must finish;
classify every failure against preserved non-slice evidence independently. Any
P1-6c failure or unclassified material failure blocks acceptance; unrelated
failures remain visible and do not become a green broad gate. Source edits require
new evidence and reviews. Listener denial cannot satisfy these gates. Historical
instructions below to inspect existing receipts first do not waive these reruns.
Only after all three formal reviews accept without material P1-6c findings may
completion documentation distinguish this slice from P1-6d, P1-7a/b, parent P1
and the failed broad gate, followed by exact-file commit and non-force push.

**Open technical questions and design review status.** Implementation must identify
which writer committed `adapterFailure` and whether corrected ordering exposes
an additional arbitration defect. These are bounded diagnostic work, not unresolved
user choices; no user-QA file is needed. No new Step 3/5 feedback was supplied.
Step 2 approves this document for independent design review only; implementation,
test-integrity, adversarial and Astra acceptance remain pending. No current host
pass or closure of the prior high cancellation finding is claimed.

**Continuation boundary.** Preserve all 28 modified tracked files and three
untracked Swift files listed by intake, plus the initially empty staged state.
One serial owner edits coupled source; independent reviews are read-only.
Protect Monja and other worktrees. No reset, broad staging, force push,
unrelated baseline repair or scratch outside repository-root `tmp/`. The
prior two-row diagnosis below is historical context, not a request to reopen
legitimate decision history.

**Decision identity and causality diagnosis.** Before changing production or
relaxing the fixture assertion, capture every decision for the exact task at
reservation, after cancellation acknowledgment, and after identical CLI replay.
Record each row's `id`, `kind`, `producer`, `taskId`, `attemptId`, `causedBy`
evidence IDs and resolved causal meaning; correlate the reserved session,
cancellation record's `decisionId`, and original decision application.
The requested human cancellation ID is `decision-remote-live-cancel`.
`Sources/RielaCLI/TaskDispatch.swift` also supplies a policy `task-run` decision
at reservation, and `Sources/RielaWork/WorkStore+Reservation.swift` commits a
reservation decision. This makes an admission decision a concrete candidate
for the extra row, not an identification of either row in the reported run.
Inspect guard/terminal decisions against their actual ordering and evidence;
a legitimate earlier decision does not authorize ordinary terminal guard
evaluation after cancellation acknowledgment.

The accepted invariant is one application of each decision identity and exactly
one cancellation request for this human intent, not a universal one-row task
history. If both observed rows prove legitimate distinct decisions, correct
both pre-replay and post-replay expectations to assert their exact identities,
kinds and causal links, one cancel, and unchanged decision/application evidence
across replay. Do not merely replace the count with two or filter out an
unexplained row. If evidence instead establishes duplicate cancellation,
reapplication, or forbidden terminal evaluation, repair only that producing or
replay seam and retain a regression that detects the defect. Never delete or
mutate decision rows to make the test pass. Keep the existing process-stop,
reserved cancelled snapshot, acknowledgment, fence, attempt, outcome and
once-only evidence/accounting assertions. Reproduce on a capable host and
record both decision identities and causality with a passing final-source run.

**Existing boundaries.** `Sources/RielaCLI/TaskCommands.swift` owns human
parsing/application; `TaskDispatch.swift` owns reserved-session orchestration
and terminal reconciliation. `Sources/RielaWork/WorkStore+Decisions.swift` and
`WorkStore+Reservation.swift` remain the sole durable decision, cancellation,
launch-authorization and replacement boundaries. The existing workflow runner,
live/final persistence and selected-host cancellation transport own execution
interruption. No second decision store, replacement scheduler, transport or
framework is introduced. Current store guards and matching-snapshot checks are
present. `TaskDispatch.swift` now fences pending cancellation before generic
`reconcileAttempt` and replays only a matching acknowledged terminal snapshot.
The preserved implementation now includes the run-owned observer and prelaunch
snapshot in `TaskRunCancellation.swift`, request-before-signal routing through
`EntryPoint.swift` and `TaskCommands.swift`, controller/worker stop receipts, and
proof-gated exact acknowledgment in dispatch. These seams are implemented WIP;
their presence does not establish task-backed live selected-host acceptance or
complete failure, replay and replacement-race coverage.

**Human command contract.** `task decide` accepts exactly one of `--accept`,
`--reject <reason>`, `--rerun [step-id]` or `--cancel`, with nonempty
`--principal`, explicit `--expected-version`, and nonempty `--decision-id`.
Reject an empty rejection reason, an optional step without rerun, conflicting
or absent actions, and invalid version/identity input before mutation. The
shared applier validates current version, task/attempt and causal evidence;
accept cannot waive completion requirements. Identical decision replay returns
the original recorded application; changed intent with the same identity
conflicts. A successful application reports request acceptance, not proof that
execution has stopped or the task is terminal.

**Durable request to live execution.** Human cancel/reject, guard
stop/replacement and task-backed Ctrl-C enter the same shared applier. Commit
the decision and cancellation request (and pending replacement when applicable)
before sending an interruption signal. A write failure is visible and does not
authorize a signal or fence release. The task-run owner observes durable pending
requests for its exact task/attempt/session while execution is active, including
requests written by a separate `task decide` process; an in-memory callback
alone is insufficient. Use a bounded polling observation in the existing run
lifetime, read once before authorization and again across launch/start, and
stop and join observation when that owned run exits. Polling must not depend
on workflow output or heartbeat arrival. Signals are retryable consequences
of the stored request, never fresh decisions on each poll. Ctrl-C first commits
its stable decision in a cancellation-safe bounded operation, then cancels the
owned runner if the request wins arbitration. Terminal-first follows the explicit
late-signal outcome below. Preserve plain, non-task workflow behavior.

| Boundary or race | Required result |
| --- | --- |
| Request commits before authorization | Authorization and node-start checks reject it. The owning runner persists cancellation for the reserved session without launching work, then uses acknowledgment; no synthetic second session. |
| Authorization/start races with request | Store checks serialize authorization with the durable request. If authorization wins, treat execution as potentially live, interrupt the exact owned execution and retain its fence. |
| Local or selected-host work is running | Interrupt the local child or existing authenticated selected-host job through the current runner path. Preserve reserved session and selected placement; no local fallback or replacement dispatch. |
| Selected-host cancellation is sent or transport fails | Sending, HTTP acceptance, lease loss or heartbeat loss is not terminal proof. Existing worker completion must establish that the owned work stopped before the runner persists the cancelled result. Uncertainty remains fenced and visible. |
| Terminal persistence fails or acknowledgment is lost | Keep the request and fence. Retry/reopen reads the canonical reserved snapshot and stored acknowledgment; it never substitutes an in-memory result. |
| Ordinary terminal persistence races with the request | Serialize both writes as specified below. Request-first blocks ordinary terminal persistence; terminal-first rejects the late request without creating pending cancellation or changing terminal success. |

**Late-cancellation arbitration (preserved acceptance contract).** The linearization point is
the commit in the shared runtime SQLite database, not task reconciliation,
observer polling, an in-memory lock, or signal arrival. `WorkStore` already
shares that database with `SQLiteWorkflowRuntimePersistenceStore`; reuse the
existing transaction-scoped snapshot read/write boundary. No new store, schema,
queue or generalized coordination framework is required.

- Request insertion in `WorkStore+Decisions.swift` and the cancellation primitive
  in `WorkStore+Reservation.swift` must read the exact reserved canonical session
  inside the same write transaction that decides whether to insert cancellation.
  Validate task/attempt/session identity and version there; attempt state alone
  is insufficient because it can lag session persistence. Preserve original
  application lookup before state validation for an already accepted replay.
- Every task-backed canonical terminal writer, including live and final saves
  through `CLIWorkflowSessionStore.swift` and
  `SQLiteWorkflowRuntimePersistenceStore.swift`, must check pending cancellation
  and commit the terminal snapshot under the same database transaction. Audit
  both snapshot save overloads and runner supervision/final persistence so no
  alternate writer bypasses arbitration. Plain workflows retain their behavior;
  artifact exports are downstream of the canonical commit, not stop proof.
  Delayed live saves must not overwrite a committed terminal winner with a
  nonterminal or contradictory terminal snapshot.
- **Request-first:** commit the stable decision and pending request before
  interruption. A competing ordinary terminal candidate must not commit. Return
  control to the owning runner to join local/selected-host work and persist the
  exact cancelled session with canonical cancelled outcome, then acknowledge via
  the existing atomic transition. A rejected ordinary candidate is not itself
  stop proof. Never rewrite an already committed success as cancelled. Database
  failure, uncertain stop or failed acknowledgement keeps the fence and a visible
  pending/error state; no success result may escape while cancellation is pending.
- **Terminal-first:** if an ordinary terminal snapshot has committed, reject a
  new cancellation as an explicit “already terminal; cancellation not applied”
  outcome. Roll back decision/application/request/task-version mutations from
  that attempted application; do not silently claim request acceptance. External
  `task decide --cancel` reports this rejection. `TaskRunCancellation.swift`
  treats the same outcome for a late SIGINT as a resolved late signal: join its
  observer, continue canonical terminal reconciliation, and preserve the run's
  original success/failure and exit result. Do not retry it as a version conflict,
  interrupt completed work, or manufacture cancellation acknowledgement. A
  subsequent identical late request remains rejected; an earlier accepted
  decision replay still returns its original application. Existing cancellation
  already acknowledged remains governed by the existing replay contract.
- `TaskDispatch.swift` consumes the canonical winner. Request-first uses exact
  cancellation acknowledgement; terminal-first uses ordinary reconciliation once.
  Keep its fence until that reconciliation commits. Do not delete or mutate
  decision rows, run hidden post-success cleanup, or retarget a stale request to
  a newer attempt. Historical contradictory rows fail closed for explicit
  diagnosis; this repair adds no retroactive data-repair operation.

**Deterministic regression matrix.** In
`Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` and its fixtures,
exercise request-first and terminal-first for both SIGINT and external
`task decide --cancel` against production persistence/application boundaries.
Use explicit barriers before the competing commits and after canonical terminal
commit but before dispatch reconciliation; timing sleeps are not ordering proof.
Preserve `testTaskRunSubprocessSIGINTCommitsAndAcknowledgesCancellation` through
real EntryPoint. Store tests in `WorkStoreCancellationTests.swift` and
`DecisionApplierStoreTests.swift` must additionally race independent SQLite
connections, check rollback and cover all cancellation insertion paths.
For request-first assert durable request before interruption, owned stop proof,
exact reserved cancelled snapshot/outcome, acknowledgment, fence release only
after proof, stable decision/application replay and once-only accounting. For
terminal-first assert successful work stays successful (also preserve an ordinary
failure), explicit external rejection/late-SIGINT handling, no new pending row or
decision/application/version mutation, ordinary reconciliation once, and unchanged
results after reopen/replay. Include cancellation arriving between observer join
and final signal commit. Retain selected-host stop-proof coverage; transport
acceptance is insufficient. Never fabricate a terminal row in place of the live
production-boundary regression.

**Persistence, acknowledgment and replay.**
`Sources/RielaCLI/WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift`
and `WorkflowRunCommand+SupervisionPersistence.swift` must preserve the exact
reserved identity through cancellation and durably persist the final cancelled
snapshot even when the execution task is cancelled. Keep bounded terminal
persistence owned and awaited; no orphan persistence task. Once the runner has
stopped and persistence has succeeded, dispatch projects canonical evidence and
routes pending cancellation through `acknowledgeAttemptCancellation`, never
ordinary completion/guard evaluation. The store checks the cancellation's
original decision/task/attempt plus the exact reserved snapshot with failed
status, cancelled failure kind and matching canonical outcome. Acknowledgment,
attempt reconciliation, lease release and task transition commit atomically:
cancel becomes cancelled, reject/stop becomes failed, rerun/recover becomes
scheduled. Generic reconciliation must continue rejecting pending requests.

Reopening after a crash before acknowledgment repeats the canonical check;
after acknowledgment it recognizes the recorded result without applying the
transition, evidence or usage twice. Do not require the low-level acknowledgment
API to accept a second mutation: the orchestration may read its durable result.
Consume a pending replacement only through the existing reservation transaction
after acknowledgment, once, with a new exact session and the original decision
linkage. Crash/replay between acknowledgment and reservation cannot lose the
request, duplicate accounting or authorize an old launch token. An unreachable
runner or uncertain terminal outcome remains an explicit fenced error/pending
state; no timeout, lease expiry, heartbeat loss or generic cleanup clears it.

**Verification and handoff.** The next plan updates
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` for P1-6c,
retaining the completed P1-6b evidence. Tests in
`Tests/RielaWorkTests/WorkStoreCancellationTests.swift`,
`WorkStoreReservationTests.swift`, `DecisionApplierStoreTests.swift`,
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`TaskDispatcherIntegrationTests.swift`, and
`Tests/RielaServerTests/DistributedWorkerHTTPTests.swift` must cover the table
above with deterministic barriers at authorization, execution, persistence and
acknowledgment. Assert request-before-signal ordering, real child interruption
locally and on the selected worker, exact durable session/outcome, held fence,
no premature task terminal state, stable replay and one replacement/accounting.
Store-only or manually fabricated terminal snapshots cannot substitute for the
live local and selected-host tests. Retain the accepted V1/V2/V11 commands;
explicitly include `DecisionApplierStoreTests` and command parsing tests, plus
affected CLI, Work, Core and Server aggregate suites and strict changed-file
SwiftLint. Run the accepted plan's V0, V1, V2, V11, decisions, live, compatibility,
aggregate, strict changed-file SwiftLint, `git diff --check` and
`git diff --cached --check` gates on final source. Final-source execution
evidence records exact commands, complete foreground logs, terminal exit codes,
positive per-suite counts and source/test hashes under
`tmp/work-runtime-p1/p1-6c/`.
A bounded environment failure remains a failed run and must be separated from
source-matched capable-host evidence; P1-6b evidence cannot certify new code.

**Repaired-source command contract.** Run in the foreground, capture complete
logs and terminal exits under `tmp/work-runtime-p1/p1-6c/late-cancellation/`,
and retain the accepted plan's additional filters and strict changed-file lint.
The implementation plan must enumerate final changed Swift files explicitly for
lint and the manifest; the manifest includes all source, tests and build inputs,
not merely tracked diffs. Check manifest membership as well as file hashes.
These remain the execution commands if a material repair or evidence gap
requires new verification. For the unchanged post-helper source, inspect the
current receipts below first; do not repeat the aggregate in this sandbox.
These command examples are not results from this design step:

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests|TaskDispatcherIntegrationTests|WorkStoreCancellationTests|DecisionApplierStoreTests|DistributedWorkerHTTPTests|DistributedJobControllerTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests|RielaServerTests'
xargs -0 swiftlint lint --strict --no-cache < tmp/work-runtime-p1/p1-6c/late-cancellation/changed-swift-files.nul
shasum -a 256 -c tmp/work-runtime-p1/p1-6c/late-cancellation/final-source.sha256
git diff --check
git diff --cached --check
```

Record zero-test selections as verification gaps; build/lint/hash checks have
no test count. Listener-denied runs are environmental failures, not passes.
Obtain source-matched capable-host focused and serial aggregate logs. Preserve
the 19 owned non-slice failures below until new evidence establishes their
actual disposition; the broad aggregate remains FAILED until it passes.

**Historical post-helper capable-host evidence (2026-09-24).** The prior
receipt is `tmp/work-runtime-p1-6c-after-helper-acceptance/host-evidence.json`.
Its source manifest covers `Sources/`, `Tests/`, `Package.swift` and
`Package.resolved`. Step 2 independently checked all 973 hashes and exact
tracked/untracked membership: 973 matched, zero mismatches, no missing or extra
paths. Documentation is outside that manifest and must also be included in the
later exact combined-tree review.

| Artifact | Path | SHA-256 | Host result |
| --- | --- | --- | --- |
| Source manifest | `tmp/work-runtime-p1-6c-late-cancel-host/final-source-after-helper.sha256` | `b4609069880f14c0bd4f62053d39b73cd13556078fc688d763643fd243ab0f1c` | 973 entries, zero mismatches |
| Focused log | `tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log` | `b6d4dd35c487172f34542e302093e8f5908ffcb1a5da61d5c391ac7c096646e1` | 136 tests, zero failures; reported exit 0 |
| Serial aggregate log | `tmp/work-runtime-p1-6c-late-cancel-host/aggregate-after-helper.log` | `bceedcfbe1aaa20653088bdcdf4c37045081a0b546492f72b67dac375ac21ccd` | 2,057 tests, 19 assertions, 7 unexpected; reported exit 1; **FAILED** |

Step 2 used `shasum -a 256` to verify all three digests and
`shasum -a 256 -c` to verify source bytes (exit 0). A full-file parser consumed
all 330 focused-log lines and 4,968 aggregate-log lines, checked XCTest summaries
and matched every aggregate assertion's suite, test and source line against
inventory IDs 1–8 and 14–24: 19 matches, zero new or missing assertions.
The host exit codes above are recorded by the operator receipt, not new test
executions or exit markers inferred from XCTest text. Inspection evidence is in
`tmp/p1-6c-step2-after-helper/evidence-inspection.json`, `digests.log` and
`manifest-check.log`. This establishes evidence identity, not independent
acceptance of the non-slice classification or implementation correctness.

Exclude `tmp/work-runtime-p1-6c-late-cancel-host/aggregate.log` (interrupted
before the helper repair) and
`tmp/work-runtime-p1-6c-late-cancel-20260924-session-1/aggregate-final-3.log`
(older sandbox run) from current-source acceptance. Pre-repair 99-test and
2,049-test logs are historical only. Do not rerun the listener-dependent
aggregate inside this sandbox. Review complete current logs and source/test
semantics downstream; passing counts alone do not prove coverage. Retain the
real EntryPoint SIGINT test, selected-host stop proof, exact cancelled-session
acknowledgment and deterministic ordering obligations above.

**Failure disposition and bounded review.** The inventory
`tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json`
contains 24 historical assertion records. IDs 9–13 are the five catalog and
projection assertions repaired in preserved WIP and absent from the current
aggregate. The intake reports that the other 19 match current assertions by test identity
and exact assertion source line, with zero new or missing records. Independently
compare every assertion to IDs 1–8 and 14–24; any new P1-6c failure blocks slice
acceptance. Historical log line numbers must not be mistaken for current log
lines.
Keep every record's source-history and focused-reproduction evidence available
for independent review; unchanged filenames alone do not establish irrelevance.

| Current failures | Inventory IDs | Follow-up owner |
| --- | --- | --- |
| Doctor decoding, 7 | 1–7 | CLI doctor / backend-capability owner |
| Example parity, 1 | 8 | P1-7b examples owner |
| Workflow commands, 8 | 14–21 | workflow-command/host-readiness owner (outside P1-6c) |
| Runner admission, 1 | 22 | Workflow runner admission owner |
| Temporary workflow requirements, 2 | 23–24 | Temporary workflow/host-requirements owner |

These are assertion counts, not necessarily distinct tests. The inventory's
non-slice classifications are proposals for independent disposition, not a
waiver. Review changed dependencies and source history, including the recorded
limits on historical root-cause evidence for workflow-command IDs 16–21.
Retain the catalog's actual registered mutation/audit behavior and the failed
session's canonical `acceptanceNotMet` reason; do not suppress assertions,
weaken completion semantics, or repair unrelated baseline failures.

**Acceptance and rollout boundary.** The next plan updates
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` for final evidence review and any material bounded repair, preserving the
accepted atomicity contract, deterministic regression matrix and WIP. Independent
`gpt-6-sol` test-integrity and independent `gpt-6-sol` adversarial reviewers
assess source, tests, request-before-signal ordering, owned stop proof, exact
cancelled session, acknowledgment, fence/replay, real EntryPoint SIGINT and
selected-host behavior, and slice-only
eligibility. Astra independently reviews the exact combined tree, including
documentation and any serial repair. Record each decision, findings, file paths,
commands and complete log/exit evidence. These reviews remain pending; Step 2
makes no implementation acceptance decision.

Retain the accepted V0/V1/V2/V11, decision, live, compatibility and changed-file
lint obligations. Assess existing source-matched evidence first; run focused
checks only for a concrete gap. Do not rerun the 2,057-test aggregate in a
listener-denied sandbox to reinterpret known host failures. Any source/test
change invalidates final-source acceptance evidence until its manifest is
rechecked and affected tests rerun on a capable host where required. One serial
owner makes coupled edits; reviewers investigate independently. No direct
decision-row mutation, new framework, unrelated cleanup or package edit is in
scope. Runtime-resolved workflow provenance and effective workflowInput are
authoritative; this node adds no workflow readiness requirements.

Current evidence inspection commands (not new test executions) include:

```bash
shasum -a 256 tmp/work-runtime-p1-6c-late-cancel-host/final-source-after-helper.sha256 tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log tmp/work-runtime-p1-6c-late-cancel-host/aggregate-after-helper.log
shasum -a 256 -c tmp/work-runtime-p1-6c-late-cancel-host/final-source-after-helper.sha256
cat tmp/work-runtime-p1-6c-after-helper-acceptance/host-evidence.json
cat tmp/work-runtime-p1-6c-late-cancel-host/focused-after-helper.log
cat tmp/work-runtime-p1-6c-late-cancel-host/aggregate-after-helper.log
cat tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json
git diff --check
git diff --cached --check
```

Open evidence questions are whether independent review accepts all 19
non-slice classifications and whether the preserved tests/evidence satisfy all
material cancellation obligations. An unclassified failure, missing material
coverage, or unresolved high/mid P1-6c finding blocks acceptance and requires a
precise finding and bounded repair. No unresolved product choice requires a
user-QA document. No new Step 3/5 revision feedback was supplied. The prior adversarial high
finding is addressed by the preserved arbitration contract and repaired WIP;
its formal closure remains pending independent verification of that repair.
The earlier mid finding about helper-only SIGINT coverage likewise requires
renewed review of the preserved real EntryPoint subprocess test.

Only after explicit independent slice-only acceptance, refresh documentation
and `impl-plans/progress/p1-dispatch.md`, exact-file commit and non-force push
on `feat/remaining-impl-plans`. Preserve P1-6d, P1-7a/b, parent P1, all 19
follow-ups and the failed broad gate as open. No main merge or release.

Single design-author role: prior `/root/design_author`, continued by this Step 2
author only. Plan author and serial implementation owner are downstream;
independent test-integrity, adversarial and Astra exact combined-tree reviewers
remain pending. These are required review roles, not claims of completed review.
These codex-agent references describe workflow roles, not a Codex behavior
reference. No Cursor CLI change, adapter or intentional reference divergence
is required; no reference-repository inspection is needed for this scope.

#### P1-6b bounded continuation (2026-09-24)

This continuation addresses **Work Runtime P1-6b** (no GitHub issue number
supplied), from `codex-design-and-implement-review-loop-session-1`,
`step1-issue-intake`, `comm-000002` (intake also references `comm-000001`).
Historical design acceptance is `comm-000004`,
`step3-design-review-attempt-1-exec-4`; it is not current implementation
acceptance. Effective workflow input limits this slice to P1-6b on
`feat/remaining-impl-plans`, preserving accepted P1-6a commit
`2f10916a14501af68fd7e7f63cb91f244a343f8c`. The broader rollout requirements
below remain parent-plan requirements, not authorization to implement or
certify P1-6c/d, P1-7a/b or parent P1 in this slice. No new architecture,
storage schema, task-management command or adapter is needed.

**Resolution and mutation boundary.** Parse `task run <task-id> [--dry-run]`
with the existing scope, working-directory, session-store and output options.
Preserve their precedence and missing-ID/invalid-option diagnostics. Both
modes locate the stored task and workflow reference, resolve the selected
entry (including an existing pending request), validate reachable/called
workflow requirements, and compute prospective host/backend placement through
the existing dispatcher. Select read-only dependencies before any loader or
constructor that could initialize, migrate, reset, quarantine or write state.
Dry-run stops before reservation, request consumption, launch authorization or
runner execution. Only real execution reserves and runs the exact reserved
session under the accepted P1-6a contract. A preview is not a reservation:
concurrent dependency/version/capacity changes remain subject to admission
rechecks; preview does not promise a later launch.

**Result contract.** Text and structured JSON expose the same task ID, status,
and applicable result data using the existing typed result model:

| Outcome | Required result |
| --- | --- |
| Dry-run ready | `ready`, prospective per-node host/backend placement, no attempt/session IDs and no wait reason |
| Dependency/capacity wait | `waiting`, exact typed wait reason and available placement diagnostics; no allocated attempt/session IDs |
| Admitted execution | Exact reserved attempt/session IDs and observed execution status, including a failed execution once those identities exist; preserve nonzero failure exit status |
| Pre-admission error | Actionable diagnostic with nonzero exit status; structured output uses the existing task failure envelope and does not invent allocated IDs |

Missing task/store, incompatible or corrupt database, invalid stored plan and
unreadable/corrupt profile are errors, not successful readiness or capacity
waits. Missing optional host configuration retains existing in-memory defaults
without persisting a default profile. Text preview must expose placement as
well as status; a structured invocation must not lose its typed result merely
because a lower-level runner returns an error. Preserve existing JSON optional
field conventions; no new streaming protocol is required.

**Existing implementation under review.** The current continuation starts at
pushed planning checkpoint `788d45a44f1da19ea2a85f311ace19a8eec31202` plus
the retained P1-6b WIP. The prior Step 6 owner and read-only reviewers
`cli_audit` and `readonly_audit` identified result-channel and sidecar defects.
The WIP addresses text placement, structured failures and exact admitted IDs
in `Sources/RielaCLI/TaskDispatch.swift`, strict store/dispatcher reads and
corrupt profile diagnostics. Review the existing implementation and focused
`Tests/RielaCLITests/TaskRunResultTests.swift` and
`Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift`; do not re-dispatch coding
unless independent review proves a material defect. No implementation
acceptance is implied by this design update.

**Historical SQLite amendment (withdrawn).** The prior owner observed seeded
preview changing SHM bytes. The proposed amendment to
`Sources/RielaSQLite/SQLiteDatabase.swift` treats an existing zero-byte WAL as
idle for immutable reads, extending the existing absent-WAL case. Task preview
must reject a nonempty WAL before opening either relevant store, with an
actionable error and unchanged database/sidecar bytes. It must never report
readiness from an immutable read that silently omits committed WAL contents.
This is a bounded shared-helper change, not a schema or global SQLite rewrite.
Independent test-integrity, adversarial and Astra combined-tree integration
reviews must each explicitly accept or reject the amendment, including shared
reader compatibility and whether WAL-state checks uphold the contract under
concurrent writers. A material failure requires a bounded repair and affected
gate reruns; a successful idle fixture alone does not establish that boundary.

**Step 6 review outcome.** Independent reviews found that a live immutable
reader could miss a WAL commit after the size check. The zero-byte-WAL change
to `SQLiteDatabase.swift` was withdrawn and the shared helper restored to its
prior behavior. Dry-run now copies each candidate task database into a private
temporary store after rejecting a nonempty WAL. It compares the original main
database, WAL, and SHM inventory and bytes after copying and again before a
ready or waiting result. A concurrent change yields an error instead of a
stale preview. The private copy may use immutable reads; live task reads keep
their prior SQLite mode. A controlled writer test covers this boundary.

**Evidence and acceptance.** Exercise the command boundary and real retained
read paths for ready/wait/error outcomes in text and JSON. Compare complete
before/after file inventories and bytes, including database WAL/SHM sidecars,
host/controller configuration and profile files, plus affected row values
(not only counts), including `work_hosts`. Include existing, absent,
incompatible and corrupt stores; existing, absent and corrupt profiles; and
sidecars present and absent. Read fixtures through nonmutating inspection;
do not checkpoint or repair them to make comparisons pass. Where corruption
prevents row decoding, record the diagnostic and byte/inventory invariance
instead of claiming a row comparison. Controlled fixtures must not confuse
external concurrent writes with command side effects.

Step 4 refines the existing plan at
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` for this slice.
Keep its V1/V2/V4/V11 command filters and add explicit parsing coverage:
`swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskCommandParsingTests`.
Run strict changed-file SwiftLint for changed Swift files and `git diff --check`.
Record exact commands, terminal exit codes, positive counts per selected suite,
complete foreground logs and final-source hashes under repository-root `tmp/`.
Reused evidence must match final relevant source bytes. Baseline failures stay
failures and require an explicit independent bounded review decision; no
zero-test or incomplete-log success. Independent test-integrity, adversarial
and Astra combined-tree integration reviews must resolve every material
finding before accepting P1-6b. Publish
only the exact reviewed file allowlist by commit and non-force push on the
same branch; do not merge main, modify unrelated worktrees, or close parent P1.

**Final-source host evidence (current intake).** The earlier 194/194 host
pass in `tmp/work-runtime-p1-6b-host/evidence.json` is historical evidence
only: the repair changed six of its nine source/test hashes. The current
host manifest `tmp/work-runtime-p1-6b-host-final/evidence.json` records exit 0
and 198/198 passing, with the complete terminal log at
`tmp/work-runtime-p1-6b-host-final/aggregate.log`. Step 2 recomputed SHA-256
with Python `hashlib.sha256` for all nine paths and matched both that manifest
and `tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/plans/p1-dispatch/attempt-1/verification-evidence-final-source-v2.json`.
The latter records source-matched safe suites of 169/169 and 15/15 and strict
changed-file SwiftLint, each exit 0; their complete log paths and exact
commands are retained in its `verification` and `lint` entries. Step 2 checked
the suite terminal summaries and lint log availability. Its separate sandbox
aggregate remains failed: exit 1, 198 tests with 24 failures (listener denial
and dependent expectations). The host pass does not relabel that failed run.

The host command is:

```sh
CLANG_MODULE_CACHE_PATH=tmp/work-runtime-p1-6b-host-final/module-cache SWIFTPM_MODULECACHE_OVERRIDE=tmp/work-runtime-p1-6b-host-final/module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'TaskCommandParsingTests|TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskRunResultTests|TaskDryRunReadOnlyTests|WorkStoreTests|TaskCommandTests|SQLiteDatabaseTests'
```

Reuse passing evidence on identical relevant bytes; do not rerun the host
aggregate or redispatch coding without a material evidence gap or defect.
Any material repair requires independent review and affected verification on
its new final hashes. `impl-plans/progress/p1-dispatch.md` records that prior
test-integrity, adversarial and Astra source reviews accepted the private-copy
repair, with Astra withholding overall verification pending the host gate.
The preserved Step 6 runtime payload records the original test-integrity and
adversarial acceptances and Astra's source acceptance; verbatim reviewer
transcripts were not retained as separate artifacts. Fresh independent
test-integrity, read-only behavior, and Astra combined-tree reviews accepted
the nine-hash tree with no material finding, including canonical first-match
SQLite path selection, read-only behavior and shared-reader compatibility.
The host aggregate closes Astra's recorded verification condition. Publication
still requires the serial exact-file commit and non-force push gates.

Step 4 retains the same active plan and remaining tasks, updating its design
reference for this amendment rather than creating a replacement plan. After
independent acceptance, directly affected documentation and the exact reviewed
P1-6b file set may proceed through commit and non-force push on
`feat/remaining-impl-plans`. Preserve current WIP, checkpoint history, Monja
`tenant-sharding-d48` and unrelated worktrees. Step 9 must explicitly record
that P1-6c/d, P1-7a/b and parent P1 remain open; the dispatcher plan stays active.

**Reference mapping and open questions.** Supplied codex-agent references are
workflow/communication identities, not a Codex source parity requirement.
Cursor CLI behavior and reference-adapter divergence are not applicable.
No unresolved user decision is needed for this bounded design; implementation
verification and independent acceptance remain downstream work.

`task decide <task-id>` requires exactly one of `--accept`, `--reject <reason>`,
`--rerun [step]`, or `--cancel`, an explicit human principal, expected task
version, and stable decision ID (`--principal`, `--expected-version`, and
`--decision-id`). Local CLI ownership is the existing local
access boundary; a principal labels the audit actor, not remote authentication.
Any existing remote manager path retains its authentication. New GraphQL
mutation exposure remains P5. Plain `workflow run` stays task-free; no implicit
task creation or additional general task-management commands are required here.

Replace auto-improve only after dispatcher tests cover its actual inactivity,
bounded retry, failure recovery, cancellation, and replay behavior. Preserve
unrelated specialist/event supervisor behavior. `examples/task-repair-loop`
must cover acceptance, gate recovery, guard stop, and capacity wait;
`examples/task-agent-director` must cover allowed output, child accounting, and
invalid-output escalation. Mock `workflow run` alone is not evidence that task
dispatch works: `TaskRuntimeExampleTests` must drive the task lifecycle against
both fixtures and compare their `EXPECTED_RESULTS.md` outcomes.

The resumed issue maps to these existing contracts; every row remains
unverified implementation work until current behavioral evidence is accepted:

| Intake item | Design contract | Required behavioral evidence |
| --- | --- | --- |
| P1-0 canonical sandbox | §17, §17.1 | Real canonical Step 6/8 payloads retain workspace-write; surrounding node access and prompt boundaries remain intact; real-payload regression verifies canonical artifact structure without package rediscovery |
| P1-1 atomic reservation | §11, §17.2 | Independent-connection races, rollback at every insertion, dependency/version rechecks, duplicate IDs, digest-only single-use launch token, uncertain-launch fencing, pending-request consumption and cancellation acknowledgment |
| P1-2 guard | §7, §17.3 | Complete durable guard batch before decisions, persistence failure blocks policy, replay deduplication, simultaneous violations, exact equality boundaries and last-admitted-attempt completion |
| P1-3 director/applier | §6, §17.2–17.3 | Stable policy ordering, all action/principal paths share store validation, same-task/attempt causality, reconstructed completion, original replay outcome and atomic pending/cancellation transitions |
| P1-4 capabilities | §5a, §17.4 | Bounded deterministic probes, declaration merge including failed-auth enable, read-only corrupt-profile handling, policy/model constraints, freshness equality, explicit host/group/liveness/capacity and per-node placement |
| P1-5 host-aware authoring | §17.4 | Entry-reachable/called-node requirements, warning versus strict-host failure, no persisted refresh during validation, and planner snapshot passed through existing workflow inputs |
| P1-6a canonical dispatch | §17.2, §17.4 | Exact reserved session executes; terminal projection precedes evaluation; dependency/version races and waits create no attempt/session/lease; selected host/backend reaches runner |
| P1-6b read-only dry-run | §17.5 | Identical resolution and prospective placement; database bytes/rows, sidecars and host configuration unchanged; absent stores remain absent; corrupt profiles are not quarantined |
| P1-6c shared human decisions and interruption | §17.2, §17.5 | Exactly one action and explicit audit/version/identity fields; identical/conflicting replay; durable cancellation during authorization/running/acknowledgment; crash-safe pending rerun consumption |
| P1-6d bounded director and planner inputs | §17.3, §17.4 | Stable policy ordering; last-attempt completion; work TaskView retained across child execution; child session/cost/attempt charged once; invalid/forbidden/failed/budget-blocked output escalates; host snapshot reaches workflow inputs |
| P1-7a ordered removal | §17.5 | Passing replacement inactivity/retry/gate/failure/cancellation/replay tests recorded before legacy deletion; removed CLI/remote fields rejected; plain workflows remain task-free; specialist/event supervisor and loop/routine regressions preserved |
| P1-7b replacement examples | §17.5 | Real task lifecycle against both deterministic mock bundles and EXPECTED_RESULTS.md: acceptance, gate recovery, guard stop, capacity wait, director output/accounting/escalation |
| P1-8 serial finalization | §17.5–17.6 | Accepted predecessor change evidence survives join; affected and aggregate gates pass; Astra combined-tree review accepts; docs, progress/indexes and owning package digests match that tree; exact commit allowlist excludes unrelated work |

Retain every verification command, final exit status, positive executed test
count (null for non-test inspections), and complete log under
`tmp/work-runtime-p1/`; poll every yielded foreground process through exit.
No zero-selected-test, incomplete-log, timeout, or unpolled command passes.
Step 4 must retain the six plans' applicable build, focused-test, strict touched/new-file
SwiftLint, repository lint baseline and diff commands, with separate logs and
build scratch paths under `tmp/work-runtime-p1/<plan-id>/` and
`tmp/work-runtime-p1/build/<plan-id>/`. Add proportional broader suites for the
actual shared-path changes: RielaWork, CLI parsing/workflow run and remote
request handling, plus Core/adapter regressions if removal touches them.
Compare repository lint with the pre-edit baseline; do not clear unrelated
diagnostics. No Swift build/test/lint result is claimed by this documentation
turn. No web code is in scope, so browser E2E is not a design gate.

Self-check and the workflow's single adversarial implementation review must
leave no material finding unresolved. Native join/change evidence and serial
shared-file reconciliation remain required when implementation fans out.
Refresh all six P1 plans and indexes only from accepted evidence; retain P2–P7
as deferred. The six current plan metadata blocks already encode this DAG. Step 4 must
reconcile their historical status/review claims and any stale package or
checkpoint references against this intake; retain identities and dependency
edges rather than resetting dispatch to a standalone plan.
Do not mark checkboxes or archive plans merely because their design or plan
was accepted. Blocked, unchanged, or materially unverified implementation
returns actionable blockers and cannot enter repetitive integrity,
adversarial, or reconciliation gates. A retained implementation may be
certified only by new behavioral evidence and independent acceptance, not
by inventing a source change to pass a change-count gate.
Author review here certifies design scope only, not implementation completion.

This turn changes only design documentation and triggers no workflow, prompt,
script, or skill digest refresh. Later edits to those repository artifacts must
refresh their applicable owning manifest; this does not require rediscovering
the executing package or inspecting user/project registries.

**Reference mapping and questions.** `../../codex-agent` is absent (`test ! -e ../../codex-agent`, exit 0); intake supplies no alternative and is not reference-driven.
There is therefore no external Codex behavior parity claim or required external
comparison. Cursor CLI remains one backend behind the existing adapter boundary
in `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`; backend-specific probe,
auth, invocation, and heartbeat details must stay there or in its adapter helpers,
not enter the neutral task state machine. Selecting another allowed backend
does not translate prompts or promise Codex/Cursor equivalence. No unresolved
user decision is required for this P1 design; implementation correctness,
host-probe results, and independent review remain verification work.


### 17.6 Historical resumption evidence and dependency readiness (2026-09-22)

Current inspected HEAD is `8286b20f16548354d9023c1255c12dfd4ce4f70d` on
`feat/remaining-impl-plans`, matching the supplied checkpoint. Initial status
matches intake: no staged or untracked changes and eleven pre-existing modified
tracked files:

- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`
- `Sources/RielaWork/WorkStore+Reservation.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Tests/RielaCLITests/ImplementationWorkflowSandboxTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Tests/RielaWorkTests/WorkStoreReservationTests.swift`
- `Tests/RielaWorkTests/WorkStoreTests.swift`
- `impl-plans/progress/p1-reservation.md`
- `impl-plans/progress/p1-sandbox.md`

Preserve all eleven files byte-for-byte in Step 2. Only this design document is
updated. Source/test/progress diffs were captured before editing; their initial
SHA-256 inventory is `tmp/p1-design-step2/preexisting-sha256.json`.
Terra must fresh-read and attribute these hunks before implementation. Reservation
owns the retained durable replay/schema and cancellation primitives, including
`DecisionApplier.swift`, `WorkStore+Decisions.swift`, and
`DecisionApplierStoreTests.swift`, until its acceptance; lifecycle then takes
ownership of its decision changes. Shared files never have concurrent writers.
The retained dependency-wait result, one-use request checks, transaction-local
snapshot reads and immutable replay records are attempts to satisfy §17.2, not
new architectural scope or accepted behavior. Historical progress claims do not
certify the current tree; preserve their record and reconcile status only after
implementation evidence is accepted.

Complete foreground inspection logs with final exits are under
`tmp/p1-design-step2/`: `inspect-0.log` (status), `inspect-1.log` (HEAD),
`read-1.log` (source and sandbox diffs), `read-2.log` (progress diffs),
`remaining-diff.log` (remaining tests), `plans.log`, and `source.log`.
Each listed inspection exited 0. Step 1's missing-log limitation stays an intake
fact, not a failed product check. This design turn executes no behavioral tests.

The authoritative intake is `comm-000002`, with the prior intake reference
`comm-000001` and model roles supplied directly by runtime input. No current
Step 3/5 feedback was delivered. Step 4 must reconcile historical plan claims
against this intake and the next accepted design without changing any plan ID,
path, task ID or dependency edge. Existing current-workflow CLI validation
commands are not node-side readiness gates: remove those obsolete invocations
from the executable plan commands. P1-0 instead requires the real checked-in
payload regression; runner preflight owns executing-package readiness.
Deterministic task-example validation remains product verification and must use
explicit fixture paths, without rediscovering the current workflow.

| Current-source observation | Consequence for this package |
| --- | --- |
| `Sources/RielaCLI/TaskCommands.swift` switches only over show/list; `TaskCommandModels.swift` contains read-result models. Source inventory contains no `TaskDispatcher*.swift` or `AgentDirector*.swift`. | P1-6a–d require actual integration; do not infer it from reservation APIs or the checkpoint subjects. |
| Canonical Step 6/8 node payloads already declare workspace-write, and `Tests/RielaCLITests/ImplementationWorkflowSandboxTests.swift` exists. | `p1-sandbox` fresh-reads and behaviorally verifies the retained correction. Its real-payload regression checks the repository artifact; executing-package readiness belongs to runner preflight. |
| `Sources/RielaWork/WorkStore+Reservation.swift` has reservation, authorization, pending-request and cancellation APIs and `Tests/RielaWorkTests/WorkStoreReservationTests.swift` exists. | `p1-reservation` audits and repairs only gaps against §17.2, records finalized primitive signatures, and obtains current behavioral acceptance before lifecycle/capabilities consume them. Existing APIs and tests alone do not close P1-1. |
| Retained reservation/schema changes add a transaction-scoped enqueue seam, unconsumed-request uniqueness, cancelled-snapshot acknowledgment, durable original decision-application records, and schema generation 8; retained tests exercise successive requests and cancellation provenance. | Preserve and behaviorally reverify these repairs. Generation policy remains the existing no-compatibility contract; use task-owned scratch stores only, never open or reset other sessions' runtime databases to validate it. Source presence does not certify rollback, replay, or cancellation behavior. |
| `Sources/RielaWork/WorkStore+Decisions.swift` accepts caller completion, copies causal IDs without validating their ledger scope, now returns persisted original application records on replay, and specially defers only cancel for a live attempt. A transaction-scoped enqueue seam now exists in `WorkStore+Reservation.swift`, but the applier does not call it. | Shared-applier integration must enforce §17.2 at the durable boundary; the retained original-outcome replay must be verified, rerun recording must be atomic with decision application, and all live terminal/replacement actions must await cancellation acknowledgment. These are material current-source gaps, not passing behavior. |
| `Sources/RielaWork/DeterministicDirector.swift` selects the first violation/gate in input order and gate recovery lacks an attempt-budget check. `TaskGuardCoordinator.swift` passes a caller completion verdict to the store. | `p1-lifecycle` owns stable ordering, remaining-budget and store-authoritative completion/causality/replay repairs, using accepted reservation primitives. Never compensate with a CLI-only validation path. |
| No work host-capability/placement implementation was identified by the source inventory and `HostCapability`, `BackendCapability`, `backendPolicy` search (existing generic runner capability diagnostics are unrelated). | `p1-capabilities` implements the §17.4 snapshot/resolver/placement contract after reservation acceptance. Its accepted interface gates dispatch; no dispatcher-local capability registry. |
| Required `TaskCommandMutationTests`, `TaskDispatcherTests`, `TaskDispatcherIntegrationTests`, `TaskRuntimeExampleTests`, `examples/task-repair-loop/`, `examples/task-agent-director/` and `impl-plans/progress/p1-dispatch.md` are absent from the inventory. | These are deliverables to author and execute, not existing passing suites, examples or progress evidence. |
| Legacy `WorkflowRunCommand+AutoImprove.swift`, CLI policy/options, remote forwarding, tests and all three old example directories remain. `WorkflowAutoImprovePolicy` and `WorkflowMutationMode` actually live in `Sources/RielaCLI/RielaCommand.swift`. | Keep the removal barrier. Step 4 must use actual references, including `Sources/RielaCLI/ParsedWorkflowOptions.swift` and `Sources/RielaCLI/WorkflowCommands.swift`, when assigning narrowly required serialized removal paths; a broad supervisor-name deletion is forbidden. |

The six plan identities and paths remain unchanged. Step 4 authors their
reconciliation as one DAG, without planning fanout; it does not manufacture
predecessor implementation evidence. The implementation/gate nodes record
that evidence when it exists, before admitting a dependent wave:

| Wave | Plan ID and exact path | Required accepted predecessors | Scope / ownership |
| --- | --- | --- | --- |
| 1 | `p1-sandbox`: `impl-plans/active/work-runtime-p1-sandbox.md` | none | P1-0 canonical Step 6/8 payloads and their regression only |
| 1 | `p1-reservation`: `impl-plans/active/work-runtime-p1-reservation.md` | none | P1-1 Work models/store/schema, shared SQLite reservation connection and launch/cancellation/request primitives; initial Package.swift ownership |
| 2 | `p1-lifecycle`: `impl-plans/active/work-runtime-p1-guard-director.md` | `p1-reservation` | P1-2/3 guard/director/completion and WorkStore+Decisions; consumes accepted durable primitives |
| 2 | `p1-capabilities`: `impl-plans/active/work-runtime-p1-capabilities.md` | `p1-reservation` | P1-4/5 neutral Core capability values, adapter probes, Work host storage/placement, CLI/server/profile registration and host-aware validation; owns schema in this wave |
| 3 | `p1-dispatch`: `impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` | `p1-sandbox`, `p1-reservation`, `p1-lifecycle`, `p1-capabilities` | P1-6/7 CLI/runner integration, bounded director, replacement examples, then legacy removal |
| 4 | `p1-finalize`: `impl-plans/active/work-runtime-p1-finalization.md` | `p1-sandbox`, `p1-reservation`, `p1-lifecycle`, `p1-capabilities`, `p1-dispatch` | P1-8 serial join/repair, aggregate verification, documentation/digest/index reconciliation |

Admission requires each predecessor's accepted source revision or content
hashes, exact interface owner/signatures, behavioral commands with complete
logs/final exits/positive counts, and an integration review decision with no
unresolved high/mid finding. Sol gates readiness; these are not additional
adversarial passes. Astra reviews the final combined tree independently.
Initially no plan has that acceptance, so only the two root plans are eligible
for implementation after design/plan acceptance. Lifecycle and capabilities
can proceed independently after reservation passes; dispatcher waits for all
four predecessors. Finalization waits for all five implementation plans.

One owner writes each overlapping file at a time. Lifecycle must not edit the
schema, WorkModels, WorkStore.swift, or Package.swift while capabilities owns
its wave. Dispatcher fresh-reads accepted interfaces before touching shared
coordinator/applier/CLI files. Missing shared contracts return to the designated
owner for serial repair; do not silently expand concurrent write sets.
Native intent/change evidence and pre/post hashes drive the join. Independent
verification uses distinct build paths, or serializes access to a shared cache.
No worker edits another worker's append-only progress log.

The final aggregate command source remains
`impl-plans/active/work-runtime-p1-finalization.md`, including the explicit
dry-run database-equivalence case and help/doctor/SurfaceCatalog checks, not
only the intake's abbreviated aggregate list. Required core commands include:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-finalize
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter RielaWorkTests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkStoreReservationTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|ImplementationWorkflowSandboxTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/examples/task-agent-director --output json
git diff --check
git diff --name-only
```

Run strict SwiftLint on the union of surviving touched/new Swift files and
compare full repository lint against the pre-edit baseline; retain each exact
command and diagnostic log. Each named required suite must execute positive
test counts, even if a combined filter exits 0. Record self-review, Sol's one
material adversarial review and Astra's combined-tree review against the
actual joined content. Finalization prepares closure evidence; later workflow
gates grant independent acceptance. Repairs invalidate affected earlier evidence
and require the corresponding checks/review before final acceptance.

After acceptance, the serial documentation owner reconciles the six checklists,
`impl-plans/README.md`, `impl-plans/PROGRESS.json`, and affected
`impl-plans/progress/` indexes from that same tree. Audit all owning
`riela-package.json` files for workflow/prompt/script/skill edits; refresh using
the owning package's established tool or retain an explicit no-owner audit.
The installed package stays immutable. Preserve non-P1 entries and other
sessions' evidence. Plan paths/IDs in this DAG remain canonical throughout
execution; any later archive must retain their identity and source-path mapping.

Only accepted P1 implementation and narrowly required documentation/index
changes may enter the final commit allowlist and push. Intake identifies the
unambiguous `origin` remote but supplies no upstream or live remote-branch
readiness evidence. Final publication must freshly inspect origin, explicitly
target `origin` / `feat/remaining-impl-plans`, establish any missing upstream
through the authorized finalization path, and verify the accepted hash remotely.
Do not force-push. If the installed finalizer cannot
handle a first push without an upstream, report that concrete blocker rather
than altering this immutable workflow, fabricating tracking refs, or claiming
publication. Base-branch integration is not requested.

Missing/failing predecessor evidence blocks only affected descendants;
eligible independent work may continue. An unchanged or materially unverified
implementation returns its missing contract, responsible owner, required
command/access repair and failed exit/log once; it does not cycle through
integrity/adversarial/reconciliation gates. No fallback or checkbox update
substitutes for readiness. No unresolved user product decision remains; source
gaps, downstream access and publication readiness are verification/implementation
work, so no new user-QA document is necessary.


### 17.7 Resumption contracts (2026-09-23)

**Current execution: P1-6a SHD-5 finalization only, 2026-09-24.** Mode:
`issue-resolution`. Issue: `local-request: Work Runtime P1-6a SHD-5; no GitHub
issue supplied`. Step 1 intake `comm-000002` in
`codex-design-and-implement-review-loop-session-1` supplies checkpoint
`22643151891ad47e999343d05da1a20044176193` plus the preserved uncommitted
source/test/plan changes. The sole effective implementation plan is
`impl-plans/active/work-runtime-p1-selected-host-delivery.md`.

Retain the applicable §17.2, §17.4 and §17.7 contracts: selected root/callee
host/backend/model delivery, exact reserved root and ordinary child admission,
terminal projection before evaluation, waits/races without allocation, and no
fallback, duplicate launch or premature fence release after worker loss. The
plan's T1–T8 matrix remains the behavioral acceptance contract. This continuation
reviews existing implementation and evidence; it adds no runtime component or
new product behavior. Reopen design or repair code only for a concrete material
correctness, data-loss, security or verification defect in this slice.

**Evidence and bounded exception.** The authoritative host evidence is
`tmp/p1-6a-finalization/host-verify/evidence.json` and its adjacent complete
logs. Recomputed SHA-256 values for `Sources/RielaCLI/HostCapabilityResolver.swift`,
`Sources/RielaCLI/TaskDispatch.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` and
`Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift`,
and the tracked code diff hash, match that manifest in this Step 2 execution.
Recorded host results are V0 exit 0; V1 41/41, V2 23/23, V3 80/80, V4 55/55,
V11 53/53; V5 adapters/server/GraphQL/app 440 XCTest cases (two skipped) and
19 Swift Testing cases with no failures; V6/V7 exit 0 (30 repository warnings
in unchanged files). V1/V11 include authenticated T4/T6 worker cases. These
are carried-forward host results, not tests rerun by this documentation step.

V5 CLI/Core remains **failing**, exit 1: 1,965 tests, 24 assertions in 22 cases.
Independent adversarial and combined-tree integration reviews must compare
21 cases/23 assertions with
`tmp/p1-6a-host-verify/preimplementation-baseline/all-current-failures.log`
and the additional
`WorkflowCommandTests.testCallStepCompletesChangeTrackedFanoutBeforeStopping`
case with `tmp/p1-6a-finalization/host-verify/baseline-cbe1dd1-call-step.log`
(exit 1, identical missing `agentSandbox` validation error at checkpoint
`cbe1dd1`). Case names/counts alone do not waive review of failure signatures
and relevance to this slice. Both reviews must explicitly accept or reject
this bounded 22-case/24-assertion baseline exception and resolve every high/mid
P1-6a finding. The exception is pending; it cannot turn V5 green or close parent
P1. Preserve complete terminal logs and exit statuses. Do not repeat completed
host gates unless source bytes change or evidence is materially insufficient;
a repair requires affected gates and source identity to be refreshed.

**Acceptance and rollout boundary.** Only after independent acceptance may the
slice plan/progress be updated and the exact reviewed file allowlist committed
and pushed without force to `origin` / `feat/remaining-impl-plans`. Include this
design revision in downstream review and reconcile the final allowlist with
the existing WIP; preserve checkpoint history, Monja, unrelated plans and other
worktrees. No acceptance checkbox, commit or push is authorized by Step 2
completion alone. The parent plan
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` remains a
reference, not another work package. Parent P1 and later slices stay open.

**Questions and reference mapping.** The remaining decisions are independent
adversarial/integration acceptance and the bounded V5 exception, not unresolved
user product choices; no user-QA file is needed. Intake supplies no codex-agent
reference-code input (`codexAgentReferences: []`); no reference checkout or new
Cursor behavior is required. Existing adapter isolation remains unchanged.
Historical review identifiers, reference checks, source inventories, package
versions, model assignments and scheduling statements below belong to earlier
executions and do not establish current evidence or expand this intake.

**Earlier parent-run context: checkpoint f46ff788.** The rest of this section
records that earlier run's input, inventories and verification scope; it does
not authorize their execution in the current P1-6a slice. Its applicable
behavior contracts remain binding without importing later-slice work.

**Authority and review.** Mode: `issue-resolution`. Issue reference: Work
Runtime P1-6a–P1-6d and P1-7a–P1-7b; no GitHub issue URL or number supplied.
Step 1 `comm-000002`, execution `step1-issue-intake-attempt-1-exec-2`, supplies
“Finish retained Work Runtime P1 dispatcher, director, and legacy replacement
requirements” to `step2-design-doc-update`. Codex-agent references are
`codex-design-and-implement-review-loop-session-1`,
`nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`,
`dispatch_audit`, `director_audit`, and `legacy_audit`.
The accepted plan records prior Step 3 design acceptance through `comm-000004`
and `step3-design-review-attempt-1-exec-4`, with no findings. No new Step 3/5
corrective feedback was supplied. The second run ended at
`implementation-blocked-output`; its findings are evidence, not implementation
acceptance or an exhaustive source audit. Accepted design and plan remain in
force. This refresh corrects execution metadata and stale source observations
only; behavioral contracts and implementation-plan scope are unchanged.

This section supersedes historical execution inventories, scheduler waves and
publication context in §17.1/17.6. Behavioral contracts §17.2–17.5 remain in
force. That earlier run's complete effective plan input was exactly
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md`; supporting
reservation, lifecycle, capability and finalization plans are references, not
additional work packages. Reconcile prerequisite repairs inside this one plan.
Runtime-resolved immutable user-scope workflow provenance and the effective
input are authoritative; no contradiction is present and no provenance
rediscovery is required. That earlier intake supplied no minimum or exact
package version; the current runtime-supplied input governs this execution.

Inspected HEAD is `f46ff788d522b6e53631862253fdcbcf17adfb1a`.
Implementation and base branch are both `feat/remaining-impl-plans`, with
`origin/feat/remaining-impl-plans` supplied as upstream. Preserve all 93
pre-existing changed/untracked files (49 tracked, 44 untracked; zero staged)
as owned WIP. The active plan retains its earlier 50/44 inventory as historical
evidence; checkpoint f46ff788 committed the design and plan updates. Reconcile
individual P1 files and hunks before finalization rather than inferring ownership
from counts. This design refresh adds one tracked documentation modification.
Only accepted P1 files and hunks may enter finalization; no merge to main is
requested. Exclude loop-engineering, agent-node-output-contract, workflow defect
detection, Tauri, Note, gateway SDK, Monja and P2–P7 implementation. Use existing
runner, store, adapter and distributed execution seams; no new planner, task
service, authentication system or generic framework is required.

**Current source evidence, not acceptance.** Inspection of retained source and
`impl-plans/progress/p1-dispatch.md` (implementation attempt 3)
confirms useful implementation but material remaining gaps:

| Finding | Source evidence | Required completion contract |
| --- | --- | --- |
| Bounded director remains unwired | `Sources/RielaCLI/TaskDispatch.swift` rejects `.director`; `Sources/RielaWork/AgentDirector.swift` escalates every `accept`. | Execute one bounded ordinary child and apply decisions against persisted judged-work linkage as below. |
| Cancellation primitives lack proven live integration | `Sources/RielaWork/WorkStore+Reservation.swift` requires a matching cancelled snapshot; `TaskDispatch.swift` uses generic terminal reconciliation without calling cancellation acknowledgment. | Connect durable requests to running execution and acknowledge the exact reserved session before releasing its fence. Store-only tests do not establish this path. |
| Reachable callees and selected hosts are not delivered by task dispatch | `TaskDispatch.swift` now resolves reachable workflow/add-on maps, but still asks for local capabilities and supplies no workers; `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift` rejects nonlocal or other-workflow placement. | Resolve reachable callees and execute the selected per-node host/backend through the existing distributed path; no silent local fallback. |
| Replacement examples cover only part of the required behavior | `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` covers acceptance, guard stop and capacity wait, but its director test runs a single ordinary task attempt and inspects recommendation output. | Add real recovery and bounded child application/accounting/escalation evidence before legacy removal. Recommendation JSON alone does not prove director behavior. |
| Guard coverage still needs end-to-end certification | `TaskDispatch.swift` now sums exact durable attempt-session durations and supplies gate visits; `TaskDispatcherIntegrationTests.swift` includes cumulative wall-clock coverage. Repeated-finding and inactivity dispatch inputs remain open. | Reinspect guard data flow and prove cumulative budgets, repeated findings, inactivity, ordering and last-admitted-attempt completion under §17.3; do not assume the four reported gaps are exhaustive. |

**Director execution and judged-work acceptance (P1-6d).** Reconcile work and
persist its evidence before reserving one `.director` attempt. The reservation
transaction records task identity, judged attempt, child attempt and child
session in the existing durable store. Preserve the judged work TaskView across
child execution. Admission consumes remaining attempt budget; completion/replay
charges child cost and usage once. A last-admitted work attempt may finish even
when no child can be admitted. The child does not recursively invoke a director.

The shared applier verifies persisted linkage, producer child session, terminal
child state, task identity and current version. Only the linked child may
intervene after judged work; newer work or missing/foreign/stale linkage rejects
the decision. Reconstruct completion from judged work's durable required gates,
verification, acceptance payload and applicable blocking findings. Child success
is never work-completion evidence. Preserve latest-attempt checks elsewhere;
agent output cannot waive `requiresHumanAccept`. Validate allowed P1 action
kinds and typed fields before application. Invalid/forbidden output, child
failure, exhausted admission budget or unavailable linkage records escalation
and requires a human. Replay returns the original application without another
child, duplicated accounting or changed judged-work evidence. Reopened-store,
rollback, valid accept, child-only success, stale/foreign linkage, human-required
acceptance and exact child session/usage tests are mandatory.

**Live cancellation (P1-6c).** Human cancel/reject, guard stop/replacement and
process interruption use the shared durable decision/request path. Persist the
request before signalling the running local or selected-host execution. Keep
the one-live-attempt fence until the exact reserved runtime session durably
records the matching cancelled terminal outcome and the store acknowledges it.
Generic terminal reconciliation must not bypass a pending cancellation.
Pre-launch cancellation prevents authorization; uncertainty after authorization,
lost acknowledgment or interrupted persistence retains the fence for explicit
reconciliation. Do not infer termination from timeout, expired lease or missing
heartbeat. A replacement request is consumed once only after acknowledgment.
Test real runner interruption before authorization, during running execution,
during terminal persistence and on reopen/replay; assert durable cancellation,
no stale launch, no premature replacement and no duplicate decision/accounting.

**Called workflows and selected-host execution (P1-6a and prerequisites).**
The task composition boundary supplies the requirement resolver with reachable
called bundles and add-on/environment requirements using existing callee
resolution. Traverse from the actual selected entry, including returns and
joins; retain workflow/step/node identity, skip reused prefixes, visit cycles
once and fail unresolved executable targets before reservation. Unreachable
nodes impose no requirement. Do not rediscover the executing implementation
workflow package to establish these product behavior tests.

Use one fresh merged capability evaluation for the existing local/registered
worker topology, retaining explicit assignment/group rules and deterministic
ordering from §17.4. Persist selected per-node host/backend/model and snapshot
provenance with admission; pass the intended snapshot to existing planner inputs.
Carry each root/callee choice into existing distributed execution with the exact
reserved task session and existing authentication. Preserve choices across
handoff; a remote choice cannot execute locally or discard a callee's backend.
Unavailable capacity waits without reservation; unresolved targets are errors.
If a selected worker becomes unavailable after admission, retain execution
certainty/fencing rules rather than silently launch a second copy elsewhere.
Tests must observe the selected worker executing and reporting evidence into the
reserved session, plus explicit assignment, callee-only capability, unavailable
host and cancellation acknowledgment cases. Placement DTO assertions alone do
not establish execution.

**Replacement and final acceptance (P1-7b before P1-7a).** Preserve
`examples/task-repair-loop/` and `examples/task-agent-director/`; complete real
task-backed recovery, guard stop, capacity wait, accepted director output,
accounting and invalid-output escalation against their `EXPECTED_RESULTS.md`.
First record passing replacement inactivity/retry/failure/cancellation/replay
coverage; only then remove the legacy auto-improve path, flags, remote fields
and three obsolete example directories. Repeat affected tests after removal.
Reject removed input fields explicitly; preserve plain task-free workflow runs
and unrelated specialist/event supervisors, loops and routines. No publication
occurs between replacement and removal.

The `agentSandbox: .readOnly` field is present in the previously failing
callee fixture in `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`.
Attempt-3 progress records a corrected passing rerun; final-source verification
must establish it again. Historical mutable-registry test failures and the
truncated XCTest aggregate require test-execution investigation, not a new
workflow-provenance requirement.

Use the supplied plan's V0–V9 commands and this intake's core gates:

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
git diff --check
git diff --cached --check
```

Required prerequisite suites, strict touched-Swift lint, repository lint baseline
comparison and task-example runs remain in the plan. Classify remaining legacy
search matches against the preserved behavior rather than requiring an empty
search indiscriminately. Retain complete logs, exact commands, final exit
statuses, source hashes and positive counts for every required suite under this
worktree's `tmp/`. Run foreground commands and poll yielded handles to exit.
Prior broad failures require investigation; a zero exit with an incomplete
XCTest aggregate is not passing evidence. These are downstream test execution
concerns, not workflow provenance concerns. No implementation test is claimed
as rerun by this documentation step.

Final-source focused/broad tests, test-integrity review, material adversarial
review and necessary repairs precede checkbox closure. Tie every completion
mark to behavioral evidence. Reconcile P1 documentation and plan/progress
indexes from the accepted tree while preserving unrelated entries. Attribute
retained changes and prepare an exact P1 file/hunk allowlist before authorized
commit/push to `origin` / `feat/remaining-impl-plans`; verify published hash.
Push any checkpoint commit before final git-push so exactly one unpublished
final commit remains. Require test-integrity review and one adversarial
implementation review of the final source, with necessary repair verification.
Historical progress referring to another finalization plan does not expand this
single-plan input or waive any acceptance gate.

**Reference mapping, questions and author evidence.** Step 1 names
`../../codex-agent`; this step establishes it as absent: `test ! -e ../../codex-agent`
also exited 0 in this step. No external code-parity claim is made. The
codex-agent identifiers above map to workflow review provenance, not inspected
reference code. Cursor invocation/authentication/probing and heartbeat behavior
remain isolated in `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` and
adapter helpers, including `Sources/RielaAdapters/BackendCapabilityProbe.swift`.
Work/Core consume neutral capability and decision contracts; no cross-backend
prompt or model equivalence is promised. No new Cursor behavior or intentional
reference divergence is proposed.

No unresolved product decision requires a user-QA file. Remaining questions are
implementation investigations: cumulative guard coverage, actual distributed
handoff and live cancellation behavior, and completion of final-source test
execution. They do not permit broader design or accepting retained code.
Step 2 inspection, preservation and author-check evidence is recorded in
`tmp/work-runtime-p1/step2-f46ff788/verification-evidence.json`.
Only this design document changes; no workflow/prompt/script/skill digest
refresh is triggered. Author review checks intake/reference mapping, necessary
scope, explicit data/validation boundaries, recorded questions and WIP
preservation. No unresolved high/mid design finding remains; implementation
findings and downstream review/test gates above remain open.

### 17.8 P1-6d bounded director execution (2026-09-24)

**Current authority and scope (continuation 2026-09-25).** Mode `issue-resolution`;
issue “Complete Work Runtime P1-6d after Step 6 finalization-boundary repair”, sourced
from effective `workflowInput.issueTitle`/`issueBody` (`comm-000001`), delivered
by Step 1 `comm-000002`, execution `step1-issue-intake-attempt-1-exec-2`, in
`codex-design-and-implement-review-loop-session-1`. No GitHub number/URL or
codex-agent reference input was supplied. Workflow execution identifiers are
not external reference-code evidence; no Cursor behavior change or reference
divergence is requested. Existing backend adapters retain their boundaries.

This subsection scopes the present run to P1-6d and supersedes older current-run
inventories in §17.7, without replacing its behavioral contracts. The complete
plan input is `impl-plans/active/work-runtime-p1-dispatcher-guard-director.md`,
especially its first-section D0–D5 matrix. The accepted plan checkpoint and
current HEAD are `79eea8114b7d407e3fb7ed18faf5de5d86bce1ab` on
`feat/remaining-impl-plans`. The earlier clean
`d3f78df230d1d5c289102c54660ecaec2da90e7c` baseline is historical, not this
execution's starting state. Preserve all current tracked and untracked P1-6d
changes, accepted P1-6a/b/c and other sessions' work. Reuse the accepted design
and plan; repair only demonstrated material deficiencies. P1-7b then P1-7a,
parent P1, and unrelated broad failures remain open. One serial owner edits
coupled model/store/CLI code; independent investigation and review are read-only.
No second task store, replacement planner, recursive repair, legacy removal,
reset, broad staging, force push or main merge belongs to this slice.

**Historical starting seams.** Before the retained implementation,
`Sources/RielaWork/AgentDirector.swift` validated
bounded typed output but deliberately refused accept. `WorkStore+Decisions.swift`
already reconstructed durable completion and enforced latest-attempt, causality,
version and replay checks. `Sources/RielaCLI/TaskDispatch.swift` rejected director
entry. `Tests/RielaWorkTests/AgentDirectorTests.swift` asserted that temporary
refusal; `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` observed recommendation
output without proving child execution. Extend these seams; their existence or
old passing tests do not establish P1-6d acceptance. These descriptions are the
original design baseline, not claims that the current implementation still
refuses linked acceptance or director execution. Current retained work and
evidence are recorded in the plan's continuation-3 entry and
`impl-plans/progress/p1-dispatch.md`.

**Execution and durable identity.** Preserve §17.3 deterministic ordering.
Only configured escalation invokes one optional director round. First reconcile
the judged non-director work attempt and persist its outcome and evidence.
Successful last-admitted work may complete without needing another reservation.
When escalation needs a child, use ordinary admission, placement and runner
execution against the same task and store. Atomically reserve the `.director`
attempt and persist task ID, judged attempt ID, child attempt ID and exact child
session ID. Linkage must identify the one round for that judged attempt across
reopen/retry; an in-memory TaskView or caller-provided identity is insufficient.
Reservation failure leaves neither partial linkage nor a charged child attempt.

Retain the judged TaskView as child input, including durable completion, guard
findings, evidence and remaining budget. Child results and usage belong to the
child attempt/session; they never replace judged-work outcome or evidence.
Reconcile child usage/cost exactly once with existing shared-store accounting.
An interrupted/repeated dispatch uses the durable round and ordinary reservation
reconciliation, not a fresh child or an inferred successful termination. Preserve
the existing live-attempt fence and accepted cancellation rules.

**Application boundary.** A child recommendation is untrusted input. Validate
configured allowed kinds, P1 typed fields and causal evidence before routing it
through the shared applier. For a new application, atomically check the current
task version, stored same-task linkage, producer's exact child session, reconciled
successful child and reconciled judged work. Permit the linked child as the sole
intervening attempt; newer work, an unrelated intervening attempt or missing,
foreign or stale linkage rejects the recommendation. Keep ordinary latest-attempt
enforcement for every unrelated decision path.

An allowed accept reconstructs completion from the judged work's durable required
gates, verification ledger, acceptance payload and applicable blocking findings.
Neither child success nor a caller-supplied satisfied verdict proves work success.
`requiresHumanAccept` remains binding. Rerun/recover must retain existing target,
causality, pending-reservation and remaining-budget validation. Remove unconditional
accept refusal only together with these shared-store protections.

Invalid/forbidden output, failed child, denied admission or unusable linkage
persists escalation evidence and requires human action; child completion must not
trigger another director. A stale decision must not overwrite newer task state:
record its rejection through the current-version shared path, preserving that
newer work. Failed persistence is an error, never a claimed durable escalation.
Identical replay returns the recorded application before evaluating a new action;
conflicting reuse of a decision identity rejects. Replay cannot launch another
child, duplicate attempts/cost/evidence or rewrite judged work.

**Planner input and delivery.** Reuse
`Sources/RielaCore/WorkflowRequirements.swift`'s
`WorkflowPlanningCapabilityContext.workflowVariables()` and existing
`hostCapabilityContext` key. Forward the finite selected host snapshot and
reachable requirements from the accepted capability evaluation into existing
planner workflow inputs. Keep admission's selected backend/host authoritative
through ordinary execution; prove actual delivery, not only DTO serialization.
No new discovery architecture is needed. Preserve dry-run invariance and P1-6a/c
placement/cancellation behavior.

**Acceptance and evidence.** Real shared-store and ordinary-runner tests must
cover allowed accept; child-only success, missing gates, blocking findings,
newer work, missing/foreign linkage, human-required acceptance and stale-version
rejection; failed/invalid/forbidden/budget-blocked escalation; last-admitted
work and nonrecursion. Fresh/reopened-store, rollback and replay cases assert
exact task/attempt/session identities and once-only attempt/cost accounting,
with unchanged judged-work evidence. Use the intake's Work store/director suites
and CLI integration/example suites, plus affected plan V1–V4/V11 checks.

Before Swift edits capture source manifest and lint baseline. Required downstream
commands include `swift build`,
`swift test --filter 'AgentDirectorTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|WorkStoreReservationTests|WorkStoreTests'`,
`swift test --filter 'TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'`,
`swift test --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'`,
strict touched-file SwiftLint using the plan's NUL manifest command,
`git diff --check`, `git diff --cached --check`, and serial `swift test`.
Record exact commands, complete logs, source/log hashes, positive test counts and
terminal statuses under repository `tmp/`; poll all foreground sessions to exit.
Listener denial is an environment failure, not product acceptance. P1-6c's
selected-host 1/1, store 56/56, focused 104/104, compatibility 28/28, build and lint
receipts predate this slice. Its 2,059-test aggregate with 19 non-slice assertions
remains failed; retain the earlier intermittent live-progress timing limitation.
Neither classification nor focused success makes the broad gate green.

For this continuation, intake and retained evidence under
`tmp/work-runtime-p1/p1-dispatch/p1-6d/attempt-3/` report build exit 0,
seven focused selections passing 55, 81, 43, 30, 80, 55 and 55 tests, and
strict 18-file SwiftLint exit 0. `source-final9.sha256` identifies the Swift
source; `final7-focused-exits.txt` records filters and exits. The complete
`broad-final4.log` ran 2,666 tests and exited 1 with 19 assertions;
`broad4-classification.json` reports exact historical non-slice identity equality.
The broad gate remains **FAILED**. Independent reviewers must verify this
classification before explicit slice-only acceptance; any new or unclassified
failure blocks acceptance. Reuse unchanged-source evidence where valid, rerun
checks invalidated by material edits, and avoid another broad run on unchanged
source. Read-only advice from `final_integrity3`, `final_adversarial3` and
`astra_combined3` reported no remaining material high/mid P1-6d defect; it does
not replace the formal workflow reviews.

Step 6 assesses the retained D0–D4 implementation and behavioral verification.
Formal review, review-dependent D5 documentation, commit and push are downstream
gates, not reasons by themselves to label Step 6 implementation incomplete.
D5 remains required after formal acceptance; completion cannot be claimed until
documentation and exact-file commit/non-force push finish. The current intake
requires no new product behavior or expansion of the accepted D0–D5 matrix.

Independent test-integrity, single adversarial and Astra combined-tree review
must find no material P1-6d defect before completion documentation and exact-file
commit/non-force push. Refresh the plan, `impl-plans/progress/p1-dispatch.md`,
`impl-plans/README.md` and `impl-plans/REMAINING-WORK-HANDOVER.md` only to reflect
actual accepted evidence and remaining dependencies. No implementation or review
acceptance is claimed by this design update.

**Questions and self-check.** No unresolved user decision or Step 3/5 feedback
was supplied; no user-QA document is needed. The minimal persisted linkage shape
and its transaction integration are implementation-plan details constrained above,
not permission to add a new subsystem. Author inspection confirms the one-plan
scope, reference mapping, data flow, validation and rollout requirements cover
the intake. No high/mid design finding remains; implementation verification and
independent review remain downstream gates.

### 17.9 P1-7b task-backed replacement examples (2026-09-25)

**Current authority — bounded catalog ownership amendment (intake
comm-000002).** Mode `issue-resolution`; issue “Finish P1-7b after integration
review found missing example-catalog coverage”. Effective `workflowInput`
requires preserving checkpoint `bffa1da4ab161892ecec54784439e6148860f302` on
`feat/remaining-impl-plans` and all eight dirty files: `Sources/RielaCLI/WorkflowRunCommand.swift`,
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift`,
`examples/task-agent-director/EXPECTED_RESULTS.md`,
`examples/task-agent-director/README.md`,
`examples/task-repair-loop/EXPECTED_RESULTS.md`,
`examples/task-repair-loop/README.md`, `examples/task-repair-loop/workflow.json`,
and `impl-plans/progress/p1-dispatch.md`. Preserve unrelated work as well.
Step 2 changes only this design; Step 4 must align the current executable plan
and dispatch ownership before another implementation dispatch. No GitHub issue
number/URL or codex-agent reference was supplied.

**Material integration feedback and bounded remedy.** Prior execution receipts
`comm-000018` and `comm-000027` from `integration-review` in
`tmp/work-runtime-p1-7b-repair/sessions/runtime-records/runtime-message-log.sqlite`
record `needs_revision` and `rejected_unchanged_retry`, respectively. The latter
reports `blocked_on_unchanged_plan_ownership`. Finding
`p1-7b-example-parity-misclassified` is mid severity: the shared expected catalog
omits both replacement bundles, and the failed catalog assertion belongs to
P1-7b. Prior Sol test-integrity/adversarial acceptance does not supersede Astra's
rejection. This design addresses the repair boundary; the implementation finding
remains open until fresh verification and formal acceptance.

Add exactly two new test write paths to the sole serial `p1-dispatch` owner:
`Tests/RielaCLITests/RielaExampleCatalog.swift` and
`Tests/RielaCLITests/RielaExampleParityTests.swift`. Add `task-agent-director`
and `task-repair-loop` to the shared catalog so existing catalog validation and
deterministic mock selection exercise both bundles. Update only affected expected
mock counts from observed selection/results; retain all catalog, validation,
execution and output assertions and existing exclusions. Do not remove legacy
entries, seed success, skip new bundles or weaken assertions to fit a count.
No additional production source, public API, schema, dispatcher/director policy
or P1-7a work is authorized.

The downstream amendment must update
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` and the exact
write-path ownership in
`impl-plans/active/work-runtime-p1-7b-catalog-20260925-bffa1da-comm000006-dispatch.json`
as its linked runtime-generated successor. Review, exact-file
checkpoint and non-force push the design/plan/manifest amendment before dispatch;
a failed checkpoint push stops dispatch. Preserve dirty implementation/progress
bytes outside that checkpoint. Keep coupled edits and verification serial under
one implementation owner; independent investigation may be read-only. Repeating
unchanged implementation or reconciliation evidence cannot clear the finding.

**Retained task-gate correction (prior accepted amendment).**
**Demonstrated defect and one-file boundary.** The proposal at
`tmp/work-runtime-p1-7b-20260925-comm000008-59f45c1a/plans/p1-dispatch/attempt-2/bounded-amendment-request.json`
and failed V1 log at that directory's `logs/before-removal-final.log` show a
reserved task's rejected required gate reaching a completed canonical session.
`WorkflowRunCommand.finalizeRun` projects gate evidence, then unconditionally
applies required-gate failure, rewriting the completed session as failed.
`SQLiteWorkflowRuntimePersistenceStore.validateTaskTerminalWrite` correctly
rejects this terminal change with `terminalSnapshotConflict`.

The only additional production write path authorized by the accepted
amendment is `Sources/RielaCLI/WorkflowRunCommand.swift`. Carry actual
`taskReservation != nil` into `RunFinalizeContext` at both existing call sites
(plain and auto-improve); apply `applyRequiredLoopGateFailureIfNeeded` only
when no reservation exists. Use the internal reservation, never authored
variables, workflow names, task-context payloads or a new public option.
Preserve gate projection, loop-evidence summary, canonical persistence,
notifications, telemetry and rendering order. This does not convert real
runner failures or cancellations to success. Keep the completed task-backed
session and rejected gate/finding evidence intact so ordinary TaskDispatch
reconciliation and DeterministicDirector can reject acceptance and persist a
causal recovery request under existing budget rules. A completed workflow
session is not successful task acceptance. Standalone runs retain failed
status, failure exit and inspectable rejected-gate evidence. SQLite terminal
immutability, schemas, dispatcher/director policy and public APIs stay unchanged.

**Amendment evidence and remaining gates.** The existing exact regressions are
`TaskRuntimeExampleTests.testRejectedGateRecoveryConsumesPendingRequestAndAcceptsSecondAttempt`
and `WorkflowCommandLivePersistenceTests.testWorkflowRunPersistsRejectedRequiredLoopGateForFailedRunInspection`.
Run each separately with a positive executed count after later implementation;
then renew final-source V1, V11 and serial broad verification using the current
plan's commands and full logs/final exits. Recovery must prove completed first
canonical session, retained rejection, no premature acceptance, causal pending
`verification` recovery, distinct second attempt/session, passing gate and task
success, request consumption and duplicate-free replay. Standalone verification
must prove failure exit/status and rejected evidence in canonical and artifact
stores. Do not clear findings manually, preseed success or weaken assertions.
The earlier amendment-time V1 had 56 tests and four failed assertions, including intermittent
second-attempt/replay recovery failures; that historical receipt is not current acceptance evidence. Preserve them as implementation acceptance blockers if they
persist; a repair outside this boundary needs a separately reviewed amendment.
The prior broad receipt predates the last fixture edit and is not final-source
acceptance. Classify every final-source failure by test/assertion, cause, source
identity and owner; new/slice failures block, unrelated failures retain FAILED
status and explicit follow-up. Only a complete passing broad run can be called
passing. Formal test-integrity, single adversarial and Astra combined-tree
reviews, B4 documentation and exact-file commit/non-force push remain later
gates. P1-7b, P1-7a and parent P1 remain open. No user decision is unresolved.

**Authority and delivery boundary.** Mode `issue-resolution`; issue “Finish
P1-7b after integration review found missing example-catalog coverage”, from effective
`workflowInput` and Step 1 `comm-000002` in
`codex-design-and-implement-review-loop-session-1`. No GitHub issue number/URL
or codex-agent reference input was supplied. No reference-code parity, Cursor
CLI change, or intentional reference divergence is proposed; existing adapter
boundaries remain unchanged. This subsection governs the current P1-7b slice
and supersedes older combined-delivery/no-publication requirements in §17.7
and the parent plan for this execution only. P1-7b may be committed and pushed
after its own review/documentation gates while P1-7a and parent P1 stay open.

Preserve accepted P1-6d commit
`59f45c1a126d451fbe2eaf775306785d53b518d2` and all other session work on
`feat/remaining-impl-plans`. The sole plan input remains
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md`. Do not
reconstruct P1-6a/b/c/d, remove P1-7a implementation, add task creation CLI,
change storage schemas, or repair unrelated broad failures. Retain legacy
example directories in this slice: deletion is unnecessary to demonstrate
replacement and requires separately reviewed exact ownership and a passing
current-source V1 before-removal receipt. No reset, force push, broad staging,
main merge, stash, revert, or additional worktree creation is permitted.

**Existing assets and minimal changes.** Both `examples/task-repair-loop/`
and `examples/task-agent-director/` already contain `workflow.json`, referenced
`nodes/` and `prompts/`, `mock-scenario.json`, `README.md`, and
`EXPECTED_RESULTS.md`. Retain their minimal shapes: repair then required
`verification` gate; one bounded director worker returning a recommendation.
Keep deterministic mock keys aligned with node IDs and stable business output;
generated session IDs/timestamps are not expected-output constants. Bundle
READMEs distinguish standalone workflow completion from task acceptance and
describe fixture setup through existing store APIs, without inventing a CLI.

`Tests/RielaCLITests/TaskRuntimeExampleTests.swift` already covers real reserved
attempts, guards, capacity and substantial accepted P1-6d child behavior.
`TaskExampleHarness` in `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`
uses the real WorkStore, TaskDispatch and WorkflowRunCommand with deterministic
node responses. Reuse it; helper edits require explicit exact-path ownership
only if necessary. Inventory current assertions before adding tests. The
initial guard test expects CLI success despite terminal task failure; compare
that expectation with the accepted dispatcher contract and fresh failure
evidence rather than weakening runtime semantics to preserve the fixture.

**Behavioral acceptance matrix.** Fixtures may seed tasks and initial judged
work through existing store APIs. Transitions being tested must pass through
actual reservation, runner reconciliation and shared decision application;
directly writing the expected terminal state is not evidence.

| Case | Required durable observation at the real boundary |
| --- | --- |
| Acceptance | Repair and verify execute; required gate, verification and acceptance evidence belong to the reserved session; reconciled attempt and causal accept decision produce succeeded task. |
| Gate recovery | A rejected required gate cannot accept work. Remaining budget produces a recover decision naming `verification`; subsequent task dispatch consumes that request, executes recovery with deterministic passing output, and persists successful completion. Assert distinct attempt/session linkage, bounded attempt count and no duplicate recovery on replay. |
| Guard stop | A deterministic configured convergence violation persists guard evidence and a stop decision referencing it; task is failed, CLI terminal reporting agrees with the accepted contract, and repeated dispatch launches no extra work. Do not claim repeated-finding coverage from a gate-visit-only fixture. |
| Capacity wait | Capacity denial reports waiting/capacity with no attempt/session identifiers and creates no attempt, canonical session or lease; compare store state, not only response strings. |
| Bounded director decision | Reconciled judged work feeds one ordinarily executed linked child. An allowed recommendation is applied through shared causal/version/completion/budget validation; child success alone cannot accept failed work. |
| Once-only child accounting | Assert exact parent/judged/child/session linkage and concrete nonzero usage/cost charged once. Reopen the store and repeat ordinary dispatch; attempts, accounting, decisions and original judged evidence remain unchanged. Reuse existing accepted cases where they already prove this. |
| Invalid-output escalation | Invalid/forbidden output persists human-wait escalation and decision evidence. Failed or budget-blocked child cases retain accepted P1-6d behavior. Reopen/replay creates neither another child nor duplicate charges; no recursive director repair. |

Mock workflow runs are supplemental: repair returns accepted `verification`
with `acceptance.met: true`; director returns one `kind: accept` recommendation.
They cannot satisfy any task-ledger row by themselves. Stable expected results
must describe these distinctions and match executable tests.

**Dependency-ready execution and ownership.** Carry this as one scope through
native Riela waves: inventory and exact ownership first; minimal bundle/test
completion second; joined final-source verification third; independent review,
then serial documentation and publication. The test and its shared harness
have one editor; assign disjoint bundle work only after shared fixture contracts
are fixed. No nested orchestration framework or extra design author is needed.
Implementation writes follow the amended plan and dispatch manifest: retain
the existing two-bundle, TaskRuntimeExampleTests and WorkflowRunCommand scope,
and add only the two exact catalog/parity test paths specified above.
Directly affected shared documentation is finalized only at B4. Any further
production path requires another bounded reviewed amendment and renewed
affected evidence. Keep scratch and full verification artifacts under `tmp/`.

**Verification and review gates.** Use the parent plan's exact V0 build, V1
four-suite before-removal selection, V8 four example validate/mock commands and
V11 selected-host selection. V8 addresses these repository example bundles,
not the executing workflow. Run affected store/decision/guard suites where
fixture or helper changes exercise them. Core command forms are:

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel
git diff --check
git diff --cached --check
```

Also execute these exact catalog checks on the post-repair source, recording
observed mock counts without predicting acceptance from static enumeration:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI
```

Rerun the two exact recovery/standalone regressions above separately, V1
before-removal, V11, affected suites, strict changed-file SwiftLint including
both new test paths, and complete serial broad regression. Prior `final5`
receipts can be carried forward only where source identity remains valid;
catalog edits invalidate catalog/mock and broad acceptance. Classify every fresh
broad failure by exact test/assertion identity, cause, source identity, owner and
follow-up. Resolve every P1-7b-owned failure; unrelated failures remain **FAILED**.
Obtain fresh formal test-integrity, one Sol adversarial and Astra combined-tree
acceptance before B4 docs/progress and exact-file implementation publication.
P1-7a and parent P1 remain open even when P1-7b is accepted.

The plan's V6 strict touched-file SwiftLint command and V7 baseline comparison
apply to exact changed Swift paths, including necessary new helper files.
Record source identity before/after, exact command/toolchain, full log path,
terminal exit, positive per-suite counts and the test-to-matrix mapping. Run
broad regression serially; poll foreground handles through exit. Incomplete
logs, missing suites and zero-test selections cannot pass. Rerun invalidated
checks on final source. Build/lint success does not substitute for behavior.

The P1-6d broad gate remains **FAILED** with 19 classified assertions; its
“non-slice” classification was relative to P1-6d. The example assertion belongs
to this P1-7b investigation. Fresh current-source failures need identity/cause/
ownership classification: resolve new and P1-7b-owned failures, retain unrelated
follow-ups explicitly, and never relabel a failed broad command as passing.
Formal test-integrity, the workflow's single adversarial review, and Astra
combined-tree review must accept no material P1-7b defect. Record each actual
decision and finding; historical P1-6d acceptance does not certify this slice.

After those gates, update directly affected README/design/plan/progress entries
from evidence, leaving P1-7a, parent P1 and unresolved broad follow-ups open.
Commit only reviewed exact paths and non-force push the accepted commit after
documentation gates. No implementation, test or independent review acceptance
is claimed by this design update.

**Questions and author check.** No unresolved user decision or Step 3/5 review
feedback was supplied for this execution; the prior integration feedback above
is explicitly addressed. No user-QA file is needed. Fresh gate-recovery coverage
and current broad failure classification are implementation investigations,
not architectural unknowns. The author checked intake traceability, existing
assets and task boundaries, minimal scope, explicit ownership/dependencies,
and the separation of replacement evidence from legacy deletion. No unresolved
high/mid design finding remains. Subsequent behavioral gates remain required.


### 17.10 P1-7a ordered legacy removal (2026-09-25)

**Intake and scope.** Mode `issue-resolution`; issue “Finish Work Runtime P1-7a
ordered legacy auto-improve removal”; issue reference `comm-000001`, intake
`comm-000002`, execution `codex-design-and-implement-review-loop-session-1`,
Step 2 `step2-design-doc-update`. The complete implementation-plan batch is
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md`; preserve its
original task IDs and file map. This section governs only P1-7a and supersedes
historical no-publication-between-slices wording: P1-7b is already accepted at
the checkpoint above. This slice may publish after its own gates; parent P1
requires a separate completion audit. No Codex-agent reference repository or
Cursor-specific behavior is supplied or needed; no adapter divergence is proposed.

The prior evidence root is
`tmp/work-runtime-p1-7b-catalog-20260925-bffa1da-comm000006/plans/p1-dispatch/attempt-2/`.
Its `verification-evidence.json` and `broad-classification.json` are historical
receipts, not a new P1-7a deletion authorization. The latter records 2,668 tests,
two skips and 18 assertions: Doctor/backend capability (7), workflow/host
readiness (8), runner admission (1), temporary registration (2). Preserve the
exact identities and owners when comparing fresh results; do not assume that
a failure in a previously failing suite is unrelated to this removal.

**Replacement behavior and deletion barrier.** Reuse task dispatch → reserved
ordinary workflow execution → canonical terminal evidence → guard/director →
shared decision applier. No parallel supervision store, new public API, task
creation CLI, recursive repair or replacement framework is introduced.
Before deleting implementation, legacy tests or example files, map each row
below to named positive tests in the four V1 suites and record a fresh complete
passing V1 receipt on the before-removal source. Supplementary suites may
strengthen the evidence but do not replace this four-suite barrier.

| Behavior | Required observable evidence |
| --- | --- |
| Inactivity | A configured task guard observes lack of progress through actual dispatch, persists the violation and applies the bounded decision; progress prevents a false inactivity action. |
| Bounded retry | Recovery consumes one pending request per distinct reserved attempt/session, stops at the configured limit, and cannot bypass budget; successful completion of the last admitted attempt remains possible. |
| Gate and failure recovery | Rejected required-gate evidence and failed execution drive the existing recovery decision; an ordinary later attempt can succeed after the controlled cause changes. Do not seed successful terminal state or mark findings resolved just to satisfy assertions. |
| Cancellation | Durable cancellation fences replacement until exact-session terminal acknowledgment; cancelled work cannot create a new legacy incident or automatic retry. Preserve accepted local and selected-host cancellation contracts. |
| Replay | Reapplying the same decision or reopening durable state does not duplicate attempts, sessions, pending requests, ledger entries or accounting. |

Each V1 receipt records exact command, terminal exit 0, complete log, positive
counts separately for `TaskCommandMutationTests`, `TaskDispatcherTests`,
`TaskDispatcherIntegrationTests`, `TaskRuntimeExampleTests`, and source identity
(HEAD plus manifest/diff covering dirty source, tests and fixtures). Old P1-7b
57-test evidence alone cannot establish these new acceptance rows. Failure,
missing suite, truncated log or changed relevant source leaves deletion blocked.

**Removal and retained boundaries.** Use the P1-7a file-map rows in the plan:
remove `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift`, its policy and
mutation types, `SupervisedScenarioNodeAdapter`, and exclusively obsolete
supervision state/result plumbing, including `supervision-record.json` output
and `WorkflowRunResult.supervision`. Do not delete existing user artifacts.
Delete only the legacy example directories `examples/auto-improve/`,
`examples/default-superviser/`, `examples/supervised-mock-retry/`; retain both
accepted task examples and their shared catalog coverage. Section 12's broader
routine, specialist and loop removals belong to later phases, not this slice.

Removed workflow-run options must produce usage errors, including
`--auto-improve`, `--no-auto-improve`, `--max-supervised-attempts`,
`--max-workflow-patches`, `--monitor-interval-ms`, `--stall-timeout-ms`,
`--workflow-mutation-mode`, `--nested-superviser` and `--nested-supervisor`.
Preserve unrelated `--supervisor-mode` / `--no-supervisor-mode`, default loop
guard and agent-silence controls. Inventory shared session/loop consumers before
removing any option there; names alone are not evidence of obsolete behavior.
Remote workflow requests containing removed `input.autoImprove` or
`input.nestedSuperviser` must reject at the receiving validation boundary,
including false/null values, rather than ignoring them or forwarding them.
Ordinary authenticated remote requests must retain their authentication and
payload contract. Existing user workflow variables with similar names are not
new reserved fields. No broad unknown-field policy is added.

Preserve task-free plain runs, mock scenarios, canonical required-gate failure
for standalone runs, optional-gate behavior, specialist/event dispatch, loop
and routine stores and execution. Rewrite obsolete tests as explicit rejection
and preservation regressions only after the barrier. Keep meaningful assertions;
remove only assertions whose specified legacy behavior is intentionally gone.

**Ownership and dependency-ready waves.** One design author covers the whole
plan batch; one integration owner owns coupled Swift source/tests. Downstream
native Riela waves are ordered: (1) exact reference inventory, reviewed path
ownership and replacement tests with passing before-removal V1; (2) bounded
removal and rejection/preservation regressions; (3) final-source verification,
formal reviews, documentation and publication. Independent read-only investigation
may run alongside a wave; mutation and Git operations remain serial. Any newly
found decoder, result consumer, fixture or catalog path outside the plan's
listed ownership requires an exact-path bounded reviewed amendment before edit.
A contradictory retained consumer blocks that removal, not permission to redesign
another subsystem. Implementation planning must enumerate such paths and exact
retained-path test identities before dispatching edits.

**Final-source acceptance.** Repeat V1 after removal and run the plan's V0 build,
V2 reservation/cancellation/budgets, V3 guards/directors/decisions, V4 capabilities,
both V5 groups, V6 strict changed-file lint, V7 repository lint and V9 classified
reference/diff audit. Preserve V8 replacement-example behavior checks; these
exercise repository examples only. No current-workflow provenance rediscovery
is part of verification. Run affected retained-path tests for plain/mock runs,
authenticated remote payload/rejection, specialist/event dispatch and loops/
routines with positive suite counts. Include event/routine suites outside V5
where relevant, such as `EventRoutineBindingTests` and `RoutineAddonCatalogTests`.
Use the following explicit core commands; the plan retains full V2–V9 commands:

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --no-parallel
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
git diff --check
```

The serial broad command supplements, not replaces, the two V5 groups. Keep
broad failures explicitly **FAILED**, with exact test/assertion identity, cause,
owner and follow-up. Resolve every new P1-7a-owned failure; previous classification
is not automatic exemption. Slice acceptance does not turn a failed aggregate
into a pass. Record complete foreground logs, terminal exits, per-suite positive
counts, exact commands and before/after source manifests under this worktree's
`tmp/`, using separate before-removal and after-removal receipts. Poll every
yielded command through exit. Repairs invalidate affected evidence and reviews.

Require formal test-integrity, single Sol adversarial and Astra combined-tree
acceptance with no material P1-7a defect. Then refresh directly affected docs,
the active plan and `impl-plans/progress/p1-dispatch.md`, and commit only the
exact reviewed files and non-force push to `origin/feat/remaining-impl-plans`.
No reset, stash, force push, main merge, additional worktree or concurrent Git
operation is authorized. Parent P1 and unrelated broad follow-ups remain open.

**Open questions and current decision.** No unresolved user decision or
Codex-reference mapping exists. Exact additional ownership paths and named
behavior-to-test coverage are downstream investigation deliverables, not new
architectural choices. This section is author-checked design only, pending
Step 3 review; no P1-7a implementation, passing deletion barrier, formal acceptance
or publication is claimed by Step 2.
