# Bots: Overview, ACP Activity Stream, Model Catalog, Memory Loops and Server Pairing

Status: design for implementation on `feat/bots-overview` (baseline `main` @
`7f04f6e6`, which contains ACP protocol v2 support). No GitHub issue; intake was
derived from the `fable-sol-design-and-implement-review-loop` workflow input
(`workflowExecutionId fable-sol-design-and-implement-review-loop-session-1`).
Open defaults that the user may revisit are in
`design-docs/user-qa/qa-bots-overview.md`; none blocks implementation.

Related designs (baselines that this design reuses and does not restate):

- `design-docs/specs/design-control-surface-parity.md` (SurfaceCatalog, gates,
  D8/D11: console reads live on GraphQL, `/api/v1` console routes are retired)
- `design-docs/specs/design-agent-response-streaming.md` (backend-event path;
  §7 anticipates the cursor-paged read that §6.5 here implements)
- `design-docs/routine-management.md`, `design-scheduled-overlap-policy.md`
- `design-docs/specs/design-work-runtime-consolidation.md`,
  `design-work-handover-and-takeover.md` (Task/Attempt, handover questions)
- `design-docs/specs/design-evolution-history.md` (memory record versions,
  undo, diff)
- `design-docs/specs/design-agent-prompt-overflow-guard.md` (prompt budget)
- `design-docs/specs/design-app-managed-api-auth.md` (API keys, passkeys)
- `design-docs/specs/design-workflow-definition-store.md` (audited changes)

No earlier Bots design exists under `design-docs/`. The documents above were
checked first; none can hold this feature without hiding its boundary, so this
is a new dedicated document.

## 1. Problem (verified at `7f04f6e6`)

- No bot or agent-identity record exists. The closest concepts are a persona
  id string (`Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift`,
  tag `persona:<id>`), `RoutineRecord` (`Sources/RielaCore/RoutineStore.swift`,
  a JSON record in `routines.sqlite`), and `WorkTask.owner`
  (`OwnerAssignment{identity,lane}` in `Sources/RielaWork/WorkModels.swift`).
  Nothing answers "what is each of my agents doing right now".
- Every agent backend runs through the in-process agent-gateway over ACP
  (`ProductionNodeAdapter.swift` registers one gateway factory for all
  `NodeExecutionBackend` cases). The v1 collector
  (`GatewayACPUpdateCollector.consume` in `AgentGatewayNodeAdapter.swift`) keeps
  message, thought, `tool_call` and `tool_call_update` and drops `plan`,
  `user_message_chunk` and `.other`. The v2 collector
  (`AgentGatewayACPV2Turn.swift`) keeps `agentMessageChunk`, `agentMessage`,
  `agentThoughtChunk` and `toolCallUpdate` and drops every other
  `ACPV2SessionUpdate` case (`planUpdate`, `planRemoved`,
  `availableCommandsUpdate`, `configOptionUpdate`, `sessionInfoUpdate`,
  `usageUpdate`, `notice`, `subagentUpdate`, terminal updates, thoughts as
  whole messages). Tool-call `locations` are never read.
- `runGatewayTurn` installs `GatewayClientPermissionResponder(policy: .cancel)`.
  A `session/request_permission` is declined at once and never shown to anyone.
- Backend events reach `DeterministicWorkflowRunner.adapterExecutionContext`
  (`DeterministicWorkflowRunner+ExecutionEvents.swift`), which calls
  `store.recordStepBackendEventReceipt`. The store keeps a live ring per
  execution; `WorkflowFailureDiagnostics.retainedEventMetadata` strips
  tool-call metadata at persistence and the CLI live persistence writes at most
  once per second per session. No endpoint serves backend events; the web polls
  every 5 s (`web/src/polling.ts`).
- The session store database (`SQLiteWorkflowRuntimePersistenceStore`,
  generation 12) also holds the Work Runtime `work_*` tables. Generations
  9 → 12 have registered in-place migrations.
- `RielaMemoryStore` is one SQLite file per `memoryId` under `.riela/memory`,
  with records keyed by workflow id, node id and tags, and per-record evolution
  history (`undoRecord`, `redoRecord`, `recordDiff`, `restoreRecordVersion`).
  `validateMemoryId` accepts `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
- `BackendCapabilityProbe` (`Sources/RielaAdapters`) already observes backend
  executable, version and credential environment without starting a session.
  Model names are otherwise free strings; `WorkflowBackendPolicyValidation`
  reports an unknown `modelByBackend` model as an error.
- `RielaAPIKeyStore` (`Sources/RielaServer`) stores only SHA-256 digests,
  supports expiry and revocation, and is read on every request by
  `RielaAPIKeyHTTPAuthorization` and `APIKeyGraphQLAuthorization`. Keys carry
  a purpose (`client`, `worker`) but no scope. The desktop console already has
  a remote mode that sends a bearer token (`web/src/transport.ts`,
  `riela_remote_request`).
- `riela environment status|reload` already exists and means "workflow
  instance environment" (`Sources/RielaCLI/EnvironmentCommand.swift`).
- Upstream gap: in the pinned agent-gateway (`39796860`),
  `GatewayACPStreamBridge.consume` forwards only the assistant and thinking
  channels and `GatewayStreamChunk` has only `message` and `thought`. The
  in-process `GatewayACPAgent` therefore emits no tool call, plan, usage or
  permission request today (§15).

## 2. Goals and non-goals

Goals: the seven slices of the intake, in this order, each usable without the
later ones.

- a. Bot record, runtime-owned linkage, overview and task board.
- b. Typed activity stream from ACP, persisted and bounded, live and replay,
  answerable permission requests, settlement on every terminal path.
- c. Provider-instance and model catalog.
- d. Server-owned list state.
- e. Per-bot riela memory.
- f. Memory upkeep, look-around, suggestions, feedback learning.
- g. Server pairing and multi-server views.

Non-goals:

- A relay or cloud service, a new transport (SSE, WebSocket, GraphQL
  subscription), or a new auth system.
- Changing how workflows, routines, Work tasks or sessions execute. A bot is an
  identity over them; it adds no scheduler and no dispatcher.
- Bot default backend or model overriding a workflow node's own settings.
- Vendoring or patching agent-gateway, or changing `Package.swift` pins.
- kaiba long-term knowledge. Bot memory is riela memory only.
- Scripted activity in mock scenarios. Mock runs report
  `activitySource: session`.
- Queuing requests for an unreachable server. A request to a disconnected
  server fails with `remote_unreachable`.

## 3. Reference ideas: adopted, adapted, rejected

Orca and T3 Code are inspiration only. No code, names or branding are copied.

| Idea | Decision | Why |
| --- | --- | --- |
| Orca: bot = name, purpose, memory, automations | Adopted | Maps to a thin record plus existing routines and memory |
| Orca: list row with last activity, counts, last-result line | Adopted | Derivable from runtime records |
| Orca: board order Needs you → In progress → Waiting → Planned → Closed | Adopted | Required by the intake |
| Orca: soul, memory, skills as editable Markdown files | Adapted | Memory stays in `RielaMemoryStore` and is rendered, edited and exported as Markdown; persona stays an existing `personaId` reference; no new file format |
| Orca: activity transcript with duration markers and board lines | Adapted | The typed activity stream carries step and stop events; clients render durations |
| Orca: memory rules (no secrets, external content is not instruction) | Adopted | Enforced by the runtime at write time (§9.2) |
| Orca: memory upkeep (nightly, weekly, off; catch-up; text-only reply; undo) | Adopted | §10.1 |
| Orca: look-around, read-only, suggestions need acceptance | Adopted | Enforced by sandbox and tool policy (§10.2) |
| Orca: learning by correction | Adapted | Corrections and review findings become memory candidates through the same audited apply path (§10.4) |
| Orca: avatar, connector conversations as children | Rejected | Not needed to answer "what is it doing"; chat event sources already exist |
| T3: route by provider instance, not driver kind | Adopted | §7 |
| T3: bundled manifest merged with agent-reported models, live update | Adopted | §7.2 |
| T3: `default` sentinel never sent | Adopted | §7.3 |
| T3: per-model options, skip what a provider does not offer | Adopted | §7.2 |
| T3: passive health probes | Adopted | Reuses `BackendCapabilityProbe` |
| T3: native option ids pass through, every request declinable | Adopted | §6.6 |
| T3: settle open items on every terminal path | Adopted | §6.7 |
| T3: server-owned list state, Working group, return-to-top, Limited | Adopted | §8 |
| T3: events, projection and commit in one transaction; bounded replay | Adapted | Applied to the activity log and its state row only (§6.4); riela's runner is not re-architected around event sourcing |
| T3: fixtures recorded from the real provider | Adapted | Real transcripts when available; otherwise scripted ACP agents, because of the upstream gap (§15) |
| Orca pairing: one-time expiring code for an explicit address | Adopted | §11 |
| Orca pairing: per-client revocable token, grants list, revoke | Adopted | On `RielaAPIKeyStore` |
| Orca pairing: `orca://pair` link scheme | Rejected | A single opaque pairing code string needs no URL scheme registration |
| Orca pairing: `environment add/list/rm`, default server, host flags | Adapted | Named `riela remote` because `riela environment` is taken (§11.4) |
| Orca pairing: one list across hosts with host label and filter | Adopted | §11.5 |
| Orca pairing: queue requests while a host is unreachable | Rejected | Adds a durable client-side outbox with replay semantics; not required by the acceptance criteria |

