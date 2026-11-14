# Scheduled Workflow Overlap Policy

Status: design for implementation on `feat/schedule-overlap-policy`
(baseline `main` @ `3e6d4adf`). No GitHub issue; intake was derived from the
`opus-luna-design-and-implement-review-loop` workflow input
(`workflowExecutionId opus-luna-design-and-implement-review-loop-session-471`).

Related designs:

- `design-docs/specs/event-listener-workflow-trigger/provider-source-types.md`
  (cron source)
- `design-docs/routine-management.md` (routine gate, `recordRunCompletion`)
- `design-docs/specs/design-cancellation-and-orphan-session-resilience.md`
  (cancellation path reused by `cancelRunning`)

## 1. Problem (verified at `3e6d4adf`)

- `DefaultEventLiveServer.servePrepared`
  (`Sources/RielaCLI/EventLiveServe.swift`, repeat loop around l.192-320)
  awaits `dispatchCronTick` inline. `dispatchCronTick`
  (`Sources/RielaCLI/EventLiveServe+Cron.swift:6`) awaits `runEventWorkflow`
  (`Sources/RielaCLI/EventReadOnly.swift:27`) once per matched binding, one
  after another. A long cron run therefore blocks every other source in the
  process: other cron sources, webhooky, file-change and the chat gateways.
- `CronScheduleSource.dueTick` (`EventLiveServe+Cron.swift:180`) returns only
  the latest match in `(lastCheckedAt, now]`. Ticks missed while the loop was
  blocked are silently merged into one fire after the run.
- Live cron dispatch writes no event receipt. It only overwrites
  `serve-record.json`, so `riela events list` never shows cron fires.
- Routine runs pass `RoutineDispatchGate` before the run and call
  `RoutineStore.recordRunCompletion` (`Sources/RielaCore/RoutineStore.swift:253`)
  with `try?` after an inline run.
- `EventWorkflowRunning.runWorkflow` returns only after the run reaches a
  terminal state. The serve loop cannot learn the session id of an in-flight
  run.
- No overlap policy exists anywhere in `Sources`. The only related mechanism is
  `workflow.loop.concurrency` (`LoopConcurrencyDeclaration`). It is a
  cross-process lease that is checked inside `riela workflow run` and that a
  busy lease turns into `loop_concurrency_skipped`. It is orthogonal to this
  design (see §10).

## 2. Goals and non-goals

Goals:

- One deterministic, recorded and inspectable overlap policy for cron-fired
  workflow runs. It has exactly four values: `skip` (default), `cancelRunning`,
  `queue` and `concurrent`.
- The policy can be set on the workflow definition, overridden on the event
  binding, and set by routines through the CLI and GraphQL.
- Cron runs execute as tracked in-flight tasks. A long cron run never blocks
  the serve loop.

Non-goals:

- Overlap policy for non-cron sources (webhooky, file-change, telegram,
  discord, slack, matrix). Those dispatch paths stay inline and unchanged. The
  acceptance requirement only says that they must not be blocked *by cron*,
  and making cron non-blocking satisfies it (§6.1). Chat dispatch keeps its
  current coupling of replies, dedupe and offsets to inline completion.
- Cross-process overlap control. Two `riela events serve` processes on the
  same event root do not share overlap state. `workflow.loop.concurrency`
  remains the cross-process guard.
- Persisting the queue. Queue entries are in memory only (§6.7).
- A new `WorkflowSessionStatus.cancelled` case (§8.3).
- Builtin routine add-ons (`riela/routine-create`, ...) gain no new config
  keys in this iteration.

## 3. Policy values and semantics

| Value | Meaning when a fire arrives while a run of the same overlap scope is in flight |
|---|---|
| `skip` (default) | First wins. The fire starts no run. It is recorded as skipped with reason `overlap-skip:<bindingId>:<runningSessionId>`. The first fire after the in-flight run ends dispatches normally. |
| `cancelRunning` | Last wins. Every in-flight run of the scope is cancelled through the runtime cancellation path (§8). The new fire waits, with a bound, for those runs to settle and then starts. The cancelled session ids are recorded on both sides. |
| `queue` | The fire is appended to a FIFO queue of at most `maxQueuedRuns` entries (default `1`). When the in-flight run ends, the head of the queue starts. A fire that finds the queue full is dropped (drop-newest) and recorded. |
| `concurrent` | The fire starts at once, in parallel. If `maxConcurrentRuns` is set and that many runs are already in flight, the fire is dropped (drop-newest) and recorded. Without `maxConcurrentRuns` there is no cap. |

When nothing is in flight for the scope, every policy starts the run at once.

Only these four values are valid. No alias, no `none`, no `inherit` value.
Leaving the field out means inherit (§4.3).

## 4. Configuration surface

### 4.1 Event binding (`.riela-events/bindings/*.json` or `events.json`)

New optional top-level fields on `EventBindingContract`
(`Sources/RielaEvents/EventContracts.swift`, next to `routineId`):

