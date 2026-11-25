# ask-04-surfaces: catalog rows, `riela ask`, GraphQL, SDL, host chaining, remote forwarding, example

```json
{
  "planId": "ask-04-surfaces",
  "planPath": "impl-plans/active/ask-04-surfaces.md",
  "dependsOn": [
    "ask-03-turn-engine"
  ],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/Ask",
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/Remotes",
    "Sources/RielaCLI/ModelCatalog",
    "Sources/RielaCore/Ask",
    "Sources/RielaGraphQL",
    "Sources/RielaServer",
    "Sources/RielaCore/SurfaceCatalog.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsAsk.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift",
    "Sources/RielaCLI/APIKeyGraphQLAuthorization.swift",
    "Sources/RielaCLI/CLISubcommandHelp.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Sources/RielaCLI/ParityCommands.swift",
    "Sources/RielaCLI/RielaArgumentParserHelpers.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/ScopedParityCommands+Serve.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaCLI/ServeWebAccess.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ServeWebHost+Configuration.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaApp/RielaAppWebRouter.swift",
    "Sources/RielaApp/RielaAppConfigurationGraphQLProvider.swift",
    "Sources/RielaAppSupport/RielaConsoleGraphQLProvider.swift",
    "Resources/skills",
    "scripts/surface-parity",
    "examples/ask-run-status",
    "examples/README.md",
    "Tests/RielaCLITests/Ask",
    "Tests/RielaCoreTests/Ask",
    "Tests/RielaGraphQLTests",
    "Tests/RielaServerTests",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCoreTests/RielaTestSurfaceCoverageTests.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/SubcommandHelpTests.swift",
    "Tests/RielaCLITests/SubcommandHelpApplicationTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Tests/RielaCLITests/SurfaceParityConsoleReadTests.swift",
    "Tests/RielaCLITests/SurfaceParityLibraryTests.swift",
    "Tests/RielaCLITests/SurfaceParitySkillTests.swift",
    "Tests/RielaCLITests/SurfaceParityWebAPITests.swift",
    "Tests/RielaCLITests/ServeWebHostTests.swift",
    "Tests/RielaCLITests/ServeHTTPCommandTests.swift",
    "impl-plans/progress/ask-04-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCore/SurfaceCatalog+Rows.swift",
      "intendedEdit": "Append `+ askRows` where `botFamilyRows + remoteRows` are concatenated (line 16)."
    },
    {
      "path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
      "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh. Never edit by hand."
    },
    {
      "path": "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
      "intendedEdit": "Register the ask types, inputs and root fields from the new descriptor file."
    },
    {
      "path": "Sources/RielaCLI/RielaCLIApplication.swift",
      "intendedEdit": "Help text lines for the `riela ask` commands."
    },
    {
      "path": "Sources/RielaCLI/Bots",
      "intendedEdit": "Only if a shared helper (origin, waiters, JSON rendering) must become reusable; no behaviour change."
    },
    {
      "path": "Sources/RielaServer",
      "intendedEdit": "Only if a scope or field list names fields explicitly; the ask mutations must be `operate`, the ask queries `read`."
    },
    {
      "path": "Resources/skills",
      "intendedEdit": "Only if SurfaceParitySkillTests requires a generated command block for the new family."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2, §3.3, §3.4. Design: §7.3, §8.1
(read), §12, §13, §15 (example).

## Intent and context

Expose the chat on CLI and GraphQL through the SurfaceCatalog, on every host
that serves bots today, and against a paired remote. Add the example that
answers "what is the state of this run?".

Available from earlier plans: `AskService` with `send`, `waitForTurn`,
`cancel`, `conversation`, `conversations`, `activity`, `confirm`, `dismiss`,
`remove`; `AskHost`; `AskScriptedBackend`.

Existing wiring to copy (the `remote` and `bot` families):

- Catalog rows: `Sources/RielaCore/SurfaceCatalog+RowsBots.swift:remoteRows`
  and `botRow`, registered in `SurfaceCatalog+Rows.swift:16`.
- CLI: route in `Sources/RielaCLI/RielaClientCommandRouter.swift:150,165`,
  command kind in `RielaCommand.swift:282,520-526`, dispatch in
  `ScopedParityCommands.swift:84,117`, enumeration in
  `CLISurfaceEnumeration.swift:108-118,165` (bare route plus actions: see
  `serve`), help in `RielaCLIApplication.swift:329-342` and
  `CLISubcommandHelp.swift`.
- Commands and options: `Sources/RielaCLI/Remotes/RemoteCommands.swift`,
  `Sources/RielaCLI/Remotes/ParsedRemoteSelector.swift`,
  `Sources/RielaCLI/Bots/BotActivityCommands.swift` (`--follow`).
- GraphQL: `Sources/RielaGraphQL/Bots/RemotesGraphQL.swift` (contracts,
  executor branch), `BotActivityGraphQLContracts.swift`,
  `BotsSchemaDescriptors.swift`; executor chain sites
  `ServeWebHost.swift:249`, `ServeHTTPCommand.swift:247`,
  `RielaLibrary.swift:143`, `ScopedParityCommands+GraphQLDocument.swift:50`,
  `RielaApp/RielaAppWebGraphQL.swift:73` (five sites).
  `Remotes/ParsedRemoteSelector.swift:26` builds a `BotsGraphQLProvider`
  for direct CLI use without an executor; it is the pattern for the CLI's
  direct `AskGraphQLProvider` use.
- Remote forwarding: `Remotes/RemoteBotsProvider.swift`,
  `RemoteGraphQLClient.swift`, `RemoteRouting.swift`,
  `Sources/RielaGraphQL/Bots/GraphQLSelectionBuilder.swift`.
- Example registration: `Tests/RielaCLITests/RielaExampleCatalog.swift`,
  walkthrough test `Tests/RielaCLITests/BotExample/BotExampleWalkthroughTests.swift`.

## Non-goals

- No REST route; `RielaWebAPIRouteTable` is not edited.
- No `riela ask tool-server` and no `ask.tool-server` row (plan 05).
- No workflow proposal handling (plan 06); `draftDefinition` is accepted by
  the inputs and passed to `AskSendRequest`.
- No web change (plan 07).
- No interactive prompt loop in the CLI.

## Changes

### 1. Catalog rows (`Sources/RielaCore/SurfaceCatalog+RowsAsk.swift`, new)

`static let askRows`, family `ask`, design anchor
`design-docs/specs/design-ask-riela-chat.md#13-control-surfaces`. Defaults:
webAPI excluded ("Ask operations use GraphQL"), library excluded
(`notALibraryEntryPoint`).

