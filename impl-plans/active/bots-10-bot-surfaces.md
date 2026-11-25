# bots-10-bot-surfaces: `riela bot` management, overview, board and list state on CLI and GraphQL

```json
{
  "planId": "bots-10-bot-surfaces",
  "planPath": "impl-plans/active/bots-10-bot-surfaces.md",
  "dependsOn": ["bots-02-board-projector", "bots-03-activity-core", "bots-09-run-linkage"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/Bots",
    "Sources/RielaGraphQL/Bots",
    "Tests/RielaCLITests/Bots",
    "Tests/RielaGraphQLTests/Bots",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/CLISubcommandHelp.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift",
    "impl-plans/progress/bots-10-bot-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaClientCommandRouter.swift", "intendedEdit": "Register `BotRoute` (passthrough route named `bot`) next to RoutineRoute (lines 32, 140-141)."},
    {"path": "Sources/RielaCLI/RielaCommand.swift", "intendedEdit": "Add `case bot` to ScopedCommandKind (line 273-282) and the BotRoute branch beside the RoutineRoute branch (line 490)."},
    {"path": "Sources/RielaCLI/ScopedParityCommands.swift", "intendedEdit": "Add `case .bot` beside `case .routine` (line 111) calling botResult(options:)."},
    {"path": "Sources/RielaCLI/CLISurfaceEnumeration.swift", "intendedEdit": "Add `case \"bot\"` expansion from BotClientAction.allRawValues and add \"bot\" to expandedRoutes."},
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "rielaCLIHelpText only (line 324-): add the `riela bot ...` usage lines."},
    {"path": "Sources/RielaCLI/CLISubcommandHelp.swift", "intendedEdit": "Only if a family needs a registration entry for `riela bot --help` to print its lines; follow how `routine` is handled."},
    {"path": "Sources/RielaCLI/ServeWebHost.swift", "intendedEdit": "ServeWebRegistryExecutor only (line 194-): chain BotsGraphQLDocumentExecutor into the composite. No routing change."},
    {"path": "Sources/RielaCLI/ServeHTTPCommand.swift", "intendedEdit": "serveMachineGraphQLAdapter only (line 165-): chain BotsGraphQLDocumentExecutor into the API-key composite, behind APIKeyGraphQLAuthorization. This is the path paired clients use."},
    {"path": "Sources/RielaApp/RielaAppWebGraphQL.swift", "intendedEdit": "Chain BotsGraphQLDocumentExecutor into the composite at line 38-75. Nothing else."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."},
    {"path": "Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift", "intendedEdit": "Add BotsGraphQLDocumentExecutor.queryFields / mutationFields to executorFields() (line 44-60)."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §5 (all), §8.6, §12. This plan makes bots usable: create, list, show,
update, pause, resume, remove and the list-state verbs, on the CLI and on
GraphQL, both rendering the same projected DTO from plan 02. It also creates
the bots GraphQL executor and chains it into every `/graphql` composite, so
later plans only add fields.

The `routine` family is the end-to-end pattern to copy:
`RoutineRoute` (`RielaClientCommandRouter.swift:32,140`),
`ScopedCommandKind.routine` and its parse branch (`RielaCommand.swift:278,490`),
`RoutineClientAction` (`RielaClientFamilyArguments.swift:152-161`),
dispatch (`ScopedParityCommands.swift:111`), runner
(`RoutineCommands.swift:routineResult`), enumeration
(`CLISurfaceEnumeration.swift:108,139`), catalog rows
(`SurfaceCatalog+RowsCLI.swift:51-56,459-533`), GraphQL
(`Sources/RielaGraphQL/RoutineGraphQL.swift`: DTOs, `RoutineGraphQLProviding`
`:271`, `RoutineGraphQLDocumentExecutor` `:281-`), descriptors
(`GraphQLSchemaGenerator.swift` `types` and `rootFields` `:618-`).

Composites that must chain the new executor (five):
`ServeWebHost.swift:205-` (browser console of `riela serve`),
`ServeHTTPCommand.swift:serveMachineGraphQLAdapter` (`:165-`, API-key
clients), `RielaLibrary.swift:119-`,
`ScopedParityCommands+GraphQLDocument.swift:28-` (`riela graphql document`),
`RielaAppWebGraphQL.swift:38-` (RielaApp).

## Non-goals

- No activity or answer commands (plan 12), no memory, jobs, suggestions,
  models, remotes (plans 13–19). The DTO fields for them are added later.
- No web (plan 14).
- No REST routes: webAPI is excluded for this family.

## Changes

### CLI verbs (`Sources/RielaCLI/Bots/BotCommands.swift`)

`BotClientAction` (in `RielaClientFamilyArguments.swift`): `create`, `list`,
`show`, `update`, `pause`, `resume`, `remove`, `pin`, `unpin`, `move`,
`snooze`, `unsnooze`, `settle`, `unsettle`, with `allRawValues` like the
other action enums.

`ParsedBotOptions: ParsableArguments` (same style as `ParsedRoutineOptions`):
`--id`, `--name`, `--purpose`, `--persona`, `--backend`, `--model`,
`--provider`, `--workspace`, `--memory-upkeep off|nightly|weekly`,
`--look-around off|nightly|weekly`, `--permission-wait-ms`,
`--item session:<id>|task:<id>`, `--position <int>`, `--until <ISO-8601>`,
`--for <duration like 2h, 3d>`, `--group-by none|workspace`,
`--session-store`, `--scope`, `--working-dir`, `--output json|text`. The bot
id is the first positional argument for every verb except `create` and `list`.

| Verb | Behaviour |
| --- | --- |
| `create --name N [--id ID] ...` | id defaults to `BotRecord.slug(from: name)`; prints the record |
| `list [--group-by]` | overview list (rows in server order with section) |
| `show <id>` | board in group order, then routines with next run; placeholders `suggestions: []`, `memory: null` until later plans |
| `update <id> ...` | changes only the options given |
| `pause` / `resume <id>` | sets `paused` |
| `remove <id>` | see removal order below |
| `pin` / `unpin`, `move --position N`, `snooze --until/--for`, `unsnooze`, `settle`, `unsettle` | list state for the bot row, or for `--item` |

Text output: one line per bot for `list`
(`<id>  <section>  needs:<n> working:<n> waiting:<n> planned:<n>  <last activity or ->  <last result>`),
grouped headings for `show`. JSON output is the encoded GraphQL DTO.

### Service (`Sources/RielaCLI/Bots/BotsService.swift`)

`struct BotsService { workingDirectory, sessionStoreRoot, environment, now: () -> Date, origin: () -> BotOrigin }`
used by both the CLI and the GraphQL provider:

- `overview(groupBy:)`, `detail(botId:)`: build one `BotBoardInput` per bot
  and call `BotBoardProjector`.
  - sessions: `BotStore.links(botId:)` → load each root session and its
    family from the session store. Read
    `Sources/RielaCLI/SessionObservabilityComposition.swift` and
    `SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` and reuse the
    existing family read; do not write a new SQL reader.
  - activity: `BotStore.activityStates(sessionIds:)` and
    `pendingActivityRequests(sessionIds:)` from plan 03, for the root session
    and its descendants. Until plan 11 injects the recorder these return
    nothing and items report `activitySource: session`.
  - Work tasks: the listing used by `riela task list`
    (`Sources/RielaCLI/TaskCommands.swift`), filtered in memory to
    `owner?.identity == "bot:<botId>"`; attempts give `attemptSessionIds`;
    the latest handover with reason `userInputRequired` gives the question.
  - routines: `RoutineStore.list` filtered to `botId`; next fire time from
    the routine's cron schedule and time zone. Use the next-match logic that
    `CronScheduleSource.dueTick` relies on (`EventLiveServe+Cron.swift:180`);
    if only a "latest match in a window" function exists, add a small forward
    search helper in `Sources/RielaCLI/Bots/` (do not edit `CronSchedule.swift`).
  - `redact` for `lastResultLine`: `HandoverRedactionRules` default rules
    (`Sources/RielaWork/HandoverRedaction.swift:43`).
- `create`, `update`, `setPaused`, `setListState` (validates with
  `BotBoardProjector.canSettle` / `canSettleBot`; refusal → `list_item_busy`;
  `--item` must name an item of that bot → else `list_item_not_found`).
- `remove(botId:)`, in this order: (1) refuse with `bot_busy` when the board
  has an In-progress item or a pending request; (2) clear `botId` on every
  routine of the bot in the routine store; (3) `BotStore.remove`. A crash
  between 2 and 3 leaves a bot without routines, never a routine pointing at
  a removed bot.
- A `remote` argument other than nil or `local` → error
  `remote_not_configured` (plan 19 replaces this).

### GraphQL (`Sources/RielaGraphQL/Bots/BotsGraphQL.swift`)

- DTOs: `GraphQLBot` (record fields), `GraphQLBotCounts`,
  `GraphQLBotBoardItem`, `GraphQLBotBoard` (five arrays + `closedTotal`),
  `GraphQLBotOverviewRow`, `GraphQLBotWorkspaceGroup`, `GraphQLBotOrigin`,
  `GraphQLBotListState`, `GraphQLBotRoutine` (`routineId`, `name`,
  `workflowName`, `status`, `nextRunAt`), payloads `BotListPayload`
  (`bots`, `groups`), `BotDetailPayload` (`bot`, `board`, `routines`,
  `origin`), `BotMutationPayload` (`bot`).
- Inputs: `BotFilter { groupBy, remote }`, `CreateBotInput`, `UpdateBotInput`,
  `SetBotPausedInput { botId, paused, remote }`, `RemoveBotInput`,
  `SetBotListStateInput { botId, itemKind, itemId, pinned, manualOrder, snoozedUntil, clearSnooze, settled, remote }`.
- Root fields: `Query.bots(filter: BotFilter): BotListPayload!`,
  `Query.bot(botId: String!, remote: String): BotDetailPayload!`,
  `Mutation.createBot`, `updateBot`, `setBotPaused`, `removeBot`,
  `setBotListState` (each `(input: ...Input!): BotMutationPayload!`).
- `public protocol BotsGraphQLProviding: Sendable` with one async throwing
  method per root field.
- `public struct BotsGraphQLDocumentExecutor: GraphQLDocumentExecuting` with
  `static let queryFields`, `static let mutationFields`, `provider`, `next`,
  `supports(_:)`; it is a local-trust surface exactly like the routine
  executor (refuse when `!request.isLocallyTrusted`).
- Errors are GraphQL errors whose `extensions.code` is the store error code.
- Provider implementation `BotsGraphQLProvider` in
  `Sources/RielaCLI/Bots/BotsGraphQLProvider.swift`, built on `BotsService`.

### Registries

- `SurfaceCatalog+RowsBots.swift`: one row per verb above (`bot.create`,
  `bot.list`, `bot.show`, `bot.update`, `bot.set-paused` for pause and
  resume as two rows if the CLI gate needs one row per command path, ...,
  `bot.list-state.*`). Defaults for the family: cli implemented, graphql
  implemented, webAPI `SurfaceExclusion.notAConsoleOperation(...)`-style
  exclusion citing `design-bots-overview.md §12`, library
  `SurfaceExclusion.notALibraryEntryPoint("bot management")`, desktop and
  skill as the routine rows declare them. Every verb needs a GraphQL binding
  or an exclusion; the list-state verbs all bind `setBotListState`.
- `GraphQLSchemaGenerator`: type descriptors and `rootFields` entries; then
  regenerate the SDL.
- Help text: usage lines for every verb.

## Pitfalls

- The four parity gates compare the router, the catalog, the executors and
  the SDL. Adding a verb means touching all of them in the same plan; run the
  gate suites before finishing.
- `SurfaceParityExecutorCoverageTests` must list the new executor or the new
  fields count as "without executor".
- Chain the executor so that unsupported fields still reach the existing
  executors (`next`), and preflight of mixed documents keeps working: copy
  the `RoutineAwareGraphQLFallbackExecutor` approach where a composite needs it.
- `bot list` on a store with no database must print an empty list and must
  not create the database.
- Reads never write list state.
- Session store root resolution must match `riela session` and `riela task`
  (`CLIWorkflowSessionStore.resolveRootDirectory`).

## Tests

`Tests/RielaCLITests/Bots/BotCommandTests` (temporary roots, mock runs):
- `bot create --name "Release Bot"` → id `release-bot`; `bot list --output json`
  lists it with zero counts and null last activity.
- duplicate create → stderr `bot_exists`, non-zero exit.
- after a `workflow run --bot` mock run → `bot show` lists the session under
  Closed with a `lastResult`; `bot list` shows `lastActivityAt`.
- routine with `--bot` → `bot show` lists it under routines with `nextRunAt`
  and one Planned item.
- `pause` → `paused: true`; `resume` → false.
- `pin` then `list` → pinned bot first; `move --position 1` reorders.
- `snooze --for 2h` → section `snoozed`; `unsnooze` → `active`.
- `settle --item session:<id>` on a closed item → settled; `settle` on a bot
  with a running session (seed the store) → `list_item_busy`.
- `remove` with a routine → routine `botId` cleared, bot gone; remove with a
  pending request row (seeded) → `bot_busy`.
- empty store → `bot list` prints `[]` and no database file exists afterwards.
- `--output json` of `bot show` decodes as the GraphQL `BotDetailPayload` DTO.

`Tests/RielaGraphQLTests/Bots/BotsGraphQLTests` (stub provider):
- `bots`, `bot`, each mutation → provider called with decoded input, payload
  encoded with the declared field names.
- not locally trusted → refused like the routine executor.
- unknown field → falls through to `next`.

## Verification

```
mkdir -p tmp/bots-overview/bots-10-bot-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-10-bot-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotCommandTests|BotsGraphQLTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|SurfaceParitySkillTests|RoutineCommandTests"' > tmp/bots-overview/bots-10-bot-surfaces/test.log 2>&1
```

Both exit 0. Evidence: bot verbs work end to end on isolated stores and all
nine parity gates are green with the new family.

## Done criteria

- `riela bot --help` (run `.build/debug/riela bot --help` through the arm64 wrapper) lists every verb.
- `grep -c "BotsGraphQLDocumentExecutor(" Sources/RielaCLI/ServeWebHost.swift Sources/RielaCLI/ServeHTTPCommand.swift Sources/RielaCLI/RielaLibrary.swift Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift Sources/RielaApp/RielaAppWebGraphQL.swift` prints 1 for each file.
- A second run of the SDL script leaves the SDL file unchanged.
- Verification exits 0; progress log written.
