# Manual Instance Run Overlap and Terminal-Reserve Precondition

Status: design for implementation on `fix/manual-overlap-terminal-reserve`
(base `main` @ `ac6670fe`, branch head `c6e127b6`). No GitHub issue. The
intake comes from the ART hourly workflow recovery on 2026-11-11 (workflow
input `requestedBehavior` of
`opus-terra-design-and-implement-review-loop-session-1`).

Baselines this document amends. Their decisions stay in force unless a
section below says otherwise:

- `design-docs/specs/design-scheduled-overlap-policy.md`: cron overlap
  policy, `CronOverlapDispatcher`, reason vocabulary.
- `design-docs/specs/design-instance-reload-run-cli.md`: `riela instance
  run`, App `POST /api/v1/instances/{identity}/runs`.
- `design-docs/specs/design-loop-engineering-convergence-and-operations.md`
  §"Reserved terminal steps": terminal reservation (S9a).

## 1. Problems (verified at `c6e127b6`)

### Bug A: manual runs are invisible to cron overlap, and to each other

- The App runs a manual launch in-process.
  `RielaApp.webConfiguredRunResponse`
  (`Sources/RielaApp/RielaAppConfiguredRunAPI.swift`) calls
  `launchConfiguredWorkflow`
  (`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`), which
  runs `WorkflowRunCommand` in a detached task with
  `configuredInstanceOverride` set. The session store is
  `daemonSessionStoreRoot(profileName:)`.
- Cron runs execute in a separate `riela events serve` child process
  (`DaemonWorkflowEventServeProcess.eventServeCommand`). The App passes it the
  same per-profile session store with `--session-store`
  (`DaemonWorkflowSupport.swift`, `WorkflowServeStartRequest.sessionStoreRoot`).
- `CronOverlapDispatcher.submitReserved`
  (`Sources/RielaCLI/EventCronOverlapDispatcher.swift`) only looks at
  `scopes[bindingId].running`, which are runs that this dispatcher started.
  A manual session in another process is never seen, so
  `hourly-refresh-session-249` (manual) overlapped cron sessions 250 and 252.
- `launchConfiguredWorkflow` only enforces the global `run_limit` (at most 4
  running launches). It has no per-instance busy check.
- Persisted session facts this design relies on:
  - `WorkflowSession.instanceIdentity`, `instanceKind` and
    `instanceBaseIdentity` (`RuntimeStore.swift` session create) come from
    `WorkflowInstanceResolver.resolve`.
  - A manual configured run has a named base: kind `named` with
    `instanceIdentity = <App identity>`, or kind `ephemeral` with
    `instanceBaseIdentity = <App identity>` when variables are supplied.
  - An `events serve` run has no `--instance`, so its base is the default
    instance: kind `default`, or `ephemeral` with
    `instanceBaseIdentity = "default"`.
- Liveness primitive: `LockReservingWorkflowRuntimeIDGenerator` takes the
  per-session flock (`SessionExecutionLockRegistry`) *before* the session id
  reaches the store. The kernel releases the lock when the process exits.
  `riela session reconcile` already uses "non-blocking acquire fails ⇒ live"
  as its liveness predicate
  (`design-cancellation-and-orphan-session-resilience.md` P4 contract).

### Bug B: terminal reservation skips steps of short acyclic workflows

- `redirectForTerminalReservationIfNeeded`
  (`Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`) redirects
  when `corridor` exists, the current step is outside it, and
  `remaining = maxSteps - visitedSteps` satisfies
  `corridor.count <= remaining <= max(3, corridor.count)`.
- The default budget is `steps.count + maxLoopIterations`
  (`DeterministicWorkflowRunner.swift`). For `check -(conditional)-> remediate`
  with `maxLoopIterations = 1`, the budget is 3. The corridor is `[remediate]`
  because a labelled edge stops the corridor walk. At `visitedSteps = 0`,
  `remaining = 3 <= 3`, so `check` is skipped (sessions
  `output-monitor-session-251` and `output-monitor-session-255`). Long
  acyclic chains whose edges are conditional lose late steps the same way.
