# ask-06-workflow-authoring: `propose_workflow`, apply on confirm, removal of the generation routes

```json
{
  "planId": "ask-06-workflow-authoring",
  "planPath": "impl-plans/active/ask-06-workflow-authoring.md",
  "dependsOn": [],
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
    "impl-plans/progress/ask-06-workflow-authoring.md",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryService.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryGraphQLProvider.swift",
    "Tests/RielaCLITests/WorkflowRegistryMutationRevisionTests.swift",
    "Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift",
    "web/e2e/workflow-studio.spec.ts"
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
    },
    {
      "path": "Sources/RielaWorkflowRegistry/WorkflowRegistryService.swift",
      "intendedEdit": "Amendment round 1: add `WorkflowRegistryMutationResult.definitionRevision` (not encoded), set it inside the coordinated register, update and updateBundleDefinition operations, and add the optional `expectedDefinitionRevision` guard to `update`. No other behaviour change."
    },
    {
      "path": "Sources/RielaWorkflowRegistry/WorkflowRegistryGraphQLProvider.swift",
      "intendedEdit": "Amendment round 1: `projectMutation` copies the result revision into the existing `definitionRevision` output field; the plain update path passes `input.expectedDefinitionRevision` to the service. Inputs, retain-handle logic and projections are unchanged."
    },
    {
      "path": "Tests/RielaCLITests/WorkflowRegistryMutationRevisionTests.swift",
      "intendedEdit": "New file: service and provider tests for the returned revision and the plain-path revision guard."
    },
    {
      "path": "Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift",
      "intendedEdit": "Only the assertion at line 49 (`XCTAssertNil(registered.workflow?.definitionRevision)`) changes to expect the 64-character revision equal to the one read afterwards; `definition` stays nil."
    },
    {
      "path": "web/e2e/workflow-studio.spec.ts",
      "intendedEdit": "Remove the mocks of the retired `/api/v1/workflow-editor/generations` routes, their state (`generationRequests`, `generationPolls`) and the test `shows agent changes while still running and restores draft with undo after stop`. No other test changes."
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
  editor), except the stale browser fixture named in the amendment below.
- No change to the other `workflow-editor` routes, to the editor's save
  path, or to the registry mutation inputs. The registry mutation result
  changes only as the amendment below states.
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

## Amendment 2026-11-25 (blocked-wave-scope-or-contract, round 1)

Source: `checkpointAmendment` of wave 1 in session 5 (previous checkpoint
`efb07056`), blocker `ASK-06-REGISTRY-RESULT-REVISION`, evidence
`tmp/ask-riela/ask-06-workflow-authoring/scope-and-checkpoint.log`.
Decision: the two registry paths are authorized, with the additive contract
below. No redesign, no new plan, no plan id or wave change. Where this
section differs from `## Changes` §2, this section wins.

Starting state: the working tree already holds the uncommitted ask-06 work
listed in `impl-plans/progress/ask-06-workflow-authoring.md` (proposals,
draft confirm, removal). Keep it. Do not redo or revert it. Only the items
A1 to A5 remain. Record new edits in the same progress log.

### A1. Registry result revision (`WorkflowRegistryService.swift`)

- `WorkflowRegistryMutationResult` gains `public var definitionRevision: String?`
  and a last init parameter `definitionRevision: String? = nil`. Add an
  explicit `CodingKeys` enum with the five existing keys only, so the field
  is never encoded or decoded. `riela workflow register|update --output json`
  must stay byte-identical (`WorkflowRegistryCLICommand.render` encodes this
  type).
- The value is `WorkflowHistoryCanonicalCoding.sha256` of the bytes of the
  stored `workflow.json`, the same value `definitionSnapshot` returns
  (`WorkflowRegistryService.swift:229-247`).
- Set it in exactly three operations, inside the existing lock closure and
  before the closure returns:
  - `register(input:overwrite:activationState:workingDirectory:)`: after
    `registry.register`, from the private `definitionData(for:)` of the new
    entry, inside `coordinated`.
  - `update(target:input:workingDirectory:)`: inside
    `withCoordinatorWorkflowLocks`, after `registry.update`.
  - `updateBundleDefinition(...)`: the hash of the `replacement` bytes that
    were written and published. `updateDefinition` and
    `updateEditorNodeSettings` get it through this function.
- `update` gains `expectedDefinitionRevision: String? = nil` (before
  `workingDirectory`). When it is set, call
  `requireDefinitionRevision(_:entry:)` inside the workflow locks before
  `registry.update`, as `delete` does (line 168). A mismatch throws the
  existing `REGISTRY_CONFLICT` error and writes nothing.
- `delete`, `setActivation` and `consolidate` keep `definitionRevision == nil`.

Pitfalls: do not call `definitionSnapshot` or `withCoordinatedRead` from
inside `coordinated` to get the revision (nested lock). Do not compute the
revision after the lock closure returns. Do not change
`WorkflowMutableRegistry`, the journal, or any error code.

