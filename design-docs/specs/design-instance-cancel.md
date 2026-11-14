# Cancel one running RielaApp instance execution: `riela instance cancel`

Status: proposed 2026-11-11 on branch `feat/instance-cancel`. No GitHub issue;
the operator request (2026-11-11, ART hourly duplicates stopped by hand with
`kill -TERM`) in the workflow input is the source of truth.

Baselines this design extends without changing their decisions:

- `design-instance-reload-run-cli.md`: endpoint/profile discovery (D1), identity
  normalization (D3), the `/reload` and `/runs` routes (D4), CLI conventions
  (D5) and the executions projection (D6). `cancel` reuses all of them.
- `design-cancellation-and-orphan-session-resilience.md` §"2026-10-24 Contract":
  first-class `cancelled` session/step status written through the single
  `markSessionFailed` choke point when `failureKind == .cancelled`, and the
  flock-based `riela session reconcile` for orphans.
- `design-scheduled-overlap-policy.md` behavior as implemented in
  `Sources/RielaCLI/EventCronOverlapDispatcher.swift` (per-binding `running`
  run handles, `cancelRunning`, queue advance in `finish`).

## 1. Goal and non-goals

An operator cancels exactly one running execution of a resident App instance,
through the App control plane, without restarting RielaApp:

```
riela instance cancel <identity> [--session <sessionId>] --reason <text>
    [--wait] [--timeout-seconds N] [--server URL] [--profile P] [--cwd DIR]
```

The in-flight step's adapter task is cancelled, the command node's whole
process tree is terminated (SIGTERM, then SIGKILL after a grace period). That
includes descendants in other process groups, such as the command groups of a
nested `riela workflow run`, and is guaranteed before the adapter returns (C8).
The session ends
`cancelled` with the reason and actor recorded, and the run's slot (cron overlap
scope, admission gate, App launch slot) is released. Other executions of the
same instance keep running.

Non-goals: cancelling sessions not owned by a live runner of this App (orphans
stay with `riela session reconcile`), cancelling plain `riela workflow run`
processes, a GraphQL surface, a `riela serve` host route, changing
`LocalProcess` spawn flags, changing the normal-exit or deadline-timeout paths
of `LocalProcess`, changing the `await-owner` policy, any change to the
reload/run/executions request or response shapes, and Web console UI.

## 2. Verified current state (base `c6e127b6`)

| Fact | Evidence |
| --- | --- |
| A resident instance's event and cron runs execute **in-process** inside the instance's child `riela events serve` process. Every live run passes one choke point, `DefaultEventLiveServer.runEventWorkflow` (admission gate admit/release, then `workflowRunner.runWorkflow`), whose production runner calls `WorkflowRunCommand.run` and observes `session_started` through `request.onSessionStarted` | `Sources/RielaCLI/EventReadOnly.swift:27-48`, `EventLiveServe.swift:1020-1060` (`CLIEventWorkflowRunner`) |
| Cron runs are tracked per binding in `CronOverlapDispatcher.scopes[binding].running` (`RunHandle{receiptId, task, sessionId, cancelCause}`); the slot is released only in `finish`, called after the run task returns. `cancelCause == nil` and no result → receipt `failed` + `recordWorkflowDispatchFailure` | `EventCronOverlapDispatcher.swift:113-121, 349-424` |
| Non-cron runs (webhook, chat, file-change, Matrix, Slack, Discord) call `runEventWorkflow` inline from their source loops; there is no session→task registry for them | `EventLiveServe+*.swift` callers of `runEventWorkflow` |
| App-process manual runs (`POST /instances/{id}/runs`) execute in the App as `runtime.launchTasks[launchId] = Task.detached { WorkflowRunCommand.run }`; `WebWorkflowLaunch` records the `sessionId` from the JSONL stream; a launch counts against the 4-running cap until `finish` | `Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift:15-79`, `WebWorkflowLaunch.swift` |
| The parent→child private channel (`--runtime-environment-channel`) already multiplexes environment frames and admission frames. The child decodes control frames first (`WorkflowServeAdmissionFrame.decodeControlLine`), otherwise treats the line as an environment frame; an undecodable environment frame is rejected without state change. The parent correlates admission acks by `requestId` in `admissionAcknowledgements` | `Sources/RielaCLI/RuntimeEnvironmentChannel.swift:204-238`, `Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift:475-505, 563-581`, `Sources/RielaServer/WorkflowServeAdmission.swift` |
| The App may spawn the child from `RIELA_APP_RIELA_EXECUTABLE`, the bundled sibling `riela`, or `/usr/bin/env riela`, so a child older than the App is possible | `DaemonWorkflowEventServeProcess.swift:220-236` |
| `LocalProcess` spawns every command with `POSIX_SPAWN_SETPGROUP` + `setpgroup(0)`, so **each** command, including each command of a nested `riela`, leads its own new group. On Task cancellation it sends SIGTERM to the owned group only and schedules SIGKILL to that group 1 s later. **As soon as the leader exits**, the exit observer calls `killGroupOrProcess()` and SIGKILLs the remaining group at once, in the cancellation path too. The adapter returns `CancellationError` only after the leader exited, output reached EOF and the group was reaped. A node may opt into `cancellationPolicy: await-owner` (SIGTERM to the leader only) | `Sources/RielaAdapters/LocalProcess.swift:413-423, 476-583, 653-669, 804-827`, `Sources/RielaCore/WorkflowProcessCancellation.swift` |
| A nested `riela` CLI handles SIGTERM cooperatively. Signals are set to `SIG_IGN` and delivered via `DispatchSourceSignal`, which cancels the run task. Its own `LocalProcess` then terminates its inner command groups (SIGTERM, SIGKILL after 1 s, reap), and the runner finalizes the nested session before the process exits. That cleanup needs roughly 1 s plus finalization, and nothing in the outer adapter waits for it | `Sources/RielaCLI/EntryPoint.swift:55-76`, `Sources/RielaCLI/CLISignalCancellation.swift:4-17` |
| Counterexample (source-derived): outer wrapper `python3 art.py` (group G1) → nested `riela workflow run` (G1) → inner command (own group G2). On cancel, G1 gets SIGTERM, python exits at once, and the leader-exit path SIGKILLs G1, including the nested `riela`, before it finished cleaning up G2. G2 is reparented to launchd and survives. The group mechanism alone therefore does **not** terminate the tree | `LocalProcess.swift:804-813` combined with the two rows above |
| Run cancellation finalizes through `finalizeInterruptedSessionFailed`: `CancellationError` → `failureKind .cancelled`, reason `"workflow run cancelled"`; `markSessionFailed` persists `status = .cancelled` and moves running step executions to `.cancelled`. `request.cancellationCause` can only override the failure **kind** | `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:9-105`, `DeterministicWorkflowRunner.swift:37`, `RuntimeSession.swift` |
| `GET /api/v1/instances/{id}/executions[/{sessionId}]` is served by the shared projection from the profile session store (by workflow directory). It answers any path it does not own with 404 `not_found`; a 7-segment `.../executions/{sid}/cancel` path is not owned by any route today | `Sources/RielaAppSupport/RielaWebAPIProjection.swift:100-150`, `RielaWebAPIRouteTable.swift:55-115` |
| The executions list is bounded: `loadSessionSummaries(workflowId:limit: 101)`, at most 100 items returned, newest first. It cannot establish how many runs are live: an older running session can be beyond the bound, and orphans can read `running` | `Sources/RielaAppSupport/RielaWebAPIProjection.swift:117-157`, `Sources/RielaViewer/WorkflowViewer.swift:313-333` |
| `/reload` runs inside `distributedControllerOperations.run` and checks the `x-riela-profile` header first | `Sources/RielaApp/RielaAppInstanceReloadAPI.swift:14-38` |