```json
{
  "id": "nightly-report",
  "sourceId": "every-10-minutes",
  "workflowName": "report",
  "inputMapping": { "mode": "template", "template": {} },
  "overlapPolicy": "queue",
  "maxQueuedRuns": 2
}
```

| Field | JSON type | Notes |
|---|---|---|
| `overlapPolicy` | string | One of `skip`, `cancelRunning`, `queue`, `concurrent`. Decoded as a raw string so that unknown values become validator diagnostics, not decode failures. This follows the `LoopConcurrencyDeclaration.onBusy` precedent. |
| `maxQueuedRuns` | integer ≥ 1 | Allowed only together with `"overlapPolicy": "queue"` on the same binding. |
| `maxConcurrentRuns` | integer ≥ 1 | Allowed only together with `"overlapPolicy": "concurrent"` on the same binding. |

The encoder omits all three fields when they are nil, so existing binding files
round-trip byte-stable through `RoutineService`.

### 4.2 Workflow definition (`workflow.json`)

New optional top-level object `triggerDefaults` on `WorkflowDefinition`
(`Sources/RielaCore/WorkflowModel.swift`). It must also flow through
`AuthoredWorkflowJSON`:

```json
{
  "workflowId": "report",
  "triggerDefaults": { "overlapPolicy": "skip" }
}
```

`triggerDefaults` accepts the same three keys with the same types and pairing
rules as §4.1. It applies only to event-triggered dispatch in
`riela events serve`. Manual `riela workflow run`, GraphQL runs and
cross-workflow calls ignore it. A dedicated object, rather than adding the
keys to `defaults`, makes that scope clear: `defaults` holds node and run
runtime defaults that apply to every run.

### 4.3 Resolution (binding > workflow > default)

The effective policy is resolved per binding:

1. If the binding sets `overlapPolicy`, the binding layer wins (source
   `binding`).
2. Otherwise, if the bound workflow's `triggerDefaults.overlapPolicy` is set,
   the workflow layer wins (source `workflow`).
3. Otherwise the policy is `skip` (source `default`).

`maxQueuedRuns` and `maxConcurrentRuns` come only from the layer that won. A
cap set on a losing layer is ignored. A missing cap on the winning layer
falls back to the default: `maxQueuedRuns = 1`, no concurrency cap. Because
the pairing rules in §4.1 forbid caps that do not match the same layer's
policy, a resolved cap always belongs to its policy.

Resolution timing: the policy is resolved once per enabled cron binding at
`events serve` startup. Event config is also loaded only at startup, so the
two stay consistent. Workflow definitions are loaded through the same
resolution inputs `CLIEventWorkflowRunner` uses: scope,
`--workflow-definition-dir` and the working directory. They are loaded through
an injectable resolver seam (`EventWorkflowTriggerDefaultsResolving`), so
tests do not touch registries. If the workflow cannot be resolved at startup,
the binding resolves to `skip` (source `default`). The serve record then gets
diagnostic code `overlap_policy_workflow_unresolved` for that binding, and
serve does not fail. The run itself will surface the resolution error when it
fires, as it does today.

Implementation home: a small value type in `RielaCore` (for example
`Sources/RielaCore/EventOverlapPolicy.swift`). It holds the enum with
`allValues`, the settings struct, the effective-policy struct
`{policy, source, maxQueuedRuns, maxConcurrentRuns}` and the pure resolver
function. It lives in `RielaCore` because `RielaEvents`, `RoutineRecord` and
`WorkflowDefinition` all need it, and `RielaEvents` already depends on
`RielaCore`.

### 4.4 Backward compatibility

Configs and workflows without the fields keep validating and resolve to
`skip`. There are no shims and no deprecated aliases.

Intended behavior change: before this change, a long run blocked the loop and
the missed ticks were merged into one fire after the run. That was in effect
a one-slot queue. Under the default `skip`, fires that overlap a running run
are now skipped and recorded, and the next tick after completion fires
normally. Operators who want the old catch-up behavior set
`"overlapPolicy": "queue"`.

## 5. Validation

### 5.1 `riela events validate` (`EventContractValidator`)

New diagnostic code: `INVALID_EVENT_OVERLAP_POLICY`. The messages below are
exact, with `<i>` = binding index and `<v>` = the authored value.

| Condition | path | message |
|---|---|---|
| unknown value | `bindings[<i>].overlapPolicy` | `overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got '<v>'` |
| source kind is not `cron` (and the source is known) | `bindings[<i>].overlapPolicy` | `overlapPolicy is only supported on bindings whose source kind is cron` |
| `maxQueuedRuns` < 1 | `bindings[<i>].maxQueuedRuns` | `maxQueuedRuns must be an integer >= 1` |
| `maxQueuedRuns` without `overlapPolicy: queue` | `bindings[<i>].maxQueuedRuns` | `maxQueuedRuns requires overlapPolicy queue on the same binding` |
| `maxConcurrentRuns` < 1 | `bindings[<i>].maxConcurrentRuns` | `maxConcurrentRuns must be an integer >= 1` |
| `maxConcurrentRuns` without `overlapPolicy: concurrent` | `bindings[<i>].maxConcurrentRuns` | `maxConcurrentRuns requires overlapPolicy concurrent on the same binding` |