### A2. Provider output (`WorkflowRegistryGraphQLProvider.swift`)

- `projectMutation`: when `result.definitionRevision` is not nil and the
  projected `workflow` is not nil, set `workflow.definitionRevision` to it.
  No extra read. `definition` stays as it is today (nil for a web principal).
- Plain path of `updateMutableWorkflow` (no `webPrincipalId`, line 120):
  pass `expectedDefinitionRevision: input.expectedDefinitionRevision` to
  `WorkflowRegistryService.update`.
- Nothing else changes: no input field, no SDL change
  (`definitionRevision: String` already exists in
  `Sources/RielaGraphQL/WorkflowRegistryGraphQLSchema.swift:64`), retain
  handles and web checks untouched.

### A3. Ask store confirm (`Sources/RielaCLI/Ask`)

- `AskMutationSurface` gains
  `applyWorkflow(_ target: AskWorkflowActionTarget) async throws -> AskActionResult`.
- `ProviderAskMutationSurface` gains `registry: any GraphQLDocumentExecuting`.
  It is built once in `AskHost.local` (`Surfaces/AskHost+Surfaces.swift:25`,
  the only construction site) as
  `WorkflowRegistryGraphQLDocumentExecutor(localProvider: <authoring provider>)`,
  where the authoring provider is the same instance `AskReadProviders.local`
  already builds (`webPrincipalId: "ask"`, `authoringProjection: true`);
  expose it as a stored property of `AskReadProviders`. This is the
  revision-guarded path: it requires `expectedDefinitionRevision` on update
  and expands retain handles. The per-host closures of `## Changes` §2 are
  not needed; do not edit the host files for this.
- Build the request as a locally trusted request, the way
  `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift` builds its
  `GraphQLDocumentRequest` (`isLocallyTrusted: true`,
  `localWorkingDirectory`). Two constant documents, variables only from the
  stored target:
  - no base: `registerMutableWorkflow` with input `definition` and
    `overwrite: false`;
  - base: `updateMutableWorkflow` with input `target` (`workflowId`,
    `scope: USER`, `originId`), `definition`, `expectedDefinitionRevision`.
  Both select `accepted`, `workflow` (`workflowId`, `definitionRevision`) and
  `errors` (`code`, `message`).
- The target record gains `baseOriginId` (string), stored at proposal from the
  inspected entry's `originId`. `baseWorkflowId`, `baseOriginId` and
  `expectedDefinitionRevision` are all present or all absent; otherwise
  `action_target_invalid`. With a base, `definition.workflowId` must equal
  `baseWorkflowId`; otherwise `workflow_invalid` and no row.
- Result: `ok: true`, `summary` `"Workflow registered"` or
  `"Workflow updated"`, `ids: [workflowId, definitionRevision]`, both taken
  from the mutation payload. A registry error (response `errors` or payload
  `errors`) becomes a thrown `AskError` whose code is the registry code
  (`REGISTRY_CONFLICT`, `DUPLICATE_WORKFLOW`, and so on). An accepted payload
  without `definitionRevision` throws `action_mutation_failed`.
- Never read the workflow again after the mutation to get the revision.
  Remove the "cannot report the applied definition revision" refusal in
  `AskActionService.execute`.

### A4. Retain key shared by host and tool server (`Sources/RielaCLI/Ask/Tools`)

A retain handle is an HMAC with a key that is random per process
(`WorkflowRegistryGraphQLProvider.swift:7`). With the `mcp` transport the
handle is issued in the tool-server process and checked at confirm in the
host process, so the authoring provider must use one key per store.

- `AskReadProviders.local` passes `retainKey:` to the authoring provider. The
  key is 32 random bytes in the file `<session store root>/ask-retain-key`,
  mode 0600, created exclusively on first use; if the file exists, read it;
  a file that is not exactly 32 bytes is an error (`AskError` code
  `retain_key_invalid`), never replaced silently.
- The file is not under `ask-turns`, is never logged, and is never put in
  argv, an environment hand-off or a prompt.
- No registry source change is needed for this (`retainKey:` exists).

### A5. Stale browser fixture (`web/e2e/workflow-studio.spec.ts`)

Remove the two route mocks for `/api/v1/workflow-editor/generations`, the
`generationRequests` and `generationPolls` state, and the test
`shows agent changes while still running and restores draft with undo after stop`
(its UI was removed by plan 07). Change nothing else under `web/`.

### Tests added by this amendment

`Tests/RielaCLITests/WorkflowRegistryMutationRevisionTests.swift` (temporary
registry home; imitate the environment set-up of
`Tests/RielaCLITests/WorkflowMutableRegistryTests.swift`):
- `register` of a valid bundle -> `definitionRevision` is 64 hex characters
  and equals the SHA-256 of the stored `workflow.json`.