## 4. Storage and ownership

All bot records are owned by the runtime store. Workers and adapters never
create ids for them.

### 4.1 Session store database, generation 13

The session store database gains these tables. `schemaGeneration` becomes 13
with a registered `SQLiteSchemaMigration(fromGeneration: 12)` that only runs
`CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS`. The fresh-store
builder creates the same tables. Existing generation-12 stores migrate in
place; nothing is discarded. This mirrors how `WorkStore+Schema.swift` adds
the `work_*` tables behind the same guard.

| Table | Key | Content |
| --- | --- | --- |
| `bots` | `bot_id` | `record_json` (jsonb), generated `name`, `paused`, `updated_at` |
| `bot_session_links` | `session_id` | `bot_id`, `source` (`run`, `routine`, `job`), `source_ref`, `linked_at` |
| `bot_list_state` | `(bot_id, item_kind, item_id)` | pin, manual order, snooze, settle (§8) |
| `bot_suggestions` | `suggestion_id` | `bot_id`, `record_json`, generated `status` |
| `bot_job_runs` | `(bot_id, job, period_key)` | upkeep and look-around run ledger (§10) |
| `bot_memory_changes` | `change_id` | audited memory change sets (§9.4) |
| `activity_events` | `(session_id, seq)` | typed activity event log (§6.4) |
| `activity_state` | `session_id` | projection JSON, `last_seq`, `first_retained_seq`, `source` |
| `activity_requests` | `request_id` | pending and resolved permission requests (§6.6) |
| `provider_instances` | `instance_id` | user-declared provider instances and custom models (§7) |
| `provider_reports` | `(instance_id)` | last backend-reported models, options and probe result |

`activity_*` rows reference the session and are deleted with it by the
existing session retention paths; retention code is extended to delete them in
the same transaction as the session rows. `bots`, `bot_list_state`,
`bot_suggestions`, `bot_job_runs`, `bot_memory_changes` and `provider_*` are
never touched by retention.

A new `BotStore` type in `Sources/RielaCore` owns reads and writes of the
`bot_*` tables, opened the same way as the routine and Work stores (one
connection per operation, WAL for writes, a missing database reads as empty).
The session store root is resolved exactly as for `riela session` and
`riela task` (`--session-store`, `RIELA_SESSION_STORE`, scope default), so
tests isolate everything with one `--session-store` path.

### 4.2 Records kept where they already live

- Routine linkage: `RoutineRecord` gains an optional `botId`. It is stored in
  the existing `record_json`, so the routine store generation stays 1.
- Work task linkage: `WorkTask.owner.identity == "bot:<botId>"`. No schema
  change. An attempt's session (`Attempt.sessionId`) is attributed through its
  task.
- Bot memory: memory id `bot-<botId>` in the existing `RielaMemoryStore`. The
  memory schema version is not changed.
- Pairing grants: `RielaAPIKeyStore` records with new optional fields (§11.2).

## 5. Slice a: bot record, linkage, overview

### 5.1 Bot record

```
BotRecord {
  botId            // ^[a-z0-9][a-z0-9-]{0,62}$, immutable, unique per store
  name             // 1...200 chars, no control characters
  purpose          // optional free text
  personaId        // optional reference to an existing persona id
  defaultBackend   // optional NodeExecutionBackend raw value
  defaultModel     // optional; "default" or a model id (§7.3)
  providerInstanceId // optional (§7.1)
  workspace        // optional path used for grouping (§8.5)
  paused           // Bool
  memoryUpkeep     // off | nightly (default) | weekly
  lookAround       // off (default) | nightly | weekly
  permissionWaitMs // 0...3_600_000, default 300_000 (§6.6)
  createdAt, updatedAt
}
```

`botId` defaults to a slug of `name` when not supplied. Create fails with
`bot_exists` on a duplicate id. Remove deletes the bot row, its links, list
state, suggestions and job ledger in one transaction; it is refused with
`bot_busy` while a linked session is running or a permission request is
pending. Remove never deletes sessions, routines, Work tasks or the memory
database; it clears `botId` on the bot's routines. `defaultBackend` and
`defaultModel` are used by the bot's own jobs (§10) and shown as defaults by
clients. They never override a workflow node.

Pause sets `paused`. A paused bot's routines are not dispatched: the cron
routine gate that already consults `RoutineStore` before each dispatch also
checks the routine's bot and records the tick as skipped with reason
`bot_paused`. Jobs (§10) do not run. Runs started by hand with `--bot` are
refused with `bot_paused`. Running sessions are not cancelled.

### 5.2 Linkage (runtime-owned)

