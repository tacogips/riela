# ask-02-store-tools: chat store, limits, context, redaction, read tools, executor, proposed actions

```json
{
  "planId": "ask-02-store-tools",
  "planPath": "impl-plans/active/ask-02-store-tools.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/Ask",
    "Sources/RielaCore/Bots/BotStore.swift",
    "Sources/RielaCLI/Ask/Tools",
    "Sources/RielaCLI/Ask/Actions",
    "Tests/RielaCoreTests/Ask",
    "Tests/RielaCLITests/Ask/Tools",
    "Tests/RielaCLITests/Ask/Actions",
    "impl-plans/progress/ask-02-store-tools.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCore/Bots/BotStore.swift",
      "intendedEdit": "In `BotStore.write`, call `try AskStoreSchema.prepare(in: database)` right after `BotStoreSchema.prepare(in: database)`. Nothing else."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2 and §3.1, §3.2. Design: §4, §5.1,
§5.2, §6, §7, §10.2, §10.3, §15.

## Intent and context

The chat answers from runtime records through a fixed read-only tool set and
may only propose mutations. This plan builds everything below the turn
engine: persisted records, the tool set, the one executor every transport
calls, and proposed actions with confirm, dismiss and audit. No model is
called here.

Current code:

- `BotStore` (`Sources/RielaCore/Bots/BotStore.swift`): `read` returns `nil`
  when the database or a table is missing; `write` prepares tables with
  `BotStoreSchema.prepare` (`CREATE TABLE IF NOT EXISTS`). Session store
  generation is 13 and must not change.
- Activity: `extension BotStore` in
  `Sources/RielaCore/BotActivity/ActivityStore.swift` (`activityPage`,
  `settleOpenActivity`, `deleteActivity(sessionIds:in:)`), recorder protocol
  `WorkflowActivityRecording` (`Sources/RielaCore/Bots/ActivityModels.swift:109`).
- Read providers (protocols in `Sources/RielaGraphQL`):
  `WorkflowExecutionGraphQLProviding`, `GraphQLConsoleProviding`,
  `WorkflowRegistryGraphQLProviding`, `WorkflowDefinitionGraphQLProviding`,
  `RoutineGraphQLProviding`, `BotsGraphQLProviding`. A local set is built in
  `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift:28-70`.
- Mutation providers: `GraphQLSessionControlProviding.stopSession/rerunSession`
  (`Sources/RielaCLI/SessionControlProvider.swift:92,159`),
  `BotsGraphQLProviding.answerBotRequest/setBotPaused`
  (`Sources/RielaCLI/Bots/BotsGraphQLProvider.swift:282,303`).
- Redaction: `BotMemoryRuntime.redactionRules(environment:)`
  (`Sources/RielaCLI/BotRuntime/BotMemoryRuntime.swift:14`),
  `HandoverRedactionRules.redactText` (`Sources/RielaWork/HandoverRedaction.swift:43`),
  `redactAdapterSensitiveText` (`Sources/RielaAdapters/AdapterUtilities.swift:358`).

## Non-goals

- No model call, prompt, turn loop or activity long-poll (plan 03).
- No CLI command, GraphQL field or catalog row (plan 04).
- No `propose_workflow` tool and no `applyWorkflow` kind (plan 06).
- No change to bot tables, activity tables or the store generation.
- No tool that takes a `remote` argument; `remote_list` only lists.

## Changes

### 1. Models, limits, schema, store (`Sources/RielaCore/Ask/`, new)

Files: `AskModels.swift`, `AskLimits.swift`, `AskStoreSchema.swift`,
`AskStore.swift`, `AskToolSet.swift`. Types exactly as overview §3.1.

`AskLimits` fields and `standard` values (design §4): `userMessageBytes`
16384, `assistantMessageBytes` 32768, `messagesPerConversation` 200,
`conversationsPerStore` 200, `historyMessages` 12, `historyMessageCharacters`
4000, `turnsPerConversation` 50, `toolCallsPerTurn` 24,
`toolCallsPerConversation` 400, `toolResultBytes` 16384,
`toolBytesPerTurn` 262144, `toolBytesPerConversation` 4194304,
`roundsPerTurn` 12, `turnDeadlineSeconds` 600, `draftDefinitionBytes` 524288,
`actionsPerTurn` 5, `actionLifetimeSeconds` 86400, `contextSummaryBytes` 4096.

Tables (design §4): `ask_conversations`, `ask_messages`, `ask_actions`, all
`CREATE TABLE IF NOT EXISTS`, plus an index on `ask_actions(conversation_id)`.

Store functions (`extension BotStore`; each write is one transaction):

| Function | Behaviour |
| --- | --- |
| `createAskConversation(context:selection:firstMessage:now:)` | id `ask-<uuid>`, title = first 80 characters of the message; then prune conversations beyond the limit, least recently updated first, never one whose turn is `running` |
| `askConversations()`, `askConversation(id:)`, `askMessages(conversationId:)`, `askActions(conversationId:)`, `askAction(id:)` | reads; missing table or database → empty or `nil` |
| `beginAskTurn(conversationId:message:context:turn:limits:now:)` | rejects `ask_turn_running` (a turn is `running`), `ask_budget_exceeded` (turn count at limit), `ask_message_too_large`; writes the user message, the turn with id `turn-<n>`, `usage.turns += 1`, optional new context; prunes messages beyond the limit, oldest first |
| `finishAskTurn(conversationId:turnId:status:error:assistantText:citations:limits:now:)` | only when that turn is `running`; writes the assistant message only for `completed` (cut to the byte limit on a character boundary, `truncated: true`); returns whether it changed anything |
| `touchAskTurn(conversationId:turnId:runnerId:now:)` | heartbeat |
| `failStaleAskTurn(conversationId:currentRunnerId:staleAfterSeconds:now:)` | when the turn is `running`, `runnerId != currentRunnerId` and the heartbeat is older: mark `failed` with `ask_interrupted`; returns `true` |
| `reserveAskToolCall(conversationId:turnId:limits:)` | counts one call per turn and per conversation, or throws `budget_exceeded`; per-turn counts are kept on the turn record |
| `addAskToolBytes(conversationId:turnId:bytes:limits:)` | adds bytes; returns `false` when a byte budget is exceeded |
| `insertAskAction(_:limits:)` | rejects `action_limit` (more than 5 `proposed` for the turn) |
| `decideAskAction(conversationId:actionId:decision:decidedBy:now:)` | one conditional `UPDATE ... WHERE status = 'proposed'`; `confirm` → `confirming`, `dismiss` → `dismissed`; expired → `action_expired`; already decided → `action_already_decided`; wrong conversation or unknown → `action_not_found` |
| `completeAskAction(actionId:result:now:)` | `confirming` → `confirmed` or `failed`; a row not in `confirming` is never changed |
| `removeAskConversation(id:)` | rejects `ask_turn_running`; deletes the conversation, its messages, its actions whose status is not `confirmed`, and its activity rows through `BotStore.deleteActivity(sessionIds: ["ask:<id>"], in:)` in the same transaction |

Errors are `AskError` with the exact codes above plus `ask_conversation_not_found`.

`AskToolSet.all`: the 16 read tools of design §5.1 (names, arguments, ranges
and defaults exactly as the table there) plus `propose_action`. Argument
validation lives here: `AskToolSet.validate(name:arguments:) throws -> JSONObject`
(applies defaults; unknown tool → `tool_unknown`; unknown key, wrong type,
out-of-range integer, missing required → `tool_arguments_invalid`).
`bot_activity` needs exactly one of `sessionId`, `botId`.

### 2. Read surface and executor (`Sources/RielaCLI/Ask/Tools/`, new)

- `protocol AskReadSurface: Sendable` with one `async throws` function per
  read tool returning `(data: JSONValue, refs: [AskRef])`, and
  `func contextSummary(_ context: AskContext) async throws -> (data: JSONObject, ref: AskRef)?`.
- `struct AskReadProviders` holding the provider existentials listed above
  plus three closures for the reads that have no GraphQL field
  (`sessionLogs`, `workflowInspect`, `workflowValidate`).
  `static func local(workingDirectory:sessionStore:scope:environment:) -> AskReadProviders`
  builds the same providers the CLI builds today. For the three closures use
  the functions behind `riela session logs`, `riela workflow inspect` and
  `riela workflow validate` (find them from the command dispatch in
  `Sources/RielaCLI/SessionCommands.swift` and
  `Sources/RielaCLI/WorkflowCommands.swift`); `workflow_inspect` returns the
  authoring projection the workflow editor uses (retain handles instead of
  secret values).
- `struct ProviderAskReadSurface: AskReadSurface` calls those providers.
  Every bot-family call passes `remote: "local"`. `bot_activity` passes
  `waitMs: 0`. `remote_list` returns names, server names and connection only.
  Refs are filled from typed fields of the provider result (session id, step
  id with its session id, bot id, workflow id, routine id).
- `enum AskRedaction`: `static func apply(_ value: JSONValue, environment:) -> JSONValue`
  and `static func text(_:environment:) -> String`. Order: the rules of
  `BotMemoryRuntime.redactionRules(environment:)` on every string leaf, then
  `redactAdapterSensitiveText` on every string leaf. Keys are not changed.
- `struct AskToolExecutor` with
  `init(store: BotStore, surface: any AskReadSurface, proposals: AskActionProposer, recorder: any WorkflowActivityRecording, environment: [String: String], limits: AskLimits, now: @Sendable () -> Date)` and
  `func execute(conversationId:turnId:toolCallId:name:arguments:) async -> AskToolResult`
  (never throws). Pipeline, in this order:
  1. the turn must be `running` with that id, else `turn_not_running`;
  2. `AskToolSet.validate`;
  3. `reserveAskToolCall` (overrun → result `budget_exceeded`, nothing runs);
  4. record activity `toolCall` `inProgress` (title = tool name, kind `read`
     or `propose`);
  5. run the surface function or the proposer; a thrown not-found error →
     `not_found`; any other error → `tool_failed` with a redacted message;
  6. redact, then cap the encoded `data` at `toolResultBytes` (replace `data`
     by a truncated JSON string and set `truncated: true`);
  7. `addAskToolBytes` (overrun → the result becomes `budget_exceeded`);
  8. record activity `toolCall` `completed` or `failed`; return.
- `func resolveContext(_:) async throws -> (summary: JSONObject, ref: AskRef)?`
  on the executor: `none` → `nil`; unresolved id → throws
  `ask_context_not_found`; summary fields as design §6, redacted, capped at
  `contextSummaryBytes`.

### 3. Proposed actions (`Sources/RielaCLI/Ask/Actions/`, new)

- `struct AskActionProposer` (uses the read surface and the store):
  `propose(conversationId:turnId:kind:target:reason:) async throws -> AskAction`.
  Validation per design §7.2: `stopSession` needs an existing, non-terminal
  session; `rerunSession` needs the session and the step; `answerBotRequest`
  needs a pending request and an `optionId` among its options, or
  `decline: true`; `setBotPaused` needs the bot and a boolean `paused`.
  Failures: `action_kind_unknown`, `action_target_invalid`. The stored target
  holds only typed fields; `workflowId` for session actions is read from the
  session record. `reason` is cut to 200 characters, control characters
  removed. `expiresAt = createdAt + actionLifetimeSeconds`.
- `protocol AskMutationSurface: Sendable` with `stopSession(sessionId:workflowId:)`,
  `rerunSession(sessionId:workflowId:stepId:)`,
  `answerBotRequest(requestId:optionId:decline:)`, `setBotPaused(botId:paused:)`,
  each returning `AskActionResult`. `ProviderAskMutationSurface` calls the
  provider functions listed above (bot calls with `remote: "local"`).
- `struct AskActionService`: `confirm(conversationId:actionId:decidedBy:) async throws -> AskAction`
  and `dismiss(...)`. Confirm: `decideAskAction` → re-run the proposer's
  validation on the stored target (failure → `completeAskAction` with
  `failed`, code `action_target_invalid`) → call the mutation surface with
  arguments built only from the stored target → `completeAskAction`. A thrown
  mutation error becomes `failed` with its code and a redacted message; the
  function returns the action, it does not throw for a failed mutation.
  `decidedBy` is a string supplied by the caller (`local`, or
  `<grantId> <clientName>`).

## Imitate

- `Sources/RielaCore/Bots/BotStoreSchema.swift` and
  `Sources/RielaCore/BotActivity/ActivityStore.swift` for schema statements,
  JSON record columns and `extension BotStore` queries.
- `Sources/RielaCore/BotJobs` suggestion store for a decide-once row.
- `Tests/RielaCLITests/Bots/BotActivityServiceTests.swift` and
  `Tests/RielaCLITests/Remotes` for building real providers over temporary
  stores.

## Pitfalls

- The executor must not import or hold any mutation provider. Only
  `AskActionService` holds `AskMutationSurface`.
- Redact before capping and before counting bytes; never return an
  unredacted error message.
- Budgets are enforced in store transactions, because plan 05 runs the
  executor in a second process.
- `decideAskAction` must be a single conditional update; a read followed by a
  write lets two confirmations both execute.
- Never build a mutation argument from `reason` or from any model text.
- `BotStore.read` on a store without `ask_*` tables returns empty, it does
  not throw and does not create tables.
- Removing a conversation keeps `confirmed` action rows.
- Do not add a tool, an argument or a kind that the design tables do not
  list.

## Tests

`Tests/RielaCoreTests/Ask/AskStoreTests.swift`:
- store with existing sessions and bots at generation 13 → after one ask
  write the generation is still 13 and bot rows are unchanged.
- read on a store without ask tables → empty list, no table created.
- second `beginAskTurn` while running → `ask_turn_running`.
- limits with `turnsPerConversation = 2` → third turn `ask_budget_exceeded`.
- `messagesPerConversation = 4` → oldest messages removed, `seq` keeps rising.
- `conversationsPerStore = 2` → least recently updated removed; a running one
  is kept.
- `finishAskTurn` with `failed` → no assistant message; with a long text →
  stored cut, `truncated == true`.
- stale heartbeat with another runner id → failed `ask_interrupted`; same
  runner id → unchanged.
- remove → messages gone, `proposed` action gone, `confirmed` action kept,
  activity rows for `ask:<id>` gone, activity rows of another key kept.

`Tests/RielaCoreTests/Ask/AskToolSetTests.swift`:
- the tool names equal the 16 names of design §5.1 plus `propose_action`.
- `session_logs` with `tail: 500` → `tool_arguments_invalid`; without `tail`
  → default 80.
- unknown name → `tool_unknown`; unknown key → `tool_arguments_invalid`.

`Tests/RielaCLITests/Ask/Tools/AskToolExecutorTests.swift` (real providers
over temporary stores; one mock-scenario run creates a session):
- each read tool with valid arguments → `ok`, expected ref kinds.
- `session_status` with an unknown id → `not_found`, turn still running.
- a log line containing the value of `TEST_API_TOKEN` from the injected
  environment and an `sk-` key → neither appears in the result.
- `toolResultBytes = 200` → `truncated == true`, encoded size within limit.
- `toolCallsPerTurn = 1` → second call `budget_exceeded` and the surface spy
  saw one call.
- each call records `toolCall` activity `inProgress` then `completed` (or
  `failed`) under `ask:<conversationId>` with `executionId == turnId`.
- call for a turn that is not running → `turn_not_running`.

`Tests/RielaCLITests/Ask/Tools/AskContextTests.swift`:
- session, bot and workflow contexts resolve with their ref; `none` → `nil`.
- unknown id → `ask_context_not_found`.

`Tests/RielaCLITests/Ask/Tools/AskReadOnlyTests.swift`:
- `AskToolSet.all` has no descriptor of kind other than `read` or `propose`.
- a spy `AskMutationSurface` is never reachable from the executor: run every
  tool once, the spy saw zero calls.

`Tests/RielaCLITests/Ask/Actions/AskActionTests.swift`:
- `propose_action stopSession` for a terminal session → error result, no row.
- `answerBotRequest` with an option id that the request does not have →
  `action_target_invalid`.
- kind `deleteBot` → `action_kind_unknown`.
- sixth proposal in a turn → `action_limit`.
- confirm → the spy saw exactly one call with arguments from the target;
  row `confirmed` with `decidedBy`, `decidedAt`, `result.ok`.
- confirm twice → second `action_already_decided`, spy still one call.
- dismiss → `dismissed`, spy zero calls.
- expired → `action_expired`.
- mutation throws → row `failed` with the code; the call returns the action.
- target became invalid between proposal and confirm → `failed`
  `action_target_invalid`, spy zero calls.

## Verification

```
mkdir -p tmp/ask-riela/ask-02-store-tools
arch -arm64 /bin/zsh -lc 'swift test --filter "AskStoreTests|AskToolSetTests|AskToolExecutorTests|AskContextTests|AskReadOnlyTests|AskActionTests|BotStoreTests|BotStoreMigrationTests|ActivityRecorderTests"' > tmp/ask-riela/ask-02-store-tools/test.log 2>&1
```

Exit 0. Evidence: additive storage, bounds, tool results against real
stores, redaction, budgets, read-only executor, confirm-once and audit.

## Done criteria

- `grep -rn "stopSession\|rerunSession\|setBotPaused\|answerBotRequest" Sources/RielaCLI/Ask/Tools` prints nothing.
- `git diff Sources/RielaCore/Bots/BotStore.swift` shows one added line.
- Verification exits 0; progress log written.
