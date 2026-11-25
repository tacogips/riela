# Ask Riela: Runtime-Grounded Chat Unified with Workflow Authoring

Status: design for implementation on `feat/bots-overview` (baseline
`6b370139`, which contains the Bots feature). No GitHub issue; intake was
derived from the `fable-sol-design-and-implement-review-loop` workflow input
(`workflowExecutionId fable-sol-design-and-implement-review-loop-session-4`).
Open defaults that the user may revisit are in
`design-docs/user-qa/qa-ask-riela-chat.md`; none blocks implementation.

Implemented and accepted on 2026-11-26. Plans:
`impl-plans/completed/ask-riela.md` and `impl-plans/completed/ask-0*.md`; user
guide: `docs/ask.md`. Shipped deviations, accepted in plan review and recorded
in the parent plan section 3.4 (the sections below still carry the original
wording):

- §5.3, §9, §10.1: Ask does not run on `official/cursor-sdk`; such a turn is
  refused with `ask_provider_unsupported` before anything is written.
- §13: `riela ask --no-follow` is accepted only for a paired remote; for a
  local turn it is a usage error.
- §7.3: the definition audit reason `ask:<conversationId>/<actionId>` is not
  written; the link is kept on the confirmed action row.
- §9: assistant settings list models from `ModelManifest` only; live vendor
  listing is dropped.

Baselines that this design reuses and does not restate:

- `design-docs/specs/design-bots-overview.md` (activity event model §6,
  provider and model catalog §7, remotes and scopes §11, control surfaces §12,
  upstream agent-gateway gap §15)
- `design-docs/specs/design-control-surface-parity.md` (SurfaceCatalog, gates,
  generated SDL; console reads and writes live on GraphQL)
- `design-docs/specs/design-agent-tool-policy-presets.md` (`none` preset argv)
- `design-docs/specs/design-workflow-graph-studio.md` (workflow editor,
  authoring projection with opaque retain handles)

No earlier design covers a runtime-grounded chat. The documents above and
`design-voice-assistant.md`, `design-riela-note-edit-agent-ui.md` and
`design-rielaapp-*` were checked; none can hold this feature without hiding
its boundary, so this is a new dedicated document.

## 1. Problem (verified at `6b370139`)

- Two unrelated assistants exist and neither can read runtime records.
  - Workflow editor chat: `web/src/workflows/WorkflowAgentChat.tsx` posts to
    `/api/v1/workflow-editor/generations` (start, status, cancel), handled by
    `Sources/RielaCLI/WebWorkflowRequestHandler+Generation.swift` with
    `WorkflowEditorGenerationStore` and `WorkflowEditorAuthoringRounds`
    (`Sources/RielaAppSupport`). State is in memory, the client polls every
    400 ms, the model replies in NDJSON rounds and each round rewrites the
    visible graph.
  - RielaApp mini chat: `Sources/RielaApp/EntryPoint+Assistant.swift`. It runs
    an agent with write access that authors and executes a private workflow.
    Its transcript is `RielaAppAssistantSettings.messages` (max 80).
- Vendor selection: `RielaAppAssistantSettings { vendor, modelsByVendor }`
  (`Sources/RielaAppSupport/RielaAppProfileModels.swift`),
  `RielaWebAssistantProvider.resolve/backend`
  (`Sources/RielaCLI/RielaWebAssistantProvider.swift`). `automatic` is honoured
  when stored but `updateAssistantConfiguration` refuses to select it.
- Two model lists exist: `Sources/RielaAppSupport/Resources/assistant-models.json`
  (read by `RielaAppAssistantModelCatalog`, plus live listing in
  `RielaAppAssistantModelLoader`) and `ModelManifest`
  (`Sources/RielaCore/ModelCatalog/ModelManifest.swift`), which feeds the Bots
  catalog. Both are stale: neither lists `gpt-6.2-sol`, `gpt-6.1-terra`,
  `gpt-6-astra`, `claude-fable-5-2`, `claude-opus-5-5`, `claude-sonnet-5-5` or
  `claude-haiku-5-5`.
- Tool mechanisms in the pinned agent-gateway (`39796860`, pin unchanged):
  - `GatewayACPMCP.swift`: client-provided stdio MCP servers are handed to the
    vendor CLI for `claudeCode` (`--mcp-config`) and `codex`
    (`-c mcp_servers.<name>...`) only. `connectsToMCPServers` is false for
    `cursor`, `cursorAPI`, `openAI`, `anthropic`, `gemini`, `openRouter`.
  - API vendors run no tool loop. `GatewayAPIRequest.swift` sends only the
    vendor's built-in web search tool; a client cannot supply tool definitions.
    Native tool calling is therefore not available without a pin change.
  - Riela sends `mcpServers: []` today
    (`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`, v1 and v2).
  - The in-process agent emits only message and thought chunks (Bots design
    §15), so a vendor's own tool-call events never reach riela.
- `AgentToolPolicyPreset.none` removes every vendor tool for `codex-agent`,
  `claude-code-agent`, `official/openai-sdk`, `official/anthropic-sdk`,
  `official/gemini-sdk` and `official/cursor-sdk`. It is not supported for
  `cursor-cli-agent`. The preset also empties the vendor MCP configuration.
- Activity (`activity_events`, `activity_state`, `activity_requests`) is keyed
  by a session id string. `SQLiteWorkflowActivityRecorder` and
  `BotStore.waitForActivity` do not require a workflow session to exist.
  `Query.botActivity` does: it reports `sessionStatus: unknown` and the web
  stream stops when the id is not a session.
- `BotStore.write` creates its tables with `CREATE TABLE IF NOT EXISTS` on every
  writable open; reads treat a missing table as empty. The session store is at
  generation 13.
- Redaction in use: `BotMemoryRuntime.redactionRules(environment:)` builds
  `HandoverRedactionRules` from environment variables whose names contain KEY,
  TOKEN, SECRET, PASSWORD or CREDENTIAL; `redactAdapterSensitiveText`
  (`Sources/RielaAdapters/AdapterUtilities.swift`) adds pattern rules
  (`sk-…`, `Bearer …`, `NAME_TOKEN=value`).