- `riela workflow run --bot <botId>` and the GraphQL execution input field
  `botId`: the run command writes the `bot_session_links` row when the runtime
  assigns the session id (the existing `sessionStartedObserver` seam in
  `WorkflowRunCommand.swift`), before the first step runs.
- Routine with `botId` (set by `riela routine create --bot <botId>` and the
  matching GraphQL routine input field; the bot must exist): the cron dispatch
  path passes the bot id to the same run path, with `source = routine` and
  `source_ref = routineId`.
- Bot jobs: `source = job`, `source_ref = <job>:<period_key>`.
- Child sessions (nested and cross-workflow) are attributed through
  `rootSessionId`. Only root sessions get a link row.
- An unknown `botId` fails the run before a session is created
  (`bot_not_found`).

### 5.3 Board derivation

`BotBoardProjector` in `RielaCore` is a pure function. Inputs: the bot, its
linked root sessions and their descendants, `activity_state` rows, pending
`activity_requests`, owned Work tasks with their latest handover, the bot's
routines with next fire time, suggestions, list state, and `now`. No clock or
I/O inside.

A board item is one linked root session, or one owned Work task. A session
that is an attempt of an owned task is reported under the task, never twice.

Groups, evaluated in this order; the first match wins:

| Group | Condition |
| --- | --- |
| Needs you | a pending permission request in the session family; or session `suspended` with reason `userInputRequired` or `userPresenceRequired`; or Work task `needsDecision`; or Work task whose latest handover reason is `userInputRequired` |
| In progress | session `running`; or Work task `running` or `verifying` |
| Waiting | session `suspended` for another reason; or Work task `waiting`; or item status `limited` (§8.4). The reason is the suspend reason kind, the wait decision reason, or `limited` with its reset time |
| Planned | session `created`; Work task `draft`, `ready` or `scheduled`; each active routine's next fire (one item per routine); accepted suggestions not yet started |
| Closed | session `completed`, `failed` or `cancelled`; Work task terminal. Newest first, at most 20 per bot; `closedTotal` reports the full count |

Each item carries: `itemKind`, `itemId`, `title` (workflow id or task title),
`workflowId`, `stepId`, `nodeId`, `backend`, `model`, `startedAt`,
`elapsedMs`, `lastActivityAt`, `status`, `waitingReason`, `activitySource`,
`doingNow`, `checklist`, `pendingRequests`, `lastResult`, `sessionId`, and
`origin` (§11.5).

- `backend` is the running execution's backend. `model` is the model the
  backend reported for the turn when known, otherwise the node's configured
  model, otherwise null. It is never guessed.
- `doingNow` is the title of the newest in-flight tool call from
  `activity_state`, otherwise the current step id.
- `checklist` is the plan from `activity_state` (§6.3).
- `lastResult` is one line, at most 200 characters, taken in this order: the
  failure reason for a failed session; the first line of the final agent
  message recorded in the activity log; otherwise `<status> at step <stepId>`.
  It is passed through the secret redaction of §9.2.

### 5.4 Overview row

Per bot: `counts { needsYou, working, waiting, planned }`, `inProgress` (the
In-progress items), `lastActivityAt` (the newest of session `updatedAt`, last
activity event, task update), `lastResult` (from the newest Closed item, only
when `working == 0`), `paused`, `listState`, `origin`. A bot with no linked
work reports zero counts and null `lastActivityAt`.

`riela bot list` prints one row per bot. `riela bot show <botId>` prints the
board in group order, then routines with next run, suggestions and a memory
summary (entry counts and last change). Both accept `--output json|text`.

## 6. Slice b: activity stream

### 6.1 Event model (backend-neutral)

`ActivityEvent { sessionId, seq, executionId?, at, kind, payload }`. `seq` is
assigned by the store, starts at 1 per session and has no gaps at write time.

| `kind` | Payload |
| --- | --- |
| `stepStarted` | `stepId`, `nodeId`, `backend`, `requestedModel` |
| `stepFinished` | `stepId`, `status` |
| `message` | `messageId`, `text`, `final` |
| `thought` | `text` |
| `toolCall` | `toolCallId`, `title`, `toolKind`, `status`, `locations[{path,line}]` |
| `plan` | `planId`, `entries[{content,status,priority}]` |
| `planRemoved` | `planId` |
| `mode` | `modeId` |
| `commands` | `names[]` |
| `configOptions` | `options[{id,category,currentValue,values[]}]` |
| `sessionInfo` | `title` |
| `usage` | `contextUsed`, `contextSize`, `inputTokens`, `outputTokens`, `totalTokens`, `cost` (each optional) |
| `notice` | `severity`, `title`, `description` |
| `subagent` | `subSessionId`, `title`, `state` |
| `permissionRequested` | `requestId`, `toolCallId`, `title`, `options[{optionId,name,kind}]`, `expiresAt` |
| `permissionResolved` | `requestId`, `outcome` (`selected` + `optionId`, or `cancelled`), `resolvedBy` (`user`, `timeout`, `policy`, `settlement`) |
| `stop` | `stopReason`, `limited { resetAt? }` when the stop is a usage or rate limit |
| `settled` | `reason`, `closed { toolCalls, planEntries, subagents, permissionRequests }` |
| `other` | `updateKind` only (an ACP update kind this build does not model) |

Tool-call status values: `pending`, `inProgress`, `completed`, `failed`,
`interrupted`. Plan entry status values: `pending`, `inProgress`, `completed`,
`abandoned`. `interrupted` and `abandoned` are written only by settlement.

### 6.2 Normalisation from ACP

The gateway collector maps every update to an `AdapterActivityUpdate` value
(a typed enum in `RielaCore/AdapterContracts.swift` mirroring the payloads
above) and attaches it to the `AdapterBackendEvent` it already produces in a
new optional `activity` field. Updates that produced no backend event before
now produce one whose `eventType` is the ACP discriminator, so the existing
ring, counters and silence monitor see them too. Existing event types and
metadata keys are unchanged.

| ACP v1 | ACP v2 | Activity |
| --- | --- | --- |
| `agent_message_chunk` (text) | `agentMessageChunk`, `agentMessage` | `message` |
| `agent_thought_chunk` (text) | `agentThoughtChunk`, `agentThought` | `thought` |
| `tool_call` | first `toolCallUpdate` for an id | `toolCall` |
| `tool_call_update` | later `toolCallUpdate` | `toolCall` |
| `plan` | `planUpdate` | `plan` (v1 uses `planId = "default"`) |
| — | `planRemoved` | `planRemoved` |
| `.other` with `current_mode_update` | `configOptionUpdate` option of category `mode` | `mode` |
| `.other` with `available_commands_update` | `availableCommandsUpdate` | `commands` |
| — | `configOptionUpdate` | `configOptions` (also feeds §7.2) |
| — | `sessionInfoUpdate` | `sessionInfo` |
| end-of-turn `_meta.usage` | `usageUpdate`, end-of-turn `_meta.usage` | `usage` |
| — | `notice` | `notice` |
| — | `subagentUpdate` | `subagent` |
| `session/request_permission` | same | `permissionRequested`, `permissionResolved` |
| prompt response `stopReason` | idle `stateUpdate.stopReason` | `stop` |
| any other discriminator | `other`, terminal updates, tool-call content chunks, user messages | `other` (kind only) |