- The reserve exists only to stop an *undeclared loop* from consuming the
  terminal capacity. An acyclic remainder cannot loop.

## 2. Goals and non-goals

Goals:

- A live manual (named-instance) run of the workflow counts as a running
  session for that workflow's cron overlap policy in `events serve`.
- `riela instance run` refuses with `instance_busy`, naming the running
  session, when the instance already has a live execution, unless
  `--allow-overlap` is passed.
- Terminal reservation never redirects when the remaining reachable graph is
  acyclic and its longest path fits the remaining budget.

Non-goals (all unchanged):

- Cron-vs-cron overlap semantics, reason formats, receipts and per-binding
  scope (baseline §6.2).
- Cross-process *cancellation*. The dispatcher never cancels a session that
  another process owns (baseline §2 non-goal).
- A new atomic cross-process run claim or lease (§3.5 residual window).
- The `reload` contract, the executions projection, and the existing
  `instance_busy` meaning for reload and shutdown.
- Loop-guard behavior when a cycle is reachable, authored loop policies,
  `--disable-default-loop-guard`, and the hard `maxSteps` limit.

## 3. Bug A design

### 3.1 Shared definition: live instance session

A **live session of workflow W in store S** is a session record in session
store root `S` that meets all of these:

1. `workflowId == W`;
2. it is a root session (`parentSessionId == nil`). Nested, fanout and
   reserved children never count;
3. `status ∈ {created, running}`;
4. its execution lock is held by some process: a non-blocking acquire through
   a fresh `SessionExecutionLockRegistry(sessionStoreRoot: S)` fails with
   `alreadyRunning`. If the acquire succeeds (the session is orphaned), the
   lock is released at once and the session does **not** count.

Rule 4 is the stale-`running` guard. A session whose runner crashed never
blocks cron or manual runs, and no timeout is involved. It is the same
predicate `riela session reconcile` uses. A probe holds the lock only for an
orphan's lock file, and an orphan's id is never re-allocated because the
generator skips persisted ids. So the probe cannot disturb a live runner.

A **manual session** is a live session whose named base is not the default
instance: `instanceKind == "named"`, or `instanceKind == "ephemeral"` with
`instanceBaseIdentity` non-nil and `!= "default"`.

One read-only helper in `RielaCLI` implements both, next to
`SessionExecutionLockRegistry`. It is shaped like
`liveRootSessions(workflowId:sessionStoreRoot:) -> [(sessionId, createdAt,
isManual)]`, sorted by `createdAt` ascending. It reads the store in read-only
mode, so it never creates a database or schema. A missing store returns `[]`.

### 3.2 Cron dispatcher (events serve)

