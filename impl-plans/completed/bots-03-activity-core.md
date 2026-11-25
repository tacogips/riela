# bots-03-activity-core: reducer, bounded recorder, reads, permission records, runner hook

```json
{
  "planId": "bots-03-activity-core",
  "planPath": "impl-plans/active/bots-03-activity-core.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/BotActivity",
    "Tests/RielaCoreTests/BotActivity",
    "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift",
    "impl-plans/progress/bots-03-activity-core.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner.swift", "intendedEdit": "Only the adapter call site near line 862-884 (pass the request to adapterExecutionContext and wrap the call in the settlement helper). Do not touch DeterministicWorkflowRunRequest (plan 01) or prompt code."},
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift", "intendedEdit": "Only the adapterExecutionContext call near line 180 and the adapter call it guards."},
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift", "intendedEdit": "Only the adapterExecutionContext call near line 85 and the adapter call it guards."},
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift", "intendedEdit": "Only the adapterExecutionContext call near line 54 and the adapter call it guards."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §6.1, §6.3, §6.4, §6.5 (read side), §6.6 (record and wait), §6.7.
Activity updates from adapters become a bounded, replayable event log plus a
state row, written in one transaction. The runner feeds it and settles it.

Current code: `adapterExecutionContext`
(`DeterministicWorkflowRunner+ExecutionEvents.swift:101-145`) builds the
backend-event handler. It is called from four places (see sharedPathNotes).
`recordStepStartedExecution` (`:57-99`) is where a step execution starts.
Plan 01 added `request.activityRecorder`, `request.botContext`,
`AdapterBackendEvent.activity` and
`AdapterExecutionContext.permissionRequestHandler`.

## Non-goals

- No ACP parsing (plan 04). No CLI or GraphQL (plans 11, 12).
- No injection of the recorder into production run paths (plan 11).
- No change to `store.recordStepBackendEventReceipt` or the live ring.

## Changes

### `Sources/RielaCore/BotActivity/ActivityReducer.swift` (new, pure)

`public enum ActivityReducer`:
- `static func apply(_ update: AdapterActivityUpdate, to state: inout ActivityState, executionId: String, at: Date) -> [ActivityEventDraft]`
  where `ActivityEventDraft { kind: ActivityEventKind, payload: JSONObject }`.
- `static func stepStarted(...)`, `static func settle(state: inout ActivityState, reason: ActivitySettleReason, stepStatus: String, at: Date) -> [ActivityEventDraft]`.

Rules (design §6.3, §6.7):
- Tool call: upsert by `toolCallId`. Unknown id creates the call from the
  fields present. A nil field in the update leaves the stored value. Status
  mapping from ACP raw values: `pending`→`pending`, `in_progress`→`inProgress`,
  `completed`→`completed`, `failed`→`failed`; other strings are kept raw.
  `completed`, `failed`, `interrupted` are sticky. Emit one `toolCall` event
  only when a stored field changed.
- At most 200 tool calls in state; drop the oldest terminal ones first; never
  drop an open one.
- `plan`: replace that plan's entries; keep plan order by first appearance.
  `planRemoved`: remove it. Entry status mapping `in_progress`→`inProgress`.
- `message` / `thought`: not emitted by the reducer per chunk; the recorder
  coalesces (below). The reducer keeps `lastMessageLine` (first line of the
  latest flushed message, at most 200 characters).
- `reportedModel` sets `state.reportedModel` and emits nothing.
- Any update other than step events sets `state.source = "acp"`.
- `stop` sets `lastStop`.
- `settle`: open tool calls → `interrupted`; plan entries not `completed` →
  `abandoned`; subagents whose state is not `completed`/`failed`/`cancelled`
  → `interrupted`; emits `stepFinished` then one `settled` event with
  `reason` and `closed { toolCalls, planEntries, subagents, permissionRequests }`.
  The request count is supplied by the recorder. A state already settled for
  this execution (`currentExecutionId` cleared) yields no events.

### `Sources/RielaCore/BotActivity/SQLiteWorkflowActivityRecorder.swift` (new)

`public actor SQLiteWorkflowActivityRecorder: WorkflowActivityRecording`,
`public init(sessionStoreRoot: String, limits: ActivityLimits = .default, sleep: @escaping @Sendable (UInt64) async -> Void = default)`.
`ActivityLimits`: `maxEventsPerSession = 2000`, `maxPayloadBytes = 8192`,
`textFlushBytes = 4096`, `textFlushIntervalMs = 1000`,
`requestPollIntervalMs = 500`.

- Every write is one `BotStore.write` transaction: load state row, apply the
  reducer, insert events with `seq = last_seq + 1...`, upsert the state row
  (`last_seq`, `first_retained_seq`, `source`), trim: delete rows with
  `seq <= last_seq - maxEventsPerSession` and set `first_retained_seq`.
- Text coalescing: keep one open buffer per session and kind. A chunk is
  flushed (one `message` or `thought` event) when the buffer reaches
  `textFlushBytes`, when the chunk arrives at least `textFlushIntervalMs`
  after the last flush, before any non-text event, and at settle
  (`final: true` on the last message flush). `replace: true` replaces the
  buffer for that message id. Time comes from the `at` argument only.
- Payload text longer than `maxPayloadBytes` is cut on a UTF-8 boundary and
  `truncated: true` is added.
- `requestPermission`: insert an `activity_requests` row (`request_id` =
  `"req-" + UUID`, status `pending`, `expires_at = min(at + waitMs, deadline)`),
  record `permissionRequested`, then poll the row every
  `requestPollIntervalMs` through the injected `sleep` until status is not
  `pending`, the expiry passed, or `Task.isCancelled`. Then, in one
  transaction, set the final status if still pending (`cancelled`,
  `resolved_by` = `timeout`, or `policy` when `waitMs == 0`, or `settlement`
  when cancelled by the task), record `permissionResolved`, and return the
  outcome. `waitMs == 0` resolves without sleeping. Any thrown store error
  returns `.cancelled`.
- `settle`: flush text, mark this execution's pending requests `cancelled`
  with `resolved_by = settlement` (emitting `permissionResolved` for each),
  apply reducer settle. Idempotent.
- Every method catches errors, logs once per session to stderr with the
  prefix `riela activity recorder:` and returns; it never throws.

### `Sources/RielaCore/BotActivity/ActivityStore.swift` (new)

`extension BotStore` (read and answer side, used by plans 10–12):
- `activityPage(sessionId:afterSequence:limit:) throws -> ActivityPage`
  with `ActivityPage { events, state: ActivityState?, lastSequence, firstRetainedSequence, truncated, activitySource }`;
  `limit` clamped to 1...500; `truncated = afterSequence + 1 < firstRetainedSequence`;
  a session with no rows returns an empty page with source `session`.
- `activityStates(sessionIds:) throws -> [String: ActivityState]`
- `pendingActivityRequests(sessionIds:) throws -> [ActivityRequestRecord]`
- `answerActivityRequest(requestId:optionId:decline:now:) throws -> ActivityRequestRecord`:
  one conditional `UPDATE ... WHERE request_id = ? AND status = 'pending'`.
  Errors: `request_not_found`; `request_expired` when `now >= expires_at` or
  status `cancelled`; `request_already_resolved` when status `answered`;
  `request_option_unknown` when `optionId` is not in `options_json`.
  `decline: true` stores status `answered` with a nil option (outcome
  cancelled, `resolved_by = user`). Exactly one of `optionId` / `decline`.
- `settleOpenActivity(sessionId:reason:at:) throws -> Bool`: settles whatever
  is open for the session (used by reconcilers for `processExit`); false when
  nothing was open.
- `deleteActivity(sessionIds:in db:) throws` for retention (plan 11 calls it).
- `static func waitForActivity(store:sessionId:afterSequence:waitMs:pollMs:sleep:isStillAuthorized:) async throws -> ActivityPage`:
  returns as soon as `last_seq > afterSequence`, or the state shows no
  `currentExecutionId` (settled), or `waitMs` (clamped 0...25_000) elapsed, or
  `isStillAuthorized()` returns false (then throws `activity_wait_revoked`).

### Runner hook (existing files)

- `adapterExecutionContext(...)` gains a `request: DeterministicWorkflowRunRequest`
  parameter. When `request.activityRecorder` is non-nil:
  - after the existing receipt write, if `backendEvent.activity` is non-nil,
    call `recorder.record(sessionId:executionId:update:at:)` with the receipt
    time (`receipt.at ?? Date()`);
  - set `permissionRequestHandler` to a closure calling
    `recorder.requestPermission(... waitMs: request.botContext?.permissionWaitMs ?? 0, deadline: deadline)`.
  With no recorder the context is built exactly as today.
- `recordStepStartedExecution` gains `requestedModel: String? = nil` and
  `recorder: (any WorkflowActivityRecording)? = nil`; when set it calls
  `recorder.stepStarted` after the execution is recorded. Call sites in the
  four files pass `request.activityRecorder` and the node payload model where
  a payload is in scope.
- New helper in `+ExecutionEvents.swift`:
  `func settlingActivity<T>(request:sessionId:executionId:_ body: () async throws -> T) async throws -> T`.
  It runs `body`; on return it settles with `completed`; on throw it settles
  with `cancelled` for `CancellationError` or `Task.isCancelled`, `timeout`
  for an `AdapterExecutionError` whose kind is timeout, `providerError`
  otherwise; then rethrows. Wrap the adapter call at each of the four sites.

## Imitate

- `Sources/RielaCore/RoutineStore.swift` for JSON rows; plan 01 `BotStore.write`.
- `Sources/RielaCore/RuntimeStore.swift:appendRecentBackendEvent` for a
  bounded ring kept beside a counter.

## Pitfalls

- The wait loop must end when the step task is cancelled; check
  `Task.isCancelled` after every sleep and never use an uncancellable sleep.
- Never return `.selected` unless the row says `answered` with a non-nil
  option id that is in the stored options.
- `seq` must be assigned inside the write transaction, not in memory, because
  other processes (answering, reconcile) also append.
- Settlement must run on the throw path too; do not use `defer` with `await`.
- Existing runner tests construct `adapterExecutionContext` indirectly; all
  must pass unchanged with `activityRecorder == nil`.
- Do not persist one event per text chunk.

## Tests (`Tests/RielaCoreTests/BotActivity/`)

`ActivityReducerTests`:
- `toolCall` update for an unknown id → call created with given fields.
- completed then `in_progress` update → status stays `completed`, no event.
- update with only a title → title changes, status kept, one event.
- plan A then plan A with fewer entries → entries replaced.
- two plans → checklist order by first appearance; `planRemoved` drops one.
- 205 tool calls with 5 open → state has 200, all 5 open ones kept.
- settle with 2 open calls, 3 unfinished entries, 1 running subagent →
  statuses `interrupted`/`abandoned`/`interrupted`, counts 2/3/1; second
  settle → no events.

`ActivityRecorderTests` (temporary session store root):
- 10 chunks 100 ms apart → 1 message event after settle with joined text,
  `final: true`.
- chunk, then tool call → message flushed before the tool event (seq order).
- 2,100 structural events → 2,000 rows, `first_retained_seq == 101`, state
  still lists open calls.
- 20 KiB message → payload ≤ 8,192 bytes with `truncated: true`.
- page `afterSequence: 50` on that store → `truncated == true`.
- store root that is a file → recorder methods return without throwing.

`ActivityPermissionTests` (injected sleep):
- answer with a listed option during the wait → `.selected(optionId)`,
  events `permissionRequested` then `permissionResolved(user)`.
- decline → `.cancelled`, `resolvedBy user`.
- unknown option → `request_option_unknown`, row still pending.
- second answer → `request_already_resolved`.
- no answer until expiry → `.cancelled`, `resolvedBy timeout`.
- `waitMs: 0` → `.cancelled`, `resolvedBy policy`, zero sleeps.
- task cancelled during the wait → `.cancelled`, `resolvedBy settlement`.
- answer after expiry → `request_expired`.

`ActivitySettlementRunnerTests` (runner with an in-memory store, a fake
adapter that emits activity updates, and the SQLite recorder):
- adapter returns normally with nothing open → `settled` with zero counts.
- adapter throws a provider error with an open tool call → call
  `interrupted`, reason `providerError`.
- run cancelled mid-step → reason `cancelled`.
- deadline exceeded → reason `timeout`.
- `settleOpenActivity(reason: .processExit)` on a store left open → settled;
  second call returns false.
- the same workflow with `activityRecorder == nil` → no `activity_*` rows and
  the same step result.

`ActivityWaitTests`: wait returns on a new event; returns at timeout with an
empty page; throws `activity_wait_revoked` when the authorisation closure
turns false.

## Verification

```
mkdir -p tmp/bots-overview/bots-03-activity-core
arch -arm64 /bin/zsh -lc 'swift test --filter "ActivityReducerTests|ActivityRecorderTests|ActivityPermissionTests|ActivitySettlementRunnerTests|ActivityWaitTests|DeterministicWorkflowRunnerTests"' > tmp/bots-overview/bots-03-activity-core/test.log 2>&1
```

Exit 0. Evidence: the five new suites pass and the existing runner suite is
unchanged (no behaviour change without a recorder).

## Done criteria

- `grep -rn "settlingActivity" Sources/RielaCore` shows the helper and four call sites.
- `grep -rn "Date()" Sources/RielaCore/BotActivity/ActivityReducer.swift` prints nothing.
- Verification exits 0; progress log written.