| Row id | Kind | CLI | GraphQL |
| --- | --- | --- | --- |
| `ask.send` | mutation | `ask` | `Mutation.startAsk` |
| `ask.reply` | mutation | excluded: "riela ask --conversation uses the ask command" | `Mutation.sendAskMessage` |
| `ask.list` | query | `ask list` | `Query.askConversations` |
| `ask.show` | query | `ask show` | `Query.askConversation` |
| `ask.activity` | stream | excluded: "riela ask and riela ask show --follow read this stream" | `Query.askActivity` |
| `ask.cancel` | mutation | `ask cancel` | `Mutation.cancelAsk` |
| `ask.confirm` | mutation | `ask confirm` | `Mutation.confirmAskAction` |
| `ask.dismiss` | mutation | `ask dismiss` | `Mutation.dismissAskAction` |
| `ask.remove` | mutation | `ask remove` | `Mutation.removeAskConversation` |

CLI options: `ask`: `--conversation`, `--session`, `--bot`, `--workflow`,
`--remote`, `--provider`, `--model`, `--effort`, `--no-follow`, `--output`,
`--session-store`, `--scope`, `--working-dir`. `ask show`: `--follow`,
`--remote`, `--output`, store options. Others: `--remote`, `--output`,
store options.

### 2. GraphQL (`Sources/RielaGraphQL/Ask/`, new)

`AskGraphQLContracts.swift`, `AskSchemaDescriptors.swift`, `AskGraphQL.swift`.

- `protocol AskGraphQLProviding: Sendable` with one function per root field
  of overview §3.3.
- `AskGraphQLDocumentExecutor(provider:next:)` in the style of
  `BotsGraphQLDocumentExecutor`: static `queryFields` / `mutationFields`,
  argument validation, error mapping with `extensions.code`.
- Inputs: `StartAskInput { message!, context, selection, draftDefinition, remote }`,
  `SendAskMessageInput { conversationId!, message!, context, draftDefinition, remote }`,
  `AskActionInput { conversationId!, actionId!, remote }`,
  `AskConversationInput { conversationId!, remote }`,
  `AskContextInput { kind!, id }`, `AskSelectionInput { vendor, providerInstanceId, model, effort }`.
  `draftDefinition` and action `target` use the existing `JSON` scalar.
