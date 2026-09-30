# wh-14: Task dispatch runtime — seal, takeover, answer injection, branches, leases, triggers

```json
{
  "planId": "wh-14-task-dispatch-runtime",
  "planPath": "impl-plans/active/wh-14-task-dispatch-runtime.md",
  "wave": "W3",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskDispatch+Handover.swift",
    "Sources/RielaCLI/TaskHandoverRuntime.swift",
    "Sources/RielaCLI/TaskHandoverSupport.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+HandoverRequestAddon.swift",
    "Sources/RielaWork/WorkStore+Isolation.swift",
    "Tests/RielaCLITests/TaskHandoverTestSupport.swift",
    "Tests/RielaCLITests/TaskHandoverDispatchTests.swift",
    "Tests/RielaCLITests/TaskHandoverLeaseTests.swift",
    "Tests/RielaCLITests/TaskHandoverRepositoryTests.swift",
    "Tests/RielaCLITests/HandoverRequestAddonTests.swift",
    "impl-plans/progress/wh-14-task-dispatch-runtime.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaAddons/RielaAddons.swift"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCLI/WorkflowRunCommand.swift",
      "intendedEdit": "In the run-event handler (~line 123), await `taskContext?.stepBoundaryHook?(event)` for `.stepCompleted`. When building the DeterministicWorkflowRunRequest for a task run, set `boundaryHandover` from `taskContext?.boundaryHandover`. No other change; wh-02's suspended mapping stays."
    },
    {
      "path": "Sources/RielaCLI/ProductionNodeAdapter.swift",
      "intendedEdit": "One dispatch branch `if input.addon.name == \"riela/handover-request\" { return try executeHandoverRequest(input) }` beside the other riela/* branches."
    },
    {
      "path": "Sources/RielaAddons/RielaAddons.swift",
      "intendedEdit": "Add `public static let handoverAddons = [.init(name: \"riela/handover-request\", version: \"1\")]` and include it in `all`."
    }
  ],
  "progressLog": "impl-plans/progress/wh-14-task-dispatch-runtime.md"
}
```

## Intent and context

This plan wires the wave-2 parts into task execution: sealing after every trigger, same-store takeover,
answer injection, the attempt branch with checkpoints, heartbeat and fence, the owner-side leaseLost, orphan takeover,
reconcile, adoption, and the `riela/handover-request` add-on. It also exposes the runtime API that the CLI (wh-15),
GraphQL (wh-16), examples (wh-17) and remote takeover (wh-18) call. Design §5, §6, §9.1, §10.1, §10.4, §10.5, §11,
§21 R16 and R19–R22. The existing flow to extend is `TaskDispatch.run` (`TaskDispatch.swift:116-321`), `TaskRunCancellation.run`
and its observer loop (`TaskRunCancellation.swift:72-243`), and `runTaskReservation` (`WorkflowRunCommand+TaskReservation.swift`).

Non-goals: command parsing and rendering (wh-15), GraphQL (wh-16), the remote successor (wh-18), docs, catalog and SDL.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-14-task-dispatch-runtime/`,
writePaths only plus the shared edits stated above, arm64 logs; tests use temp stores and repos under `tmp/`; no
project-repo git state changes; own progress log).

## Pinned runtime API (`TaskHandoverRuntime.swift`)

```swift
struct TaskHandoverRuntime: Sendable {
  var located: TaskCommandRunner.LocatedTask      // store + root, as TaskDispatch uses
  var options: TaskStoreOptions
  var hostId: String = "local"
  var now: @Sendable () -> Date = { Date() }
  func answer(taskId: TaskID, questionId: String, payload: JSONObject, producer: DecisionProducer) throws -> WorkTask
  func requestTakeover(taskId: TaskID, traits: [HostTrait], producer: DecisionProducer) throws -> WorkTask
  func requestHandover(taskId: TaskID, reason: String, immediate: Bool, target: String?, sinks: [HandoverSinkKind]) throws -> HandoverRequestRecord
  func forceOrphan(taskId: TaskID, producer: DecisionProducer, cliSinks: [HandoverSinkKind]) async throws -> HandoverPacket
  func reconcileExpired(dryRun: Bool, cliSinks: [HandoverSinkKind]) async throws -> [TaskReconcileEntry]   // {taskId, attemptId, handoverId?, action}
  func adoptAndSeal(sessionId: String, workingDirectory: String, reason: String, principal: String, existingTaskId: TaskID? = nil, cliSinks: [HandoverSinkKind]) async throws -> (WorkTask, HandoverPacket)
  func handovers(taskId: TaskID) throws -> [HandoverPacket]
}
```