The caps are decoded as `Int`, like other typed binding fields. A non-integer
JSON value therefore fails config decoding, which is the existing behavior for
typed binding fields. The value range and pairing rules are validator
diagnostics.

The source-kind rule also applies to `maxQueuedRuns` and `maxConcurrentRuns`
when they are set on a non-cron binding, through the pairing rule (they need
`overlapPolicy`, which is itself rejected). `RoutineService` already calls
`EventContractValidator.validate` with a cron source, so routine-created
bindings get the same checks.

When validation succeeds, `events validate` adds one record per enabled cron
binding: `binding=<id> overlapPolicy=<value|inherit>`. `inherit` here is only
a display token for "not set on the binding". It is not an accepted value.

### 5.2 `riela workflow validate` (`validateRawAuthoredWorkflow`)

Raw validation runs before typed decode
(`Sources/RielaCore/WorkflowValidation.swift`, `validateAuthoredWorkflowData`),
so these checks fire even for values that would not decode. All have severity
`error`.

| Condition | path | message |
|---|---|---|
| not an object | `workflow.triggerDefaults` | `must be an object when provided` |
| unknown key `<k>` | `workflow.triggerDefaults.<k>` | `is not a supported triggerDefaults field` |
| unknown value | `workflow.triggerDefaults.overlapPolicy` | `must be one of skip, cancelRunning, queue, concurrent` |
| non-integer or < 1 cap | `workflow.triggerDefaults.maxQueuedRuns` / `.maxConcurrentRuns` | `must be an integer >= 1` |
| cap without matching policy | `workflow.triggerDefaults.maxQueuedRuns` | `requires workflow.triggerDefaults.overlapPolicy queue` |
| cap without matching policy | `workflow.triggerDefaults.maxConcurrentRuns` | `requires workflow.triggerDefaults.overlapPolicy concurrent` |

## 6. Serve-loop dispatch model

### 6.1 Non-blocking cron dispatch

`dispatchCronTick` no longer awaits `runEventWorkflow`. It evaluates dry-run
matching, read-only handling and the routine gate exactly as today. For each
matched binding that has a `workflowName`, it submits a *fire* to a new
`CronOverlapDispatcher` actor (in `RielaCLI`, owned by one `servePrepared`
invocation) and returns at once. The dispatcher applies the binding's
effective policy. Each run it starts is an unstructured `Task` whose handle it
keeps, so it can cancel and await the run. Unstructured tasks inherit the task
locals (`CLIRuntimeEnvironment.$captured`). `runEventWorkflow` already
re-scopes the environment for every call.

Other sources keep inline dispatch. They are no longer blocked by cron runs.
An inline chat or file-change run can still delay the *evaluation* of cron
ticks. §6.3 covers how missed ticks are handled.

### 6.2 Overlap scope key = binding id

The dispatcher tracks in-flight runs and queues per `bindingId`.
`workflowName` is fixed per binding, so the key is the same as
binding+workflow. Reasons for choosing it over the workflow name across
bindings:

- The effective policy is resolved per binding (§4.3). A key shared by
  workflow name could mix bindings with different policies, for example one
  binding with `queue` and one with `concurrent` for the same workflow, and
  produce an undefined interaction. A per-binding key gives each scope exactly
  one policy.
- Each routine owns exactly one binding (`<routineId>-binding`), so routine
  accounting stays per routine.
- Mutual exclusion across bindings and across processes for one workflow is
  already available through `workflow.loop.concurrency`. This design does not
  duplicate it.

### 6.3 Due-tick evaluation

`CronScheduleSource.dueTick(after:until:)` is replaced by
`dueTicks(after:until:) -> [Date]`. It returns every match in
`(after, until]` in ascending order, still bounded by
`CronSchedule.maximumCatchUpSeconds` (3600 s). Per binding:

- `concurrent`: every due tick is a separate fire, submitted in ascending
  order and each subject to `maxConcurrentRuns`. Ticks never coalesce
  silently.
- `skip`, `queue`, `cancelRunning`: only the latest due tick is submitted.
  Older missed ticks are recorded on that fire's receipt as
  `coalescedTickCount` (an integer, omitted when 0). Coalescing is therefore
  explicit, not silent.

Each tick keeps its envelope identity: `eventId = <sourceId>-<epoch>` and
`dedupeKey = <sourceId>:<epoch>`. Distinct ticks never share a dedupe key.
Receipts are keyed per (tick, binding) (§7.1), so several bindings on one
source never collide.

`processedEvents` (`--limit`) increments by 1 per due tick for which at least
one binding produced an overlap outcome (started, queued, skipped, dropped, or
cancel-pending). That keeps today's rule of one count per dispatching tick. A
tick whose bindings were all stopped by the routine gate still does not count,
as today. Under `concurrent`, every catch-up tick counts on its own.