- DTOs mirror overview §3.1 field for field (`AskConversation`, `AskTurn`,
  `AskTurnError`, `AskUsage`, `AskMessage`, `AskRef`, `AskAction`,
  `AskActionResult`, `AskLimits`), plus `AskConversationPayload`,
  `AskConversationListPayload` and `AskActivityPage`. `AskActivityPage` has
  the fields of `BotActivityPage` except `sessionStatus`, plus
  `turnStatus: String!` and `origin`. Reuse the existing activity event and
  state DTO types; do not copy them.
- Register in `GraphQLSchemaGenerator` and regenerate the SDL.

### 3. Provider and remote (`Sources/RielaCLI/Ask/Surfaces/`, new)

- `AskGraphQLProvider: AskGraphQLProviding`, built from `AskHost`,
  `decidedBy: String`, `isStillAuthorized`, the remote registry and
  transport, the same construction parameters each host gives
  `BotsGraphQLProvider`. `decidedBy` is `local` for a locally trusted
  request, otherwise the pairing grant id and client name.
- Routing per call with `RemoteRouting.resolve`: local → `AskService`;
  a named remote → `RemoteAskProvider`; `*` → `remote_selector_invalid`.
- `RemoteAskProvider`: one document per operation, selection sets from
  `GraphQLSelectionBuilder.selection(forType:)`, the `remote` argument is
  never sent, `origin` rewritten exactly as `RemoteBotsProvider` does.
  Nothing is stored locally. `remote_unreachable`, `remote_not_found`,
  `remote_unauthorized` and `scope_insufficient` are thrown as errors.
- `AskHost` factories: `static func local(workingDirectory:sessionStore:scope:environment:settings:)`
  for CLI and library use; hosts with a server pass their own providers and
  assistant settings (`ServeWebHost+Configuration.swift` state,
  `RielaAppConfigurationGraphQLProvider` daemon state). CLI without a server
  reads the assistant settings from the same profile state `riela serve`
  reads; when none exists, default settings (`automatic`).
  `scratchRoot` is `<store root>/ask-turns`.
- Chain `AskGraphQLDocumentExecutor` next to `BotsGraphQLDocumentExecutor`
  in the five executor chain sites listed above.

### 4. CLI (`Sources/RielaCLI/Ask/Surfaces/AskCommands.swift`, new, plus wiring)

- `riela ask "<message>"`; verbs `list`, `show`, `cancel`, `confirm`,
  `dismiss`, `remove`. The first positional is a verb only when it equals one
  of those names; a message equal to a verb is given after `--`.
- `--session`, `--bot`, `--workflow`: at most one (`CLIUsageError`
  otherwise); they build `AskContext`. `--provider`, `--model`, `--effort`
  build `AskSelection`. `--conversation <id>` sends to an existing
  conversation.
- Default: follow the turn. Text output: answer text as `message` events
  arrive, one line `· <tool> <first ref or argument>` per tool call, then
  `Records:` (citations), `Proposed:` (one line per action: action id, kind,
  target), then `conversation <id>`. Failure: turn error code and message on
  stderr, failure exit code. `--no-follow` returns after the turn starts.
  `--output json` prints the final `AskConversationPayload` once (after the
  turn unless `--no-follow`).
- Local mode runs the turn in this process (`AskService.send` then
  `waitForTurn`) and reads activity from the store while waiting. With
  `--remote` the documents go to that server through
  `RemoteGraphQLClient` and the CLI polls `askActivity` with `waitMs`.
- SIGINT while following in local mode cancels the turn before exit.
- Warnings (`model_unknown`) go to stderr, one per line.
- Wiring: route, command kind, dispatch, enumeration (bare `ask` plus the
  six verbs), help text, subcommand help.

### 5. Example (`examples/ask-run-status/`, new)

`workflow.json` (one step, mock scenario), `mock-scenario.json`,
`ask-script.json` (two rounds: a `session_status` tool line; an answer that
cites `[[session:<id>]]` through a placeholder the test fills, or that cites
the context ref), `README.md`, `EXPECTED_RESULTS.md` with the commands:
a mock run under `tmp/ask-riela/example` stores, then
`RIELA_ASK_SCRIPTED_BACKEND=examples/ask-run-status/ask-script.json riela ask --session <id> "what is the state of this run?"`.
Register the example name in `RielaExampleCatalog.swift` and
`examples/README.md`.

## Pitfalls

- Write catalog rows first, then CLI, then descriptors, then regenerate the
  SDL; the parity gates compare all of them.