Rules:

- Non-text content blocks are counted in `other`; their bytes are not stored.
- A v1 `.other` update is classified by its raw `sessionUpdate` string. No
  agent-id special cases exist anywhere in the mapping.
- Unknown plan priority or status strings and unknown tool kinds are kept as
  the raw string. An unknown permission option kind is never treated as
  approval.

### 6.3 Reducer (deterministic)

`ActivityReducer` in `RielaCore` is pure:
`(state, update, at) -> (state, events)`. The state holds open and recent tool
calls by id, plans by id, mode, commands, config options, usage, subagents,
pending request ids, the open message and thought buffers, and the last stop.

- Tool calls are upserts by `toolCallId`. An update for an unknown id creates
  the call with the fields it carries (out-of-order `tool_call_update`). A
  patch changes only the fields it carries. `completed`, `failed` and
  `interrupted` are sticky: a later non-terminal status is ignored. An event is
  emitted only when a field changed.
- A `plan` update replaces that plan's whole entry list. The checklist is all
  plans in first-seen order.
- `message` and `thought` chunks append to a buffer. One event is emitted when
  the buffer reaches 4 KiB, when 1 s has passed since the last flush, when a
  different event kind arrives, or at step end (`final: true` on the last
  message flush). A v2 whole-message update replaces the buffer for that
  message id.
- The state keeps at most 200 tool calls; the oldest terminal ones are dropped
  first. Open calls are never dropped.

### 6.4 Persistence (bounded)

The runner gains an injected `WorkflowActivityRecording` dependency. Its
backend-event handler passes `backendEvent.activity`, together with the
session and execution ids it already holds, to the recorder after the existing
receipt write. The recorder also receives step start and step finish from the
runner. The SQLite implementation writes the events and the new
`activity_state` row in one transaction on the session store database. It does
not go through the throttled live session snapshot. A recorder failure is
logged once per session and never fails the step.

- Each event payload is capped at 8 KiB; longer text is cut and marked
  `truncated: true`.
- At most 2,000 events are kept per session. On overflow the oldest rows are
  deleted in the same transaction and `first_retained_seq` advances. The state
  row is complete on its own, so open items survive log trimming.
- With message coalescing, text produces at most one write per second per
  session; structural events are written as they arrive.
- With no recorder injected (library callers, tests that do not need it)
  nothing is written and behaviour is as today.

`activity_state.source` is `acp` once any ACP-derived update was recorded for
the session, otherwise `session`. A `session` stream contains only
`stepStarted`, `stepFinished`, `stop` and `settled`. Clients must show the
source; nothing is synthesised to make a `session` stream look richer.

### 6.5 Live and replay

One read serves both: `Query.botActivity(sessionId, afterSequence = 0,
limit = 200, waitMs = 0, remote)` returns `{ events, state, lastSequence,
firstRetainedSequence, truncated, activitySource, sessionStatus, origin }`.

- Replay: `afterSequence = 0` returns the retained log from
  `firstRetainedSequence`. `truncated` is true when `afterSequence + 1 <
  firstRetainedSequence`; the client then rebuilds from `state`.
- Live: `waitMs` (0...25,000) makes the server hold the request until an event
  with `seq > afterSequence` exists, the session is terminal and settled, or
  the wait ends. The server checks `last_seq` every 250 ms. At most 32 waiters
  are held per server; beyond that the request returns at once as if
  `waitMs = 0`. This is long-poll over the existing HTTP and GraphQL path; no
  transport changes.
- `limit` is 1...500. Events are ordered by `seq` and never duplicated.
- CLI: `riela bot activity (--session <id> | <botId>) [--follow]
  [--after <seq>]`. With a bot id it follows the bot's newest In-progress or
  Needs-you item. Local reads use the store directly with the same loop.
- Web: the bot detail view uses the same query with `waitMs` and falls back to
  the existing 5 s polling helper when a request fails.

### 6.6 Permission requests and questions

`AdapterExecutionContext` gains an optional `permissionRequestHandler`:
`(AdapterPermissionRequest) async -> AdapterPermissionOutcome`. The gateway
adapter replaces `GatewayClientPermissionResponder(policy: .cancel)` with its
own `ACPClientDelegate` that decodes `session/request_permission` (tool call
reference and options, same shape in v1 and v2), calls the handler and returns
`selected(optionId)` or `cancelled`. Option ids are passed through unchanged.
Any other agent-initiated method is still rejected with `methodNotFound`.

The runner supplies the handler:

1. It inserts an `activity_requests` row (`request_id` generated by the store,
   session, execution, tool call id, title, options, `expires_at`) and records
   `permissionRequested`.
2. It waits by reading the row every 500 ms until it is answered, until
   `expires_at`, or until the step task is cancelled or its deadline passes.
3. It records `permissionResolved` and returns the outcome.

Wait bound: `expires_at = now + waitMs`, cut to the step deadline. `waitMs` is
the bot's `permissionWaitMs` for a bot-linked session (default 300,000) and 0
for a session with no bot. With 0 the handler resolves at once as `cancelled`
with `resolvedBy: policy` and still records both events, so an unlinked
workflow step behaves exactly as today. Look-around runs always use 0 (§10.2).

Deterministic default: timeout, cancellation, a missing handler and any store
error all resolve to `cancelled`. Nothing ever auto-approves.

Answering: `riela bot answer <requestId> (--option <optionId> | --decline)`,
`Mutation.answerBotRequest(input: { requestId, optionId, decline, remote })`,
and the web Needs-you card. The answer is one conditional update of the row
(`status = pending` → `answered`); the first answer wins and a second gets
`request_already_resolved`. `--option` must be one of the stored option ids,
else `request_option_unknown`. `--decline` is always accepted and maps to
`cancelled`. An expired or settled request returns `request_expired`.

Handover questions are not duplicated. A Needs-you item that comes from a Work
task or a suspended session carries `answerPath: "task"` with the task id and
question id, and is answered through the existing `riela task answer` /
`Mutation.answerTask` path. `riela bot answer` accepts only permission request
ids and says so when given a question id.

### 6.7 Settlement invariant

After any terminal path of a step execution, its activity state has no open
tool call, no live plan entry, no running subagent and no pending request.

The runner calls `recorder.settle(executionId, reason)` exactly where it marks
the execution terminal: completion (`completed`), cancellation (`cancelled`),
deadline (`timeout`), adapter error (`providerError`). The orphan paths that
mark a session failed after its process died (`riela session reconcile`,
`SessionAbandonedInvocationReconciler`) call it with `processExit` for every
execution they close. Settlement, in one transaction:

- open tool calls (`pending`, `inProgress`) → `interrupted`;
- plan entries not `completed` → `abandoned`;
- subagents not in a terminal state → `interrupted`;
- pending requests → `cancelled`, `resolvedBy: settlement`; a handler still
  waiting sees the row change and returns `cancelled` to the agent;
- one `settled` event with the reason and the four counts.