The dispatcher gets an injectable probe seam,
`ExternalRunProbing: (workflowId) throws -> [String]`. It returns the session
ids of live **manual** sessions, oldest first. The default implementation
uses §3.1 with the serve's effective session store root (the root the serve's
runs use). Tests inject a fake. The binding's `workflowId` is resolved once at
startup alongside the overlap policy, through the existing
`EventWorkflowTriggerDefaultsResolving` resolution. A binding whose workflow
did not resolve has no external probe (today's behavior).

The dispatcher consults the probe only where today it would start a fire
because the scope is idle (`running.isEmpty && pendingAfterCancel == nil`),
and when it counts the cap for `concurrent`. Whenever the scope has in-process
runs, the existing transitions, reason ids and cron-vs-cron outcomes apply
unchanged. Only manual sessions are probed, so cron runs of *other bindings*
in the same serve, whose sessions are default-based, never block a binding.
Per-binding scope therefore stays exactly as it is.

Let `E` be the probe result for an idle scope.

| Policy | `E` non-empty, scope idle |
|---|---|
| `skip` | Record `skipped` with `overlap-skip:<bindingId>:<E[0]>`, the existing format, naming the manual session. |
| `concurrent` | Start if `maxConcurrentRuns == nil` or `running.count + E.count < maxConcurrentRuns`. Otherwise record `overlap-concurrency-cap:<bindingId>:<cap>`. For a non-idle scope the cap check also adds `E.count`. |
| `queue` | Append the fire and record it as `overlap-queued:<bindingId>:<pos>`, under the same cap and the same `overlap-queue-full` rule. The queue head starts when the scope has no in-process run **and** the probe returns `[]`. |
| `cancelRunning` | A manual run is never cancelled. Record `skipped` with `overlap-skip:<bindingId>:<E[0]>`. |

**FIFO under external blocking (queued-idle state).** An external blocker
allows a new state: `running.isEmpty && pendingAfterCancel == nil &&
!queue.isEmpty`. The idle-start shortcut in `submitReserved` therefore
changes from `running.isEmpty && pendingAfterCancel == nil` to
`running.isEmpty && pendingAfterCancel == nil && queue.isEmpty`. A new fire
can never start directly while older fires are queued. All advancement goes
through one actor-isolated step, **`advanceExternallyBlocked(bindingId)`**:

1. It applies only to a scope in the queued-idle state. Otherwise it does
   nothing.
2. It probes. If `E` is non-empty, it does nothing and the head keeps
   waiting.
3. If `E` is empty, it runs the existing `advanceDeferred` queue branch. That
   branch dequeues the head in FIFO order, re-checks the routine gate (a
   gated head is recorded `skipped` with the gate reason, its reservation is
   released, and the next head is tried), and starts the first eligible head
   through `start`. Queue-cap and receipt rules are unchanged. A started head
   keeps the admission-gate reservation it took at submit time.
   `releaseQueuedReservation` is called only for heads that do not start,
   exactly as today.

`advanceExternallyBlocked` is called in two places:

- **At the start of `submitReserved`, before any policy decision**, for the
  fire's binding. So when `B` arrives after the manual session has cleared but
  before the periodic re-probe, the queued head `A` starts first. `B` is then
  evaluated against a scope that has an in-process run, and gets the existing
  `queue` outcome (`overlap-queued`, or `overlap-queue-full` at the cap).
  When the manual session is still live, `B` sees the queued-idle state with a
  non-empty `E`. It is not idle by the revised shortcut, so it gets the same
  `queue` or cap outcome. Both calls run synchronously inside one actor turn
  with no suspension between them, so no reentrant submit can interleave.
- **Once per serve-loop iteration** (the existing poll cadence), for every
  scope in the queued-idle state. This starts the head when no new tick
  arrives. No new timer is added. In-process completion keeps calling
  `advanceDeferred` immediately, as today. If a manual session is live at
  that moment, the head is left queued, since the queued-idle state allows it,
  and the next submit or loop iteration retries.

Drain on `--limit` (baseline §6.7) treats a queued-idle scope as not drained,
and is advanced by the same per-iteration call. In this phase it reuses the
serve clock's sleep between re-probes. Shutdown discards queued-idle entries
with `overlap-shutdown-discarded`, unchanged.

The queued-idle state only arises under `queue`. Under `skip`,
`cancelRunning` and `concurrent` nothing is queued while a manual session is
live, so their idle shortcut behaves as before. Without a live manual session
the queue is never non-empty while the scope is idle, so cron-vs-cron
transitions are identical to today's.

Probe failure (store unreadable, lock root error) is fail-open: the fire
behaves as if `E = []`. Telemetry gets `overlap-external-probe-failed:<bindingId>`
through the existing overlap telemetry log. This keeps today's behavior on
error and never blocks cron indefinitely.

Receipts keep their shape. `workflowExecutionId` stays empty for skipped
fires, and the manual session id appears only in the reason, as in
cron-vs-cron.

### 3.3 App manual run busy check

`POST /api/v1/instances/{identity}/runs` request body: the key set must be
`{expectedProfile, expectedRevision, variables}` plus an optional
`allowOverlap: Bool`. Any other key is still `invalid_configured_run`.

Inside the existing `distributedControllerOperations.run` closure, after
approval, environment preparation and revision re-validation, and before
`launchConfiguredWorkflow`, unless `allowOverlap == true`:

1. **In-process launches.** `runtime.launches` entries for the same
   `identity` with status `running` count as busy. `WebWorkflowLaunch` gains
   the launch identity for this purpose. The entry's `sessionId` is used when
   known, otherwise the literal `pending`. This covers a manual launch that has
   not yet allocated its session id.
2. **Store.** Every live session (§3.1, any instance kind) of
   `source.workflowId` in `context.sessionStoreRoot` counts. That includes
   cron runs of the instance's events-serve child.

If busy, the response is HTTP 409 with
`{"error":{"code":"instance_busy","runningSessionId":"<sid|pending>"}}`, the
oldest blocker first: in-process launches, then store sessions by
`createdAt`. Nothing is launched. A successful 202 body is unchanged. Probe
failure is fail-open (launch as today). That matches §3.2 and keeps manual
recovery possible.

Atomicity inside the App: the check and the `runtime.launches[job.id]`
registration happen in the same serialized `distributedControllerOperations`
operation. `launchConfiguredWorkflow` registers the launch synchronously
before it returns. Two concurrent manual requests for one identity therefore
cannot both pass.

`instance_busy` is already a 409 code in the reload contract and in the
instance API for "App shutting down". The run route reuses the same code
because the user asked for it. It is distinguished by `runningSessionId`, and
the shutdown variant keeps its current shape.

### 3.4 CLI `riela instance run`

- New flag `--allow-overlap`. When set, the request includes
  `"allowOverlap": true`. When not set, the key is omitted, so the CLI stays
  wire-compatible with older Apps. An older App rejects the key with
  `invalid_configured_run`, and the docs say so.
- On HTTP 409 `instance_busy`, the CLI exits 1. Stdout is
  `{"error":"instance_busy","sessionId":"<runningSessionId>","exitCode":1}`
  and stderr is `instance_busy`. `RielaAppAPIClient`'s safe-code mapping must
  pass `instance_busy` and surface `runningSessionId`. Other error output is
  unchanged.
- `--wait`, timeouts and polling are unchanged.

### 3.5 Residual window (accepted)

Both checks happen before the session id is allocated. The flock is taken at
id allocation, so a cron fire in the child and a manual request in the App
that both check inside the other's pre-allocation window (bundle resolution,
environment and preflight) can still both start. The window is bounded by
that preflight, typically sub-second. Closing it would need a new
cross-process claim keyed by workflow, which the intake does not require and
which would also have to model `concurrent`. This is documented as a known
limit.