- The SDL file is generated. A hand edit fails `SurfaceParityDTOSchemaTests`.
- `askActivity` long-poll must re-check authorization per wake and share
  `BotActivityWaiters.shared`.
- An unreachable remote returns the error; never a payload with an empty or
  placeholder answer.
- The remote token never appears in output, errors or logs.
- `--remote` on `riela ask` talks to the remote directly; it must not create
  a local conversation.
- A `read` grant may call the three queries; every ask mutation needs
  `operate`. Do not add ask fields to the admin set.
- `Sources/RielaCLI/RielaLibrary.swift`: chain the executor only; no new
  library entry point.
- The example must not need a vendor: the walkthrough test fails if the
  production adapter is constructed.

## Tests

`Tests/RielaGraphQLTests/Ask/AskGraphQLTests.swift` (stub provider):
- each root field reaches the stub with decoded arguments.
- `startAsk` without `message` → validation error; unknown context kind →
  validation error.
- a provider `AskError(code: "ask_turn_running")` → `extensions.code`.
- the generated selection for `AskConversationPayload` executes without a
  validation error.

`Tests/RielaCLITests/Ask/Surfaces/AskCommandTests.swift` (scripted backend,
temporary stores):
- `ask --session S "state?"` text → stdout has the answer, a `· session_status`
  line, `Records:` with the session, `conversation ask-...`; exit success.
- `--output json` → one JSON document with `conversation.turn.status == "completed"`.
- `ask --conversation <id> "again"` → same conversation, two user messages.
- `ask list`, `ask show <id>`, `ask remove <id>` → expected rows; after
  remove, `show` fails with `ask_conversation_not_found`.
- `ask -- list` → sends the message `list`.
- `--session a --bot b` → usage error.
- `ask confirm <conv> <action>` after a scripted proposal → action
  `confirmed`, the bot is paused in the store; `ask dismiss` → `dismissed`.
- scripted failure → non-zero exit, error code on stderr, no answer on stdout.
- `--model unknown-x` → one `model_unknown:` line on stderr.

`Tests/RielaCLITests/Ask/Surfaces/AskRemoteTests.swift` (in-process server
composite with its own stores, injected transport, as in
`Tests/RielaCLITests/Remotes/RemoteForwardingTests.swift`):
- `ask --remote srv "state?"` → conversation exists in the server store, none
  locally; payload `origin.remote == "srv"`.
- transport failing → `remote_unreachable`, stdout empty.
- `read` grant → `startAsk` fails `scope_insufficient`; `askConversations`
  succeeds.
- confirm through the remote with an `operate` grant → the server-side
  record changed and the action's `decidedBy` names the grant.

`Tests/RielaCLITests/Ask/Surfaces/AskExampleWalkthroughTests.swift`:
- the commands of `EXPECTED_RESULTS.md` against temporary stores → the answer
  names the run status and `citations` holds the session.

Existing gates must pass with the new rows: `SurfaceCatalogTests`,
`SurfaceParityCLITests`, `SurfaceParityGraphQLTests`,
`SurfaceParityExecutorCoverageTests`, `SurfaceParityDTOSchemaTests`,
`SurfaceParityWebAPITests`, `SurfaceParityConsoleReadTests`,
`SurfaceParityLibraryTests`, `SurfaceParitySkillTests`,
`RielaExampleParityTests`, `SubcommandHelpTests`, `CommandParsingTests`.

## Verification

```
mkdir -p tmp/ask-riela/ask-04-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/ask-riela/ask-04-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift build' > tmp/ask-riela/ask-04-surfaces/build.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "AskGraphQLTests|AskCommandTests|AskRemoteTests|AskExampleWalkthroughTests|AskTurnEngineTests|AskActionTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|SurfaceParitySkillTests|RielaExampleParityTests|SubcommandHelpTests|SubcommandHelpApplicationTests|CommandParsingTests|BotCommandTests|BotsGraphQLTests|RemoteForwardingTests|PairingScopeEnforcementTests|ServeWebHostTests|ServeHTTPCommandTests"' > tmp/ask-riela/ask-04-surfaces/test.log 2>&1
```

All exit 0. A second run of `generate-sdl.sh` leaves
`Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` byte-identical
(`shasum -a 256` before and after, recorded in the progress log). Evidence:
CLI and GraphQL parity, remote forwarding with origin and scope, the example
answer.

## Done criteria

- `grep -n "api/v1" Sources/RielaCLI/Ask -r` prints nothing.
- `git diff --stat Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` is empty.
- Verification exits 0; progress log written.