### 6.4 Dispatcher state and transitions

Per scope key the dispatcher holds:

- `running: [RunHandle]`, where `RunHandle = {receiptId, task, sessionId?,
  scheduledAt, firedAt, cancelRequested}`
- `queue: [PendingFire]` (FIFO, `queue` policy only)
- `pendingAfterCancel: PendingFire?` (`cancelRunning` only)

Transitions:

- **submit, nothing running and nothing pending:** start.
- **skip:** record `skipped` with `overlap-skip:<bindingId>:<sid>`. `<sid>` is
  the session id of the oldest running run, or `pending` if that run has not
  yet emitted `session_started`.
- **concurrent:** start if `maxConcurrentRuns == nil || running.count <
  maxConcurrentRuns`. Otherwise record `skipped` with
  `overlap-concurrency-cap:<bindingId>:<maxConcurrentRuns>`.
- **queue:** if `queue.count < maxQueuedRuns`, append and record `queued`
  with `overlap-queued:<bindingId>:<1-based position>`. Otherwise record
  `skipped` with `overlap-queue-full:<bindingId>:<maxQueuedRuns>`. When a
  run of the scope ends and `queue` is non-empty, the head is dequeued and
  started.
- **cancelRunning:** set `cancelRequested` on every running handle and call
  `task.cancel()`. Store the fire as `pendingAfterCancel`. If a pending fire
  already exists, the newer fire replaces it (last wins) and the replaced fire
  is recorded `skipped` with `overlap-superseded:<bindingId>`. The pending fire
  is recorded `queued` with `overlap-cancel-pending:<bindingId>` until it
  settles. A settle waiter, started when the first fire of a cancel wave
  becomes pending and shared by any superseding fire so the bound is not
  restarted, races "all cancelled handles reached terminal" against
  `clock.sleep(cancelSettleTimeout)`:
  - settled: start the pending fire. Its receipt carries
    `cancelledSessionIds` and reason
    `overlap-cancel-running:<bindingId>:<first cancelled sid|pending>`.
  - timed out: do not start, so the runs never overlap. Record the pending
    fire `skipped` with `overlap-cancel-timeout:<bindingId>:<sid|pending>`
    and write the same reason to the serve record. The unsettled run stays
    tracked and is recorded when it ends. A later fire repeats
    `cancelRunning`; calling `cancel()` again is idempotent.
  - `cancelSettleTimeout` is a constant of 30 seconds, injectable for tests.
    It is not user-configurable.
- **Re-check before a deferred start:** before a queued or
  pending-after-cancel fire starts, the routine gate (§11) is evaluated again.
  If the routine is no longer active, the fire is recorded `skipped` with the
  gate's existing reason (`routine-<status>:<id>`, `routine-missing:<id>`)
  and the next queued entry, if any, is considered.

All state lives in one actor, so the decisions are serialized and
deterministic for a given submit and completion order.

### 6.5 Session id seam

`EventWorkflowRunRequest` gains
`onSessionStarted: (@Sendable (String) -> Void)?`. `CLIEventWorkflowRunner`
forwards it to a new internal `WorkflowRunCommand.sessionStartedObserver`.
The existing `runEventHandler` invokes that observer whenever
`event.type == .sessionStarted && event.workflowId == persistenceBundle.workflow.workflowId`.

The check must not depend on `options.output`. It goes in `runEventHandler`
itself, outside the `if let jsonlRecorder { ... }` block
(`Sources/RielaCLI/WorkflowRunCommand.swift:165`) that holds the
`WorkflowRunContextRecord` check. `jsonlRecorder` is non-nil only for `.jsonl`
output (`WorkflowRunCommand.swift:51`), but `CLIEventWorkflowRunner` always
runs with `output: .json` (`Sources/RielaCLI/EventLiveServe.swift:824`). An
observer placed inside that block would therefore never fire for
event-served runs.

Event-served runs keep `.json` output. No output mode is added or changed.
Fake runners call the callback themselves. The session id stays a runtime-store id: the runtime allocates
it, and the dispatcher only observes it. Nothing in the dispatcher creates or
owns session ids.

### 6.6 Injected clock

`DefaultEventLiveServer` gains `clock: any EventServeClock` (`now() -> Date`,
`sleep(for: Duration) async throws`). The default is the system clock. It is
used for:

- the cron `lastCheckedAt` / `now` bookkeeping
- the idle sleep at the end of each loop iteration
- the cancel settle timeout

Tests inject a manual clock and a fake `EventWorkflowRunning` whose runs
suspend until the test releases them. No serve-loop test uses wall-clock
sleeps.

### 6.7 `--limit` and shutdown

- **`--limit` reached:** polling stops and no new fires are accepted. The
  dispatcher then *drains*: in-flight runs are awaited to terminal, the
  pending-after-cancel fire settles and runs, and queued fires start in FIFO
  order and are awaited. Only then does `servePrepared` record completion and
  return. Every accepted fire therefore reaches a terminal recorded outcome,
  and existing `--limit 1` tests keep their current observable behavior.
