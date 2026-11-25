# ask-06-workflow-authoring: `propose_workflow`, apply on confirm, removal of the generation routes

```json
{
  "planId": "ask-06-workflow-authoring",
  "planPath": "impl-plans/active/ask-06-workflow-authoring.md",
  "dependsOn": [
    "ask-05-mcp-transport"
  ],
  "wave": 5,
  "writePaths": [
    "Sources/RielaCLI/Ask",
    "Sources/RielaCore/Ask",
    "Sources/RielaAppSupport",
    "Sources/RielaApp",
    "Sources/RielaGraphQL/Ask",
    "Sources/RielaCLI/RielaWebWorkflowRuntime.swift",
    "Sources/RielaCLI/WebWorkflowLaunch.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Generation.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Launch.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+NodeSettings.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+RunEvidence.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsAsk.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "scripts/surface-parity",
    "Tests/RielaCLITests/Ask",
    "Tests/RielaCoreTests/Ask",
    "Tests/RielaGraphQLTests/Ask",
    "Tests/RielaAppSupportTests/WorkflowEditorGenerationTests.swift",
    "Tests/RielaAppSupportTests/WorkflowEditorLiveAgentTests.swift",
    "Tests/RielaAppSupportTests/WorkflowEditorDefinitionTests.swift",
    "Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift",
    "Tests/RielaCLITests/ServeWebEditorTests.swift",
    "Tests/RielaCLITests/ServeWebHostTests.swift",
    "Tests/RielaCLITests/SurfaceParityWebAPITests.swift",
    "Tests/RielaCLITests/SurfaceParityConsoleReadTests.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
    "Tests/RielaGraphQLTests/SurfaceParityGraphQLTests.swift",
    "impl-plans/progress/ask-06-workflow-authoring.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaAppSupport",
      "intendedEdit": "Delete WorkflowEditorGeneration.swift and WorkflowEditorAuthoringRounds.swift; remove the three generation entries and the generation prefix from RielaWebAPIRouteTable.swift (lines 126-128, 179). Keep every other workflow-editor file."
    },
    {
      "path": "Sources/RielaApp",
      "intendedEdit": "Remove the `workflowEditorGenerations` accessor (EntryPoint.swift:76) and any code that only served the generation routes (check RielaAppWebWorkflowChat.swift). The native mini chat (EntryPoint+Assistant.swift) is not changed."
    },
    {
      "path": "Sources/RielaCLI/WebWorkflowRequestHandler+Generation.swift",
      "intendedEdit": "Delete the file after moving the authoring guidance text into the ask prompt."
    },
    {
      "path": "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift",
      "intendedEdit": "Remove the rows generation-start, generation-status, generation-cancel (lines 315-317)."
    },
    {
      "path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
      "intendedEdit": "Generated: regenerate only if a descriptor changed."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2, §3.3. Design: §7.1 (`applyWorkflow`),
§7.3, §11, §15 (`AskWorkflowAuthoringTests`).

## Intent and context

Workflow authoring becomes a capability of Ask Riela: the model proposes a
complete workflow definition, the server validates it, and it is applied
only when the user confirms. The old generation endpoints and their
in-memory store are removed with no shim.

Current code:

- Old path: `Sources/RielaCLI/WebWorkflowRequestHandler+Generation.swift`
  (handler and `workflowEditorSystemPrompt`, line 96),
  `Sources/RielaAppSupport/WorkflowEditorGeneration.swift`
  (`WorkflowEditorGenerationStore`), `WorkflowEditorAuthoringRounds.swift`,
  `RielaWebWorkflowRuntime.generations`
  (`Sources/RielaCLI/RielaWebWorkflowRuntime.swift:36,67,94`).
- Registry mutations take a resolved bundle URL
  (`Sources/RielaWorkflowRegistry/WorkflowRegistryGraphQLProvider.swift:45,82`);
  the inline `definition` is resolved by `WorkflowRegistryGraphQLDocumentExecutor`
  (`Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift`).
- From earlier plans: `AskToolSet`, `AskToolExecutor`, `AskActionProposer`,
  `AskMutationSurface`, `AskActionService`, `AskPrompt`,
  `AskSendRequest.draftDefinition`, GraphQL DTOs with `target` as `JSON`.

## Non-goals

- No web change (plan 07 removes `WorkflowAgentChat.tsx` and wires the
  editor).
- No change to the other `workflow-editor` routes, to the editor's save
  path, or to the registry mutations and their inputs.
- No patch format; a proposal is always a complete definition.
- No change to the RielaApp native mini chat.

## Changes

### 1. `propose_workflow` (`Sources/RielaCore/Ask`, `Sources/RielaCLI/Ask`)

- `AskActionKind` gains `applyWorkflow`. `AskToolSet.all` gains
  `propose_workflow { definition: object (required), baseWorkflowId: string? }`
  of kind `propose` (add `object` to the descriptor argument types).
  `propose_action` still rejects `applyWorkflow` with `action_kind_unknown`.
- `AskActionProposer.proposeWorkflow(conversationId:turnId:definition:baseWorkflowId:draft:)`:
  1. encoded size above `draftDefinitionBytes` → `workflow_too_large`;
  2. validate with the validator behind `riela workflow validate` and the
     editor's structural checks (the checks the editor save path runs; see
     `Tests/RielaAppSupportTests/WorkflowEditorDefinitionTests.swift` for
     their entry point). Issues → `workflow_invalid` with the issue list
     (path and message, at most 20) as the error data, so the model can fix
     them;
  3. target: when the turn carried a `draftDefinition` → `mode: "draft"`;
     else `mode: "store"`. With `baseWorkflowId`: the workflow must exist
     (`not_found`) and be mutable (`workflow_not_mutable`); store
     `expectedDefinitionRevision` read now. The target is
     `{ mode, definition, workflowId, baseWorkflowId?, expectedDefinitionRevision? }`
     with `workflowId` taken from the definition;
  4. an earlier `proposed` `applyWorkflow` action of the same turn is set to
     `dismissed` (decision `replaced`) in the same transaction; then insert.
- The turn's `draftDefinition` is available to the executor through the
  store: `beginAskTurn` keeps it on the turn record (not in the GraphQL
  `AskTurn` DTO), cleared by `finishAskTurn`.
- Prompt (`AskPrompt`): when the turn has a draft, add a labelled block
  "Editor draft (user input)" with the definition's authoring projection
  (retain handles, never secret values). Move the authoring guidance of
  `workflowEditorSystemPrompt` (definition format, node roles, retain
  handles, no coordinates) into the constant ask system prompt as one
  section, reworded for `propose_workflow`: "call `propose_workflow` with
  the complete definition". Drop the NDJSON round and `continue` rules.

### 2. Apply on confirm (`Sources/RielaCLI/Ask/Actions`)

- `AskMutationSurface` gains
  `applyWorkflow(definition:baseWorkflowId:expectedDefinitionRevision:) async throws -> AskActionResult`.
- `ProviderAskMutationSurface` implements it by executing the existing
  mutation document through an injected closure
  `executeRegistryDocument: @Sendable (GraphQLDocumentRequest) async -> <executor response>`
  that each host binds to the registry document executor it already builds
  (`ServeWebHost.swift`, `ServeHTTPCommand.swift`,
  `ScopedParityCommands+GraphQLDocument.swift`, `RielaLibrary.swift`,
  `Sources/RielaApp/RielaAppWebGraphQL.swift`). Two constant documents:
  `registerMutableWorkflow(input: { definition, overwrite: false })` and
  `updateMutableWorkflow(input: { target, definition, expectedDefinitionRevision })`.
  Variables come only from the stored target. A GraphQL error becomes a
  thrown error with its `extensions.code`.
- `AskActionService.confirm` for `applyWorkflow`: `mode: "draft"` → no
  mutation; result `{ ok: true, summary: "draft", ids: [workflowId] }`.
  `mode: "store"` → re-validate the definition, call `applyWorkflow`; result
  ids hold the workflow id and the new definition revision. A revision
  conflict ends the action as `failed` with the mutation's code.
- Design §7.3 asks for the definition audit reason
  `ask:<conversationId>/<actionId>`. The registry mutation inputs have no
  reason field and this plan must not change them. The link is kept on the
  ask side: the confirmed action row stores the workflow id and the
  resulting definition revision. Record this under `Deviations`.

### 3. Removal

Delete, with their tests, and fix every reference until the build is green:

- `Sources/RielaCLI/WebWorkflowRequestHandler+Generation.swift`
- `Sources/RielaAppSupport/WorkflowEditorGeneration.swift`
- `Sources/RielaAppSupport/WorkflowEditorAuthoringRounds.swift`
- `RielaWebWorkflowRuntime.generations` and its uses (lines 36, 67, 94)
- route table entries and prefix for `/api/v1/workflow-editor/generations`
- catalog rows `generation-start`, `generation-status`, `generation-cancel`
- `Sources/RielaApp/EntryPoint.swift:76` accessor and dependent code
- `Tests/RielaAppSupportTests/WorkflowEditorGenerationTests.swift`,
  `WorkflowEditorLiveAgentTests.swift`; generation cases in
  `Tests/RielaCLITests/ServeWebEditorTests.swift`,
  `RielaAppWebAPIRouteTests.swift` and the parity tests' expected lists.

## Imitate

- `Sources/RielaCLI/Ask/Actions` (plan 02) for proposer validation and the
  confirm flow.
- `Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift` for running
  registry mutations against a temporary registry.

## Pitfalls

- Never save on a draft confirm. The editor saves.
- Never call `registerMutableWorkflow` with `overwrite: true`.
- An immutable workflow cannot be a base, even if the model insists.
- The proposal definition is model output: validate it again at confirm; do
  not trust the validation done at proposal time.
- The draft is user input, not a record: it is not redacted away, but it is
  sent through the authoring projection so retained secret values never
  reach the model.
- After the deletion, `grep` must find no reference to the removed symbols;
  do not leave an empty handler, a route that returns 404 by hand, or a
  commented-out row.
- The web still calls the generation routes until plan 07 lands in the same
  run; that is expected and not a reason to keep them.
- `AskToolServerTests` expects 17 tools; it becomes 18.

## Tests

`Tests/RielaCLITests/Ask/Actions/AskWorkflowAuthoringTests.swift` (temporary
registry and stores, scripted backend where a turn is needed):
- invalid definition → error result `workflow_invalid` with issues; no row.
- valid definition without draft → action `applyWorkflow`, `mode == "store"`.
- two valid proposals in one turn → the first is `dismissed` with decision
  `replaced`, one `proposed` remains.
- turn with `draftDefinition` → `mode == "draft"`; confirm → `confirmed`,
  the registry is unchanged, the spy saw no registry document.
- store confirm without base → the workflow exists in the registry; a second
  proposal with the same id and no base → confirm fails with the mutation's
  conflict code and the registry is unchanged.
- store confirm with a mutable base → updated; the action result holds the
  new revision.
- base changed after the proposal → `failed` with the conflict code.
- immutable base → `workflow_not_mutable`, no row.
- definition above the size limit → `workflow_too_large`.
- the prompt of a draft turn contains the draft block and no secret value
  from a node with a retained secret.

Updated: `AskToolSetTests` (18 names), `AskToolServerTests` (18 tools),
`AskReadOnlyTests` (still no mutation reachable from the executor),
`AskGraphQLTests` if a descriptor changed.

Parity: `SurfaceCatalogTests`, `SurfaceParityWebAPITests`,
`SurfaceParityConsoleReadTests`, `RielaAppWebAPIRouteTests` pass without the
three routes.

## Verification

```
mkdir -p tmp/ask-riela/ask-06-workflow-authoring
scripts/surface-parity/generate-sdl.sh > tmp/ask-riela/ask-06-workflow-authoring/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift build' > tmp/ask-riela/ask-06-workflow-authoring/build.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "AskWorkflowAuthoringTests|AskToolSetTests|AskToolServerTests|AskReadOnlyTests|AskActionTests|AskTurnEngineTests|AskPromptInjectionTests|AskCommandTests|AskGraphQLTests|AskExampleWalkthroughTests|WorkflowEditorDefinitionTests|WorkflowEditorLaunchTests|WorkflowEditorRunEvidenceTests|ServeWebEditorTests|ServeWebHostTests|RielaAppWebAPIRouteTests|SurfaceCatalogTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParityExecutorCoverageTests"' > tmp/ask-riela/ask-06-workflow-authoring/test.log 2>&1
```

All exit 0. Evidence: proposals are validated, applied only on confirm, the
draft path saves nothing, and the old endpoints are gone from code, route
table and catalog.

## Done criteria

- `grep -rn "workflow-editor/generations\|WorkflowEditorGenerationStore\|WorkflowEditorAuthoringRounds\|workflowEditorGenerations\|workflowEditorSystemPrompt\|generation-start" Sources Tests` prints nothing.
- `grep -rn "overwrite: true" Sources/RielaCLI/Ask` prints nothing.
- Verification exits 0; progress log written with the §7.3 deviation.