- `riela bot create` text output writes the row to stdout without a line end
  and the `model_unknown` warning to stderr (`renderBotMutation`), so a
  terminal shows `release-bot  release-botmodel_unknown: ...`.

## 2. Goals and non-goals

Goals:

- One persisted chat service that answers questions about this riela server
  from its runtime records, on CLI, GraphQL and the web console.
- A fixed, read-only, typed tool set implemented once.
- Mutations only as typed proposed actions that the user confirms.
- Vendor and model from one source: assistant settings for the default, the
  Bots catalog for lists and overrides.
- Workflow authoring as a capability of the same chat.
- Streaming through the Bots activity event model and long-poll.
- The same chat against a paired remote.

Non-goals:

- A pin change, vendoring or patching of agent-gateway.
- A new transport (SSE, WebSocket, subscription) or a new auth system.
- New REST console routes. The three generation routes are removed.
- Replacing the RielaApp native mini chat. It keeps its behaviour (an agent
  that executes private workflows) and its transcript. It only shares the
  vendor resolution and the model lists that this design changes (§9).
- Web search, file access or command execution for the chat model.
- Chat memory across conversations, kaiba, or bot memory writes.
- An interactive terminal REPL (qa item 2).

## 3. Names

User-facing name: "Ask Riela". Surface family: `ask`. Record prefix: `ask`.
Code lives in new directories only, plus call-site wiring:

| Module | Directory | Holds |
| --- | --- | --- |
| RielaCore | `Sources/RielaCore/Ask/` | models, limits, store and schema, context reference, tool descriptors, tool-call protocol parsing, proposed actions, citation parsing |
| RielaCLI | `Sources/RielaCLI/Ask/` | `AskService`, read surface, tool executor, turn engine, tool server, commands, GraphQL provider, remote forwarding |
| RielaGraphQL | `Sources/RielaGraphQL/Ask/` | contracts, schema descriptors, document executor |
| web | `web/src/ask/` | panel, client, pure logic |

## 4. Storage

Owned by the runtime store. Three tables in the session store database,
created by `AskStoreSchema` with `CREATE TABLE IF NOT EXISTS` on writable open,
the same way `BotStoreSchema` works. No generation bump: the change is purely
additive, older builds ignore the tables, and a read on a store without them
returns empty.

- `ask_conversations(conversation_id PRIMARY KEY, record_json, updated_at)`
- `ask_messages(conversation_id, seq, record_json, PRIMARY KEY (conversation_id, seq))`
- `ask_actions(action_id PRIMARY KEY, conversation_id, record_json, status, updated_at)`

Ids are assigned by the store: `ask-<uuid>` for conversations, `act-<uuid>`
for actions, `turn-<n>` (1-based per conversation) for turns.

`AskConversation`:

| Field | Meaning |
| --- | --- |
| `conversationId`, `title` | title is the first 80 characters of the first user message |
| `context` | `{ kind: none|session|bot|workflow, id }` (§6) |
| `selection` | `{ vendor?, providerInstanceId?, model?, effort? }` as requested (§9) |
| `turn` | current or last turn: `{ turnId, status, startedAt, finishedAt?, backend, providerInstanceId, model, toolTransport, error?, runnerId, heartbeatAt }` |
| `usage` | counters: `turns`, `toolCalls`, `toolBytes` |
| `createdAt`, `updatedAt` | |

Turn status: `running`, `completed`, `failed`, `cancelled`.

`AskMessage`: `{ seq, role: user|assistant, text, turnId, citations[], createdAt }`.
A user message is written when the turn starts. One assistant message is
written when the turn completes. A failed or cancelled turn writes no
assistant message; the turn `error` carries the reason.

Streaming events are not stored here. They go to the existing activity tables
under the activity key `ask:<conversationId>` with `executionId = turnId`
(§8).

Bounds (`AskLimits`, constants; tests inject smaller values):