- **Signal or error exit:** the serve task is cancelled (`EntryPoint` routes
  SIGINT and SIGTERM to `runTask.cancel()`), or a non-poll error is thrown.
  `servePrepared` catches this and calls `dispatcher.shutdown(.cancel)` inside
  an awaited unstructured `Task { }.value`, so the shutdown is not itself
  pre-cancelled. This is the same pattern
  `finalizeInterruptedSessionFailed` uses. Shutdown:
  1. records every queued fire and the pending-after-cancel fire as receipt
     status `discarded` with `overlap-shutdown-discarded:<bindingId>`
  2. cancels all in-flight runs
  3. awaits them up to `cancelSettleTimeout`
  4. records their outcomes, then rethrows

  Runs still unsettled at that point are left to the existing runtime
  finalizer and orphan handling.
- No queue persistence: queued fires exist only in the serve process. They
  are discarded and recorded on shutdown, and they are not restored on
  restart. This is documented operator-facing behavior.
- Abandoned receipts: after `kill -9`, or a shutdown that outlives its
  bound, cron receipts can be left `queued` or `dispatched`. Every receipt a
  dispatcher writes carries a `serveInstanceId` stamp (`<pid>-<random>`). When
  a dispatcher starts, it closes each binding-scoped receipt in one of those
  states whose stamp names a process that is no longer running (or that has
  no stamp): `queued` becomes `discarded` and `dispatched` becomes `failed`,
  both with `overlap-abandoned:<bindingId>` (plus `:<sessionId|pending>` for
  `dispatched`). Receipts stamped by a live process, including another serve
  on the same event root, are left alone. The sweep does not read the runtime
  store; the runtime session named by `workflowExecutionId` keeps its own
  terminal state through the runtime finalizer and orphan handling.

### 6.8 Concurrency safety of shared records

- **Receipts** for cron fires are written only by the dispatcher actor, which
  serializes them.
- **`serve-record.json`** is a read-modify-write file that both the loop and
  run-completion tasks write. `writeServeRecord` serializes its whole
  read-modify-write behind a process-wide lock. It is a synchronous function,
  so an `NSLock` is enough.
- **The routine store** uses SQLite transactions (`RoutineStore.update`), so
  concurrent `recordRunCompletion` calls cannot lose increments.
- **`processedEvents`** is changed only by the serve-loop task.

## 7. Observability

### 7.1 Event receipts (`riela events list`)

Every cron fire outcome, per (tick, binding), is persisted to
`<eventRoot>/receipts/` through the existing receipt layout:

- `receiptId = "event-cron-" + sha256hex(sourceId + "\0" + eventId + "\0" + bindingId)`.
  This is 75 characters and satisfies `isSafeEventRecordId`.
- `PersistedEventReceipt` gains optional fields, which existing receipts
  decode without:
  - `bindingId`
  - `overlapPolicy`
  - `overlapPolicySource` (`binding` | `workflow` | `default`)
  - `cancelledSessionIds: [String]`
  - `coalescedTickCount`
- `serveInstanceId` (optional) is set on dispatcher-written receipts (§6.7)
  and omitted elsewhere, so older receipts decode unchanged. All receipt
  reads and writes (CLI, read-only ingestion and dispatcher) go through one
  receipt store
  that checks the id and containment and writes the directory 0700 and the
  files 0600.
- Status lifecycle: `queued` → `dispatched` → `completed` | `failed` |
  `cancelled`. A fire can also end as `skipped` or as `discarded`.
  `workflowExecutionId` is set from `onSessionStarted` and updated from the
  final result.
- The `reason` field holds the machine-readable reason string (§7.2). The
  cancelled run's own receipt gets `cancelled` with
  `overlap-cancelled:<bindingId>:<supersedingReceiptId>`, unless the run won
  the race and completed first, in which case its real terminal status is
  recorded. The superseding receipt id is stored on the run when the cancel
  is requested (and moves to the newest fire if a pending fire is
  superseded), so it stays correct when the run ends after a settle timeout.
  A run cancelled only by signal or error shutdown gets
  `overlap-shutdown-cancelled:<bindingId>`.
- A fire the routine gate stops at submit time is recorded `skipped` with the
  gate's reason (`routine-<status>:<id>`, `routine-missing:<id>`,
  `routine-store-error:<id>`), exactly like the deferred-start re-check. It
  still does not count toward `--limit` (§6.3).
- `riela events list` keeps its line format and appends ` reason=<reason>`
  when a reason exists and ` binding=<bindingId>` when a binding id exists.
  The existing `--status` filter works with the new statuses (for example
  `--status skipped`). Receipts are listed newest first (`updatedAt`
  descending, then `receiptId`), so `--limit` returns recent outcomes even
  though cron receipt ids are hashes.
