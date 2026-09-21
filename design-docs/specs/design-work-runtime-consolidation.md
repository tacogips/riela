# Work Runtime: consolidating auto-improve, loop engineering, supervision, and routines

Status: accepted 2026-09-20 with the three section-16 questions resolved by the user. **P0 implemented 2026-09-21** (§4 model, §8 projection, §11 `work_*` tables, §13 P0 read commands); P1 onward not started. P0 plan: `impl-plans/active/work-runtime-p0-model-and-store.md`.
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