| Limit | Value |
| --- | --- |
| user message | 16,384 bytes (today's editor limit) |
| assistant message stored | 32,768 bytes, cut with `truncated: true` |
| messages kept per conversation | 200, oldest removed first |
| conversations kept per store | 200, least recently updated removed first, never one with a running turn |
| history sent to the model | last 12 messages, 4,000 characters each (today's editor limit) |
| turns per conversation | 50 |
| tool calls per turn / per conversation | 24 / 400 |
| tool result | 16 KiB each after redaction, cut with `truncated: true` |
| tool result bytes per turn / per conversation | 256 KiB / 4 MiB |
| rounds per turn (rounds transport) | 12 |
| turn deadline | 600 s (today's editor deadline) |
| draft definition | 524,288 bytes (today's editor limit) |

Removing a conversation deletes its messages, its actions that are not
`confirmed`, and its activity rows (`BotStore.deleteActivity`). Confirmed
action rows are kept as the audit record (§7.3). Session retention and `riela gc`
do not touch `ask_*` tables.

`RielaAppAssistantSettings` storage is unchanged: `vendor`, `modelsByVendor`,
`assistance`, `isFolded` and `messages` keep their JSON shape and meaning.
`messages` stays the RielaApp mini chat transcript. Nothing is migrated and
nothing stored becomes unreadable.

## 5. Tool set

### 5.1 Read tools

`AskToolSet` in `RielaCore` is a constant list of descriptors: name, argument
schema (JSON Schema subset: string, integer, boolean, enum, required), and
result kind. `AskToolExecutor` in `RielaCLI` runs a call against
`AskReadSurface`, a protocol with one function per tool. The production
implementation calls the function that already backs the listed surface; no
tool has its own store query.

| Tool | Arguments | Existing surface it calls |
| --- | --- | --- |
| `session_list` | `workflowName?`, `status?`, `limit` (1...50, default 20) | `Query.workflowSessions` |
| `session_status` | `sessionId` | `Query.workflowSession` (status, lineage, step executions with status, attempt, times, error summary) |
| `session_progress` | `sessionId`, `includeChildren?` | `Query.sessionProgress` |
| `session_health` | `sessionId` | `Query.sessionHealth` |
| `session_logs` | `sessionId`, `stepExecutionId?`, `tail` (1...200, default 80), `contains?` | the reader behind `riela session logs` |
| `ops_overview` | none | `Query.opsOverview` |
| `bot_list` | none | `Query.bots` |
| `bot_board` | `botId` | `Query.bot` (record, board groups, routines, suggestions summary) |
| `bot_activity` | `sessionId` or `botId`, `afterSequence?`, `limit` (1...100) | `Query.botActivity` with `waitMs = 0` |
| `routine_list` | `status?` | `Query.routines` |
| `workflow_list` | `query?` | `Query.workflows` |
| `workflow_inspect` | `workflowId` | `riela workflow inspect` projection, through the authoring projection (retain handles, no secret values) |
| `workflow_validate` | `workflowId` | `riela workflow validate` |
| `definition_history` | `workflowName`, `limit` (1...50) | `Query.workflowDefinitionHistory` |
| `model_catalog` | `providerInstanceId?` | `Query.modelCatalog` |
| `remote_list` | none | `Query.remotes` (names, server names, connection; never tokens) |

Rules:

- Every tool reads the server that runs the conversation. No tool takes a
  `remote` argument and no tool fans out to remotes.
- Arguments are validated against the schema before the call. Unknown tool
  name → `tool_unknown`. Invalid arguments → `tool_arguments_invalid`. A
  missing record → `not_found`. All three are returned to the model as an
  error result; none fails the turn.
- Each result is `{ ok, data | error, refs[], truncated }`. `refs` are the
  records the result contains: `{ kind: session|step|bot|workflow|routine, id, sessionId? }`,
  filled by the executor from typed fields, never from text.
- Result pipeline, in this order, in one function: project to the tool's
  result shape → redact (§10.2) → cap to 16 KiB → count against budgets →
  record activity (§8) → return.
- A budget overrun returns `budget_exceeded` as the result and the executor
  runs nothing. The turn continues so the model can answer from what it has.

### 5.2 Proposal tools

Two more tools exist. They write only an `ask_actions` row.

- `propose_action { kind, target, reason? }` (§7.1).
- `propose_workflow { definition, baseWorkflowId? }` (§11).

There is no other tool. In particular there is no tool that calls a mutation,
writes a file, runs a command or fetches a URL. A test enumerates `AskToolSet`
and asserts that `AskReadSurface` and the executor's dependencies contain no
mutating function (the production executor is constructed from read providers
and the ask store only).

### 5.3 How tools are offered (one executor, two transports)

The mechanism the intake names for API backends, native tool calling, does not
exist in the pinned gateway (§1). The design therefore has two transports and
both call the same `AskToolExecutor`:

| Transport | Backends | How |
| --- | --- | --- |
| `mcp` | `codex-agent`, `claude-code-agent` | A stdio MCP server is handed to the gateway in `session/new`; the vendor CLI calls the tools itself |
| `rounds` | `cursor-cli-agent`, `official/openai-sdk`, `official/anthropic-sdk`, `official/cursor-sdk`, and any backend when `mcp` is unavailable | The host runs the tool loop: the model asks for tools in a line protocol, the host executes them and calls the model again |

Selection is deterministic and recorded on the turn (`toolTransport`):
`mcp` when the backend is one of the two above and the host has an absolute
path to a `riela` executable; otherwise `rounds`.
`RIELA_ASK_TOOL_TRANSPORT=rounds` forces `rounds`. This switch exists because
the vendor CLI side of `mcp` cannot be exercised by deterministic tests (§15).

`mcp` transport:

- `AdapterExecutionInput` gains `mcpServers: [AdapterMCPServer]` (name,
  absolute command, arguments, environment), default empty. The gateway
  adapter passes it to `ACPNewSessionRequest` / `ACPV2NewSessionRequest`
  instead of the literal `[]`. Workflow nodes never set it.
- The server is `riela ask tool-server --session-store <root> --working-dir <dir>
  --conversation <id> --turn <turnId>`. It speaks MCP over stdio
  (`initialize`, `tools/list`, `tools/call`; nothing else), lists `AskToolSet`
  plus the two proposal tools, and runs each call through `AskToolExecutor`
  against the store. It refuses to start unless that turn is `running`.
  It exits when stdin closes.
- The executable path comes from the host: the running `riela` binary for CLI
  hosts, the bundled sibling `riela` for RielaApp (the lookup
  `DaemonWorkflowEventServeProcess` already uses, absolute paths only).
- Budgets, redaction and activity recording happen in the tool-server process
  through the store, in a transaction per call, so they hold across processes.

`rounds` transport:

- The model replies with one JSON object per line.
  `{"type":"tool","id":"<id>","name":"<tool>","arguments":{...}}` asks for a
  tool; at most 8 per round. `{"type":"message","text":"..."}` is answer text.
  A line that is not a JSON object of a known type is answer text.
- A round with at least one `tool` line is followed by another model call whose
  prompt carries the results. A round with none ends the turn; its answer text
  is the assistant message. Reaching 12 rounds ends the turn with the text of
  the last round and a `notice` event `round_limit`.
- This replaces `WorkflowEditorAuthoringRounds`; the two do not coexist.

## 6. Context reference

`AskContext { kind, id }` with `kind` one of `none`, `session`, `bot`,
`workflow`. It is the only context a client sends. The server resolves it at
the start of every turn through the same read surface:

| Kind | Resolved summary |
| --- | --- |
| `session` | session id, workflow name, status, current step, started and finished times |
| `bot` | bot id, name, paused, board counts |
| `workflow` | workflow id, origin, definition revision, activation state |

- The summary is redacted, capped at 4 KiB and placed in the prompt as a
  context record. Its ref is added to the turn's refs. "This run" resolves to
  it.
- An id that does not resolve fails the request with `ask_context_not_found`
  before any model call.
- `sendAskMessage` may carry a new context; the conversation then stores it.
  The web panel sends the current view on every send, so context follows
  navigation.
- A client never supplies record content. The one client-supplied document is
  the editor's unsaved draft (§11), which is user input like the message and
  is labelled as such in the prompt.

Remote is not part of the context. It is routing (§12).

## 7. Proposed actions

### 7.1 Kinds

| `kind` | `target` | Mutation executed on confirm |
| --- | --- | --- |
| `stopSession` | `sessionId` | `Mutation.stopSession` |
| `rerunSession` | `sessionId`, `stepId` | `Mutation.rerunSession` |
| `answerBotRequest` | `requestId`, `optionId` or `decline` | `Mutation.answerBotRequest` |
| `setBotPaused` | `botId`, `paused` | `Mutation.setBotPaused` |
| `applyWorkflow` | proposal definition (§11) | `Mutation.registerMutableWorkflow` or `Mutation.updateMutableWorkflow`, or none for an editor draft |

The list is closed. `propose_action` rejects any other kind with
`action_kind_unknown`.

### 7.2 Proposal

`propose_action` validates the target with the read surface (the session
exists and is not terminal for `stopSession`; the step exists for
`rerunSession`; the request is pending and the option id is one of its options
for `answerBotRequest`; the bot exists for `setBotPaused`). A failed check is
returned to the model as an error result and writes nothing. On success it
writes an action `{ actionId, conversationId, turnId, kind, target, reason,
status: proposed, createdAt, expiresAt }` and returns the `actionId`.

- `workflowId` for the session mutations is filled by the server from the
  session record, never by the model.
- `reason` is model text: plain text, 200 characters at most. Clients show the
  kind and the typed target as the card title and the reason as secondary
  text.
- At most 5 `proposed` actions per turn; more are rejected with
  `action_limit`.
- An action expires 24 hours after creation.

### 7.3 Confirm, dismiss, audit

`confirmAskAction(conversationId, actionId)` and
`dismissAskAction(conversationId, actionId)`:

1. One conditional update moves the row from `proposed` to `confirming` or
   `dismissed`. The first decision wins; a second gets
   `action_already_decided`. An expired row gets `action_expired`.
2. Confirm re-validates the target (§7.2), then calls the provider function
   behind the listed mutation, the same function the GraphQL field calls, with
   the authority of the confirming request. Nothing is executed from model
   text: the call arguments are built from the stored typed target.
3. The row ends as `confirmed` with `result { ok: true, summary, ids }` or
   `failed` with `result { ok: false, code, message }`.

The row is the audit record: kind, target, reason, conversation, turn,
`proposedAt`, `decidedAt`, `decision`, `decidedBy` (`local`, or the pairing
grant id and client name of the request), and `result`. Decided rows are never
updated again and confirmed rows survive conversation removal. The applied
workflow mutation also writes its normal definition audit record; its reason
is `ask:<conversationId>/<actionId>`.

Authority: confirm and dismiss are mutations outside the admin set, so a
remote caller needs the `operate` scope (Bots design §11.2). Every kind maps
to a mutation that `operate` may already call directly, so confirmation grants
nothing new.

## 8. Turn engine, streaming, cancellation

`AskService.send` (start is send with a new conversation):

1. Validate the message and budgets (`ask_budget_exceeded` when the
   conversation is at 50 turns), reject when a turn is `running`
   (`ask_turn_running`), resolve context (§6) and vendor (§9).
2. In one transaction: write the user message, the turn (`running`) and the
   counters. Record `stepStarted` on the activity key (`stepId: "ask"`,
   `nodeId: "ask"`, backend, requested model).
3. Return the conversation. The turn runs in a task owned by the host's
   `AskRuntime` actor (one per host process). The CLI one-shot awaits it.
4. Run the model through `makeProductionNodeAdapter`, or an injected
   `NodeAdapter` in tests, with the policy of §10.1.
5. On completion write the assistant message with citations (§8.2), set the
   turn `completed`, and settle activity with `completed`.

### 8.1 Activity mapping

The chat writes to the existing recorder (`SQLiteWorkflowActivityRecorder`),
journal and reducer. No new event kind is added.

| Source | Activity |
| --- | --- |
| backend event with `activity` (message, thought, plan, usage, stop, …) | recorded as is in `mcp` transport |
| `rounds` transport model output | `message` events for answer text only, emitted per completed line; `tool` lines are never shown as text; thoughts, plans and usage are recorded as is |
| tool call accepted by the executor | `toolCall { toolCallId, title: tool name, toolKind: "read" or "propose", status: inProgress }` then `completed` or `failed` |
| proposal written | the `toolCall` above; clients read the card from the conversation |
| turn end | `stop`, `stepFinished`, `settled` |

`activity_state.source` is `acp` as for any agent step.

Read: `Query.askActivity(conversationId, afterSequence = 0, limit = 200,
waitMs = 0, remote)` returns the fields of `BotActivityPage` with
`turnStatus` in place of `sessionStatus`. It uses `BotStore.waitForActivity`,
the same 250 ms check, the same 25 s cap, the same pool of 32 waiters and the
same per-wake grant re-check. The wait ends when an event exists after the
cursor, when the turn is not `running` and its activity is settled, or when
the time is up. `Query.botActivity` is not reused directly because it derives
its end condition from a workflow session record (§1).

### 8.2 Citations

The system prompt tells the model to cite with `[[session:<id>]]`,
`[[step:<sessionId>/<stepId>]]`, `[[bot:<id>]]`, `[[workflow:<id>]]`,
`[[routine:<id>]]`. When the turn completes the server parses the markers and
keeps, as `citations[]` on the message, those that match a ref gathered in
this conversation (tool results and resolved context). A marker without a
matching ref stays in the text and is not a citation. Clients turn only
`citations[]` into links; the CLI prints them as a `Records:` list.

### 8.3 Cancellation and failure

`cancelAsk(conversationId)` cancels the turn task. Every terminal path ends
with exactly one settlement on the activity key, which closes open tool calls
as `interrupted` (existing invariant, Bots design §6.7):

| Path | Turn status | Settle reason |
| --- | --- | --- |
| completed | `completed` | `completed` |
| `cancelAsk`, client gone in CLI one-shot | `cancelled` | `cancelled` |
| deadline | `failed`, `ask_timeout` | `timeout` |
| adapter or vendor error | `failed`, redacted message | `providerError` |
| host process died | `failed`, `ask_interrupted` | `processExit` |

Process death: the runner writes `heartbeatAt` every 5 s. Any read or send
that finds a `running` turn whose heartbeat is older than 30 s, and whose
`runnerId` is not this process's runner, marks it failed and calls
`settleOpenActivity(reason: processExit)` in the same call. `cancelAsk` on a
turn that is not running returns the conversation unchanged.

A failed turn never produces an assistant message. Clients show the turn
error.

## 9. Vendor and model

One rule set, in `AskModelSelection.resolve(settings, selection, catalog,
environment)` in `RielaCLI/Ask`, used by the chat. The workflow editor uses
the chat. The RielaApp mini chat keeps calling
`RielaWebAssistantProvider.resolve` and gets its model lists from the same
manifest.

- Default: the stored assistant settings. `vendor` → driver through
  `RielaWebAssistantProvider.backend(for:)` → the built-in provider instance
  with that driver id. Model: `settings.selectedModel(for:)`.
- `automatic` resolves through `RielaWebAssistantProvider.resolve` with its
  current order (codex, claude, cursor-agent executables, then
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`/`CLAUDE_API_KEY`, `CURSOR_API_KEY`).
  `updateAssistantConfiguration` and the settings UI now accept `automatic`
  as a selectable value.
- Per-conversation override: `selection { providerInstanceId, model?, effort? }`.
  The instance must exist in the catalog (built-in or user-declared), else
  `provider_instance_not_found`. A user-declared instance contributes its
  `providerName`, `providerProxy` and `apiKeyEnvironment` to the node payload.
  `official/gemini-sdk` instances are refused with `ask_provider_unsupported`
  (no assistant vendor maps to it today and nothing in the intake adds one).
- Model: an unlisted model is allowed and reported as the warning
  `model_unknown` on the mutation payload (Bots design §7.3). `default` or
  unset is never sent to the gateway. `effort` must be one of the model's
  catalog `reasoningEfforts` when the catalog lists any, else
  `ask_option_unsupported`.
- The resolved backend, instance and model are stored on the turn and shown by
  every client.
- A resolved vendor that cannot run (no executable, no key) fails the request
  with `ask_vendor_unavailable` and the names of what is missing. No answer is
  produced.

One model list:

- `ModelManifest` becomes the only bundled list. It gains, ahead of the
  existing ids: `gpt-6.2-sol`, `gpt-6.1-terra`, `gpt-6-astra` for
  `codex-agent` and `official/openai-sdk`; `claude-sonnet-5-5`,
  `claude-opus-5-5`, `claude-fable-5-2`, `claude-haiku-5-5` for
  `claude-code-agent` and `official/anthropic-sdk`. It also gains every id
  that is in `assistant-models.json` today and not yet in the manifest, so no
  currently offered model disappears. Existing ids stay.
- `RielaAppAssistantModelCatalog` is computed from `ModelManifest` through the
  vendor → driver map. `assistant-models.json`, the bundle lookup
  (`installedCatalogURL`) and the `resources:` entry of the `RielaAppSupport`
  target are removed (a target setting in `Package.swift`, not a dependency
  pin; `scripts/lib/riela-web-packaging.sh` copies bundles by glob and must
  still pass with none for this target).
- The first manifest entry of a driver is the default for a vendor with no
  stored choice, as today. That default becomes `gpt-6.2-sol` and
  `claude-sonnet-5-5` (qa item 3). A stored `modelsByVendor` value always
  wins and is never rewritten.
- `GraphQLAssistantConfiguration.modelCatalogs` is built from the Bots catalog
  for each vendor's built-in instance (manifest, reported and custom models,
  with option metadata). `RielaAppAssistantModelLoader` is removed; models a
  backend reports reach the list through `provider_reports` as they already do
  for bots.
  Module seam: `RielaWebConfigurationSupport.assistantConfiguration` is in
  `RielaAppSupport`, which cannot import `RielaCLI` where
  `ModelCatalogService` lives. The function therefore takes the per-driver
  model lists as a parameter. Its callers (the `RielaCLI` web GraphQL
  configuration provider and `RielaAppWebGraphQL`) pass the lists of the
  built-in instances from `ModelCatalogService.catalog()`. Without that
  argument the function uses `ModelManifest` alone, which is what
  `RielaAppAssistantModelCatalog` returns.
- Settings UI (`web/src/views/SettingsView.tsx`): vendor select including
  Automatic, model select from that catalog, and a link to `#/models`.

## 10. Safety

### 10.1 Read-only enforcement by policy

The chat node payload is built by one function, `AskAgentPolicy.payload`, and
a test asserts its output per backend:

| Backend | Policy |
| --- | --- |
| `codex-agent`, `claude-code-agent`, `rounds` transport | `agentToolPolicy.preset = none`, `agentSandbox = read-only` |
| `codex-agent`, `mcp` transport | the `none` preset argv without its empty-MCP-configuration arguments, `agentSandbox = read-only`, plus `mcp_servers.riela-ask.default_tools_approval_mode="approve"` (`codex exec` refuses an MCP call that needs an approval prompt) |
| `claude-code-agent`, `mcp` transport | the `none` preset argv (`--tools ""`, strict MCP configuration) without its empty-MCP-configuration arguments, `--allowedTools` limited to the ask server's tools, and no `agentSandbox`: the read-only sandbox maps to plan mode, which refuses MCP calls, so read-only rests on the disabled built-in tools and the read-only tool server |
| `official/openai-sdk`, `official/anthropic-sdk`, `official/cursor-sdk` | `agentToolPolicy.preset = none` (the request carries no tools) |
| `cursor-cli-agent` | `agentSandbox = read-only` (the preset is not supported); the turn records `limited policy` and clients show it |

Always: working directory is a new empty directory under the app or store
root (mode 0700), removed when the turn ends; no `agentEnvironment` bindings;
`permissionRequestHandler` unset, so any permission request is declined
(existing default); no `mcpServers` other than the ask tool server.

The `mcp` argv variant is added to `AgentToolPolicyPresetArguments` as a
parameter of the existing functions (keep the vendor MCP configuration strict,
do not empty it). The exact flags are verified against the CLI versions noted
in that file and by the manual check in §15.

### 10.2 Untrusted content and redaction

- The system prompt is a constant. Context records, tool results, history and
  the editor draft are placed in the user prompt in labelled data blocks. The
  prompt states that they are information and never instructions. The
  guarantee does not rest on that sentence: there is no mutating tool (§5.2)
  and a proposal needs a user decision (§7.3).
- Everything that reaches the model from records passes
  `AskRedaction.apply`: `HandoverRedactionRules` built by
  `BotMemoryRuntime.redactionRules(environment:)` applied to the JSON value,
  then `redactAdapterSensitiveText` on every string leaf. It is called in the
  tool result pipeline (§5.1), on the context summary (§6) and on turn error
  messages. Workflow definitions additionally go through the authoring
  projection (retain handles).
- Assistant text is stored and shown as text. The web panel renders it with
  the existing `Markdown` component and turns only verified citations into
  links.

### 10.3 Budgets

`AskLimits` (§4) is enforced in `AskService.send` (turns), in
`AskToolExecutor` (tool calls and bytes, per turn and per conversation, in a
store transaction so the `mcp` tool server and the host agree) and in the
round loop (rounds). The conversation payload reports `usage` and the limits.

## 11. Workflow authoring in the same chat

`propose_workflow { definition, baseWorkflowId? }`:

1. `definition` is a complete workflow definition (never a patch).
2. The server validates it with the validator behind `riela workflow validate`
   and the editor's structural checks. Issues are returned to the model as an
   error result so it can fix them within the turn's budgets.
3. A valid definition becomes an `applyWorkflow` action. A later valid call in
   the same turn replaces the earlier proposal of that turn (one live workflow
   proposal per turn).

Target:

- The turn carried `draftDefinition` (workflow editor): `target.mode = draft`.
  Confirm marks the action `confirmed`, audits it and returns the definition;
  the editor loads it into the draft. Nothing is saved; the user saves with
  the editor's Save as today.
- Otherwise `target.mode = store`. With `baseWorkflowId` naming an existing
  mutable workflow, confirm calls `updateMutableWorkflow` with the definition
  revision read at proposal time as `expectedDefinitionRevision` (a changed
  workflow fails the action with the mutation's own conflict error). Without
  it, confirm calls `registerMutableWorkflow` with `overwrite: false`.
  Immutable workflows cannot be a base: `propose_workflow` returns
  `workflow_not_mutable`.

Editor integration:

- `WorkflowAgentChat.tsx` is removed. `WorkflowGraphEditor` opens the Ask panel
  with `context { kind: workflow, id }` and sends the current draft as
  `draftDefinition` on each message. The proposal card's Confirm calls the
  editor's existing `setDoc`.
- The graph no longer changes while the model works. It changes when the user
  confirms. This is the intake's rule for generated workflows.
- The authoring guidance in `workflowEditorSystemPrompt` (format, roles, retain
  handles, no coordinates) moves into the ask system prompt. The round and
  `continue` rules are dropped.

Removed with no shim: the three `/api/v1/workflow-editor/generations` routes
(handler, `RielaWebAPIRouteTable` entries, the `generation-start`,
`generation-status`, `generation-cancel` rows in
`SurfaceCatalog+RowsConsole.swift`), `WorkflowEditorGenerationStore`,
`WorkflowEditorAuthoringRounds`, `RielaWebWorkflowRuntime.generations`, the
`workflowEditorGenerations` accessor in `Sources/RielaApp/EntryPoint.swift`
and their tests. The other `workflow-editor` routes stay.

## 12. Paired remote

Every `ask` GraphQL field takes an optional `remote`, resolved with
`RemoteRouting.resolve` exactly as bot fields are (`*` is refused).

- With a remote, the local executor forwards the same document to that server
  with the stored token. The conversation, its records, its tool reads, its
  model credentials and its confirmed mutations all belong to that server.
  Nothing is stored locally.
- Every `ask` payload carries `origin` (Bots design §11.5). Clients show it.
- `remote_unreachable`, `remote_not_found` and `scope_insufficient` are
  returned as errors. No answer text is produced on those paths and no cached
  answer exists.
- Queries need `read`; `startAsk`, `sendAskMessage`, `cancelAsk`,
  `confirmAskAction`, `dismissAskAction` and `removeAskConversation` need
  `operate`, which the existing scope rule already gives (mutations outside
  the admin set).
- The CLI with `--remote` sends the documents directly to the remote, as bot
  commands do.

## 13. Control surfaces

SurfaceCatalog rows first (`Sources/RielaCore/SurfaceCatalog+RowsAsk.swift`),
then CLI, then GraphQL descriptors, then the SDL regenerated with
`scripts/surface-parity/generate-sdl.sh`.

| Row | CLI | GraphQL |
| --- | --- | --- |
| `ask.send` | `riela ask "<message>"` | `Mutation.startAsk`; `Mutation.sendAskMessage` with `--conversation` |
| `ask.list` | `riela ask list` | `Query.askConversations` |
| `ask.show` | `riela ask show <conversationId>` | `Query.askConversation` |
| `ask.activity` (stream) | `riela ask show <conversationId> --follow`, and the default live output of `riela ask "<message>"` | `Query.askActivity` |
| `ask.cancel` | `riela ask cancel <conversationId>` | `Mutation.cancelAsk` |
| `ask.confirm` | `riela ask confirm <conversationId> <actionId>` | `Mutation.confirmAskAction` |
| `ask.dismiss` | `riela ask dismiss <conversationId> <actionId>` | `Mutation.dismissAskAction` |
| `ask.remove` | `riela ask remove <conversationId>` | `Mutation.removeAskConversation` |
| `ask.tool-server` (process) | `riela ask tool-server` | excluded: local stdio process started by the vendor CLI |

webAPI: excluded for every row (console reads and writes are on GraphQL).
library: excluded (not a library entry point). The plan settles whether one
CLI verb maps to two GraphQL fields as one row or as two rows with a shared
binding, following how `botRow(sharesMutation:)` does it.

CLI:

- `riela ask "<message>"` options: `--conversation <id>`, `--session <id>`,
  `--bot <id>`, `--workflow <id>` (at most one of the three), `--remote <name>`,
  `--provider <instanceId>`, `--model <id>`, `--effort <value>`, `--no-follow`,
  `--output json|text`, `--session-store`, `--scope`, `--working-dir`.
- The first positional is a verb when it equals `list`, `show`, `cancel`,
  `confirm`, `dismiss`, `remove` or `tool-server`; anything else is the
  message. A message equal to a verb is passed after `--`.
- Text output streams answer text as it arrives, one line per tool call
  (`· session_status ses-…`), then `Records:` and `Proposed:` lists with the
  conversation id and each action id, so the next command is copyable.
  `--output json` prints the final conversation payload once.
- Without a server the CLI runs the turn in its own process against the local
  store, as `riela bot` commands do. Assistant settings come from the profile
  state `riela serve` reads.
- Exit code is failure when the turn fails; the error goes to stderr.

GraphQL: `AskGraphQLProviding` and `AskGraphQLDocumentExecutor` in
`RielaGraphQL/Ask`, provider in `RielaCLI/Ask`, chained in every place that
chains `BotsGraphQLDocumentExecutor` today (`ServeWebHost`, `ServeHTTPCommand`,
`RielaLibrary`, `ScopedParityCommands+GraphQLDocument`, `ParsedRemoteSelector`,
`RielaAppWebGraphQL`).

Inputs: `StartAskInput { message, context, selection, draftDefinition, remote }`,
`SendAskMessageInput { conversationId, message, context, draftDefinition, remote }`,
`AskActionInput { conversationId, actionId, remote }`,
`AskConversationInput { conversationId, remote }`.
Payload: `AskConversationPayload { conversation, messages, actions, limits,
warnings, origin }`.

Follow-up fix in the same family of output code: for text output,
`renderBotMutation` ends the stdout row with a line end before warnings are
written, and each warning is its own stderr line. JSON output is unchanged
(warnings are in the payload).

## 14. Web console

New files under `web/src/ask/`; `App.tsx` mounts the panel once, outside the
routed view, so it is available from every view. English only, low text.

- Dock: a collapsible right side panel with a rail button. Open state and the
  active conversation id are kept in `profileViewState.ts`.
- Context chip from the current route (`routes.ts`): `run-detail` and
  `ops-run` → `Run <id>`; `bot-detail` → `Bot <name>`; `workflow-detail` and
  the editor → `Workflow <id>`; otherwise none. The chip can be cleared. A
  route with `remote`, or the Bots view's selected remote, sets the panel's
  remote; the panel header shows the origin server name.
- "Ask" buttons in the Bots detail view and the run view open the panel with
  that item as context.
- Vendor and model picker: default from `Query.configuration.assistant`,
  override from `Query.modelCatalog` (instances, models, effort when the model
  lists efforts). The chosen and the resolved values are both shown.
- Streaming: `createActivityStream` from `web/src/bots/activityStream.ts` is
  given a reader parameter so it can read `askActivity`; the feed reducer
  (`activityFeed.ts`) is reused unchanged. The fallback on error is the
  existing 5 s retry.
- Messages render with the `Markdown` component. Citations become links built
  with `viewHash` (`run-detail`, `bot-detail`, `workflow-detail`), carrying
  the conversation's remote.
- Proposed-action cards: kind and typed target as title, reason as secondary
  text, Confirm and Dismiss, then the result or error. Confirm on an
  `applyWorkflow` draft action hands the definition to the open editor.
- Errors are shown as errors (`remote_unreachable`, `ask_vendor_unavailable`,
  turn errors). The panel never shows placeholder answer text.

Pure logic with unit tests: context from route, citation link building,
action card state, picker state, panel reducer over conversation plus feed.

## 15. Verification

Deterministic suites (prefixes; plans may split). None calls a live vendor.
Every store, registry and profile root is under a temporary directory.

- `AskStoreTests`: additive tables on a generation-13 store with existing
  sessions and bots, bounds (messages, conversations), removal keeps confirmed
  actions and deletes activity.
- `AskToolSetTests`: each tool against fixture stores built with the
  production stores; argument validation; `not_found`; result cap; refs.
- `AskReadOnlyTests`: the tool set has no mutating dependency;
  `AskAgentPolicy.payload` per backend and transport; argv for the `mcp`
  variant.
- `AskContextTests`: each kind resolves; unknown id fails before any model
  call; client content is never used as a record.
- `AskActionTests`: validation at proposal, confirm executes the provider
  function once with arguments from the typed target, dismiss, double
  decision, expiry, failure result, audit fields, confirmed row survives
  removal, scope `read` is refused.
- `AskModelSelectionTests`: settings default, `automatic` order, override by
  instance, unknown instance, `model_unknown` warning, unsupported effort,
  unavailable vendor.
- `AskTurnEngineTests` with a scripted `NodeAdapter`: `rounds` protocol
  (tool lines, plain text, round limit), activity mapping, citations,
  budgets per turn and per conversation, cancellation and each failure path
  settle open tool calls, stale heartbeat recovery.
- `AskToolServerTests`: MCP `initialize`, `tools/list`, `tools/call` over
  pipes against a fixture store; refusal when the turn is not running;
  budgets shared with the host. Adapter test with a scripted ACP agent
  asserting `session/new` carries the server (v1 and v2).
- `AskPromptInjectionTests`: a fixture session log line tells the model to
  stop a session. The scripted backend obeys: it calls an unknown mutating
  tool name and `propose_action stopSession`. Asserted: the session is
  unchanged, a spy mutation surface saw zero calls, at most one `proposed`
  action exists, and a secret placed in the log does not appear in any prompt
  passed to the adapter.
- `AskWorkflowAuthoringTests`: invalid definition returned to the model,
  replacement within a turn, draft confirm saves nothing, store confirm calls
  register or update with the expected revision, immutable base refused.
- `AskRemoteTests`: forwarding with a fake transport, origin, unreachable
  remote returns the error and no message.
- `AskCommandTests`, `AskGraphQLTests`: verbs, options, verb/message
  disambiguation, text and JSON output.
- Catalog follow-ups: `ModelManifestTests` (required ids present for the four
  drivers), `RielaAppAssistantModelCatalogTests` updated to the manifest
  source, a `BotCommandTests` case for the warning on its own stderr line and
  the row ending with a line end.
- Existing gates: `SurfaceCatalogTests`, `SurfaceParityCLITests`,
  `SurfaceParityGraphQLTests`, `SurfaceParityExecutorCoverageTests`,
  `SurfaceParityDTOSchemaTests`, `SurfaceParityWebAPITests`,
  `SurfaceParityConsoleReadTests`, `SurfaceParityLibraryTests`,
  `SurfaceParitySkillTests`, the `Bot*`, `Activity*` and `ModelCatalog*`
  suites, `WorkflowEditor*` tests that remain, `RielaCLITests` example
  registration.
- Web: unit tests for the pure logic in §14, `routes.test.ts`, `App.test.ts`.

Example: `examples/ask-run-status/` with a one-step mock-scenario workflow, a
scripted ask backend file (rounds transport) and `EXPECTED_RESULTS.md`: a mock
run, then `riela ask --session <id> "what is the state of this run?"` with
`RIELA_ASK_SCRIPTED_BACKEND=<file>` under `tmp/ask-riela/` stores. The
scripted backend is read only when that variable is set; it replaces the node
adapter for the chat and nothing else. The example is registered in
`Tests/RielaCLITests/RielaExampleCatalog.swift`.

Commands:

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter <Suite>'
scripts/surface-parity/generate-sdl.sh
cd web && bun run typecheck && bun test src && bun run lint && bun run build
```

Not covered by deterministic tests, recorded as a manual check for the
operator: one live turn each on codex and claude with the `mcp` transport
(tools listed, a tool call succeeds, no vendor tool is available). Until that
check passes for a CLI version, `RIELA_ASK_TOOL_TRANSPORT=rounds` is the
supported fallback.

## 16. Rollout

Suggested plans (the plan author owns final names and write paths). The chain
is serial from plan 2 on because plans 4 to 7 touch shared surface files.

| Plan | Content | Main directories |
| --- | --- | --- |
| `ask-01-catalog-and-selection` | manifest ids, assistant catalogs from the manifest, resource removal, `automatic` selectable, `AskModelSelection`, settings GraphQL, `bot create` warning fix | `Sources/RielaCore/ModelCatalog`, `Sources/RielaAppSupport`, `Sources/RielaCLI/Bots`, `Sources/RielaCLI/Ask`, `Sources/RielaGraphQL`, `Package.swift`, `Tests` |
| `ask-02-store-tools` | store, limits, context, redaction, tool set, executor, read surface, proposed-action model | `Sources/RielaCore/Ask`, `Sources/RielaCLI/Ask`, `Tests` |
| `ask-03-turn-engine` | service, rounds transport, activity mapping, citations, budgets, cancellation, policy, injection test | `Sources/RielaCLI/Ask`, `Sources/RielaCore/Ask`, `Sources/RielaCore/AgentToolPolicyPresetArguments.swift`, `Tests` |
| `ask-04-surfaces` | catalog rows, CLI, GraphQL, SDL, host chaining, remote forwarding, action confirm and audit, example | `Sources/RielaCore` (catalog files), `Sources/RielaCLI/Ask`, router and enumeration files, `Sources/RielaGraphQL/Ask`, generator and SDL files, host files, `Sources/RielaApp/RielaAppWebGraphQL.swift`, `examples`, `Tests` |
| `ask-05-mcp-transport` | `mcpServers` on the adapter input, tool server, `mcp` argv | `Sources/RielaAdapters`, `Sources/RielaCore`, `Sources/RielaCLI/Ask`, `Tests` |
| `ask-06-workflow-authoring` | `propose_workflow`, apply, removal of the generation routes, rows and stores | `Sources/RielaCLI`, `Sources/RielaAppSupport`, `Sources/RielaCore` (console rows), `Sources/RielaApp/EntryPoint.swift`, `Tests` |
| `ask-07-web` | panel, picker, streaming, links, cards, Bots and run view wiring, editor switch, settings UI | `web/src` |

Shared files outside the main directories that a plan must list in its write
paths: plan 1 needs the callers of `assistantConfiguration` (§9) and
`web/src/config` plus `web/src/views/SettingsView.tsx` only if it changes the
GraphQL shape (otherwise the settings UI change stays in plan 7); plan 5 adds
the `ask.tool-server` catalog row and CLI verb, so it needs
`SurfaceCatalog+RowsAsk.swift`, the CLI router and enumeration files and the
parity test fixtures again; plan 6 needs `RielaWebAPIRouteTable.swift`,
`SurfaceCatalog+RowsConsole.swift` and the `WorkflowEditor*` tests it removes.

Constraints: no `Package.swift` pin change; no backward-compatibility shims;
storage additive; scratch files under `tmp/`; no push; a plan that adds an
HTTP route declares it in `RielaWebAPIRouteTable` (none is planned).

## 17. Risks

- Vendor CLI behaviour with the `mcp` transport cannot be proven by
  deterministic tests. The `rounds` transport works on every backend and is
  the fallback by one environment variable.
- `cursor-cli-agent` has no tool-removal preset. It runs with the read-only
  sandbox in an empty directory and is labelled as limited policy.
- The upstream gap (Bots design §15) hides a vendor's own tool-call events.
  Ask tool calls are still shown because the executor records them itself.
- A wrong redaction path would send a secret to a vendor. One function
  redacts every record path and the injection test asserts on the prompts the
  adapter received.
- Confirm executes a mutation chosen by a model. The kind list is closed, the
  target is typed and re-validated, the caller's scope applies, and the card
  title is built from typed fields.
- Removing the generation routes changes the editor: the graph updates on
  confirm, not while the model works.
- Changing the default model for vendors without a stored choice
  (`gpt-6.2-sol`, `claude-sonnet-5-5`) changes cost and behaviour for those
  users only.
- Removing the `RielaAppSupport` resource bundle touches packaging; the
  packaging script must be checked in plan 1.
- Activity writes for chat share the session store database and the pool of
  32 long-poll waiters with bot activity.