- `update` with a changed bundle -> the revision differs from the register
  revision and equals the hash of the stored file.
- `update` with a stale `expectedDefinitionRevision` -> throws
  `REGISTRY_CONFLICT`; the stored file is unchanged.
- `update` with the current `expectedDefinitionRevision` -> accepted.
- JSON encoding of a result with a revision -> no `definitionRevision` key.
- plain provider `updateMutableWorkflow` with a stale
  `expectedDefinitionRevision` -> `REGISTRY_CONFLICT`.
- provider with a web principal: `registerMutableWorkflow` and
  `updateMutableWorkflow` payloads carry `workflow.definitionRevision` equal
  to the revision of a following `workflow(target:)` read, and
  `workflow.definition` is nil.

`Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift:49` and
`Tests/RielaAppSupportTests/WorkflowEditorDefinitionTests.swift:177`: the
two `XCTAssertNil` assertions on a mutation payload's `definitionRevision`
now expect the revision. Do not weaken any other assertion.

`AskWorkflowAuthoringTests` (the store cases listed in `## Tests` become
required and use the real temporary registry, no spy for the registry):
- store confirm without base -> `confirmed`; the workflow is in the registry;
  `result.ids == [workflowId, revision]` and the revision equals the hash of
  the stored file.
- second proposal with the same id and no base -> confirm ends `failed` with
  the registry's duplicate code (assert the exact code the registry returns,
  not a generic one); registry unchanged.
- store confirm with a mutable base -> updated; `result.ids[1]` is the new
  revision and differs from `expectedDefinitionRevision`.
- base changed after the proposal -> `failed` with `REGISTRY_CONFLICT`;
  the stored file still holds the other writer's content.
- base with a protected field: the proposal carries the retain handle from
  `workflow_inspect` -> after confirm the stored value equals the original.
- two `AskReadProviders.local` values for the same store root issue the same
  retain handle for the same field, equal to the handle of a provider built
  with the key file's bytes; the key file has mode 0600 and 32 bytes.
- target with `baseWorkflowId` but no `baseOriginId` -> `action_target_invalid`,
  zero registry calls.
- base whose id differs from `definition.workflowId` -> `workflow_invalid`,
  no row.

### Verification and done criteria added by this amendment

The `## Verification` block below already holds the amended test command
and the two new `grep` checks. In addition:

- Both `grep` checks exit 1 with an empty log.
- `scripts/surface-parity/generate-sdl.sh` leaves
  `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` unchanged.
- A failing test in a file outside `writePaths` is reported as
  `BLOCKED: write scope` with the test name; do not edit that file.
- No `implementation_blocked`; the progress log status is complete and its
  `BLOCKED: write scope` entry is closed with the evidence path.
- `git status --short` shows no path outside `writePaths`.
- The Playwright suite is not run here (no browser in the gate); the
  fixture change is checked by the `grep` and noted in the progress log.

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
arch -arm64 /bin/zsh -lc 'swift test --filter "AskWorkflowAuthoringTests|AskToolSetTests|AskToolServerTests|AskToolExecutorTests|AskReadOnlyTests|AskActionTests|AskTurnEngineTests|AskPromptInjectionTests|AskCommandTests|AskGraphQLTests|AskExampleWalkthroughTests|WorkflowRegistryMutationRevisionTests|WorkflowMutableRegistryTests|WorkflowRegistryEvolutionTests|WorkflowDefinitionGraphQLTests|GraphQLWorkflowRegistryTests|GraphQLWorkflowWebContractTests|RielaAppWebRegistryProviderTests|WorkflowEditorDefinitionTests|WorkflowEditorLaunchTests|WorkflowEditorRunEvidenceTests|ServeWebEditorTests|ServeWebHostTests|RielaAppWebAPIRouteTests|SurfaceCatalogTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParityExecutorCoverageTests"' > tmp/ask-riela/ask-06-workflow-authoring/test.log 2>&1
grep -n "generations\|generationRequests\|generationPolls\|Ask the agent" web/e2e/workflow-studio.spec.ts > tmp/ask-riela/ask-06-workflow-authoring/e2e-fixture.log 2>&1
grep -rn "cannot report the applied definition revision" Sources > tmp/ask-riela/ask-06-workflow-authoring/no-refusal.log 2>&1
```

The two `grep` lines must exit 1 (no match); every other line exits 0.

Evidence: proposals are validated, applied only on confirm, the
draft path saves nothing, and the old endpoints are gone from code, route
table and catalog.

## Done criteria

- `grep -rn "workflow-editor/generations\|WorkflowEditorGenerationStore\|WorkflowEditorAuthoringRounds\|workflowEditorGenerations\|workflowEditorSystemPrompt\|generation-start" Sources Tests` prints nothing.
- `grep -rn "overwrite: true" Sources/RielaCLI/Ask` prints nothing.
- Verification exits 0; progress log written with the §7.3 deviation.