Consequences. The work is:

- (a) address one live run by `sessionId` in each of the two owners: App launch
  tasks, and the instance's events-serve child;
- (b) enumerate the live runs of both owners, so a request without `--session`
  is decided from live state instead of history;
- (c) carry the operator reason into the session's terminal record;
- (d) make the cron receipt say `cancelled` instead of `failed`;
- (e) give the `LocalProcess` cancellation path real **tree** cleanup across
  process groups, with no early SIGKILL on leader exit (C8).

## 3. Decisions

### C1. Status: reuse `cancelled`, encode reason and actor in `failureReason`

The session ends `status = cancelled`, `failureKind = cancelled` (existing
values, no store schema change). `failureReason` is the stable string

```
operator_cancelled by <actor>: <reason>
```

with `<actor>` = `rielaapp-api:<profile>` (the App cannot authenticate a human
identity beyond the CSRF-holding local client of that profile). The running
step execution gets the same `failureReason` through the existing
`markSessionFailed` rule. Child sessions of fanout/cross-workflow steps are
cancelled by Task propagation and keep the generic `"workflow run cancelled"`
reason; the root session carries the operator reason.

Plumbing (additive, one optional field each):

- `DeterministicWorkflowRunRequest.cancellationReason: (@Sendable () -> String?)?`
  (default nil). In `finalizeInterruptedSessionFailed`, when the error is a
  cancellation and no handover trigger cause applies, a non-nil
  `cancellationReason()` replaces `"workflow run cancelled"` as
  `failureReason`; the kind stays `.cancelled`. The handover trigger path is
  unchanged and keeps precedence.
- `WorkflowRunCommand.operatorCancellationReason: (@Sendable () -> String?)?`,
  passed into the request (same pattern as `sessionStartedObserver`).
- `OperatorCancellation` (RielaCore, small lock-protected `Sendable` box):
  `request(reason:actor:) -> Bool` (first caller wins, returns false when
  already requested) and `reason: String?`. The runner reads it only through
  the closure above.

The cancel path never writes the session store itself. The runner remains the
only terminal writer, so there is exactly one finalization (see C6).

### C2. Live-run registry per owner (keyed by `sessionId`)

`LiveSessionCancelRegistry` (RielaCLI, lock-protected class, not an actor, so
registration happens synchronously inside `onSessionStarted`):

- `register(sessionId:, cancellation: OperatorCancellation, cancel: @Sendable () -> Void)`
- `unregister(sessionId:)`
- `requestCancel(sessionId:, reason:, actor:) -> .cancelRequested | .alreadyRequested | .notFound`
  — sets the box, then calls `cancel()`. All three under one lock, so a run
  that unregisters concurrently either sees the cancel or returns `.notFound`.
- `beginRun()` / `endRun()`: count of **in-flight** runs. It is incremented
  before the run starts and decremented after it returns, under the same lock.
- `liveSnapshot() -> (sessionIds: [String], pendingRunCount: Int)`, where
  `pendingRunCount = inFlight − registered`: runs admitted but not yet at
  `session_started`. Taken under the lock. This is the **complete** live
  inventory of the owner. It never reads session history.

Two owners use it:

1. **events-serve child.** `runEventWorkflow` creates an `OperatorCancellation`
   per run, calls `beginRun()` right after admission (`endRun()` in the same
   `defer` that unregisters), and runs `workflowRunner.runWorkflow` inside an
   unstructured child
   `Task` (inherits task-locals such as `CLIRuntimeEnvironment.$captured`),
   wrapped in `withTaskCancellationHandler` so the **outer** task's
   cancellation (cron `cancelRunning`, serve shutdown) is forwarded to the child
   exactly as today. `request.onSessionStarted` is wrapped to `register` the
   session with `cancel = { childTask.cancel() }` before calling the original
   observer. The entry is unregistered when the child task returns (success or
   throw), before admission `release()`. If the box was requested and the run
   threw, `runEventWorkflow` throws `EventOperatorCancelled(sessionId)`
   (description `operator_cancelled`) instead of the runner's error. The box is
   passed to `CLIEventWorkflowRunner` through a new optional
   `EventWorkflowRunRequest.operatorCancellation` field and set as
   `WorkflowRunCommand.operatorCancellationReason`. The registry exists only
   when the child has the runtime-environment channel (App-managed); plain
   `events serve` behavior is unchanged.