- Retention: a cron writes one receipt per fire and binding (86,400 per day
  for a per-second schedule). `riela gc --retention-days <n>` removes aged
  files under the user and project `.riela/events/receipts` roots only, and
  only when it runs. Receipts under a custom `--event-root` (including a
  routine's `eventRoot`) are not collected.
- `events replay` keeps its semantics for these receipts. A replay of a
  binding-scoped receipt is keyed like a fire,
  `event-cron-` + `sha256hex(sourceId + "\0" + "<eventId>-replay" + "\0" + bindingId)`,
  so replays for several bindings of one tick never overwrite each other, and
  it copies `bindingId`, `overlapPolicy` and `overlapPolicySource`.

Read-only mode is unchanged. It records the read-only receipt and evaluates no
overlap policy. When several ticks are due, it writes one read-only receipt
per due tick that `dueTicks` returns.

### 7.2 Reason vocabulary

All reasons have the form `overlap-<kind>:<bindingId>[:<detail>]`:

| Reason | Detail |
|---|---|
| `overlap-skip:<bindingId>:<runningSessionId\|pending>` | `skip` policy dropped the fire |
| `overlap-concurrency-cap:<bindingId>:<maxConcurrentRuns>` | `concurrent` cap overflow |
| `overlap-queued:<bindingId>:<position>` | queued (receipt only) |
| `overlap-queue-full:<bindingId>:<maxQueuedRuns>` | `queue` overflow (drop newest) |
| `overlap-cancel-running:<bindingId>:<cancelledSessionId\|pending>` | new run started after cancelling |
| `overlap-cancelled:<bindingId>:<supersedingReceiptId>` | run that was cancelled |
| `overlap-cancel-timeout:<bindingId>:<sessionId\|pending>` | settle bound exceeded; new fire not started |
| `overlap-cancel-pending:<bindingId>` | `cancelRunning` fire recorded `queued` while cancelled runs settle |
| `overlap-superseded:<bindingId>` | `cancelRunning` pending fire replaced by a newer fire |
| `overlap-shutdown-discarded:<bindingId>` | queued or pending fire discarded on signal or error shutdown |
| `overlap-shutdown-cancelled:<bindingId>` | in-flight run cancelled by signal or error shutdown (no superseding fire) |
| `overlap-abandoned:<bindingId>[:<sessionId\|pending>]` | receipt left `queued` or `dispatched` by a serve instance that is no longer running, closed at the next serve start (§6.7) |

`skipped` outcomes, overflow outcomes and cancel-timeout outcomes also set
the serve record's `lastIgnoredReason` to the same string. That covers the
intake's `overlap-skip:<bindingId>:<runningSessionId>` example.

### 7.3 Serve record and inspection

- At startup, `serve-record.json` gets
  `overlapPolicies: { "<bindingId>": { "policy", "source", "maxQueuedRuns"?, "maxConcurrentRuns"? } }`
  for every enabled cron binding. This is the effective-policy inspection for
  event bindings.
- `riela workflow inspect`: `WorkflowInspectionSummary` gains `triggerDefaults`
  (JSON). The text output prints the line
  `triggerDefaults: overlapPolicy=<v> [maxQueuedRuns=<n>] [maxConcurrentRuns=<n>]`.
- GraphQL `workflow` already returns the raw `definition` JSON, so
  `triggerDefaults` appears there without an SDL change.
- Routine inspect (CLI) and GraphQL `Routine` expose the binding-level fields
  (§11).
- Telemetry: one log per non-start outcome, `riela.events.cron.overlap`, with
  attributes `binding.id`, `overlap.policy`, `overlap.reason`. Non-start
  outcomes are `skipped`, `discarded`, `queued` (`overlap-queued`),
  cancel-pending (`overlap-cancel-pending`) and startup-abandoned receipts.
  `overlap.reason` carries the finite reason kind (the part before the first
  `:`, for example `overlap-skip` or `routine-disabled`); the binding id is in
  `binding.id` and the full reason with session ids stays on the receipt.
  `RielaTelemetryRedactor` keeps `overlap.policy` and `overlap.reason` values
  only when they are short tokens that do not look secret.

## 8. `cancelRunning` and the existing cancellation path

### 8.1 Path

Cancellation is Swift structured cancellation of the run `Task`. It is the
same path SIGINT and SIGTERM take through `CLISignalCancellation` and
`EntryPoint`:

1. `DeterministicWorkflowRunner` observes `CancellationError`.
2. `finalizeInterruptedSessionFailed`
   (`Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`)
   persists the terminal session in the runtime store.
3. `WorkflowRunCommand` persists the CLI session record in a detached task
   (`WorkflowRunCommand.swift`, `if Task.isCancelled`).
4. `LocalProcess` (`Sources/RielaAdapters/LocalProcess.swift`,
   `withTaskCancellationHandler`) signals the child's process group with
   `SIGKILL`, so no adapter child process outlives the cancellation.

The dispatcher adds no other kill or cleanup mechanism.

### 8.2 Classification

A run's receipt is `cancelled` exactly when the dispatcher requested
cancellation for it and the run did not return a successful result. A run
that completed before the cancellation took effect is recorded `completed`
and counted for its routine.

### 8.3 Terminal status representation

The runtime store's current terminal representation of a cancelled run is
`status: failed`, `failureKind: cancelled` and
`failureReason: "workflow run cancelled"` (`WorkflowSessionFailureKind.cancelled`,
`Sources/RielaCore/RuntimeSession.swift:37`). `WorkflowSessionStatus` has no
`cancelled` case: P1 of the cancellation design is not implemented. This
design reuses the existing runtime-owned representation and adds no new status
case, because a new case is a cross-surface migration outside this scope.
Tests assert `failureKind == .cancelled`. This interpretation of the intake's
"cancelled terminal status" is recorded for user confirmation in
`design-docs/user-qa/qa-scheduled-overlap-policy.md` (Q1).

## 9. Routine integration

- `RoutineCreateRequest` and `RoutineRecord` gain optional `overlapPolicy`
  (String), `maxQueuedRuns` and `maxConcurrentRuns`. They are stored in the
  existing JSONB `record_json`, so there is no schema or generation bump.
  `RoutineService.eventBinding(for:)` copies them onto the binding.
  Validation goes through `EventContractValidator`, which `create` already
  calls.
- New update path `RoutineService.setOverlapPolicy(routineId:overlapPolicy:maxQueuedRuns:maxConcurrentRuns:routineStoreRoot:)`.
  It updates the record and rewrites the binding file from
  `eventBinding(for:)`, keeping the current `enabled` state. `nil` for
  `overlapPolicy` clears the binding override, so the binding inherits the
  workflow layer or the default. A running serve picks up the change at its
  next start, the same as for new routines today.
- CLI:
  - `riela routine create ... [--overlap-policy <v>] [--max-queued-runs <n>] [--max-concurrent-runs <n>]`
  - new action `riela routine set-overlap-policy <routine-id> (--overlap-policy <v> | --clear-overlap-policy) [--max-queued-runs <n>] [--max-concurrent-runs <n>]`
  - `routine inspect` prints `overlapPolicy=<v|inherit>` plus any caps
  - adds `RoutineClientAction.setOverlapPolicy` (`set-overlap-policy`)
- GraphQL:
  - enum `EventOverlapPolicy { skip cancelRunning queue concurrent }`
  - `Routine` gains `overlapPolicy: EventOverlapPolicy`,
    `maxQueuedRuns: Int` and `maxConcurrentRuns: Int` (all nullable)
  - `CreateRoutineInput` gains the same three fields
  - new mutation
    `setRoutineOverlapPolicy(input: SetRoutineOverlapPolicyInput!): RoutineMutationPayload!`
    with input `{routineId, overlapPolicy, maxQueuedRuns, maxConcurrentRuns, routineStoreRoot}`
- SurfaceCatalog gets a row `routine.set-overlap-policy` (CLI
  `routine set-overlap-policy`, GraphQL `setRoutineOverlapPolicy`). The
  committed SDL is regenerated with `scripts/surface-parity/generate-sdl.sh`,
  and the SurfaceParity suites stay green.

## 10. Interaction with `workflow.loop.concurrency`

The overlap policy is evaluated in the serve process before a run starts. The
loop lease is evaluated inside the run. If a workflow declares
`loop.concurrency` (`maxActive: 1`), a second run that `concurrent`,
`queue`, or a timed-out `cancelRunning` lets through can still be refused by
the lease. That refusal surfaces as today's `loop_concurrency_skipped`
dispatch failure and is recorded on the receipt as `failed`. This is
documented, and there is no extra validation.

## 11. Routine accounting

- The routine gate runs at submit time (unchanged) and again before every
  deferred start (§6.4).
- `recordRunCompletion` is called once per run, from that run's completion
  task, only when the run returned a successful `WorkflowRunResult`. That
  matches today's rule: a run that throws is not counted.
- Not counted: skipped fires, dropped fires, discarded fires, cancelled runs,
  failed runs and cancel-timeout fires.
- `recordRunCompletion` changes `lastRunAt` to
  `max(existing lastRunAt, firedAt)`. Concurrent runs that finish out of
  order then cannot move `lastRunAt` backwards. `runCount` increments
  atomically inside the existing SQLite transaction. The error stays
  non-fatal to serve, as today with `try?`.

## 12. Documentation deliverables

- This design.
- `design-docs/specs/event-listener-workflow-trigger/provider-source-types.md`
  cron section: pointer to this design.
- `design-docs/routine-management.md`: surfaces and gate lines updated.
- The `riela-event-sources` and `riela-workflow` skill docs are **not
  tracked in this repository**. `git ls-files '*SKILL.md'` lists only
  `.agents`, `.codex` and `Resources/skills/riela-workflow-{reference,run}`,
  and `.gitignore` excludes `.claude/skills/riela-workflow/` and
  `.codex/skills/riela-workflow/`. The skill-doc text to apply where those
  skills are maintained is in §13. Ownership is recorded as user-QA Q2.

## 13. Skill-doc delta (to apply where the skills are maintained)

`riela-event-sources`, binding fields:

> Cron bindings accept `overlapPolicy` (`skip` default | `cancelRunning` |
> `queue` | `concurrent`) plus `maxQueuedRuns` (queue only, default 1) or
> `maxConcurrentRuns` (concurrent only, default unbounded). Resolution:
> binding > workflow `triggerDefaults` > `skip`. Overlap outcomes appear in
> `riela events list` (`reason=overlap-...`), in `serve-record.json`
> (`lastIgnoredReason`, `overlapPolicies`), and on cron receipts.

`riela-workflow`, workflow fields:

> `triggerDefaults: {overlapPolicy, maxQueuedRuns?, maxConcurrentRuns?}`
> sets the default overlap policy for event-triggered (cron) dispatch of this
> workflow. Event bindings override it. Manual runs ignore it.

## 14. Verification

Focused suites, run from an arm64 shell. Each must report a positive test
count:

- `arch -arm64 /bin/zsh -lc 'swift build'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter "EventOverlapPolicy|WorkflowValidation|RoutineStore"'`
  (RielaCoreTests: resolver precedence, raw validation messages, monotonic
  `lastRunAt`)
- `arch -arm64 /bin/zsh -lc 'swift test --filter "EventContract|EventRoutineBinding"'`
  (RielaEventsTests: §5.1 diagnostics, no-field config stays valid)
- `arch -arm64 /bin/zsh -lc 'swift test --filter "EventLiveServeCron|CronOverlap|EventLiveServe"'`
  (RielaCLITests). Required cases:
  - each policy with a fake runner and a manual clock
  - a long cron run not blocking a second cron source, a file-change source
    and a webhooky source
  - `--limit` drain
  - signal shutdown discarding the queue
  - cancel settle timeout
  - receipts and `events list` reasons
  - routine counting under skip, cancel and concurrent
  - one real `CLIEventWorkflowRunner` cancel test under `cancelRunning`. It
    runs with the production `.json` output. Its command node writes its pid.
    The test asserts:
    - the cancelled session has `failureKind == cancelled`
    - `kill(pid, 0)` fails with `ESRCH`
    - the superseding fire's receipt `cancelledSessionIds` and its
      `overlap-cancel-running:<bindingId>:<sid>` reason contain the actual
      runtime session id, not `pending`, and that id equals the id of the
      session whose `failureKind` is `cancelled`

    It waits on observed events and pid-file presence, never on fixed sleeps.
    This test guards the §6.5 requirement that the observer fires
    independently of output mode.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "RoutineCommand|RoutineGraphQL|SurfaceParity"'`
- SDL regeneration with `scripts/surface-parity/generate-sdl.sh`, followed by
  the `SurfaceParity` filter above.
- Optional smoke check under `tmp/schedule-overlap-policy-20261021-session-471/`:
  - `riela events validate` with an unknown `overlapPolicy` → diagnostic
  - `riela events validate` with no field → ok, with `overlapPolicy=inherit`
  - `riela workflow validate` with an unknown `triggerDefaults.overlapPolicy`
    → diagnostic

Full `swift test` is not a gate.

## 15. Implementation partition guidance (for plan authoring)

The work touches four SwiftPM targets: `RielaCore`, `RielaEvents`,
`RielaCLI`, and `RielaWorkflowRegistry` plus `RielaGraphQL`. A dependency-safe
split:

1. **Model + validation**: the `RielaCore` policy type and resolver,
   `WorkflowDefinition.triggerDefaults` and raw validation, `RoutineRecord`
   fields and monotonic `lastRunAt`, `EventBindingContract` fields and
   `EventContractValidator`. Everything else depends on it.
2. **Serve dispatch**, after 1: in `RielaCLI`, the dispatcher, clock,
   `dueTicks`, session seam, receipts, `writeServeRecord` lock, `--limit` and
   shutdown, the `events validate` records, `events list` suffixes, and
   `workflow inspect` `triggerDefaults`.
3. **Routine surfaces**, after 1: `RoutineService`, the GraphQL DTOs, mutation
   and provider, `RoutineCommands` and `RoutineClientAction`, the
   SurfaceCatalog row and SDL regeneration.

Plans 2 and 3 share the `RielaCLI` target but have disjoint files:
`EventLiveServe*.swift`, `EventReadOnly.swift`, `ScopedParityCommands*.swift`,
`WorkflowRunCommand.swift` and `WorkflowValidateInspectCommands.swift` belong
to plan 2. `RoutineCommands.swift` and `RielaClientFamilyArguments.swift`
belong to plan 3. Shared paths to grant up front:

- `Sources/RielaEvents/EventContracts.swift` and
  `Sources/RielaCore/RoutineStore.swift` (owned by plan 1, read by 2 and 3)
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` and
  `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` (plan 3 only)
