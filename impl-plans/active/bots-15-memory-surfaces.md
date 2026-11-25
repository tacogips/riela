# bots-15-memory-surfaces: `riela bot memory`, `riela bot feedback`, GraphQL memory, prompt injection

```json
{
  "planId": "bots-15-memory-surfaces",
  "planPath": "impl-plans/active/bots-15-memory-surfaces.md",
  "dependsOn": ["bots-06-memory-core", "bots-13-model-surfaces"],
  "wave": 6,
  "writePaths": [
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/BotRuntime",
    "Sources/RielaGraphQL/Bots",
    "Tests/RielaCLITests/Bots",
    "Tests/RielaCLITests/BotRuntime",
    "Tests/RielaGraphQLTests/Bots",
    "Tests/RielaCoreTests/BotMemory",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "impl-plans/progress/bots-15-memory-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner.swift", "intendedEdit": "ONE edit before the guardAgentPrompt call (line 686): when request.botContext?.memoryBlock is non-empty, append it to the composed system prompt. Nothing else."},
    {"path": "Sources/RielaCLI/BotRuntime", "intendedEdit": "BotRunLinker.prepare fills BotRunContext.memoryBlock; BotActivityRuntime.botContext(forExistingSession:) does the same. New file BotMemoryRuntime.swift for the shared helper."},
    {"path": "Tests/RielaCoreTests/BotMemory", "intendedEdit": "One new file BotMemoryPromptInjectionTests.swift. Plan 06's files stay unchanged."},
    {"path": "Sources/RielaCLI/CLISurfaceEnumeration.swift", "intendedEdit": "In the `bot` expansion, expand the `memory` action into its nested verbs (three-level paths), like `workflow definition`."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §9.3, §9.4, §9.5, §10.4, §5.4 (memory summary in `bot show`). Plan 06
built the writer, Markdown and undo. This plan exposes them, captures
feedback as memory candidates through the same writer, and injects the
memory block into the prompts of bot-linked runs inside the existing prompt
budget.

Current code:

- Prompt composition and guard: `DeterministicWorkflowRunner.swift:686-711`
  (`guardAgentPrompt(...)` then `systemPromptText: promptGuard.prompts.systemPromptText`),
  `ComposedAdapterPrompts.systemPromptText` (`+Prompting.swift:6`).
- Memory root resolution used by `riela memory`: read
  `Sources/RielaCLI/MemoryCommands.swift` / `ParsedMemoryOptions.swift`
  (default `RielaMemoryStore.defaultRootDirectory(workingDirectory:)`).
- Redaction: `HandoverRedactionRules` (`Sources/RielaWork/HandoverRedaction.swift:4,43,58`).
- Session review findings: `WorkflowSession.reviewFindings`
  (`Sources/RielaCore/RuntimeSession.swift:420`).
- Plan 06: `BotMemoryWriter`, `BotMemoryMarkdown`, `BotMemoryLimits`.
  Plan 09/11: `BotRunLinker`, `BotActivityRuntime`.

## Non-goals

- No upkeep job (plan 16), no web editor (plan 20).
- No kaiba; no change to `riela memory` commands or persona add-ons.
- A run without a bot gets no block: its prompts stay byte-identical.

## Changes

### Memory runtime (`Sources/RielaCLI/BotRuntime/BotMemoryRuntime.swift`, new)

- `static func writer(sessionStoreRoot:memoryRoot:) -> BotMemoryWriter` with
  `redact = HandoverRedactionRules` default rules `redactText`, `now = Date.init`.
- `static func memoryRoot(explicit:workingDirectory:environment:) -> String`
  using the same precedence as `riela memory`.
- `static func promptBlock(botId:...) -> String?` =
  `BotMemoryMarkdown.promptBlock(entries:, limitBytes: 16_000)`; errors → nil
  and one stderr line `riela bot memory: <error>`.
- `BotRunLinker.prepare` and `BotActivityRuntime.botContext(forExistingSession:)`
  set `memoryBlock` from it.

### Runner (`DeterministicWorkflowRunner.swift`)

Before `guardAgentPrompt`: if `request.botContext?.memoryBlock` is non-empty,
set the composed system prompt to
`[existing system prompt, memoryBlock].compactMap{...}.joined(separator: "\n\n")`.
The guard then measures the prompt including the block. Child requests
already inherit `botContext` (plan 01).

### CLI (`Sources/RielaCLI/Bots/BotMemoryCommands.swift`, new)

`BotClientAction` gains `memory` and `feedback`; `BotMemoryClientAction`:
`show`, `export`, `edit`, `history`, `diff`, `undo`.

| Command | Behaviour |
| --- | --- |
| `bot memory show <botId>` | prints the Markdown of design §9.3 |
| `bot memory export <botId> [--out <path>]` | same text to stdout or a file (refuses to overwrite without `--force`) |
| `bot memory edit <botId> --file <path> [--reason R]` | `applyMarkdown` with source `user`, actor `cli`; prints the change set |
| `bot memory history <botId> [--limit N]` | change sets, newest first |
| `bot memory diff <botId> <changeId>` | per-entry diffs |
| `bot memory undo <botId> [<changeId>]` | undo; prints the new change set |
| `bot feedback <botId> (--session <id> \| --task <id>) [--text T] [--topic X] [--from-findings]` | see feedback below |

Options added to `ParsedBotOptions`: `--file`, `--out`, `--force`,
`--reason`, `--text`, `--topic`, `--task`, `--from-findings`, `--memory-root`.

### Feedback (`BotsService.captureFeedback`)

- The session (or the task's attempt session) must be linked to that bot
  (`feedback_item_not_found` otherwise) and terminal (`feedback_item_not_finished`).
- `--text` → one `.add` entry, kind `instruction`, source `correction`,
  topic `--topic ?? "corrections"`.
- `--from-findings` → one `.add` note per entry of the session's
  `reviewFindings`, source `review`, topic `review`, text = the finding's
  message (one line, cut to 500 characters). No findings and no text →
  `feedback_empty`.
- One `apply` call: actor `feedback`, reason `feedback`,
  `evidenceRefs = ["session:<id>"]` or `["task:<id>"]`.

### GraphQL (`Sources/RielaGraphQL/Bots/BotMemoryGraphQL.swift`, new file; same executor)

- `Query.botMemory(botId: String!, remote: String): BotMemoryPayload!` —
  `{ botId, markdown, instructionCount, noteCount, changes: [BotMemoryChange!]!, origin }`
  (latest 20 change sets).
- `Mutation.updateBotMemory(input: UpdateBotMemoryInput!): BotMemoryChangePayload!`
  (`botId`, `markdown`, `reason`, `remote`; source `user`, actor `api`).
- `Mutation.undoBotMemoryChange(input: UndoBotMemoryChangeInput!): BotMemoryChangePayload!`
- `Mutation.captureBotFeedback(input: CaptureBotFeedbackInput!): BotMemoryChangePayload!`
- `BotDetailPayload` gains `memory { instructionCount, noteCount, lastChangedAt }`;
  `bot show` prints it.

### Registries

Catalog rows `bot.memory.show|export|edit|history|diff|undo`, `bot.feedback`
(`export`, `history`, `diff` have no GraphQL field of their own: bind `show`,
`export`, `history` to `botMemory`; `diff` is excluded on GraphQL with the
reason "diff is rendered by the CLI from record versions; design §9.4");
descriptors, SDL, help.

## Imitate

- Plan 10 and 12 files for the family skeleton.
- `Sources/RielaCLI/MemoryCommands.swift` for history and diff rendering.
- `WorkflowDefinitionClientSubcommand` handling in `CLISurfaceEnumeration.swift:56-59`
  for three-level command paths.

## Pitfalls

- The memory root used for injection must be the root the bot's memory was
  written to. Resolve it once in `BotMemoryRuntime.memoryRoot` and use that
  function everywhere (commands, provider, linker).
- Append the block before the guard, never after it.
- `memoryBlock == nil` or empty → no change at all to the prompt (assert
  byte equality in a test).
- `edit` must go through `applyMarkdown`; do not write records directly.
- GraphQL `updateBotMemory` sets source `user`; a remote caller cannot pick
  the source or actor.
- `export --out` writes only to the given path; never under the repository
  root by default.

## Tests

`Tests/RielaCLITests/Bots/BotMemoryCommandTests` (temporary session store
and memory roots):
- `edit` with a file adding one instruction and one note → `show` renders
  both with id markers.
- `export` → `edit` with the unchanged file → empty change set, exit 0.
- edit, then `undo` → `show` equals the earlier text; `history` lists both.
- `diff <changeId>` prints the changed text.
- instruction text containing an API-key-looking token → stored redacted.
- `feedback --session S --text "Use the staging cluster"` on a finished
  linked session → one instruction with source `correction`; evidence ref
  `session:S` in history.
- `feedback --from-findings` on a session with two review findings → two
  notes with source `review`.
- feedback on an unlinked session → `feedback_item_not_found`; on a running
  one → `feedback_item_not_finished`.
- `bot show` JSON has `memory.instructionCount`.

`Tests/RielaCLITests/BotRuntime/BotMemoryInjectionTests`:
- bot with memory, `workflow run --bot` with a mock scenario → the recorded
  step prompt (read it the way existing run tests read `promptText` or the
  session's input snapshot) contains `Bot memory (riela memory)` and the
  instruction text.
- the same run without `--bot` → no such text.

`Tests/RielaCoreTests/BotMemory/BotMemoryPromptInjectionTests` (runner with
a capturing adapter):
- `botContext.memoryBlock = "X"` → adapter input `systemPromptText` ends with
  `X`; with nil → `systemPromptText` equals the value of a run without
  `botContext`.
- a node with `promptMaxBytes` smaller than prompt + block → the guard
  reports over budget (the block is measured).

`Tests/RielaGraphQLTests/Bots/BotMemoryGraphQLTests`: fields reach the stub
provider and encode the declared shape.

## Verification

```
mkdir -p tmp/bots-overview/bots-15-memory-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-15-memory-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotMemoryCommandTests|BotMemoryInjectionTests|BotMemoryPromptInjectionTests|BotMemoryGraphQLTests|BotMemoryWriterTests|BotCommandTests|DeterministicWorkflowRunnerTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-15-memory-surfaces/test.log 2>&1
```

Both exit 0. Evidence: memory is editable, audited and undoable from the
CLI; feedback uses the same path; the block reaches prompts only for
bot-linked runs and is inside the guard's measurement; gates are green.

## Done criteria

- `grep -n "memoryBlock" Sources/RielaCore/DeterministicWorkflowRunner.swift` shows the single injection site above the `guardAgentPrompt` call.
- `git status --short Packages/RielaMemory` prints nothing.
- Verification exits 0; progress log written.