2. **App process (manual runs).** `RielaWebWorkflowRequestHandler.runtime` gets
   one `LiveSessionCancelRegistry` **per instance identity**, so the snapshot
   is identity-scoped. `launchConfiguredWorkflow` calls `beginRun()` when it
   creates the launch task and `endRun()` after `job.finish`. It creates the box,
   records the launch's instance `identity` on `WebWorkflowLaunch` (internal
   field, not serialized into the launch snapshot), registers the session when
   `WebWorkflowLaunch.append` first sees `sessionId` (cancel =
   `launchTasks[id]?.cancel()`), and unregisters in the task after
   `job.finish(result)`. Launch snapshot `status` stays `failed` for a
   cancelled manual run (no new launch status, so `instance run --wait`
   polling is unchanged); the session store says `cancelled`.

### C3. Child wire frames (extend the existing private channel)

New frame types on `--runtime-environment-channel`, defined next to the
admission types in `Sources/RielaServer/WorkflowServeAdmission.swift` (new
structs, existing admission structs untouched):

- Parent→child `{"type":"session-cancel","requestId":"…","sessionId":"…","reason":"…","actor":"…"}`
- Child→parent `{"type":"session-cancel-ack","requestId":"…","sessionId":"…","outcome":"cancelRequested|alreadyRequested|notFound"}`
- Parent→child `{"type":"session-list","requestId":"…"}`
- Child→parent `{"type":"session-list-ack","requestId":"…","sessionIds":["…"],"pendingRunCount":0}`

Child: `RuntimeEnvironmentChannel` decodes `session-cancel` and `session-list`
before the environment fallback. It answers from the registry at once, without
waiting on any run: `requestCancel`, or `liveSnapshot`. The child serves only
its own instance, so its snapshot is identity-scoped by construction. A child
without a registry answers `notFound`, or an empty list. Frame ≤ 1 MiB as for
admission frames; `reason` ≤ 512 UTF-8 bytes (validated by the App first).

Parent: `appendOutput` decodes `session-cancel-ack` and `session-list-ack`
lines into a separate `sessionControlAcknowledgements[requestId]` map, bounded
at 64 like admission.
`DaemonWorkflowEventServeProcess.sessionControl(_:)` reuses the
`frameWriteInProgress` claim + `writeFrame` + bounded poll of
`admissionControl`, with the same 5 s timeout. Errors: no channel →
`unsupported`; child exited → `childExited`; no ack → `noAcknowledgement`.
`RielaAppDaemonWorkflowRuntime.sessionControl(identity:frame:)` routes it
by runtime identity like `admissionControl`. An older child (from
`/usr/bin/env riela`) rejects the unknown line as an invalid environment frame
without state change, so the parent times out → `cancel_unavailable` (C4).

### C4. App route `POST /api/v1/instances/{identity}/executions/{sessionId}/cancel`

Registered in `RielaWebAPIRouteTable.desktopOnly` (one appended entry,
owner `Sources/RielaApp/RielaAppInstanceCancelAPI.swift`, marker
`parts[6] == "cancel"`). Dispatched before the shared projection so the
projection's 7-segment 404 is not reached. Router-level Host/Origin/CSRF/
content-type guards apply unchanged. The handler checks `x-riela-profile ==`
the App's profile first (→ `configuration_conflict`), as `/reload` does, and
runs inside `distributedControllerOperations.run`; during termination shutdown
it returns `instance_busy`.

Request (exact key set, extra/missing keys → 400 `invalid_cancel_request`,
body ≤ 64 KiB):

```json
{"expectedProfile":"default","reason":"duplicate hourly run"}
```

`reason`: trimmed, 1–512 UTF-8 bytes, no NUL. No `expectedRevision`: cancel
does not touch configuration, and a revision guard would only produce spurious
conflicts while configuration changes.

Decision logic lives in a pure `RielaAppInstanceCancelCoordinator`
(`Sources/RielaAppSupport/RielaAppInstanceCancelCoordinator.swift`) over a
ports protocol, separate from the reload coordinator and contract file:

1. `expectedProfile` ≠ App profile → 409 `configuration_conflict`.
2. Instance not in `daemonInstances` → 404 `instance_not_found`.
3. **App-process owner:** `launchRegistry.requestCancel` restricted to launches
   whose recorded identity equals the instance identity. Found → 202, owner
   `app`.
4. **Child owner:** if the instance child is running, send `session-cancel`.
   `cancelRequested`/`alreadyRequested` → 202, owner `eventServe`. Channel
   errors (`unsupported`, `noAcknowledgement`, `childExited`) are remembered
   and step 5 still runs.
