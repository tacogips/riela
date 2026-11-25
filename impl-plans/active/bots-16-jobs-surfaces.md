# bots-16-jobs-surfaces: memory upkeep and look-around jobs, suggestions, serve tick

```json
{
  "planId": "bots-16-jobs-surfaces",
  "planPath": "impl-plans/active/bots-16-jobs-surfaces.md",
  "dependsOn": [
    "bots-15-memory-surfaces"
  ],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/BotRuntime",
    "Sources/RielaCLI/BotJobs",
    "Sources/RielaCLI/ModelCatalog",
    "Sources/RielaCLI/Pairing",
    "Sources/RielaCLI/Remotes",
    "Sources/RielaCore/Bots",
    "Sources/RielaCore/BotMemory",
    "Sources/RielaCore/BotJobs",
    "Sources/RielaCore/BotActivity",
    "Sources/RielaCore/BotBoard",
    "Sources/RielaCore/ModelCatalog",
    "Sources/RielaGraphQL",
    "Sources/RielaServer",
    "Sources/RielaAdapters",
    "Tests/RielaCLITests/Bots",
    "Tests/RielaCLITests/BotRuntime",
    "Tests/RielaCLITests/BotJobs",
    "Tests/RielaCLITests/BotActivityRuntime",
    "Tests/RielaCLITests/ModelCatalog",
    "Tests/RielaCLITests/Pairing",
    "Tests/RielaCLITests/Remotes",
    "Tests/RielaCoreTests/Bots",
    "Tests/RielaCoreTests/BotMemory",
    "Tests/RielaCoreTests/BotJobs",
    "Tests/RielaCoreTests/BotActivity",
    "Tests/RielaCoreTests/BotBoard",
    "Tests/RielaCoreTests/ModelCatalog",
    "Tests/RielaGraphQLTests",
    "Tests/RielaServerTests",
    "scripts/surface-parity",
    "Sources/RielaCLI/APIKeyGraphQLAuthorization.swift",
    "Sources/RielaCLI/CLISubcommandHelp.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Sources/RielaCLI/EventCronOverlapDispatcher.swift",
    "Sources/RielaCLI/EventLiveServe+Cron.swift",
    "Sources/RielaCLI/EventLiveServe.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Sources/RielaCLI/ParityCommands.swift",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaArgumentParserHelpers.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/RoutineCommands.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/ScopedParityCommands+Serve.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaCLI/ServeWebAccess.swift",
    "Sources/RielaCLI/ServeWebHost+Configuration.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/SessionReconcileCommand.swift",
    "Sources/RielaCLI/TerminalRetentionExecutor.swift",
    "Sources/RielaCLI/WorkflowCommands.swift",
    "Sources/RielaCLI/WorkflowExecutionProvider.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Remote.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCore/AdapterContracts.swift",
    "Sources/RielaCore/AgentToolPolicyPresetArguments.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+DynamicWorkflow.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+StepSupervisor.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/RoutineStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift",
    "Sources/RielaCore/SurfaceCatalog.swift",
    "Sources/RielaCore/WorkflowBackendPolicy.swift",
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaAppSupport/RielaWebAPIRouteTable.swift",
    "Sources/RielaAppSupport/RielaConsoleGraphQLProvider.swift",
    "Sources/RielaAppSupport/RielaWebAPIProjection.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaApp/RielaAppWebRouter.swift",
    "Sources/RielaApp/RielaAppWebAPI.swift",
    "Sources/RielaApp/RielaAppWebServerController.swift",
    "Sources/RielaApp/EntryPoint+WebServer.swift",
    "Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift",
    "Sources/RielaWorkflowRegistry/RoutineService.swift",
    "Tests/RielaCLITests/APIKeyGraphQLAuthorizationTests.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift",
    "Tests/RielaCLITests/EventLiveServeTestSupport.swift",
    "Tests/RielaCLITests/EventLiveServeTests.swift",
    "Tests/RielaCLITests/RoutineCommandTests.swift",
    "Tests/RielaCLITests/ServeHTTPCommandTests.swift",
    "Tests/RielaCLITests/ServeWebHostTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Tests/RielaCLITests/SurfaceParityConsoleReadTests.swift",
    "Tests/RielaCLITests/SurfaceParityLibraryTests.swift",
    "Tests/RielaCLITests/SurfaceParitySkillTests.swift",
    "Tests/RielaCLITests/SurfaceParityWebAPITests.swift",
    "Tests/RielaCoreTests/AgentPromptGuardTests.swift",
    "Tests/RielaCoreTests/RoutineStoreTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift",
    "impl-plans/progress/bots-16-jobs-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCore/DeterministicWorkflowRunner.swift",
      "intendedEdit": "ONE edit where the agent node payload is prepared for the adapter input (near line 686-711): when request.botContext?.forceReadOnlySandbox is true, set the payload's agentSandbox to .readOnly. Keep plan 15's memory block edit."
    },
    {
      "path": "Sources/RielaCLI/WorkflowRunCommand.swift",
      "intendedEdit": "ONE new optional stored property `var botContextOverride: (@Sendable (BotRunContext) -> BotRunContext)?` (default nil) declared next to `botLinkSource`, and ONE use: where plan 09 assigns `request.botContext` from BotRunLinker.prepare, apply the override to that value first. nil keeps behaviour byte-identical. Plan 09's botContext and link code and plan 11's activityRecorder code stay unchanged."
    },
    {
      "path": "Tests/RielaCoreTests/BotJobs",
      "intendedEdit": "One new file ForcedReadOnlySandboxRunnerTests.swift. Plan 07's files stay unchanged."
    },
    {
      "path": "Sources/RielaCLI/EventLiveServe.swift",
      "intendedEdit": "In the serve repeat loop (around line 192-320) call the job scheduler tick once per iteration. No other change."
    },
    {
      "path": "Sources/RielaCLI/ServeHTTPCommand.swift",
      "intendedEdit": "Start the job scheduler loop after the server is ready and cancel it on shutdown."
    },
    {
      "path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
      "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."
    }
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §10.1–§10.3, §5.3 (accepted suggestions under Planned). Plan 07 built
the due check, ledger, suggestion store and policy check; plan 06/15 the
memory writer. This plan runs the two jobs as real, bot-linked single-turn
runs, applies their output in the runtime, exposes jobs and suggestions, and
ticks due jobs from the two long-running hosts.

Current code:

- Inline workflow definitions: read `Sources/RielaCore/TemporaryWorkflowPayload.swift`
  and how `riela workflow run` accepts an inline workflow (search
  `RielaCLI` for its use) — the built-in job workflow is run through that
  same path, not through a new runner.
- Agent node fields: `agentSandbox` (`AgentSandboxMode.readOnly`,
  `Sources/RielaCore/WorkflowModel.swift:66`), `agentToolPolicy.preset`
  (`.noTools` = `"none"`, `:77`), `executionBackend`, `model`, `output`.
- Serve loops: `DefaultEventLiveServer.servePrepared` repeat loop
  (`EventLiveServe.swift`), `ServeHTTPCommand.run` (`ServeHTTPCommand.swift:33-`).
- `WorkflowRunCommand.botLinkSource`, `BotRunLinker` (plan 09),
  `BotRunContext.forceReadOnlySandbox` (plan 01, unused so far).

## Non-goals

- No new scheduler concept, cron source or routine: the tick only evaluates
  `BotJobDue.decide` for each bot.
- No tool execution by the model in upkeep; no writes by look-around.
- No web (plan 20).

## Changes

### Job workflows (`Sources/RielaCLI/BotJobs/BotJobWorkflows.swift`, new)

Two built-in, single-step inline workflows, built in code:

- `riela-bot-memory-upkeep`: one agent node; `executionBackend` =
  `bot.defaultBackend`; `model` = `bot.defaultModel` unless nil or `default`;
  `agentSandbox: read-only`; `agentToolPolicy.preset: none`; output contract
  `{ memoryMarkdown: string }`. Prompt (authored here, short): the current
  memory Markdown, the last-result lines and feedback change reasons since
  the last successful upkeep, the instruction to return the full
  consolidated memory in the same Markdown format, keeping every
  `<!-- id:n -->` marker of entries it keeps, and not to change the
  Instructions section.
- `riela-bot-look-around`: same node settings but no tool preset override
  (read-only sandbox is the enforcement); output contract
  `{ suggestions: [{ title, detail?, action?: { workflowName, input? } }] }`.
  Prompt: the bot's purpose, board summary (Needs you, Waiting, Planned
  titles), and the instruction to list next steps only.

A bot without `defaultBackend` → `bot_job_backend_missing`.

### Job runner (`Sources/RielaCLI/BotJobs/BotJobRunner.swift`, new)

`struct BotJobRunner { workingDirectory, sessionStoreRoot, memoryRoot, environment, now, calendar, mockScenarioPath: String? }`

`func run(botId:job:force:) async throws -> BotJobResult` (`status`,
`periodKey`, `sessionId`, `detail`, `changeSet` or `suggestions`):

1. Load the bot and its overview row (`BotsService`). Compute
   `BotJobDue.decide` (busy = `counts.working > 0 || counts.needsYou > 0`).
   Without `force`: `.notDue` → return `not_due` with the reason; `.skip` →
   `recordSkippedJobRuns` and return `skipped`. With `force`: use the current
   period key with suffix `-manual-<UUID prefix>` and ignore `off`, `done`
   and `no_activity`, but still refuse `paused` (`bot_paused`).
2. Look-around only: `LookAroundPolicy.violations` on the workflow to run;
   non-empty → `look_around_not_read_only`, nothing started.
3. `claimJobRun`; false → return `not_due` (`claimed`). Record skipped
   catch-up keys.
4. Run the inline workflow through `WorkflowRunCommand` with `options.botId`,
   `botLinkSource = ("job", "<job>:<periodKey>")`, the mock scenario when
   given, and `command.botContextOverride` set to a closure that returns the
   prepared context with `permissionWaitMs = 0` and
   `forceReadOnlySandbox = true` (both jobs). `botContextOverride` is the new
   stored property on `WorkflowRunCommand`
   (`Sources/RielaCLI/WorkflowRunCommand.swift`, stored properties at
   `:26-43`; a Swift extension cannot add it, so the file is in this plan's
   writePaths). The override is applied after `BotRunLinker.prepare`
   succeeds and before the run request is built; it never runs when
   `options.botId` is nil.
5. Apply the output in the runtime:
   - upkeep: `BotMemoryMarkdown.parse(memoryMarkdown)`; parse error →
     `failed: memory_markdown_invalid`; `BotMemoryWriter.upkeepRejection` →
     `failed: upkeep_removes_too_much`; else `applyMarkdown(source: .upkeep, actor: "upkeep", reason: "upkeep:<periodKey>", evidenceRefs: ["session:<id>"])`.
   - look-around: `BotSuggestion.parseOutput`; error →
     `failed: look_around_output_invalid`; else `insertSuggestions`.
   - a failed or cancelled run → `failed` with the session failure reason.
6. `finishJobRun` with `succeeded` or `failed` and the detail.

### Runner enforcement (`DeterministicWorkflowRunner.swift`)

The single edit in the sharedPathNotes: `forceReadOnlySandbox` overrides the
node's `agentSandbox` for every agent step of the run and its child runs.

### Scheduler tick (`Sources/RielaCLI/BotJobs/BotJobScheduler.swift`, new)

`actor BotJobScheduler` with `func tickIfDue(now: Date)`: at most once per 60
seconds it lists bots and, for each bot and each job whose schedule is not
`off`, starts `BotJobRunner.run(force: false)` in a tracked child task. At
most one job task runs at a time per process; a tick while one is running
does nothing. `func shutdown()` cancels and awaits the running task.
- `EventLiveServe.swift`: call `await scheduler.tickIfDue(now:)` in the loop;
  it returns immediately (the job runs in its own task), so sources are not
  blocked.
- `ServeHTTPCommand.swift`: a task that calls `tickIfDue` every 60 seconds
  using the existing wall-clock sleep helper; cancelled when the server stops.
- Both use the host's session store root, working directory and environment.

### CLI (`Sources/RielaCLI/BotJobs/BotJobCommands.swift`, new)

`BotClientAction` gains `job` and `suggestion`;
`BotJobClientAction { run, list }`, `BotSuggestionClientAction { list, accept, dismiss }`.

| Command | Behaviour |
| --- | --- |
| `bot job run <botId> <upkeep\|look-around> [--force] [--mock-scenario <path>]` | runs in the foreground; prints the result |
| `bot job list <botId> [--job J] [--limit N]` | ledger rows, newest first |
| `bot suggestion list <botId> [--status S]` | suggestions |
| `bot suggestion accept <suggestionId> [--run] [--mock-scenario <path>]` | accept; with `--run` and an action, start the workflow linked to the bot and mark `started` |
| `bot suggestion dismiss <suggestionId> [--reason R]` | dismiss |

`accept --run` on a suggestion without an action → `suggestion_no_action`
(the suggestion is still accepted). The decided-by principal is `cli`.

### Service and GraphQL

- `BotsService`: pass `BotStore.suggestions` into `BotBoardInput.suggestions`;
  `BotDetailPayload` gains `suggestions` (open and accepted) and
  `jobs { job, schedule, lastRun { periodKey, status, finishedAt, detail } }`.
- `Query.botSuggestions(botId: String!, status: String, remote: String): BotSuggestionListPayload!`
- `Mutation.decideBotSuggestion(input: DecideBotSuggestionInput!): BotSuggestionPayload!`
  (`suggestionId`, `decision: accept|dismiss`, `run: Boolean`, `reason`,
  `remote`); with `run` it starts the workflow through the same provider path
  as `executeWorkflow` with `botId`.
- `Mutation.runBotJob(input: RunBotJobInput!): BotJobPayload!` (`botId`,
  `job`, `force`, `remote`).
- New file `Sources/RielaGraphQL/Bots/BotJobsGraphQL.swift`; extend the
  executor field sets and `BotsGraphQLProviding`.

### Registries

Catalog rows `bot.job.run`, `bot.job.list` (graphql: bound to `bot` detail
query), `bot.suggestion.list|accept|dismiss`; three-level enumeration for
`job` and `suggestion`; descriptors, SDL, help.

## Imitate

- Plan 15's `BotMemoryCommands.swift` for nested verbs.
- `Sources/RielaCLI/EventCronOverlapDispatcher.swift` for running work in a
  tracked task without blocking the serve loop.
- `Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift` for
  applying model output through an audited store call.

## Pitfalls

- The model's text is data. Only the runtime writes memory and suggestions;
  never give the job workflow a write-capable node.
- `claimJobRun` before starting the run; never start then claim.
- A forced manual run must not consume the scheduled period key.
- The tick must not await a job inline in the serve loop.
- Jobs of a paused bot never run, forced or not.
- With `forceReadOnlySandbox`, a node authored with `workspace-write` must
  reach the adapter as `read-only` (assert in a runner test).
- Look-around permission wait is 0: any permission request is declined.
- Tests must use `--mock-scenario` responses keyed by the job workflow's node
  id; never a real backend.

## Tests

`Tests/RielaCLITests/BotJobs/BotJobRunnerTests` (temporary roots, mock
scenario files written by the test, injected `now` and calendar):
- upkeep with activity yesterday and a scenario returning valid Markdown that
  merges two notes → `succeeded`; memory shows the merged note; history has a
  change set with actor `upkeep`; ledger row `succeeded`; the job session is
  linked with source `job`.
- upkeep output that edits an instruction → instruction unchanged,
  `ignoredInstructionChanges == 1`, still `succeeded`.
- upkeep output that is not valid Markdown → `failed: memory_markdown_invalid`,
  memory unchanged.
- upkeep output dropping 5 of 6 notes → `failed: upkeep_removes_too_much`.
- no activity since last success → `skipped`, ledger `skipped`, no session.
- second run for the same period → `not_due`.
- `--force` twice → two sessions, the scheduled key still unclaimed.
- paused bot → `bot_paused` even with `--force`.
- bot without backend → `bot_job_backend_missing`.
- look-around with a scenario returning two suggestions → two `open` rows
  with `sourceSessionId`; nothing else written (memory unchanged, no other
  session).
- look-around output without `suggestions` → `failed: look_around_output_invalid`.
- `suggestion accept --run --mock-scenario` with an action → a linked session
  exists and status is `started`; accept again → `suggestion_already_decided`.
- `suggestion dismiss --reason later` → recorded.
- accepted suggestion without run → appears under Planned in `bot show`.
- context of a job run (capture it with a test adapter or through the
  recorded `permissionResolved` policy and the execution's sandbox) →
  `permissionWaitMs == 0` and `forceReadOnlySandbox == true`; a plain
  `workflow run --bot` of the same bot → the bot's `permissionWaitMs` and
  `forceReadOnlySandbox == false`.

`Tests/RielaCLITests/BotJobs/LookAroundReadOnlyTests`:
- runner given a workflow with a command node → `look_around_not_read_only`,
  no session created.
- the look-around run's recorded execution uses sandbox `read-only` even when
  the built-in node is patched to `workspace-write` in the test.
- a scripted permission request during a look-around run (use the plan 03
  recorder with `waitMs` from the job context) resolves `cancelled` with
  `resolvedBy policy`.

`Tests/RielaCoreTests/BotJobs/ForcedReadOnlySandboxRunnerTests`:
- `botContext.forceReadOnlySandbox = true` and a node with
  `agentSandbox: workspace-write` → the adapter input node has `.readOnly`;
  with false → unchanged.

`Tests/RielaCLITests/BotJobs/BotJobSchedulerTests`:
- two ticks 10 s apart → one evaluation; a tick 61 s later → second.
- tick while a job task runs → no second task.

`Tests/RielaGraphQLTests/Bots/BotJobsGraphQLTests`: fields reach the stub
provider and encode the declared shape.

## Verification

```
mkdir -p tmp/bots-overview/bots-16-jobs-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-16-jobs-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotJobRunnerTests|LookAroundReadOnlyTests|ForcedReadOnlySandboxRunnerTests|BotJobSchedulerTests|BotJobsGraphQLTests|BotJobDueTests|BotMemoryCommandTests|BotCommandTests|BotRunLinkageTests|BotActivityRuntimeTests|BotMemoryInjectionTests|DeterministicWorkflowRunnerTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-16-jobs-surfaces/test.log 2>&1
```

Both exit 0. Evidence: upkeep applies text through the audited writer,
look-around cannot write and is enforced outside the prompt, suggestions
need acceptance, gates are green. `BotRunLinkageTests`,
`BotActivityRuntimeTests` and `BotMemoryInjectionTests` passing proves the
plan 09, 11 and 15 behaviour in `WorkflowRunCommand.swift` and the runner
survived this plan's edits.

## Done criteria

- `grep -n "botContextOverride" Sources/RielaCLI/WorkflowRunCommand.swift` shows the declaration and exactly one use.
- `grep -n "forceReadOnlySandbox" Sources/RielaCore/DeterministicWorkflowRunner.swift` shows the single override site.
- `grep -rn "tickIfDue" Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/ServeHTTPCommand.swift` shows one call in each.
- Verification exits 0; progress log written.

## Amendment 2026-11-25 (tracking-contract, plan-contract-validate)

`plan-contract-validate` rejected the broad roots (`Sources/RielaCLI`, `Sources/RielaCore`, `Tests` and the others): every write path is also a full source snapshot, and one plan may expand to at most 512 entries. This plan installs no tools, so no `artifactRoots` apply; the header `writePaths` is narrowed instead. This replaces the phrase "directory-level" of the operator amendment below; every other operator amendment stays in force.

- Scope now: the whole directories `Sources/RielaGraphQL`, `Sources/RielaServer`, `Sources/RielaAdapters`, `Tests/RielaGraphQLTests`, `Tests/RielaServerTests`, `scripts/surface-parity`; every bot-feature subdirectory of `Sources/RielaCLI`, `Sources/RielaCore`, `Tests/RielaCLITests` and `Tests/RielaCoreTests` (Bots, BotRuntime, BotJobs, BotActivity, BotActivityRuntime, BotBoard, BotMemory, ModelCatalog, Pairing, Remotes); and the named flat files in the header. Current expansion: about 316 entries (limit 512), plus what plan 15 added.
- Every `sharedPathNotes` path is in scope, including `Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCLI/EventLiveServe.swift` and `Sources/RielaCLI/ServeHTTPCommand.swift`.
- Budget: add at most 40 new files. Put new files in the listed bot-feature directories; do not create a new directory directly under `Sources/` or `Tests/`.
- If a required edit is in a file that is neither listed nor under a listed directory, do not edit it: record `BLOCKED: write scope` in the progress log with the exact path, symbol and reason, and finish the rest of the plan first.
- Tasks, tests, verification commands and done criteria are unchanged.

## Operator amendment (after fable-sol session 1)

Plans 01-14 are implemented, integration-accepted and committed in `73674ceb`; treat them as satisfied dependencies. Remaining plans run strictly serially 15 -> 16 -> 17 -> 18 -> 19 -> 20. `dependsOn` lists only the remaining predecessor. The write scope is exactly the header `writePaths` (see "Amendment 2026-11-25" above): whole bot-feature directories plus named files, including files first created by plans 01-14. Do not stop for write scope inside these paths; a scope stop is only valid for a path that is neither listed nor under a listed directory (for example Package.swift or Packages/RielaMemory). Earlier `Continuation` or `BLOCKED` notes in impl-plans/progress for this plan are void: start the implementation now.