`TaskDispatch` additions:
- `func run(taskId:options:dryRun:output:localTraits: [HostTrait] = [], packetOverride: HandoverPacket? = nil) async -> CLICommandResult`
  (new defaulted parameters; `localTraits` feeds `HostCapabilityResolver.localTraitOverride`).
- `func reconcileExternalTerminal(attemptId: AttemptID, snapshot: WorkflowRuntimePersistenceSnapshot, deliverables: [DeliverableRef], store: WorkStore, storeRoot: String) async throws -> TaskRunCommandResult`
  is used by wh-16 `reportAttempt`. It saves the snapshot for the attempt's session and seals if the snapshot is `suspended`
  (deliverables come from the report) or runs the same reconcile + guard + director path as a local terminal. In the latter case it
  first stores `Evidence(kind: .publication, payload {"deliverables": [...]})` for the reported deliverables.
- `TaskRunCommandResult` gains `statusKind .suspended` and `handoverId: String?`. The exit code is `.suspended` when sealed.

## Deliverables

1. **Seal after a run** (`TaskDispatch+Handover.swift`). After `executeReserved` joins, load the snapshot (this replaces the
   current `completed || failed` guard at `:282`; accept `suspended` too). Decide the handover trigger:
   - `status == .suspended` → the reason comes from `session.suspend` (`userInputRequired(question)`,
     `userPresenceRequired(presence)`, `operatorMove(reason)`).
   - The attempt was cancelled because of a handover request, a wait signal, a director `.handover`, or a fence loss
     (recorded by the observer, item 5) → the reason is `operatorMove`, `userPresenceRequired`, `inactivity` or `ownerLost`.
     Rewrite the terminal session's failure kind to `.cancelled`, `.stalled`, `.stalled` or `.leaseLost` respectively
     (R20) through the same save path `saveCancellationSession` uses.
   - Otherwise: today's reconcile path, unchanged.
   Seal through `HandoverCoordinator.seal` with the builder input (the workflow from the resolved bundle, `workflowRef` from the
   task plan reference, `variables` = the run variables, `progressNote` from the suspend record, and redaction rules from
   `TaskHandoverSupport.redactionRules(workflow:nodePayloads:environment:)`: every env binding name declared in
   node `addon.env` or node env, and each such name's current process value). Also pass the publisher
   (item 3), the sinks (`HandoverSinkFactory.mergedConfigs` + `make`), and `predecessorOutcome = WorkEvidenceProjector.outcome(from: snapshot)`.
   Then call `LoopNotificationDispatcher().dispatchHandover(...)` and render `.suspended` with `handoverId`. Do **not** run the
   director or `reconcileAttempt` for a sealed attempt (the seal already reconciled it).
2. **Takeover dispatch.** When the pending reservation entry is `.takeover(from, hid)`:
   `selectedEntryStep` returns `packet.contract.resumeStepId`. Placement uses `requiredTraits = presence traits`
   for `userPresenceRequired` packets and `[]` otherwise. Before `executeReserved`: (a) load the reserved session's snapshot, seed an
   `InMemoryWorkflowRuntimeStore`, run `importAcceptedHistory(WorkflowHistoryImportInput(sessionId:, sourceSessionId:
   packet.fromSessionId, bundle: packet.history, handoverId:))`, append the answer message (if an answer exists:
   delivered `{ "handover": { "answer": payload } }` to the resume step), and persist it back through
   `SQLiteWorkflowRuntimePersistenceStore.save`. The durable snapshot must hold the imported executions before the runner
   starts. (b) Pass the variables `handover = {id, reasonKind, brief, question?, answer?, progressNote?, deliverables}` and
   `rielaTask = {taskId, attemptId, fence}` through `WorkflowRunOptions.variables` (merge with any existing JSON).
   The same `rielaTask` variable is set on **every** task attempt, which is how the add-on detects that it runs in a task.
3. **Repository.** For tasks with `ContextBinding.repository` (read `WorkContext.swift`): at reservation time on a fresh
   entry, call `GitBranchWorkspaceRuntime.ensureBranch(template: handover.publish.branchTemplate, isolation: binding isolation)`.
   On a takeover with a repository deliverable, call `materialize` into the working dir (`--working-dir`), using a worktree when the
   binding isolation is `.worktree`. Record `Attempt.isolation` via the new `WorkStore.updateAttemptIsolation(attemptId:isolation:)`
   (`WorkStore+Isolation.swift`, one guarded UPDATE of the attempt record). Run the workflow with `workingDirectory = isolation.path`.
   `TaskDeliverablePublisher` (in `TaskHandoverSupport.swift`, conforms to `DeliverablePublisher`): when the owner is alive, check the
   fence (`store.loadLease(attemptId:)?.fence == reservation fence`; a mismatch → `checkpointFailed("fenced")`), then run
   `checkpoint`, then `publish` with the task's `PublicationPolicy`. A repository with no remote → `checkpointFailed("no remote")`.
   When the owner is not alive (orphan): `unpublished(lastKnown: last checkpoint sha from git log with the trailer, if readable locally, else nil)`
   plus `dirtyPaths` if the root is local. It appends `DeliverableCollector(workflow:nodePayloads:).collect(snapshot:)`.
4. **Checkpoint hook.** `TaskPlacementExecutionContext` gains `stepBoundaryHook: (@Sendable (WorkflowRunEvent) async -> Void)?` and
   `boundaryHandover: (@Sendable (String) async -> SuspendRecord?)?`. The step hook: on `.stepCompleted`, if
   `(task.guardPolicy.handover ?? .init()).checkpoint == .stepBoundary` and an isolation exists, run `checkpoint(message: "riela: checkpoint <taskId> <stepId>",
   trailer: "Riela-Checkpoint: <attemptId>/<stepExecutionId>")`. Errors become a diagnostic and never fail the run. `everyMs`
   runs the same call on a timer inside the observer. The boundary hook returns a `SuspendRecord(reasonKind: .operatorMove, stepId: next,
   producer: .human(principal))` when `store.pendingHandoverRequest(attemptId:)` is non-immediate, and consumes it.
5. **Observer** (`TaskRunCancellation`). Each iteration (100 ms loop):
   - Heartbeat every `lease.heartbeatMs` via `store.heartbeat(attemptId:fence:now:ttlMs:)`. `false` → record
     `.fenced`, cancel the execution, and stop observing.
   - An immediate handover request (`--now`) → record `.handoverRequest`, consume it, and cancel.
   - Inactivity: before calling the guard coordinator in `observeInactivity`, check
     `TableBackendWaitSignalClassifier.default.latestSignal(in: execution.recentBackendEvents ?? [], backend:)`. If there is a signal and
     `onWaitSignal` is true → record `.waitSignal(presence)`, skip the director, and cancel. Otherwise, today's path. If the applied
     decision kind is `.handover` (wh-11/wh-03) → record `.director(reason)`.
   The recorded trigger is returned to `TaskDispatch` alongside the `CLICommandResult`. Keep `run`'s existing return type and add
   an `inout`/actor holder or a small result struct, whichever is least invasive.
6. **Runtime functions** (`TaskHandoverRuntime.swift`):
   - `answer` → `store.recordAnswer` (wh-03).
   - `requestTakeover` → `store.requestTakeover` with `TakeoverPlacement(hostId, requiredTraits: traits)`.
   - `forceOrphan` → `store.fenceOrphan(now:)`, then seal from the predecessor's last snapshot with `.ownerLost(evidence)`,
     `ownerAlive: false` and the resume step = `snapshot.session.currentStepId ?? entryStepId`, then `requestTakeover` for this host.
   - `reconcileExpired` → for each `store.expiredLeases(now:)`: in dry-run, list them; otherwise `fenceOrphan` + seal, with no takeover request.
   - `adoptAndSeal` → load the session (refuse if a live `SessionExecutionLock` is held; read `SessionExecutionLock.swift`) →
     `TaskAdoption.adopt` → seal with `.operatorMove(reason)` (or the suspend record's reason if the session is suspended).
7. **Add-on `riela/handover-request@1`** (`ProductionNodeAdapter+HandoverRequestAddon.swift`). If `input.variables["rielaTask"]` is missing →
   `AdapterExecutionError(.policyBlocked, "riela/handover-request runs only inside a task attempt")` (use the existing policy error
   helper). Config/inputs: `reason, question, presence, progressNote, resumeStepId` (**required**, R21), validated by building a
   `HandoverEnvelope` via `HandoverEnvelope.parse`. Output payload: `{"status": "handover-requested", "addon": name, "stepId",
   "handover": <envelope object>}`. The wh-02 extraction then suspends at `resumeStepId`, which must be the selected next step.

## Pitfalls

- The one-live-attempt index: never reserve a takeover before the predecessor is reconciled. Seal and `fenceOrphan` do that.
- Do not import history in the runner. It must be durable before `runTaskReservation` (it resumes the reserved session).
- The fence check before publish and the heartbeat must use the fence from the **reservation** (the lease row created at reserve).
  Never re-read the task fence as "mine".
- A sealed attempt must not be reconciled again by the existing `reconcileTerminal`. Guard it with an early return.
- Keep `task run` output unchanged for non-handover runs. The existing `TaskDispatcherIntegrationTests` must stay green.

## Tests

`TaskHandoverTestSupport.swift`: `extension TaskExampleHarness` helpers that write small fixture bundles into the harness
temp dir (an envelope step using the scenario adapter, a two-step workflow, an add-on step), plus `answer`, `takeover` and
`forceOrphan` helpers that call `TaskHandoverRuntime` and `TaskDispatch`. Use `scenarioPath` per dispatch so predecessor and
successor use different mock responses.

`TaskHandoverDispatchTests`:
- envelope → `statusKind suspended`, exit `.suspended`, handoverId; the store packet reloads with an equal digest; the task is `waiting`;
  the predecessor is reconciled; there is no lease row
- `.start` dispatch while a handover is pending → waiting `handover`
- answer → takeover dispatch → session B has imported executions (`importedFrom.handoverId`); the resume step's `inputSnapshot`
  contains `handover.answer`; the task completes; lineage hops = 1; the handover successor = B
- takeover of an unanswered S1 → refused with the answer hint
- presence packet: dispatch with no traits → waiting/failure `host-traits-unavailable: userReachable`; with
  `localTraits: [.userReachable]` → proceeds
- a sink config (file) on the task → the packet file exists and the sink ref is recorded; a failing command sink → publication evidence, seal ok
- `handoverOnInactivity` + a stalled fake adapter → packet reason `inactivity`, session `failed(.stalled)`
- a wait signal: a fake adapter emitting a pending tool call, then silence → reason `userPresenceRequired`, session `failed(.stalled)`
- a cooperative `requestHandover(immediate: false)` during step 1 → suspended before step 2, reason `operatorMove`; `immediate: true` → `failed(.cancelled)` + packet
- `adoptAndSeal` of a suspended plain session → a task exists with a packet; a later takeover continues it

`TaskHandoverLeaseTests`:
- the heartbeat extends `expiresAt` during a sleeping node
- a running owner, then `fenceOrphan` with an injected `now` past expiry → the owner's next heartbeat fails, the run is cancelled, and the session is
  `failed(.leaseLost)` ("revived owner fails with leaseLost")
- a reserved-but-dead owner (launch authorized, never run) → `forceOrphan` refused before expiry and accepted after → packet `ownerLost`;
  a takeover completes the task
- `reconcileExpired(dryRun: true)` lists without writing; `false` → packets sealed, tasks waiting

`TaskHandoverRepositoryTests` (temp repo + bare remote + second clone):
- attempt start → branch `riela/task/<taskId>/g1` checked out and `Attempt.isolation` set; step boundaries → checkpoint commits with
  the trailer; handover → branch published and the packet repository deliverable is `published` with `headCommit`
- takeover with `--working-dir` = second clone → materialized at `headCommit`; the task continues and completes
- a fenced owner → the publisher returns `checkpointFailed("fenced")` and nothing is pushed

`HandoverRequestAddonTests`: outside a task → policyBlocked; inside → packet reason matches, suspended at the configured next step;
missing `resumeStepId` → config error.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-14-task-dispatch-runtime/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/focused.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskDispatcherIntegrationTests|TaskCancellationIntegrationTests|TaskRuntimeExampleTests|TaskRunResultTests|WorkflowTaskAddonTests" > tmp/work-handover/wh-14-task-dispatch-runtime/regression.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-14-task-dispatch-runtime/regression.log'
git diff --check
```

All three must end with exit=0 and non-zero counts. Every regression failure must appear in the wh-00 baseline.
This plan proves acceptance signals 1–5 at runtime level. Record the test names per signal in the progress log.

## Done criteria

- [ ] The pinned runtime API and TaskDispatch additions exist; every trigger seals exactly once
- [ ] The takeover, answer, repository, lease/fence, orphan, reconcile and adoption tests pass
- [ ] The existing task suites are green or baseline-classified; the progress log is complete


## Resume notes (2026-10-01)

wh-10 is accepted and committed. A partial wh-14 implementation is committed (`wip: partial wh-14 ...`): complete it, do not restart it. Remaining work: TaskHandoverDispatchTests, TaskHandoverLeaseTests and TaskHandoverRepositoryTests, the director `.handover` observer capture, and the `everyMs` checkpoint timer. Also enforce required host traits for a presence takeover when the workflow has no backend requirements, in this plan's dispatch path (wh-10 integration low finding).

### Resume checklist (session-4 design step, source-verified at d32077b0)

Everything below stays inside this plan's writePaths. Do not edit `Sources/RielaWork/BackendCapabilityPlacement.swift` (wh-10), `DeterministicDirector.swift` or `TaskGuardCoordinator.swift`.

1. **Director `.handover` capture** (`TaskRunCancellation.observeInactivity`). After `evaluateAndApply` returns, if
   `result.resolution?.kind` is `.handover(reason)` (`WorkDecision.swift` `DecisionKind.handover(HandoverReason)`), call
   `handoverTriggerState?.record(reason: reason, failureKind: .stalled)` (design R20) before returning `true`. Record before the
   execution is cancelled. `TaskRunHandoverTriggerState.record` keeps the first trigger, so a later fence loss cannot overwrite it.
   Keep the existing `attemptCancellation != nil` return for non-handover decisions.
   Pitfall: for a running attempt, `evaluateAndApply` on `.handover` does not apply the decision. `applyDecision` only bumps the
   task version, inserts the decision and writes a pending `work_cancellations` row (`WorkStore+Decisions.swift:147-190`,
   `requiresLiveCancellation`). Nothing in the seal path acknowledges that row, and the session save guard
   (`SQLiteWorkflowRuntimePersistenceStore.swift:753-785`) rejects a `failed(.stalled)` save while it is pending. It also rejects
   rewriting an already saved `failed(.cancelled)` to `.stalled`. Only the director path has this problem: the wait-signal,
   immediate-request and fence-loss triggers write no `work_cancellations` row. Decisions:
   - In `TaskRunCancellation.run`, after the join, when the recorded trigger is present and the pending cancellation's decision
     is the director `.handover` decision, skip `persistJoinedCancellation` and `saveCancellationSession` and return the run
     result, so the session is never saved as `failed(.cancelled)`. Remote selected-host stop proof (`proveSelectedHostStop`)
     still runs as today.
   - Add one guarded method to `Sources/RielaWork/WorkStore+Isolation.swift` (an `extension WorkStore`). In one transaction it marks
     the attempt's pending `work_cancellations` row acknowledged (`acknowledged_at`, `terminal_status = failed`), and only when
     that row's decision kind is `.handover` for that task and attempt. Otherwise it throws. It does not reconcile the attempt or
     change the task state; `sealHandoverRecords` does that. `sealHandoverIfNeeded` calls it before the `.stalled` snapshot save.
     Do not use `acknowledgeAttemptCancellation`: it requires a `failed(.cancelled)` snapshot and sets the task `.failed`.
   - The seal keeps the fresh task version (`expectedTaskVersion ?? currentTask.version`, `TaskHandoverRuntime.swift:264`), because
     the director decision already bumped it. The director decision and the coordinator's seal decision are both `.handover`
     decisions with different ids. That is expected. Do not reuse the director decision id (`insertDecision` would conflict).
2. **`everyMs` checkpoint timer.** Add this to the observer loop in `TaskRunCancellation.run`, beside the heartbeat block. When
   `reservation.task.guardPolicy.handover?.checkpoint` is `.everyMs(interval)` and the attempt has an isolation, run the
   same checkpoint call as the `stepBoundaryHook` in `TaskDispatch+Handover.swift` (message `riela: checkpoint <taskId> timer`,
   trailer `Riela-Checkpoint: <attemptId>/timer-<n>`) once `interval` ms have passed since the last timer checkpoint.
   Pass the isolation and checkpoint closure in through `TaskPlacementExecutionContext`
   (`WorkflowRunCommand+TaskReservation.swift`, a writePath), next to `stepBoundaryHook`. Do not
   recompute them in the observer. Serialize the timer and step-boundary checkpoints per attempt (one actor or lock owned in
   `TaskHandoverSupport.swift`), so two `git commit`s never run in the same worktree at once. A checkpoint error is a
   diagnostic and never cancels the run.
3. **Presence traits without backend requirements** (`TaskDispatch+Handover.swift`, the prepare step where `requiredTraits` is
   computed). `BackendCapabilityPlacementResolver.resolve` checks traits only inside its per-requirement loop, so it
   accepts anything when `requirements` is empty. When `requiredTraits` is non-empty and `requirements` is empty, check
   `topology.local` (after the `localTraits` merge) and the live `topology.workers` for a superset of `requiredTraits`. If none
   qualifies, the dispatch fails the placement with reason `host-traits-unavailable: <sorted rawValues joined by ",">` (the same
   string the resolver emits) and leaves the task waiting for the handover, unchanged. Do not reserve an attempt.
4. **Deterministic lease tests.** Drive expiry through the injected `now:` of `store.fenceOrphan`/`store.heartbeat`/`expiredLeases`
   and `TaskHandoverRuntime.now`. Use a short `LeasePolicy(ttlMs:heartbeatMs:)` on the fixture task rather than long sleeps.
   The revived-owner leg is proven by the fence bump: after `fenceOrphan`, the owner's next observer heartbeat returns `false`
   and the session ends `failed(.leaseLost)`.
5. **Tests to add:** `TaskHandoverDispatchTests`, `TaskHandoverLeaseTests` and `TaskHandoverRepositoryTests`, with the cases listed
   under Tests above, plus: a director `.handover` policy with a stalled fake adapter → packet reason `inactivity`, session
   `failed(.stalled)`, exactly one packet, and after the seal no unacknowledged `work_cancellations` row remains for the predecessor
   attempt (`store.attemptCancellation(...)` is nil or acknowledged), the task is `waiting`, and a following `task takeover`
   reservation for that handover is not rejected; `checkpoint: everyMs(50)` with a sleeping node → at least one commit whose trailer
   starts `Riela-Checkpoint: <attemptId>/timer-`; a presence packet on a workflow with no backend requirements and no traits →
   `host-traits-unavailable: userReachable` with no new attempt, and with `localTraits: [.userReachable]` → proceeds.
   Repository fixtures live under the harness temp dir (a temp repo, a bare remote and a second clone). Never use the project repo.
6. **Progress log.** Update `impl-plans/progress/wh-14-task-dispatch-runtime.md` with the test names per acceptance signal (1–5),
   the three Verification commands with `exit=` lines and log paths, and tick the Done criteria only with evidence.