5. **No live owner:** load the session from the profile session store with the
   same lookup as `GET .../executions/{sessionId}` (`webExecutionDetail`:
   `WorkflowViewerLoader.loadBounded` with `selectedSessionId`; membership =
   the instance's workflow directory):
   - absent or not a member → 404 `session_not_found`;
   - terminal (`completed|failed|cancelled`) → 409 `not_running`;
   - non-terminal and a channel error was remembered in step 4 → 409
     `cancel_unavailable`;
   - non-terminal otherwise → 409 `session_not_owned` (no live runner of this
     App owns it: an orphan, or a run in its first milliseconds before
     `session_started` registration; message suggests retry or
     `riela session reconcile`).

Response `202`:

```json
{"identity":"configuration-…","profile":"default","sessionId":"art-session-42",
 "owner":"app|eventServe","outcome":"cancelRequested|alreadyRequested"}
```

Errors use the existing envelope `{"error":{"code","message"}}` with message
through `WorkflowWebProjectionPolicy().safeSummary`. Closed code set
(`RielaAppInstanceCancelCode`): `invalid_cancel_request` 400,
`instance_not_found` 404, `session_not_found` 404, `configuration_conflict` 409,
`not_running` 409, `session_not_owned` 409, `cancel_unavailable` 409,
`instance_busy` 409. The no-session route below adds `no_running_execution`
409 and `ambiguous_running_sessions` 409. The operator `reason` is never echoed
in responses or telemetry.

### C4b. App route `POST /api/v1/instances/{identity}/cancel` (no session id)

This is a second desktop-only entry in the route table (marker
`parts[4] == "cancel"`, 5 segments). It has the same guards, the same body
`{expectedProfile, reason}` and the same serialization as C4. It decides from
**live owner inventories only**, never from the bounded executions history (§2):

1. Profile and instance checks as in C4 steps 1–2.
2. App inventory: `liveSnapshot()` of the instance's launch registry.
3. Child inventory: if the instance child is running, send `session-list`.
   A channel error → 409 `cancel_unavailable`, and nothing is cancelled. An
   unknown child state cannot prove "exactly one".
4. Let `ids` be the union of both inventories' `sessionIds`, and `pending` the
   sum of their `pendingRunCount`.
   - `ids` empty and `pending == 0` → 409 `no_running_execution`.
   - `ids.count + pending > 1` → 409 `ambiguous_running_sessions` with body
     `{"error":{…},"sessionIds":[…],"pendingRunCount":n}`. **No cancel frame
     or task cancel is sent.**
   - `ids.count == 0 && pending == 1` → 409 `session_not_owned`: the run has not
     started its session yet; retry.
   - Exactly one id and `pending == 0` → cancel it through C4 steps 3–4 for
     that id (owner-specific `requestCancel`), and return the C4 202 body.
     `notFound` at that point means the run finished in between → 409
     `not_running`.

Orphan sessions (store says `running`, no live owner) are not running
executions. They are not counted here, and they stay with
`riela session reconcile`. A run that starts after the inventory was taken is
not affected: the cancel targets one specific id. One telemetry log `riela.instance.cancel` with attributes
`instance.identity`, `session.id`, `owner`, `outcome|error_code`.

### C5. Slot release and receipts

- **Cron:** `CronOverlapDispatcher` gains `CancelCause.operatorCancelled`. In
  `finish`, when `result == nil`, `handle.cancelCause == nil` and the error is
  `EventOperatorCancelled` (passed as a new `operatorCancelled: Bool` alongside
  `admissionClosed`), the receipt becomes `cancelled` with reason
  `operator-cancelled:<bindingId>:<sessionId>` (new `CronOverlapReason`
  helper), and `recordWorkflowDispatchFailure` is skipped. The slot is removed
  and `advanceDeferred` runs exactly as for any finished run, so a queued fire
  starts and the `skip` check no longer sees the run. If a `cancelRunning`
  supersede or shutdown already set `cancelCause`, that cause wins (unchanged
  receipts).
- **Admission gate:** released by the existing `release()` in
  `runEventWorkflow` (both paths), so a later reload handoff sees `running`
  decrease.
- **Non-cron sources:** keep their existing error handling; the thrown error
  description is `operator_cancelled`.
- **App launch:** `job.finish(result)` flips the launch out of `running`,
  freeing the 4-run cap.
- **Executions/overlap views:** both derive from the above (store status
  `cancelled`, dispatcher scope emptied), so nothing else is written.

### C6. Races

- *Cancel vs. natural completion.* The registry lock serializes
  `requestCancel` and `unregister`. If unregister wins → step 5 → `not_running`.
  If cancel wins but the runner already passed its last cancellation check, the
  session completes normally; the 202 was truthful ("requested"), and
  `--wait` reports the real terminal status with `cancel_not_effective`. The
  runner stays the only terminal writer, so a session is finalized once. The
  implementer verifies with a test that a cancel requested after the runner
  recorded `completed` does not produce a second terminal write (if it does,
  the fix belongs in the runner's terminal path, not in the cancel path).
- *Double cancel* → `alreadyRequested`, no second signal.
- *Concurrent executions of the same instance*: each run has its own child
  `Task`, box and registry entry; cancel touches only the matched entry.
- *Cancel while a reload barrier is closed*: independent; frames are
  serialized by `frameWriteInProgress` and cancel does not touch the gate.

### C7. CLI `riela instance cancel`

Added as a fourth action in `Sources/RielaCLI/InstanceAppCommands.swift`
(`["reload","run","executions","cancel"]`), with subcommand help in the
existing help table. Same discovery, `--server`/`--profile`/`--cwd`, identity
check (`instance_not_found` before any request unless `--server`),
bootstrap→CSRF, JSON-on-stdout and exit codes (0/1/2) as reload/run.

- `--reason` required (1–512 bytes after trimming) → else usage
  `instance_reason_required`.
- `--session` given → POST cancel for that id (percent-encoded with
  `.alphanumerics`).
- `--session` absent → `POST /api/v1/instances/{id}/cancel` (C4b). The CLI does
  **not** read `GET .../executions` to choose a session. `no_running_execution`
  → exit 1. `ambiguous_running_sessions` → exit 1, with stdout
  `{"error":"ambiguous_running_sessions","exitCode":1,"sessionIds":[…],"pendingRunCount":n}`.
- Old App / non-desktop host: on either route, a 404 or 405 whose code is not
  `instance_not_found` or `session_not_found` → `app_cancel_unsupported`
  ("upgrade RielaApp once"). This is pinned by a fixture of the current
  projection's 404 `not_found` body. The existing `executions` listing is
  unchanged.
- `--wait`: poll `GET .../executions/{sessionId}` every 1 s until status is
  `completed|failed|cancelled`, bounded by `--timeout-seconds` (default 60,
  range 1–86400; only valid with `--wait`, else usage `instance_invalid_options`).
  Final `cancelled` → exit 0. Other terminal status → exit 1
  `cancel_not_effective` (body printed). Timeout → exit 1
  `cancel_wait_timeout` (body printed with last status). A terminal session
  implies the command's tracked process tree is gone: the adapter returns only
  after C8 step 5.
- Output (closed fields):
  `{"identity","profile","sessionId","owner","outcome","status"}`, `status`
  is the last observed session status with `--wait`, else `null`.
- Server codes from C4 pass through when safe-code shaped.

### C8. Process **tree** termination on cancellation (narrow LocalProcess change)

Group ownership is not tree ownership (§2 counterexample). The change is
limited to the `LocalProcess` **Task-cancellation path** under the default
`terminateGroup` policy. These stay unchanged: spawn flags, normal exit
(immediate SIGKILL of the remaining owned group), the deadline-timeout path,
and `await-owner`.

New internal `LocalProcessTree`, in `Sources/RielaAdapters/LocalProcessTree.swift`:

- `snapshot() -> [ProcessEntry(pid, ppid, pgid, startTime)]` for all
  processes. Darwin: `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL])` →
  `kinfo_proc` (`kp_proc.p_pid`, `kp_eproc.e_ppid`, `kp_eproc.e_pgid`,
  `kp_proc.p_starttime`). Linux: `/proc/<pid>/stat` fields 4 (ppid),
  5 (pgrp) and 22 (starttime).
- `descendants(of roots:, in:)`: the transitive ppid closure.

Cancellation sequence in `LocalProcessHandle` / `cancelConfiguredProcess`:

1. **Track.** While the leader is still unreaped (its pid is pinned by the
   existing `WNOWAIT` design), take a snapshot. The tracked set `T` is every
   descendant of the leader, in any process group, keyed by
   `(pid, startTime)`.
2. **SIGTERM.** Send SIGTERM to the owned group (existing), and send
   `kill(pid, SIGTERM)` to every tracked pid outside that group whose current
   `startTime` still matches.
3. **Grace with tracking (5 s, constant `cancellationGraceSeconds`).** Every
   100 ms: re-snapshot. Add new descendants of any still-alive tracked
   process, so lineage is kept while its parent lives, and SIGTERM them.
   Drop tracked entries that are gone. **During cancellation, leader exit no
   longer triggers the immediate `killGroupOrProcess()`.** The leader-exit
   observer checks `completion.cancelled()` and leaves escalation to this loop.
   A nested `riela`, which handles SIGTERM cooperatively (§2), therefore gets
   the full grace to stop its own command groups and finalize its nested
   session. The grace ends early when `T` is empty.
4. **SIGKILL.** After the grace: SIGKILL the owned group and every tracked pid
   that is still alive with a matching `startTime`. Repeat snapshot and kill
   every 100 ms until `T` is empty, bounded by a further 5 s.
5. **Return.** Run the existing `reapAfterOutput` and resume with
   `CancellationError`. The adapter, and so the runner's terminal write, the
   cron `finish` and the slot release, happen only after step 5. If `T` is
   still non-empty at the hard bound (only possible for processes stuck in
   uninterruptible sleep), the adapter still returns `CancellationError` and
   emits the safe code `process_tree_survivors` with a count in a telemetry
   log. It does not hang the cancel.

Safety: only pids observed as descendants of this invocation's leader are
signalled, each one re-verified by `startTime` just before the signal, so a
reused pid is not hit. Group signals go only to the owned group (pinned by the
unreaped leader). The nested `riela` and its inner commands use the same code,
so each level reclaims its own tree, and the outer level's tracking covers any
level that is SIGKILLed.

Behavior change, stated explicitly: every Task cancellation of a command node
now gives the tree up to 5 s to exit instead of 1 s. Operator cancel, CLI
SIGINT/SIGTERM and cron `cancelRunning` are all affected. Processes that exit
on SIGTERM see no difference.

Agent nodes run in-process through the gateway libraries and stop through Task
cancellation; their behavior is unchanged.

### C9. Docs

`docs/app-instance-control.md`: a "Cancel" section (command, flags, without
`--session` rule decided from live owners, `--wait` semantics, output example),
both routes (C4, C4b), the cancellation tree behavior and 5 s grace (C8), a
"Cancel error codes" table (C4/C4b codes + CLI codes `app_cancel_unsupported`,
`no_running_execution`, `ambiguous_running_sessions`, `cancel_wait_timeout`,
`cancel_not_effective`, `instance_reason_required`), and the note that a
cancelled manual run's launch status reads `failed` while the session reads
`cancelled`. Update the intro sentence to list `cancel`. One-time App upgrade
prerequisite applies (old App → `app_cancel_unsupported`).

## 4. Security

- No new listener; loopback-only App listener with existing Host/Origin/CSRF
  guards, profile header and `expectedProfile`.
- The route can cancel only sessions owned by a live runner of the named
  instance (identity-scoped launch lookup; the child serves only its instance).
  The route itself never signals PIDs. Termination goes through Task
  cancellation and the adapter's C8 sequence, which signals only the owned
  group and pids observed as descendants of its own leader, each re-verified
  by start time.
- Reason text is stored in the session record only; not echoed or exported to
  telemetry. Frames carry no environment values.

## 5. Verification

Focused tests (temp stores, fake processes, no live App):

- `RielaAdaptersTests` (`LocalProcessCancellationTreeTests`). Every fixture
  writes pids to a temp dir, waits for a ready file (bounded 10 s) before
  cancelling, and in `tearDown` SIGKILLs every recorded pid:
  - *same group*: `/bin/sh` with a background grandchild `sleep 300`. Cancel →
    `CancellationError`, and leader and grandchild are `ESRCH` **at the moment
    the call returns**.
  - *separate group + early leader exit*: the leader is
    `sh -c 'trap "exit 0" TERM; set -m; sh -c "trap \"\" TERM; echo \$\$ > g2; sleep 300" & wait'`
    (`set -m` puts the inner shell in its own group, which ignores SIGTERM).
    Cancel → the leader exits at once, and the inner process is gone at return
    (killed by step 4). This test fails on the current code (the inner process
    survives).
  - *leader exit does not preempt cooperative cleanup*: the inner group
    process traps TERM, sleeps 2 s, writes `cleaned`, then exits. The leader
    exits at once on TERM. Assert `cleaned` exists at return, which fails today
    because of the immediate leader-exit SIGKILL.
  - *pid-reuse guard*: unit test of `LocalProcessTree` with a fake snapshot
    source. A tracked `(pid, startTime)` whose start time changed is not
    signalled.
  - *unchanged paths*: the normal-exit background-child test and the deadline
    test (`LocalProcessForegroundLifetimeTests`) stay green unchanged.
- `RielaCLITests` nested-Riela regression (`InstanceCancelNestedTreeTests`). It
  locates the built `riela` like `PrivateWorkflowTests.swift:768-771`, and uses
  temp workflow and session-store roots.
  - The outer temp workflow has one command node: a wrapper
    `sh -c 'trap "exit 0" TERM; "$RIELA" workflow run inner --workflow-definition-dir … --session-store … & wait'`.
  - The inner workflow's command node, which nested `LocalProcess` puts in
    another group, writes its pid and a ready file, traps TERM to `sleep 1;
    exit`, and otherwise sleeps 300 s.
  - Two outer runs, A and B, start concurrently through
    `runEventWorkflow` + `CLIEventWorkflowRunner` with the registry.
  - After both ready files exist, cancel A by session id. Assert:
    - A's root session is `cancelled` with the operator reason;
    - at the moment A's run returns, A's wrapper, nested `riela` and inner
      command pids are all `ESRCH`, so the tree is gone **before** the
      terminal session is observable;
    - A's nested session in the temp store is terminal (`cancelled`);
    - B's inner pid is still alive and B's session is still `running`.
  - Then B is cancelled and cleaned up. Bounded at 60 s; tearDown SIGKILLs
    every recorded pid.
- `RielaCoreTests`: `finalizeInterruptedSessionFailed` with
  `cancellationReason` → `status cancelled`, `failureKind cancelled`,
  `failureReason` = the operator string, running step `cancelled`; without it →
  unchanged `"workflow run cancelled"`; handover trigger precedence unchanged;
  cancel requested after completion → single `completed` terminal record.
- `RielaCLITests`:
  - `LiveSessionCancelRegistry`: requested, already and notFound outcomes. An
    unregister racing a cancel returns either `.notFound` or cancels.
    `liveSnapshot` counts a run that has begun but not registered as
    `pendingRunCount`.
  - `runEventWorkflow` with a fake runner that blocks until cancelled: two
    concurrent runs, cancel one by sessionId → that one throws
    `EventOperatorCancelled`, the other completes; outer task cancellation
    still reaches the inner run; admission `release()` called for both.
  - `CronOverlapDispatcher`: operator-cancelled run → receipt `cancelled`
    reason `operator-cancelled:<binding>:<sid>`, no dispatch-failure record,
    scope emptied, queued fire starts; `skip` policy admits the next fire.
  - `RuntimeEnvironmentChannel`: a `session-cancel` frame gets an ack with the
    outcome; an unknown session gives `notFound`; without a registry the ack
    is `notFound`. A `session-list` frame gets an ack with ids and
    `pendingRunCount`.
  - `instance cancel` with an injected transport:
    - request path, headers and exact body keys for both routes;
    - `--session` absent posts to `/instances/{id}/cancel` and **never** calls
      `GET .../executions`;
    - `no_running_execution` and `ambiguous_running_sessions` (with
      `sessionIds`) map to exit 1;
    - 404 `not_found` maps to `app_cancel_unsupported` for both routes; `--wait` → cancelled (exit 0), completed
    (`cancel_not_effective`), timeout (`cancel_wait_timeout`); missing
    `--reason`; `--timeout-seconds` without `--wait`.
  - One mock end-to-end: a command-node workflow run through
    `CLIEventWorkflowRunner` with `operatorCancellationReason`, cancelled
    mid-step → session `cancelled` with the operator reason.
- `RielaAppSupportTests`: route table contains the cancel route as
  desktop-only; `RielaAppInstanceCancelCoordinator` with fake ports covers
  every C4 branch (app owner, child owner, already, channel error +
  non-terminal → `cancel_unavailable`, orphan → `session_not_owned`, terminal →
  `not_running`, unknown/foreign → `session_not_found`, profile mismatch);
  strict body decode; parent-side `session-cancel-ack` / `session-list-ack`
  parsing alongside admission acks.
- `RielaAppSupportTests`, C4b history-boundary cases. The fake store holds the
  sessions; the fake owners hold the live inventories:
  - running session A, followed by 100 newer terminal sessions, so
    `GET executions` omits A; A is live in the child → C4b cancels A (202);
  - running A, 99 newer terminal sessions, then running B, with A live in the
    child and B live in the App → `ambiguous_running_sessions` with both ids,
    and **zero** cancel calls recorded on either owner;
  - one live id plus one pending run → ambiguous, no cancel;
  - zero live and zero pending (the store has an orphan `running`) →
    `no_running_execution`;
  - a child `session-list` timeout → `cancel_unavailable`, no cancel;
  - `GET executions` output is byte-identical before and after (shape
    unchanged).
- Unchanged: existing reload/run/executions and overlap dispatcher tests stay
  green.

Commands (each via `arch -arm64 /bin/zsh -lc` from the worktree root):

- `swift build`
- `swift test --filter LocalProcess` (includes `LocalProcessCancellationTreeTests`
  and the unchanged `LocalProcessForegroundLifetimeTests`)
- `swift build --product riela`, then `swift test --filter InstanceCancelNestedTreeTests`
- `swift test --filter RielaCoreTests.DeterministicWorkflowRunner` (cancellation subset)
- `swift test --filter RielaCLITests.InstanceApp`, `--filter CronOverlap`,
  `--filter RuntimeEnvironmentChannel`, `--filter LiveSessionCancel`
- `swift test --filter RielaAppSupportTests`
- `swiftlint lint` on changed files

Each command's exit status and complete log go under `tmp/instance-cancel/`
(for example `tmp/instance-cancel/swift-test-localprocess.log`).

## 6. Rollout and merge constraints

- Additive only: two new route entries, new frame types, new optional fields
  and a new CLI action. Reload/run/executions shapes are unchanged. The one
  behavior change outside the new surfaces is C8: the cancellation-path grace
  goes from 1 s to 5 s, with tree tracking, in `LocalProcess.swift` and the new
  `LocalProcessTree.swift`.
- `fix/manual-overlap-terminal-reserve` touches the run route and overlap
  handling. Shared-file edits are limited to: two appended `desktopOnly` route
  entries; the action list and a new `cancel` function in
  `InstanceAppCommands.swift`; in `EventCronOverlapDispatcher.swift` one
  `CancelCause` case, one `CronOverlapReason` helper and one `finish` branch.
- Requires the one-time App upgrade (same as reload). Children launched from a
  non-bundled older `riela` answer no ack → `cancel_unavailable`; restarting
  the instance on the upgraded binary fixes it.

## 7. Risks and residual limits

- Tree tracking is snapshot-based. A process that forks and whose parent dies
  within the same 100 ms scan interval is reparented to launchd before it is
  observed. That window is bounded by the scan interval. Nested `riela` and
  ordinary wrappers are covered (tests in §5), and a process that daemonizes
  on purpose is outside the "foreign command" contract in the
  `FoundationLocalProcessRunner` doc comment (`LocalProcess.swift:704-707`).
- Processes in uninterruptible sleep can outlive the hard bound. They are
  reported as `process_tree_survivors` and do not block the cancel.
- The longer cancellation grace (5 s instead of 1 s) delays Ctrl-C and
  `cancelRunning` for commands that ignore SIGTERM. Existing tests that assume
  1 s must be checked during implementation.
- A cancel that lands after the runner's last cancellation point yields a
  completed session; `--wait` reports it as `cancel_not_effective`.
- A run that has not reached `session_started` counts as pending. The
  no-session route reports `ambiguous_running_sessions`, or `session_not_owned`
  when it is the only one; a retry succeeds.
- Process-spawning tests can leak processes. Every fixture records its pids,
  bounds its waits and SIGKILLs the recorded pids in tearDown.

## 8. Post-merge integration with main (`4841a578` merged as `8ab7f848`)

Main added the manual-run busy check (`design-manual-run-overlap-and-terminal-reserve.md`
§3.1–§3.4: `LiveRootSessionProbe`, HTTP 409 `instance_busy` unless
`allowOverlap`) and the terminal-reserve precondition. Three focused test areas
fail on the merge commit. This section records the verified root cause and the
fix boundary for each one. It does not change C1–C9 or main's busy semantics.

### 8.1 Concurrent same-identity launches vs. `instance_busy`

Verified: `launchConfiguredWorkflow(... allowOverlap: Bool = false)`
(`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`) treats any
`running` in-process launch with the same identity as busy, and so does
`LiveRootSessionProbe` (created/running root session that holds its flock).
`ConfiguredLaunchCancelTests.testConfiguredLaunchCancellationIsIdentityAndSessionScoped`
starts two launches for identity `one` without `allowOverlap`. The 409 on the
second launch is main's intended behavior, not a cancel defect.

Decisions:

- The test needs two concurrent executions, so the **second** launch passes
  `allowOverlap: true`. The first launch keeps the default, which keeps the
  first launch and the 202 assertion unchanged. Every existing cancel
  assertion stays as it is.
- The test adds busy-semantics assertions:
  1. While both are running, a third launch without `allowOverlap` returns 409
     `instance_busy`, and `runningSessionId` is the oldest blocker.
  2. **Post-cancel liveness agreement.** After both sessions are cancelled and
     the store reports `cancelled` for both, a launch for identity `one`
     without `allowOverlap` returns 202. "After cancel" is defined as the
     point where `instance cancel --wait` returns success, which is store
     session status `cancelled` (`InstanceAppCommands.cancel`). The assertion
     is made at that point, with no extra wait for launch-task teardown.
- **Required code fix (DR-01).** The busy check has two sources (§3.3
  rule 1: in-process launch `status == running`; rule 2: store probe). The
  source order is confirmed:
  1. `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
     persists the terminal `cancelled` status before its awaited
     completion-event work and before the command returns.
  2. Only then does `job.finish`
     (`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`)
     update the launch snapshot.
  3. `instance cancel --wait` already returns as soon as the store reads
     `cancelled` (`Sources/RielaCLI/InstanceAppCommands.swift`).

  In that window, rule 1 refuses a same-identity launch with 409 for a
  session the store calls terminal, which breaks the accepted criterion. The
  fix is therefore required. It does not depend on whether a polling test
  happens to hit the window.

  Rule 1 is narrowed. An in-process `running` launch does not count as busy
  when its `sessionId` is known **and** its persisted root session is
  terminal (`cancelled`/`completed`/`failed`, read through the same read-only
  store access the probe uses). This applies the §3.1 item 3 status
  predicate to rule 1. It is not a new semantic.

  These still block, unchanged:
  - launches with no session id yet (`pending`);
  - launches whose persisted session is `created`/`running`;
  - launches whose persisted status cannot be read (store read error or
    missing record). This is fail-closed for in-process launches. Rule 2
    stays fail-open as main defined it;
  - all rule 2 (store probe) blockers.
- **Required deterministic regression coverage.** A test in
  `ConfiguredLaunchCancelTests` sets up the window state directly instead of
  relying on timing.
  - Setup: an in-process launch registered for identity `one` with a snapshot
    of `status: running` and a known `sessionId`. That root session is
    persisted as `cancelled` in the temp store, with no live flock.
  - Expected: a request for `one` without `allowOverlap` returns 202 when no
    other blocker exists.

  Companion cases in the same suite show that the check still returns 409
  `instance_busy` for:
  - a running launch with no session id (`runningSessionId: "pending"`);
  - a running launch whose persisted session is `running` or `created`.

  The test must fail before the correction and pass after it. The
  two-live-launch overlap assertions (assertion 1) and every existing
  cancellation assertion stay as they are. Assertion 2 is kept as an
  end-to-end check, but it is not what justifies the fix.
- Unchanged: `allowOverlap` wire shape, `--allow-overlap`, the 409 body, the
  CLI `{error:instance_busy,sessionId,exitCode:1}` mapping, the cron overlap
  probe, and the docs in `docs/app-instance-control.md`.

### 8.2 `TaskCancellationIntegrationTests` selected-host stop proof

Verified root cause: the regression comes from this branch, not from main.
`git diff 293527c8 8ab7f848` touches only
`DeterministicWorkflowRunner+LoopPolicy.swift` and `LoopTerminalCorridor.swift`
under `Sources/RielaCore`, and touches nothing under `Sources/RielaAdapters`,
`Sources/RielaWork` or `Sources/RielaServer`. The fixture
(`TaskCancellationIntegrationTests+Fixtures.swift`,
`assertSelectedHostCancellation`) runs a leader and a child that both do
`trap '' TERM`, then waits at most **4 s** (`proofDeadline`) for the worker's
executor to throw after Task cancellation. Before C8, `LocalProcess` sent
SIGKILL 1 s after SIGTERM. C8 (`LocalProcessHandle.waitForCancellation`,
`cancellationGrace: TimeInterval = 5` in `Sources/RielaAdapters/LocalProcess.swift`)
deliberately keeps the leader alive for the full 5 s grace when it ignores
SIGTERM. The executor therefore throws after more than 5 s, and the 4 s wait
expires first. The task then stays `running` because the test never reaches
the stop-gate release.

Decision: keep C8's 5 s grace. It is documented user-facing behavior
(`docs/app-instance-control.md` Cancel section: "SIGKILL after a 5-second
grace period … up to 5 seconds instead of 1 second"), and the accepted scope
requires the documented cancel behavior to stay unchanged. §7 already lists
"Existing tests that assume 1 s must be checked". The fix is a test-intent
correction, not an assertion change. The fixture's wait bound for the delayed
stop receipt becomes the cancellation grace + hard bound + a scheduling
margin. For example, a constant tied to the 5 s defaults (≥ 12 s). The bound
stays in the same loop and still fails with "Worker did not reach its delayed
stop receipt". Every assertion stays as it is: stop-gate paused, pending
unacknowledged cancellation, job `cancelled` with `stoppedAt == nil`, no stop
proof after worker loss, a single lease, both processes stopped, and durable
`stoppedAt`. Plan rule: the implementer first confirms the hypothesis by
running the test at `293527c8` (expected to fail the same way) and at
`8ab7f848` with a temporarily raised wait (expected to pass). If either check
contradicts the hypothesis, they stop and report instead of applying the
change. `LocalProcess` code changes are out of scope unless that check
exposes a real defect, such as the executor never throwing or the tree
surviving past grace + hard bound.

### 8.3 Definition-store schema generation

Verified: the current runtime store generation is 12.
`SQLiteSchemaMigration(fromGeneration: 11)` calls
`SQLiteRuntimeExecutionRowsSchema.migrateToGeneration12`
(`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift`).
It was introduced on purpose by
`design-docs/specs/design-session-storage-efficiency-and-default-gc.md` §3.2
("generation 12, additive DDL only"). It does not come from the stale-definition
design, and it already exists at `c6e127b6`. `WorkflowDefinitionStoreTests`
predates it and still asserts `user_version == "11"`. Neither the migration
nor the definition schema is broken: generation 12 adds only payload-ref DDL.

Decision: update the tests rather than the code. Rename
`testFreshStoreCreatesDefinitionSchemaAtGenerationEleven` to
`...AtCurrentGeneration` and assert `user_version` against the store's
current-generation constant, or the literal `"12"` if no constant is visible
to the test. Make the same change for both stamps in
`testGenerationNineMigratesInPlaceAndKeepsSession`, so the 9 → current
migration path, including 11 → 12, stays covered. The definition-table and
session-survival assertions stay as they are. No user-DB-affecting change.

### 8.4 Verification and integration

Logs and exit statuses go under `tmp/instance-cancel-integration/`. All
commands run in `arch -arm64 /bin/zsh -lc`.

- `swift build`.
- `swift test --filter 'ConfiguredLaunchCancelTests|TaskCancellationIntegrationTests|WorkflowDefinitionStoreTests'`,
  then the selected-host test repeated at least 3 times (timing check).
- `swift test --filter 'Instance|Cancel|Overlap|TerminalReserv|LiveRootSession|LoopPolicy|DefinitionStore|WallClock'`:
  0 unexpected failures.
- `swiftlint` on changed files.
- Integration: re-fetch `origin/main` immediately before integrating. If it
  moved past `4841a578`, merge it again and re-run the focused filter.
  Fast-forward `main` to the verified branch tip (no rewrite) and push `main`
  and `feat/instance-cancel`. Never use bare `git stash`.