### 3.6 Scope notes

- The overlap unit is *workflow id within one session store*. That is the
  same unit the App executions projection uses (`webExecutions` loads by
  workflow directory and store). Two App instances of the same workflow id in
  the same profile therefore share busy and overlap state. This errs toward
  not overlapping, and `--allow-overlap` bypasses it for manual runs.
- A CLI `riela events serve` outside the App applies the same probe against
  its own session store. A `riela workflow run --instance <named>` of the same
  workflow in that store counts as manual.

## 4. Bug B design

### 4.1 Precondition

`LoopTerminalCorridorSelector` gains one pure function over the same
local-edge graph it already walks (`isLocalLinearEdge`, edges to unknown step
ids ignored):

`acyclicRemainingStepBound(workflow:originStepId:) -> Int?`

- It returns `nil` when a cycle is reachable from `originStepId`. A cycle is
  any strongly connected component of more than one step, or a self-edge,
  among reachable steps. **All** local edges count regardless of label or
  condition, which is conservative.
- Otherwise it returns the number of steps on the longest path from
  `originStepId` (inclusive) to any reachable sink (inclusive). It uses DFS
  with memoization in O(V+E).

`redirectForTerminalReservationIfNeeded` keeps every existing guard
(default-policy state, corridor selection, `!corridor.contains(current)`, and
the reserve window). It adds one condition before redirecting:

```
if let bound = acyclicRemainingStepBound(...), bound <= remainingSteps { return nil }
```

A redirect therefore happens only when a cycle is reachable from the current
step, or when the acyclic longest path exceeds the remaining budget, and only
inside the existing reserve window. The marker shape, payload carry-over and
`maxStepsExceeded` behavior are unchanged.

Fanout, cross-workflow and resume edges already make `select` return `nil`
through `hasReachableDispatchBoundary`, so no reservation happens there today.
The function is not consulted for them, and the call-step path-length concern
does not arise.

