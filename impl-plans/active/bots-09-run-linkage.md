# bots-09-run-linkage: `--bot` on runs and routines, runtime-owned session links, paused gate

```json
{
  "planId": "bots-09-run-linkage",
  "planPath": "impl-plans/active/bots-09-run-linkage.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/BotRuntime",
    "Tests/RielaCLITests/BotRuntime",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Remote.swift",
    "Sources/RielaCLI/WorkflowExecutionProvider.swift",
    "Sources/RielaCLI/EventLiveServe.swift",
    "Sources/RielaCLI/EventLiveServe+Cron.swift",
    "Sources/RielaCLI/EventCronOverlapDispatcher.swift",
    "Sources/RielaCLI/EventReadOnly.swift",
    "Sources/RielaCLI/RoutineCommands.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaWorkflowRegistry/RoutineService.swift",
    "Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift",
    "Sources/RielaGraphQL/RoutineGraphQL.swift",
    "Sources/RielaGraphQL/GraphQLWorkflowExecutionContracts.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "impl-plans/progress/bots-09-run-linkage.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaCommand.swift", "intendedEdit": "Add `botId: String?` to WorkflowRunOptions (stored property and init parameter, default nil). Nothing else."},
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "Only rielaCLIHelpText lines that list `workflow run` and `routine create` options, if those options are listed there: add `--bot <bot-id>`."},
    {"path": "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift", "intendedEdit": "Add field `botId: String` to the ExecuteWorkflowInput descriptor (line 52) and to the CreateRoutineInput descriptor, and `botId: String` to the Routine object descriptor."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated file: regenerate with scripts/surface-parity/generate-sdl.sh, never hand-edit."},
    {"path": "Sources/RielaCore/SurfaceCatalog+Rows.swift", "intendedEdit": "Add \"--bot\" to the cliOptions of the `workflow run` row (line 67 list). plan 01's aggregator line stays untouched."},
    {"path": "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift", "intendedEdit": "Add \"--bot\" to the options of the routine.create row (line 459-470)."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §5.1 (pause), §5.2. A run started for a bot is linked to it by the
runtime at the moment the session id is assigned. Routines can belong to a
bot. A paused bot's routines are skipped and manual `--bot` runs are refused.

Current code:

- `WorkflowRunCommand.sessionStartedObserver` (`WorkflowRunCommand.swift:30`,
  fired at `:193-195` for the root workflow's `sessionStarted` event).
- `WorkflowRunOptions` (`RielaCommand.swift:316-`), parsed from
  `ParsedWorkflowOptions` in `RielaArgumentParser+WorkflowAndMemory.swift`.
- GraphQL `executeWorkflow` builds `WorkflowRunOptions` in
  `WorkflowExecutionProvider.executeWorkflow` (`WorkflowExecutionProvider.swift:27-`).
- Event and cron runs: `EventWorkflowRunRequest` (`EventLiveServe.swift:41-45`),
  `observedCommand.sessionStartedObserver = request.onSessionStarted` (`:1069`),
  cron dispatch in `EventLiveServe+Cron.swift:39-75`, gate
  `routineDispatchGate` (`:91-124`).
- Routines: `RoutineCreateRequest` and `RoutineService.create`
  (`Sources/RielaWorkflowRegistry/RoutineService.swift:15-`), CLI
  `ParsedRoutineOptions` (`RoutineCommands.swift:6-28`), GraphQL
  `GraphQLCreateRoutineInput` / `GraphQLRoutine` (`RoutineGraphQL.swift`).
- Plan 01: `BotStore`, `BotRunContext`, `RoutineRecord.botId`,
  `DeterministicWorkflowRunRequest.botContext`.

## Non-goals

- No activity recorder injection (plan 11), no memory block (plan 15), no
  `riela bot` command (plan 10), no `--remote` (plan 19).
- Routine files on disk (cron source and binding JSON) keep their format.
- No change to resume, rerun or continue: they keep the link of the original
  session (the link key is the session id; a rerun creates a new session
  that is linked only when `--bot` is passed again).

## Changes

### `Sources/RielaCLI/BotRuntime/BotRunLinker.swift` (new)

`struct BotRunLinker { var sessionStoreRoot: String }`
- `func prepare(botId: String) throws -> BotRunContext`: load the bot;
  missing → `CLIUsageError("bot_not_found: <id>")`; paused →
  `CLIUsageError("bot_paused: <id>")`; else
  `BotRunContext(botId:, permissionWaitMs: bot.permissionWaitMs, memoryBlock: nil, forceReadOnlySandbox: false)`.
- `func link(sessionId: String, botId: String, source: String, sourceRef: String?)`:
  calls `BotStore.linkSession`; an error is written to stderr with the prefix
  `riela bot link:` and does not stop the run.
- `static func isPaused(botId:sessionStoreRoot:) -> Bool?` (nil when the bot
  does not exist).

### Local runs

- `ParsedWorkflowOptions`: `@Option(name: .customLong("bot")) var bot: String?`.
- `WorkflowRunOptions.botId`, mapped from the parsed option.
- `WorkflowRunCommand`: add `var botLinkSource: (source: String, sourceRef: String?) = ("run", nil)`.
  When `options.botId` is set, before building the run request call
  `BotRunLinker.prepare` with the resolved session store root (the same root
  the run persists to) and set `request.botContext`. In the `sessionStarted`
  branch (`:193`) call `link(...)` before `sessionStartedObserver`. A
  `prepare` failure ends the command with exit code failure, the message on
  stderr, and no session created.
- Mock-scenario and dry runs behave the same (the link is written whenever a
  session is created).

### Remote runs (`--endpoint`)

`WorkflowRunCommand+Remote.swift`: when `options.botId` is set, include
`botId` in the `executeWorkflow` input sent to the server. No local link is
written; the server's runtime writes it.

### GraphQL execution

- `GraphQLExecuteWorkflowInput.botId: String?` (decode and init, default nil).
- `WorkflowExecutionProvider.executeWorkflow` copies it to `options.botId`.
- Schema descriptor + regenerated SDL.

### Routines

- `RoutineCreateRequest.botId: String?`; `RoutineService.create` stores it in
  `RoutineRecord.botId`. When `botId` is set the service validates that the
  bot exists through a new optional init parameter
  `botExists: (@Sendable (String) -> Bool)? = nil`; when the closure is nil
  no validation happens (keeps `RielaWorkflowRegistry` free of session store
  knowledge). Unknown bot → `RoutineServiceError("bot_not_found: <id>")`.
- CLI: `ParsedRoutineOptions.bot` (`--bot`), passed on `routine create`; the
  CLI supplies `botExists` from `BotStore` at the session store root resolved
  from the working directory (`CLIWorkflowSessionStore.resolveRootDirectory`).
- GraphQL: `GraphQLCreateRoutineInput.botId`, `GraphQLRoutine.botId`; the
  file provider passes it through.
- `routine list` / `inspect` text output prints `botId` when set.

### Cron dispatch

- `EventWorkflowRunRequest` gains `botId: String?` and
  `botLinkSource: (String, String?)`; where the observed command is built
  (`EventLiveServe.swift:1060-1070`) set `options.botId` and
  `command.botLinkSource`.
- In cron dispatch (`EventLiveServe+Cron.swift:39-75`, and the queued path in
  `EventCronOverlapDispatcher.swift`), when the binding has a `routineId`,
  load the routine and pass `botId = record.botId`,
  `botLinkSource = ("routine", routineId)`.
- `routineDispatchGate`: after the `active` check, when `record.botId` is set
  and `BotRunLinker.isPaused` is true, return a gate with
  `skipReason: "bot_paused:<botId>"`. A missing bot does not skip (the run
  proceeds unlinked and prints one warning line to stderr).

## Imitate

- `RoutineCommands.swift:routineResult` for option validation and
  `CLIUsageError` messages.
- `EventLiveServe+Cron.swift:routineDispatchGate` for the skip-reason shape.
- `GraphQLWorkflowExecutionContracts.swift` existing optional fields for
  decode style.

## Pitfalls

- Link exactly the root session of the started workflow. The
  `sessionStarted` event also fires for callee workflows; the existing
  `event.workflowId == persistenceBundle.workflow.workflowId` guard is the
  filter to reuse.
- Write the link before the first step runs: do it in the event handler, not
  after the run returns.
- The session store root used for the link must be the one the run uses
  (explicit `--session-store`, environment, or scope default). Never
  `~/.riela` implicitly in tests.
- `WorkflowRunOptions` is `Equatable` and built in many places; the new init
  parameter must default to nil and go last.
- Regenerate the SDL with the script; the parity tests compare the file.
- Do not add `--bot` to `session resume|rerun|continue`.

## Tests (`Tests/RielaCLITests/BotRuntime/`)

`BotRunLinkageTests` (temporary working directory, `--session-store` under
it, mock scenario from an existing example such as
`examples/first-four-arithmetic-pipeline`):
- `workflow run --bot b1` with bot `b1` → exit success; one
  `bot_session_links` row with `source == "run"` whose session id equals the
  run's session id.
- `--bot missing` → non-zero exit, stderr contains `bot_not_found`, no
  session row and no link row.
- bot paused → stderr contains `bot_paused`, no session.
- run without `--bot` → no link row; output identical in shape to today.
- a workflow that calls a child workflow → exactly one link row (the root).

`BotRoutineLinkageTests`:
- `routine create --bot b1` → record has `botId`; `routine inspect` shows it.
- `routine create --bot missing` → error `bot_not_found`.
- gate for a routine whose bot is paused → `skipReason == "bot_paused:b1"`;
  resumed → nil.
- GraphQL `createRoutine` with `botId` → routine payload carries `botId`.
- GraphQL `executeWorkflow` with `botId` (mock scenario) → link row with
  source `run`.

## Verification

```
mkdir -p tmp/bots-overview/bots-09-run-linkage
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-09-run-linkage/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotRunLinkageTests|BotRoutineLinkageTests|RoutineCommandTests|RoutineGraphQLTests|WorkflowExecutionGraphQLTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-09-run-linkage/test.log 2>&1
```

Both exit 0. Evidence: links are written for local, GraphQL and routine
runs; existing routine and execution suites and the SDL gates still pass.

## Done criteria

- `grep -n "botId" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` shows the field in `ExecuteWorkflowInput`, `CreateRoutineInput` and `Routine`.
- Running the SDL script a second time leaves `git diff --stat` for the SDL file unchanged.
- Verification exits 0; progress log written.