Settlement is idempotent: a second call writes nothing. A `stop` event is
recorded before `settled` when the adapter reported a stop reason. On normal
completion with nothing open, `settled` is still written with zero counts, so
replay can assert the invariant on every execution.

### 6.8 `limited`

A stop is a limit only when a structured signal says so: a rate-limit or
quota code, with an optional reset time, in the ACP error object or in the
gateway `_meta` object of the turn. The adapter maps that signal to
`limited { resetAt? }` on the `stop` update. No message-text heuristics are
used; without a structured signal the item is a plain failure. Whether the
pinned gateway already exposes such a code was not verified at design time, so
the mapping is tested with scripted agents and §15 item 4 records the upstream
field.

## 7. Slice c: provider and model catalog

### 7.1 Provider instances

A provider instance is `(instanceId, driver, label, account, config)` where
`driver` is a `NodeExecutionBackend`. One built-in instance exists per driver
with `instanceId == driver raw value`; it needs no row. User-declared
instances live in `provider_instances` and add a label, a named provider
reference (the existing `provider` / `providerProxy` node fields), an
`apiKeyEnvironment` name (never a secret) and `customModels[]`. Several
instances may share one driver. Bots reference `providerInstanceId`.

### 7.2 Catalog build

`ModelCatalog` in `RielaCore` merges, per instance:

1. the bundled manifest, a Swift constant in
   `Sources/RielaCore/ModelManifest.swift` (`driver → models[{id, label,
   options{reasoningEfforts[], serviceTiers[], modes[]}}]`). It needs no
   network and no `Package.swift` resource change;
2. `provider_reports`: what the backend reported. For ACP backends the
   activity recorder upserts the report from `configOptions` events (options
   of category `model`, `mode`, `thought_level`, `model_config`) and from the
   model the turn reported, as they arrive, so the catalog updates while a
   session runs;
3. the instance's `customModels`.

Each catalog model carries `source` (`manifest`, `reported`, `custom`, or a
combination), `options`, and `observedAt` for reported data. An option a
provider does not report is absent, not an error. Reported values win over the
manifest for the same model id.

### 7.3 `default` sentinel and validation

`default` (or an unset model) means "the provider's own configuration". It is
a catalog entry on every instance and is removed before the request is built:
the node model is sent to the gateway only when it is a non-empty string other
than `default`. A node or bot that names a model the catalog does not list for
its driver gets a validation warning `model_unknown`, never an error. The one
existing error for unknown `backendPolicy.modelByBackend` models becomes the
same warning.

### 7.4 Health

`Mutation.refreshProviders` and `riela provider refresh` run
`BackendCapabilityProbe` for each instance and store availability,
authentication, version and failures in `provider_reports`. The probe checks
the executable and credential environment only. It never opens an ACP session,
never starts MCP servers or hooks and never starts a login flow. Catalog reads
never probe; they show the last report and its age.

### 7.5 Surfaces

`riela model list [--provider <instanceId>]`, `riela provider list`,
`riela provider show <instanceId>`, `riela provider refresh [<instanceId>]`,
`riela provider add|update|remove` for user instances and custom models;
`Query.modelCatalog`, `Query.providers`, `Query.provider`,
`Mutation.refreshProviders`, `Mutation.saveProviderInstance`,
`Mutation.removeProviderInstance`; web view `#/models` (instance cards with
account, auth state, refresh; model list with options). The bot create and
edit forms select from `Query.modelCatalog`.

## 8. Slice d: list state

### 8.1 Record