### 4.2 Consequences

- With the default budget, an acyclic workflow never redirects. Steps
  executed so far are ancestors of the current step, so
  `bound <= steps.count - visitedSteps <= remainingSteps`.
- Looping workflows are unchanged. For example, `revise` with a self-edge in
  `DefaultLoopGuardTests.testTerminalReservationRedirectsBeforeNonTerminalDispatch`
  returns `nil` from the bound and redirects as before.
- An explicit `--max-steps` smaller than an acyclic longest path keeps today's
  redirect inside the window, so the terminal stage still runs.

## 5. Documentation

- `docs/app-instance-control.md` Run section: document `--allow-overlap`, the
  `instance_busy` refusal with `sessionId`, and that cron overlap policies
  treat live manual runs as running sessions (skip → `overlap-skip` naming the
  manual session; cancelRunning never cancels a manual run; queue waits). Add
  the residual window and the older-App note.
- `README.md` cron overlap paragraph: one sentence noting that live manual
  (named-instance) sessions in the same session store count.
- `design-docs/specs/design-scheduled-overlap-policy.md` and
  `design-loop-engineering-convergence-and-operations.md`: pointer amendments
  to this document (done with this design).

## 6. Verification

Focused tests, run from an arm64 shell
(`arch -arm64 /bin/zsh -lc 'swift test --filter …'`):

| Area | Test |
|---|---|
| Dispatcher, fake probe | idle `skip` with a manual sid ⇒ `skipped`, reason `overlap-skip:<b>:<manualSid>`; `cancelRunning` ⇒ same skip, no cancel; `queue` waits and starts after the probe clears on the next loop re-probe; **FIFO interleaving (DR-001)**: `queue` with `maxQueuedRuns 1`, no dispatcher-owned run, manual live ⇒ submit `A` is `queued`; clear the manual session; submit `B` before any loop re-probe ⇒ `A` starts first (receipt `dispatched`) and `B` gets `overlap-queued:<b>:1` behind in-process `A` (A was dequeued); with the manual session still live, submitting `B` yields `overlap-queue-full:<b>:1` and `A` stays head; a variant whose routine gate is inactive for `A` ⇒ `A` is `skipped` with the routine reason and `B` follows the existing outcome; the admission-gate queued count returns to 0 after drain; `concurrent` cap counts `E`; probe throws ⇒ starts (fail-open). Existing `EventCronOverlap*` tests unchanged and green. |
| Probe helper, temp store | Running root session with the lock held by the test ⇒ live; same session without the lock ⇒ not live; child session ⇒ excluded; default-based vs named-based ⇒ `isManual` false or true. |
| App run route | Busy from an in-memory running launch ⇒ 409 `instance_busy` + `runningSessionId`; busy from a store-live session ⇒ same; `allowOverlap: true` ⇒ 202; unknown extra key ⇒ 400. |
| CLI | 409 `instance_busy` maps to stdout `{"error":"instance_busy","sessionId":…,"exitCode":1}` and exit 1; `--allow-overlap` sends `allowOverlap: true`; no flag ⇒ key absent. |
| Loop reserve | 2-step `check -(labelled)-> remediate`, `maxLoopIterations 1`, default budget 3 ⇒ executions `[check, remediate]`, no `loopGuardOutcome`. A 15-step chain of labelled edges with `maxLoopIterations 1` ⇒ all 15 execute. The existing `testTerminalReservationRedirectsBeforeNonTerminalDispatch` and the other `DefaultLoopGuard*` tests are unchanged and green. Unit test of `acyclicRemainingStepBound` (cycle ⇒ nil, diamond ⇒ longest branch). |

Also: `swift build`, and `swiftlint` on changed files.

## 7. Decisions recorded with defaults (revisit only on user request)

- Q1: Should two App instances of the same workflow id in one profile share
  busy and overlap state? Default: yes (§3.6), the conservative choice.
- Q2: Should `cancelRunning` cancel or wait for a manual run? Default: neither
  cancel nor wait; skip (§3.2), because a manual run is operator intent and
  cross-process cancel is a non-goal.
