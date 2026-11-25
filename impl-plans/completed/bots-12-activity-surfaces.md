# bots-12-activity-surfaces: `riela bot activity` and `riela bot answer`, GraphQL long-poll read

```json
{
  "planId": "bots-12-activity-surfaces",
  "planPath": "impl-plans/active/bots-12-activity-surfaces.md",
  "dependsOn": ["bots-10-bot-surfaces", "bots-11-activity-runtime"],
  "wave": 4,
  "writePaths": [
    "Sources/RielaCLI/Bots",
    "Sources/RielaGraphQL/Bots",
    "Tests/RielaCLITests/Bots",
    "Tests/RielaGraphQLTests/Bots",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "impl-plans/progress/bots-12-activity-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaClientFamilyArguments.swift", "intendedEdit": "Add `activity` and `answer` to BotClientAction."},
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "rielaCLIHelpText only: usage lines for `bot activity` and `bot answer`."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §6.5, §6.6 (answering), §12. The activity log written by plan 11 gets
its read surface (replay and live through one cursor-paged, long-poll query)
and pending permission requests become answerable from CLI and GraphQL.

Available: `BotStore.activityPage`, `waitForActivity`,
`pendingActivityRequests`, `answerActivityRequest` (plan 03); `BotsService`,
`BotsGraphQLDocumentExecutor`, `BotsGraphQLProviding`, `ParsedBotOptions`,
`SurfaceCatalog.botFamilyRows` (plan 10).

## Non-goals

- No SSE, WebSocket or GraphQL subscription.
- Handover questions are not answered here: they stay on `riela task answer`
  / `Mutation.answerTask`.
- No web (plan 14). No remote forwarding (plan 19).

## Changes

### GraphQL (`Sources/RielaGraphQL/Bots/`)

- `Query.botActivity(sessionId: String!, afterSequence: Int = 0, limit: Int = 200, waitMs: Int = 0, remote: String): BotActivityPage!`
- `Mutation.answerBotRequest(input: AnswerBotRequestInput!): BotRequestPayload!`
- Types: `BotActivityEvent { sessionId, seq, executionId, at, kind, payload: JSONObject! }`,
  `BotActivityState` (fields of `ActivityState`; `usage` and
  `configOptions` as JSON), `BotActivityPage { events, state, lastSequence, firstRetainedSequence, truncated, activitySource, sessionStatus, origin }`,
  `AnswerBotRequestInput { requestId: String!, optionId: String, decline: Boolean, remote: String }`,
  `BotRequestPayload { requestId, status, outcomeOptionId, resolvedBy }`.
- Add both fields to the executor's field sets and to `BotsGraphQLProviding`.

### Provider and service (`Sources/RielaCLI/Bots/`)

- `BotsService.activity(sessionId:afterSequence:limit:waitMs:isStillAuthorized:)`:
  `waitMs` clamped to 0...25,000, `limit` to 1...500; poll every 250 ms via
  `waitForActivity`. `sessionStatus` is the session's current status (or
  `unknown` when the session row is gone).
- Waiter cap: a process-wide counter (an actor or lock-protected integer in
  `Sources/RielaCLI/Bots/BotActivityWaiters.swift`) allows 32 concurrent
  waits; when full, the request is served as `waitMs = 0`. The slot is
  released on every exit path.
- `isStillAuthorized` is a closure parameter that defaults to `{ true }`;
  plan 18 passes the grant re-check. When it turns false the provider maps
  `activity_wait_revoked` to an authentication error.
- `BotsService.answer(requestId:optionId:decline:)`: exactly one of
  `optionId` / `decline: true`, else `request_answer_invalid`; then
  `BotStore.answerActivityRequest`. An id that looks like a handover question
  (no row found) → `request_not_found` with the message
  `not a permission request; answer handover questions with riela task answer`.

### CLI (`Sources/RielaCLI/Bots/BotActivityCommands.swift`)

- `riela bot activity (<botId> | --session <id>) [--after <seq>] [--limit N] [--follow] [--output json|jsonl|text]`
  - with a bot id: pick the bot's newest Needs-you item, else newest
    In-progress item, else newest Closed item; no item → `bot_no_activity`.
  - without `--follow`: one page from `--after` (default 0).
  - with `--follow`: loop with `waitMs = 25_000`, printing new events, until
    the session is terminal and the page state has no current execution, or
    the process is interrupted. `jsonl` prints one event object per line.
  - when `truncated` is true, text output starts with the line
    `(earlier events were trimmed; state follows)` and prints the state
    summary (plan checklist, open tool calls, pending requests).
  - text line format: `<seq> <HH:mm:ss> <kind> <short summary>`; the first
    line prints `activitySource: <acp|session>`.
- `riela bot answer <requestId> (--option <optionId> | --decline)`; prints the
  resulting status. Errors print the exact code.
- Add `--session`, `--after`, `--limit`, `--follow`, `--option`, `--decline`
  to `ParsedBotOptions`.

### Registries

Catalog rows `bot.activity` (kind `stream`, cli + graphql `botActivity`) and
`bot.answer` (mutation, graphql `answerBotRequest`); schema descriptors; SDL;
help lines.

## Imitate

- `Sources/RielaCLI/SessionMonitorCommand.swift` for a follow loop that ends
  on a terminal session and handles interruption.
- `Sources/RielaCLI/TaskHandoverCommands.swift:answer` (`:102-`) for option
  validation wording.

## Pitfalls

- Events must be printed in `seq` order with no duplicates across pages: the
  next request uses `afterSequence = lastSequence` of the previous page.
- `--follow` must stop; do not loop forever on a session that no longer
  exists (`sessionStatus == unknown` ends the loop).
- The waiter slot must be released when the request task is cancelled.
- Never print or log option ids as approvals; only relay what the user chose.
- `answerBotRequest` is a mutation: it must go through the executor's
  local-trust check like the others.

## Tests

`Tests/RielaCLITests/Bots/BotActivityCommandTests` (store seeded through the
plan 03 recorder):
- `bot activity --session S --output json` → all events in order,
  `activitySource` present.
- `--after 3` → only seq > 3.
- store trimmed past the cursor → `truncated: true` and the state summary line.
- `--follow` on a session that settles while following (append events from a
  second task, then settle) → prints the new events once each and exits 0.
- `bot activity <botId>` picks the Needs-you session over an older running one.
- `bot answer R --option allow-1` → status `answered`; the waiting
  `requestPermission` call returns `.selected("allow-1")`.
- `bot answer R --decline` → outcome cancelled.
- `--option nope` → `request_option_unknown`; second answer →
  `request_already_resolved`; both flags or neither → `request_answer_invalid`.
- a Work task question id → `request_not_found` with the task-answer hint.

`Tests/RielaGraphQLTests/Bots/BotActivityGraphQLTests`:
- `botActivity` decodes defaults (`afterSequence 0`, `limit 200`, `waitMs 0`).
- `waitMs: 60000` reaches the provider clamped to 25,000 (assert in the
  service test, with an injected sleep, that the wait ends at 25,000).
- 33 concurrent waits → the 33rd returns immediately; after one finishes a
  new wait is held again.
- `isStillAuthorized` turning false during a wait → the call fails with the
  authentication error within one poll interval.

## Verification

```
mkdir -p tmp/bots-overview/bots-12-activity-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-12-activity-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotActivityCommandTests|BotActivityGraphQLTests|BotCommandTests|BotsGraphQLTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-12-activity-surfaces/test.log 2>&1
```

Both exit 0. Evidence: replay, live follow and answering work on isolated
stores; parity gates are green.

## Done criteria

- `grep -n "botActivity\|answerBotRequest" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` shows both fields.
- Verification exits 0; progress log written.