`bot_list_state` rows are keyed by `(bot_id, item_kind, item_id)` where
`item_kind` is `bot` (the bot's own row in the list, `item_id = ""`),
`session` or `task`:

```
{ pinned: Bool, manualOrder: Int?, snoozedUntil: Date?, snoozedAt: Date?,
  settledAt: Date?, settledBy: "user" | "auto"?, bumpedAt: Date? }
```

Clients render the ordered result the server returns. They do not derive
order, snooze wake-up or settle from their own clock.

### 8.2 Ordering

The same pure projector orders bots in the list and items in a board group:
pinned first; then rows with `manualOrder` ascending; then by `bumpedAt`
descending, falling back to `lastActivityAt`; ties by id. The bot list is
split into `active`, `working` (bots whose only non-closed items are In
progress or Waiting, collapsed by default), `snoozed` and `settled`.

Return-to-top: when an item finishes, fails or enters Needs you, the projector
reports it as bumped. `bumpedAt` is not written by reads; it is the time of
the triggering runtime record (session terminal time, request creation time),
so every client computes the same order without a write.

### 8.3 Snooze and settle

- Snooze sets `snoozedUntil`. A snoozed row is in `snoozed` until
  `now >= snoozedUntil`. It wakes early when the bot has a Needs-you item or a
  failure newer than `snoozedAt`. Wake-up is computed, not stored.
- Settle sets `settledAt`. A settled row is hidden from `active`. Manual
  settle is refused with `list_item_busy` while the item (or, for a bot row,
  any item of the bot) is In progress, Waiting or Needs you.
- Auto-settle: a Closed item with no activity for 7 days is reported as
  settled (`settledBy: auto`) by the projector. It is never applied to an item
  that is In progress, Waiting or Needs you, or that has a pending request.
- A settled or snoozed row returns to `active` when new work or a Needs-you
  item appears after `settledAt`.

### 8.4 `limited`

An item whose last `stop` event carries `limited` reports status `limited`
with `resetAt` and sits in Waiting with reason `limited`. Nothing resumes it
automatically; the reset time is shown so the user can rerun.

### 8.5 Grouping

The list query accepts `groupBy: none | workspace`. A group key is the bot's
`workspace` (null → `ungrouped`). Each group reports `needsYou: Bool`, so a
collapsed group can show an indicator.

### 8.6 Surfaces

`riela bot pin|unpin|move|snooze|unsnooze|settle|unsettle`, each with an
optional `--item session:<id>|task:<id>`; `Mutation.setBotListState`; the web
list and board controls. CLI, GraphQL and web read the same projected DTO.

## 9. Slice e: bot memory

### 9.1 Scope and shape

Memory id `bot-<botId>` in the `RielaMemoryStore` rooted where `riela memory`
already resolves it. Records use `workflowId = "bot"` and tags:
`kind:instruction` or `kind:note`, and `topic:<slug>`. The payload is
`{ text, provenance { source, ref, capturedAt, actor } }` where `source` is
`user`, `correction`, `review`, `upkeep`, or `external`. No memory schema
change; existing user databases are opened unchanged.

### 9.2 Write rules (enforced in one function)

Every write, from every surface and job, goes through
`BotMemoryWriter.apply`:

- Secret redaction: the text passes through the existing
  `HandoverRedactionRules.redactText`. If redaction changes the text, the
  entry is stored redacted and the change records `redacted: true`.
- Provenance is required. A write without `provenance.source` is rejected.
- Only `user` and `correction` sources may create or change a
  `kind:instruction` entry. Every other source (`external`, `review`,
  `upkeep`) is stored as `kind:note`: a request to store it as an instruction
  is downgraded, and a change it proposes to an existing instruction is
  ignored. Both cases are recorded on the change set (`downgraded: true`,
  `ignoredInstructionChanges: n`). Text taken from mail, issues, webhooks,
  chat messages or tool output must be written with source `external`.
- Each entry is at most 4,000 bytes; a bot holds at most 500 entries. Over
  either limit the write is rejected with `memory_limit`.

### 9.3 Markdown

`riela bot memory show <botId>` renders Markdown: `## Instructions` then
`## Notes`, grouped by `### <topic>`, one list item per entry with a trailing
`<!-- id:<recordId> -->` marker. `riela bot memory export <botId> [--out
<path>]` writes the same text. `riela bot memory edit <botId> --file <path>`
parses that format, diffs it against the current entries by record id, and
applies adds, updates and removals as one change set through §9.2. Items
without a marker are new `user` entries. The GraphQL and web editors use the
same parser (`Query.botMemory`, `Mutation.updateBotMemory`).

### 9.4 Audited change sets, list, diff, undo

Each apply writes one `bot_memory_changes` row: `changeId`, `botId`, `actor`
(`user`, `cli`, `api`, `upkeep`, `feedback`, same vocabulary style as
`WorkflowDefinitionActorKind`), `reason`, `evidenceRefs[]`, and
`entries[{ recordId, op, fromVersion, toVersion }]`. Record versions are the
existing evolution-history versions.

- `riela bot memory history <botId>` lists change sets.
- `riela bot memory diff <botId> <changeId>` shows per-entry diffs through the
  existing `recordDiff`.
- `riela bot memory undo <botId> [<changeId>]` (default: the newest) restores
  every entry of the change set to `fromVersion` with `restoreRecordVersion`
  (an added entry is removed, a removed entry is restored) and writes a new
  change set with `reason: undo:<changeId>`. Undo is refused with
  `memory_change_conflict` when an entry has a newer version than `toVersion`.

### 9.5 Prompt injection

When a run is bot-linked, the run request carries a rendered memory block.
The runner appends it to the system prompt of every agent step before
`guardAgentPrompt` measures the prompt, so it is inside the existing budget.
The block is capped at 16,000 bytes: instructions first, then notes, newest
first, with a final `(memory truncated)` line when cut. Notes are placed under
a heading that states they are information and not instructions. A run with no
bot gets no block and its prompts are byte-identical to today.

## 10. Slice f: upkeep, look-around, suggestions, feedback

### 10.1 Memory upkeep

- Schedule: `memoryUpkeep` is `nightly` (default), `weekly` or `off`. The
  period key is the local date (nightly) or ISO week (weekly).
- Due check, a pure function over the job ledger and bot activity: the job is
  due for the newest closed period when the ledger has no row for it, the bot
  has activity newer than its last successful upkeep, the bot is not paused
  and it has no In-progress or Needs-you item. Missed periods catch up as one
  run for the newest period; older periods get `skipped` ledger rows. No
  activity writes `skipped: no_activity`.
- Trigger: `riela events serve` and `riela serve` evaluate due jobs once a
  minute alongside cron sources; `riela bot job run <botId> upkeep [--force]`
  runs it by hand. The ledger's primary key makes a period run at most once
  across processes.
- Execution: one agent turn on the bot's default backend and model with
  `toolPolicy.preset = none` and `agentSandbox = read-only`, linked to the bot
  with `source = job`. Input: the current memory Markdown and the last-result
  lines and corrections since the last upkeep. Output contract: the proposed
  memory Markdown as text.
- Apply: the runtime parses the text with the §9.3 parser and applies it as
  one change set with `actor: upkeep` and source `upkeep` through §9.2, so it
  can add, merge and remove notes but cannot create or alter instructions.
  Text that does not parse,
  or that would remove more than half of the entries, is rejected; the ledger
  records `failed` with the reason and memory is unchanged. The model never
  executes anything; only the runtime writes.

### 10.2 Look-around

- Schedule and due check as upkeep, with `lookAround` defaulting to `off`.
- Read-only by enforcement, not by prompt. The job runner refuses to start
  unless all of these hold, and forces them on the run:
  - every agent node runs with `agentSandbox = read-only`, overriding the node
    value;
  - the job workflow is the built-in single-node look-around workflow; it has
    no command, container or add-on node, and a workflow with any such node is
    rejected with `look_around_not_read_only`;
  - `permissionWaitMs = 0`, so any permission request is declined;
  - the run is started without `git` finalization and with no write paths.
- Output contract: `suggestions[{ title, detail, action? }]` where `action` is
  `{ workflowName, input }`. The runtime stores each as a `bot_suggestions`
  row (`status: open`, provenance = the job session id). Nothing else is
  written.

### 10.3 Suggestions

`open → accepted → started` or `open → dismissed`.

- Accept records `acceptedAt` and `acceptedBy`. With an `action` and `--run`
  (or `run: true`), the runtime starts the named workflow linked to the bot
  through the normal run path and stores the session id (`started`). Without
  it the suggestion stays `accepted` and shows under Planned.
- Dismiss records `dismissedAt`, `dismissedBy` and an optional reason.
- Accept and dismiss are conditional updates; a second decision returns
  `suggestion_already_decided`.
- Surfaces: `riela bot suggestion list|accept|dismiss`,
  `Query.botSuggestions`, `Mutation.decideBotSuggestion`, web cards.

### 10.4 Feedback learning

`riela bot feedback <botId> (--session <id> | --task <id>) --text <t>
[--from-findings]` and `Mutation.captureBotFeedback` create memory candidates
for a finished item of that bot:

- a user correction becomes a `correction` entry (may be an instruction);
- `--from-findings` takes the session's recorded `reviewFindings` and creates
  one `review` note per finding.

Candidates are applied as one change set with `actor: feedback` and evidence
refs to the session or task, through the same §9.2 writer and §9.4 audit as
every other change, so they are listed, diffed and undone the same way. This
follows the definition-store model (actor kinds, evidence refs, versioned
history) and uses the memory store's existing evolution history; no second
history mechanism is added.

## 11. Slice g: pairing and multi-server views

### 11.1 Server identity

A server has a stable `serverId` (UUID created on first use, stored next to
the API key store) and a display name (`--server-name`, default the host
name). Every bot DTO produced by a server carries them in `origin`.

### 11.2 Mint, redeem, grants, revoke

- Mint: `riela serve --pairing-address <url> [--pairing-scope
  read|operate|admin]` prints a pairing code once on stdout at start.
  `riela serve pairing mint --address <url> --scope <s>` and
  `Mutation.mintPairingCode` (admin scope) do the same for a running server.
  Default scope is `operate`. The code is one opaque string,
  `rp1.<base64url(JSON{ address, secret, serverId })>`, with a 256-bit random
  secret. It expires after 10 minutes and is single-use. Minting replaces the
  previous unused code. Only its SHA-256 digest and expiry are stored.
- Address rule: the address must be an absolute `http` or `https` URL with a
  host and no credentials, query or fragment. Loopback (`127.0.0.0/8`, `::1`,
  `localhost`), unspecified and wildcard addresses (`0.0.0.0`, `::`) are
  refused with `pairing_address_not_routable`. `http` is accepted only for a
  literal private-range IP (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`,
  `fc00::/7`, `fe80::/10`); every other host needs `https`, else
  `pairing_address_requires_tls`. The documented requirement is: TLS, or a
  private network path (LAN, VPN, SSH forward); never a public plain-HTTP port.
- Redeem: `POST /api/v1/pairing/redeem` with `{ secret, clientName }`. On a
  valid, unexpired, unused code the server issues an API key through
  `RielaAPIKeyStore.issue` (purpose `client`) with new optional record fields
  `scope` and `pairing { clientName, pairedAt }`, marks the code used in the
  same store transaction, and returns `{ token, grantId, scope, serverId,
  serverName }` once. Five failed redeem attempts invalidate the outstanding
  code. Failures return one generic `pairing_code_invalid`.
- Grants: `riela serve pairing list`, `Query.pairingGrants` list the key
  records that have `pairing` (id, client name, scope, created, last used,
  revoked). `riela serve pairing revoke <grantId>` and
  `Mutation.revokePairingGrant` call the existing `revoke`.
- Revocation is immediate: every request already re-reads the store, so the
  next request with a revoked token gets `401 invalid_api_key`; a held
  long-poll re-checks its grant on each 250 ms wake and ends with the same
  error. There are no other long-lived connections.
- Scopes, enforced in `APIKeyGraphQLAuthorization` by the root fields of the
  parsed document: `read` allows Query fields only; `operate` also allows
  mutations except the admin set (pairing, API-key and configuration
  mutations, provider instance changes, bot removal); `admin` allows all. A
  key without `scope` (every key issued before this change) is `admin`, which
  is what it can do today. Violations return `scope_insufficient`.
- Logs and audit: the code and tokens are never written to a log, a serve
  record, an event or an error message. Mint, redeem (success and failure),
  and revoke each append one line to `pairing-audit.jsonl` (mode 0600) in the
  API key store root with time, action, grant id, client name, scope and
  remote address. No secret and no digest is written there.

### 11.3 Client registry

Client-side records live under the credential directory
`${RIELA_CREDENTIAL_DIR:-${XDG_STATE_HOME:-~/.local/state}/riela/credentials}`
(directory 0700, files 0600), never under `~/.config`:

- `remotes.json`: `[{ name, address, serverId, serverName, grantId, scope,
  addedAt, lastSeenAt, lastKnown }]` and `active` (a name or `local`);
- `remotes/<name>.token`: the bearer token.

### 11.4 Client commands

`riela environment` is taken (§1), so the family is `riela remote`:

- `riela remote add --name <n> --code <pairing-code>`: redeems and stores. It
  refuses a duplicate name and does not change the active remote.
- `riela remote list|show <n>|remove <n>|use <n|local>`. `remove` deletes the
  local record and token; it does not revoke the grant and says so.
- Selector on the `bot`, `model` and `provider` families and on
  `workflow run`: `--remote <name>` targets one server, `--all-remotes` (list
  and show reads only) fans out to local plus every remote. With neither, the
  active remote is used; the default is `local`.
- Web console and RielaApp: the local server exposes the registry
  (`Query.remotes`, `Mutation.addRemote`, `removeRemote`, `useRemote`) and a
  remote switcher in the Bots view. The browser never holds a remote token.
  The desktop app keeps its existing direct remote mode unchanged.

### 11.5 One typed surface, with origin

Every bot-family GraphQL field takes an optional `remote` argument. The local
executor forwards the same document to the paired server over `/graphql` with
the stored bearer token and returns its result; `remote: "*"` (reads only)
merges local and all remotes. The CLI calls the remote directly with the same
documents. No operation has a remote-only or local-only shape.

Each item (bot, board item, activity page, catalog entry, memory, suggestion)
carries:

```
origin { remote, serverId, serverName, verified, connection, observedAt }
```

- `remote` is `local` or the registry name.
- `verified` is true only when the response's `serverId` equals the registered
  one. A response with no `serverId`, or a different one, is reported with
  `verified: false` and `remote: "unverified"`; it is never shown as local.
- `connection` is `connected` or `disconnected`. When a remote cannot be
  reached, the last successful overview for it (stored in `lastKnown`, bots and
  counts only) is returned with `connection: disconnected` and its
  `observedAt`. Disconnected items never report `idle`, `completed` or zero
  counts as current state; their status is `disconnected`.
- List reads accept `remote` as a filter and return the host label on every
  row.

Starting work on a server: `riela workflow run --remote <n> --bot <id>` and
`riela routine create --remote <n>` send the existing execution and routine
mutations to that server. The session, credentials and records are created by
and stay in that server's runtime store.

## 12. Control surfaces

SurfaceCatalog rows are added first (`Sources/RielaCore/SurfaceCatalog+RowsBots.swift`),
then CLI routes and help, then GraphQL descriptors, then the SDL is
regenerated with `scripts/surface-parity/generate-sdl.sh`.

| Family | CLI | GraphQL | webAPI | library |
| --- | --- | --- | --- | --- |
| `bot` (create, list, show, update, pause, resume, remove, activity, answer, list-state verbs, memory verbs, job run, suggestion verbs, feedback) | implemented | implemented | excluded: console reads and writes are on GraphQL (parity design D8, D11) | excluded: not a library entry point |
| `model`, `provider` | implemented | implemented | excluded (same) | excluded |
| `remote` (add, list, show, remove, use) | implemented | implemented | excluded (same) | excluded |
| `serve pairing` (mint, list, revoke) | implemented | implemented | excluded (same) | excluded |
| `pairing.redeem` | via `remote add` | excluded: must work before any credential exists | implemented: `POST /api/v1/pairing/redeem` | excluded |

"REST" in the acceptance criteria is satisfied by the catalog decision for
each row: the gates require every surface to be implemented, blocked or
excluded with a reason, and the console REST routes are being retired. The
only new REST route is the pre-authentication redeem.

GraphQL wiring: one bots document executor in `RielaGraphQL`, with its
provider in `RielaAppSupport`, chained into both hosts that serve `/graphql`
(`ServeWebHost` and the RielaApp desktop composite), so the web console and
RielaApp get the same fields, including `remotes`.

CLI wiring: new router routes `bot`, `model`, `provider`, `remote`; new
`serve pairing` actions; typed action enums in `RielaClientFamilyArguments`;
expansion cases in `CLISurfaceEnumeration` (so `unclassifiedRoutes()` stays
empty); entries in `rielaCLIHelpText` and subcommand help.

Web: nav view `bots`; routes `#/bots`, `#/bots/{botId}`, `#/models` in
`web/src/routes.ts`, view state in `profileViewState.ts`, mounting in
`App.tsx`; new files under `web/src/bots/`. English only, low text, existing
components and the existing polling helper. All reads and writes go through
GraphQL.

## 13. Example bundle

`examples/bot-routine-memory-upkeep/`: a workflow run by a routine that
belongs to a bot, a mock scenario, and `EXPECTED_RESULTS.md` showing
`riela bot create`, a `--bot` mock run, `riela bot list` / `show`, and
`riela bot job run <botId> upkeep --force` with a scenario response that
returns memory Markdown, followed by `riela bot memory history` and `undo`.
It is registered in `Tests/RielaCLITests/RielaExampleCatalog.swift`
(`rielaExampleWorkflowNames()`), the mock-scenario count is updated, and the
examples README lists it.

## 14. Verification

Deterministic tests (new suites; names are prefixes the plans may split):

- `BotStoreTests`: CRUD, duplicate id, remove refusal, generation 12 → 13
  migration keeps existing sessions and Work rows.
- `BotBoardProjectorTests`: every group rule, first-match order, dedupe of
  task and attempt session, counts, `lastResult`, closed bound.
- `ActivityNormalizationTests` (RielaAdapters): each v1 and v2 update kind to
  its activity update; out-of-order `tool_call_update`; plan replacement;
  unknown kinds to `other`; unknown option kind is not approval.
- `ActivityReducerTests`: sticky terminal status, coalescing, bounds.
- `ActivityRecorderTests`: transaction, 2,000-event trim with
  `firstRetainedSeq`, payload cap, replay paging, long-poll wake and cap.
- `ActivityPermissionTests`: answer, decline, unknown option, double answer,
  timeout → cancelled, cancellation → cancelled, 0 wait for unlinked sessions.
- `ActivitySettlementTests`: replay fixtures under
  `Tests/RielaAdaptersTests/Fixtures/acp/` (real transcripts where available,
  otherwise scripted) for completion, cancel, provider error, deadline and
  process exit; each asserts the invariant and idempotence.
- Gateway turn tests with a scripted ACP agent on
  `ACPClientConnection.inProcess` that emits the full update set and a
  permission request, over v1 and v2. `runGatewayTurn` gains an internal agent
  factory parameter for this; production uses `GatewayACPAgent`.
- `ModelCatalogTests`, `BotListStateTests`, `BotMemoryTests` (scoping, rules,
  Markdown round trip, undo, conflict), `BotJobTests` (due, catch-up, text
  apply, rejection), `LookAroundReadOnlyTests` (forced sandbox, rejected
  workflow shapes, declined permission), `PairingTests` (expiry, reuse,
  failed-attempt lockout, address rules, revocation including a held
  long-poll, scope enforcement, no secret in audit or logs),
  `RemoteRegistryTests` (file modes, origin verification, disconnected state).
- Existing gates: `AgentGatewayACPV2Tests`, `SurfaceCatalogTests`,
  `SurfaceParityCLITests`, `SurfaceParityGraphQLTests`,
  `SurfaceParityExecutorCoverageTests`, `SurfaceParityDTOSchemaTests`,
  `SurfaceParityWebAPITests`, `SurfaceParityConsoleReadTests`,
  `SurfaceParityLibraryTests`, `SurfaceParitySkillTests`, and the
  `RielaCLITests` example-registration tests.

Commands:

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter <Suite>'
scripts/surface-parity/generate-sdl.sh
cd web && bun run test && bun run build
```

and one mock run of the example with `--session-store` and `--artifact-root`
under `tmp/bots-overview/`. Tests never use `~/.riela`; pairing and registry
tests pass explicit roots.

## 15. Upstream agent-gateway follow-up (not done in this repository)

Riela-side normalisation is complete and tested against scripted agents, but
the pinned in-process agent emits only message and thought chunks. To make the
live view real for production backends, agent-gateway needs:

1. `GatewayACPStreamBridge.consume` to forward the `tool`, `usage`,
   `lifecycle` and `vendor` channels, and `GatewayStreamChunk` to gain cases
   for tool call (id, title, kind, status, locations), plan, usage and mode.
2. `GatewayACPAgent` to emit `tool_call` / `tool_call_update`, `plan`,
   `usage_update`, `config_option_update` (models, modes, thought levels) and
   `subagent_update` from the vendor event streams it already parses.
3. `GatewayACPAgent` to send `session/request_permission` when the vendor CLI
   asks for approval, and to honour the selected option id or `cancelled`.
4. A structured rate-limit or quota error code with an optional reset time in
   the gateway error payload and `_meta`, for `limited` (§6.8).
5. Reported models and modes at `session/new` so the catalog (§7.2) is filled
   before the first turn.

Until then production sessions report `activitySource: acp` with message and
thought events, step events and settlement only; plans, tool calls, live
catalog updates and permission prompts appear as soon as a pin that includes
the items above is adopted, with no riela change. The pin is not changed by
this work.

## 16. Rollout

Slices ship in order a → g. Each slice ends with its focused suites, the
parity gates and the SDL green. If the run cannot finish all slices, earlier
slices are finished and verified completely and the remaining plans stay
active.

Suggested plans (the plan author owns final names), each with directory-level
`writePaths`:

| Plan | Slice | Directories |
| --- | --- | --- |
| `impl-plans/bots-01-record-overview.md` | a | `Sources/RielaCore`, `Sources/RielaCLI`, `Sources/RielaGraphQL`, `Sources/RielaAppSupport`, `web/src`, `Tests` |
| `impl-plans/bots-02-activity-stream.md` | b | `Sources/RielaCore`, `Sources/RielaAdapters`, `Sources/RielaCLI`, `Sources/RielaGraphQL`, `web/src`, `Tests` |
| `impl-plans/bots-03-model-catalog.md` | c | same as a, plus `Sources/RielaAdapters` |
| `impl-plans/bots-04-list-state.md` | d | same as a |
| `impl-plans/bots-05-memory.md` | e | same as a, plus `Sources/RielaWork` (redaction reuse only) |
| `impl-plans/bots-06-jobs-suggestions.md` | f | same as a, plus `examples` |
| `impl-plans/bots-07-pairing-remotes.md` | g | `Sources/RielaServer`, `Sources/RielaCLI`, `Sources/RielaGraphQL`, `Sources/RielaAppSupport`, `Sources/RielaApp`, `web/src`, `Tests` |

Constraints: no `Package.swift` pin change; no backward-compatibility shims;
memory schema unchanged; session store migration additive; scratch files only
under `tmp/`; no push.

## 17. Risks

- Scope. Seven slices across core, CLI, GraphQL, server and web. The slice
  order and the finish-earlier-first rule bound partial delivery.
- Permission answering. A wrong default would approve tool use. Every
  non-answer path resolves to `cancelled`, unlinked sessions keep a zero wait,
  and unknown option kinds are never approval (§6.6).
- Look-around writes. Enforcement is by forced sandbox, workflow-shape
  rejection and zero permission wait, each with a test (§10.2).
- Memory injection of untrusted text. Notes and instructions are separated at
  write time and labelled in the prompt (§9.2, §9.5).
- Store contention. Activity writes share the session store database. Text is
  coalesced to one write per second per session; recorder failures never fail
  a step (§6.4).
- Generation 13. Older builds refuse a migrated store, as with every earlier
  bump.
- Upstream gap. The rich live view is provable only with scripted agents until
  the follow-up lands (§15).
- Pairing. Bearer secrets, scopes and revocation are covered by tests; keys
  issued before this change keep full access because they have it today.
