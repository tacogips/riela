# ask-01-catalog-and-selection: one model list, `automatic` selectable, `AskModelSelection`, `bot create` warning line

```json
{
  "planId": "ask-01-catalog-and-selection",
  "planPath": "impl-plans/active/ask-01-catalog-and-selection.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/ModelCatalog",
    "Sources/RielaAppSupport",
    "Sources/RielaCLI/ModelCatalog",
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/Ask/Selection",
    "Sources/RielaCLI/RielaWebAssistantProvider.swift",
    "Sources/RielaCLI/ServeWebHost+Configuration.swift",
    "Sources/RielaApp/RielaAppConfigurationGraphQLProvider.swift",
    "Sources/RielaGraphQL/ConfigurationGraphQL.swift",
    "Package.swift",
    "scripts/lib/riela-web-packaging.sh",
    "Tests/RielaCoreTests/ModelCatalog",
    "Tests/RielaAppSupportTests/RielaAppAssistantModelCatalogTests.swift",
    "Tests/RielaAppSupportTests/RielaWebAssistantConfigurationTests.swift",
    "Tests/RielaAppSupportTests/DaemonWorkflowNodePatchTests.swift",
    "Tests/RielaCLITests/Bots",
    "Tests/RielaCLITests/ModelCatalog",
    "Tests/RielaCLITests/Ask/Selection",
    "Tests/RielaGraphQLTests/ConfigurationGraphQLTests.swift",
    "impl-plans/progress/ask-01-catalog-and-selection.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Package.swift",
      "intendedEdit": "Remove only the line `resources: [.process(\"Resources\")]` of the RielaAppSupport target (and the comma before it). No dependency or pin change."
    },
    {
      "path": "scripts/lib/riela-web-packaging.sh",
      "intendedEdit": "Read-and-verify only: the resource loop globs `*.bundle` and `*.resources`. Edit only if it fails when no RielaAppSupport bundle exists."
    },
    {
      "path": "Sources/RielaCLI/Bots",
      "intendedEdit": "BotCommands.swift `renderBotMutation`: line end after the row for text output. No other file in this directory changes."
    },
    {
      "path": "Sources/RielaGraphQL/ConfigurationGraphQL.swift",
      "intendedEdit": "Only if the `updateAssistantConfiguration` input validation or description names the selectable vendors; the DTO shape does not change."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2. Design: §1, §9, §13 (last
paragraph), §15 "Catalog follow-ups".

## Intent and context

Ask Riela needs one source for vendor and model. Today there are two bundled
model lists, both stale, and the settings GraphQL refuses `automatic`.

- `Sources/RielaCore/ModelCatalog/ModelManifest.swift`: `ModelManifest.models`
  per `NodeExecutionBackend`. Feeds the Bots catalog
  (`Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift`).
- `Sources/RielaAppSupport/Resources/assistant-models.json`, read by
  `RielaAppAssistantModelCatalog.loadBundledCatalog` (bundle lookup
  `installedCatalogURL`). It is the only file in `Resources/`.
- `RielaAppAssistantModelLoader` lists live models for the selected API
  vendor (`RielaWebConfigurationSupport.assistantConfiguration`, line 93).
- `RielaWebConfigurationSupport.applying(_:to:)` (line 111) rejects
  `automatic`.
- `RielaWebAssistantProvider.backend(for:)` (RielaCLI) maps vendor → backend.
- `renderBotMutation` (`Sources/RielaCLI/Bots/BotCommands.swift:234`) prints
  the row without a line end, so the stderr warning appears glued to it.

## Non-goals

- No change to `RielaAppAssistantSettings` JSON (`vendor`, `modelsByVendor`,
  `assistance`, `isFolded`, `messages`). No migration.
- No change to the native RielaApp settings UI or mini chat behaviour.
  `settingsSelectableVendor`, `selectableVendors` and `defaultSelectableVendor`
  stay for native callers.
- No GraphQL shape change: `GraphQLAssistantConfiguration` and
  `GraphQLConfigurationModelCatalog { vendor, models }` keep their fields. No
  SDL regeneration is expected.
- No web change (plan 07).
- No chat store, tools or service.

## Changes

### 1. `ModelManifest` (`Sources/RielaCore/ModelCatalog/ModelManifest.swift`)

New ids go first, existing ids stay, ids from `assistant-models.json` that
are missing are appended. Resulting order:

| Backend | Ids, in order |
| --- | --- |
| `codexAgent` (reasoning) | `gpt-6.2-sol`, `gpt-6.1-terra`, `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.5`, `gpt-5.4-mini`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.4`, `gpt-5.3-codex-spark` |
| `claudeCodeAgent` | `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-fable-5-2`, `claude-haiku-5-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-fable-5`, `claude-sonnet-4-6`, `claude-haiku-4-5` |
| `cursorCliAgent` | `auto`, `composer-2.5`, `gpt-5.6-sol-medium`, `gpt-5.6-terra-medium`, `gpt-5.6-luna-medium`, `claude-opus-4-8-high`, `claude-sonnet-5-high` |
| `officialOpenAISDK` (reasoning) | `gpt-6.2-sol`, `gpt-6.1-terra`, `gpt-6-astra`, `gpt-5.6`, `gpt-5.4-mini`, `gpt-5.5`, `gpt-5.4` |
| `officialAnthropicSDK` | same list as `claudeCodeAgent` |
| `officialGeminiSDK`, `officialCursorSDK` | unchanged |

### 2. Assistant catalog from the manifest (`Sources/RielaAppSupport`)

- Add `public var executionBackend: NodeExecutionBackend` to
  `RielaAppAssistantVendor` (`RielaAppProfileModels.swift`) with today's map
  of `RielaWebAssistantProvider.backend(for:)` (`automatic` → `codexAgent`).
  `RielaWebAssistantProvider.backend(for:)` returns `vendor.executionBackend`.
- `RielaAppAssistantModelCatalog.shared` is built from `ModelManifest.models`:
  for each vendor in `selectableVendors`, `modelsByVendor[vendor.rawValue]` is
  the manifest ids of `vendor.executionBackend`. Keep `init(modelsByVendor:)`,
  `models(for:)` (both), `defaultModel(for:)`, `uniqueNormalizedModels`.
- Delete `loadBundledCatalog`, `installedCatalogURL`,
  `Resources/assistant-models.json`, the `Resources` directory,
  `RielaAppAssistantModelLoader.swift`, and `supportsLiveModelListing` if
  nothing else uses it (`grep -rn supportsLiveModelListing Sources`).
- `Package.swift`: remove the `resources:` line of the `RielaAppSupport`
  target. After that `Bundle.module` does not exist for this target; make
  sure no file in `Sources/RielaAppSupport` uses it
  (`grep -rn "Bundle.module" Sources/RielaAppSupport` prints nothing).

### 3. Settings GraphQL (`RielaWebConfigurationSupport.swift`)

- New signature:
  `assistantConfiguration(_ settings: RielaAppAssistantSettings, catalogModels: [NodeExecutionBackend: [String]]? = nil) -> GraphQLAssistantConfiguration`
  (no longer `async` unless a caller needs it). For each selectable vendor:
  `catalogModels?[vendor.executionBackend] ?? vendor.modelSuggestions`.
- `vendor` in the result is the stored vendor raw value, including
  `automatic`. With `automatic`, `model` is `""`.
- `applying(_:to:)` accepts `automatic`. A `model` input while the resulting
  vendor is `automatic` → `INVALID_CONFIGURATION`
  ("assistant model needs a concrete vendor"). Unknown vendor strings are
  still rejected.
- Callers pass the Bots catalog lists of the built-in instances:
  `Sources/RielaCLI/ServeWebHost+Configuration.swift:46` and
  `Sources/RielaApp/RielaAppConfigurationGraphQLProvider.swift:233` build
  `[NodeExecutionBackend: [String]]` from `ModelCatalogService.catalog()`
  (built-in instance of each driver; model ids in catalog order: manifest,
  reported, custom). Add one helper for this in
  `Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift`
  (`func builtInModelIds() throws -> [NodeExecutionBackend: [String]]`). A
  catalog read failure falls back to `nil` (manifest only).
  `ModelCatalogService` is internal to RielaCLI and
  `RielaAppConfigurationGraphQLProvider.swift` does not import RielaCLI
  today. Expose one `public` entry point in
  `Sources/RielaCLI/ModelCatalog` (for example
  `public enum AssistantCatalogModels { public static func builtIn(sessionStoreRoot:environment:) -> [NodeExecutionBackend: [String]]? }`)
  and call it from the RielaApp file, adding `import RielaCLI` there if the
  RielaApp target already depends on RielaCLI (it does:
  `Sources/RielaApp/RielaAppWebGraphQL.swift` uses `BotsGraphQLProvider`).

### 4. `AskModelSelection` (`Sources/RielaCLI/Ask/Selection/AskModelSelection.swift`, new)

Plan 02 is not available in this wave, so the request type lives here:
`struct AskModelRequest { vendor: String?, providerInstanceId: String?, model: String?, effort: String? }`
(plan 03 converts `AskSelection` to it).

`static func resolve(settings: RielaAppAssistantSettings, request: AskModelRequest, catalog: [CatalogInstance], environment: [String: String]) throws -> AskResolvedModel`
with `AskResolvedModel` as in the overview §3.2. Rules (design §9):

1. `request.providerInstanceId` set → that catalog instance. Missing →
   `provider_instance_not_found`. Driver `official/gemini-sdk` →
   `ask_provider_unsupported`. A user-declared instance contributes
   `providerName`, `providerProxy`, `apiKeyEnvironment`.
2. Else vendor = `request.vendor` (must parse, else `ask_vendor_unknown`) or
   `settings.vendor`. `automatic` → `RielaWebAssistantProvider.resolve` (its
   error becomes `ask_vendor_unavailable`). Instance = the built-in instance
   whose driver is `vendor.executionBackend`.
3. Model = `request.model`, else `settings.selectedModel(for: vendor)` when
   the instance came from a vendor, else the instance's first model. `""` and
   `default` resolve to `nil` (never sent).
4. A model not in the instance's catalog list → warning string starting
   `model_unknown:` in the same format `BotsService` produces (reuse that
   function; do not write a second message format).
5. `effort`: when the model's catalog `reasoningEfforts` is non-empty and
   does not contain it → `ask_option_unsupported`.
6. Availability: CLI vendors need their executable on `PATH`
   (`vendor.executableName`), API vendors need one of
   `apiKeyEnvironmentNames` (or the instance's `apiKeyEnvironment`) in
   `environment`. Missing → `ask_vendor_unavailable`, message names what is
   missing.

Errors are thrown as a small `AskSelectionError { code, message }` in this
directory (plan 03 maps it to `AskError`).

### 5. `riela bot create` text output (`BotCommands.swift`)

In `renderBotMutation`, text output ends the stdout row with `"\n"`; each
warning stays its own stderr line. JSON output is unchanged. Check the other
callers of `renderBot(... text:)` in this directory: apply the same line end
only where the function returns a single row without one.

## Imitate

- `Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift:catalog()` for
  reading instances with their merged model lists.
- `Sources/RielaCLI/Bots/BotsService.swift` for the `model_unknown` warning.
- `Tests/RielaCLITests/Bots/BotCommandTests.swift` for running a bot command
  against a temporary store and reading `stdout`/`stderr`.

## Pitfalls

- Do not rewrite stored `modelsByVendor`. A stored model that is not in the
  manifest stays selected.
- The default for a vendor with no stored choice is the first manifest id
  (`gpt-6.2-sol`, `claude-sonnet-5-5`). Do not special-case it.
- `RielaAppAssistantModelCatalogTests` has a test that builds a bundle path
  (`riela_RielaAppSupport.bundle`); delete that test with the lookup.
- `automatic` maps to `codexAgent` in `executionBackend` only as a fallback
  value; resolution must go through `RielaWebAssistantProvider.resolve`.
- Do not call `RielaAppAssistantModelLoader` or any network API anywhere.
- Other suites may assert old manifest contents or the old default model:
  run `grep -rn "gpt-5.6-sol\|claude-sonnet-5\"" Tests` and update only
  assertions that are about catalog order or defaults, inside this plan's
  write paths; anything outside is reported as `BLOCKED: write scope`.

## Tests

`Tests/RielaCoreTests/ModelCatalog/ModelManifestTests.swift` (new):
- each of `gpt-6.2-sol`, `gpt-6.1-terra`, `gpt-6-astra` is listed for
  `codexAgent` and `officialOpenAISDK`.
- each of `claude-fable-5-2`, `claude-opus-5-5`, `claude-sonnet-5-5`,
  `claude-haiku-5-5` is listed for `claudeCodeAgent` and
  `officialAnthropicSDK`.
- every id of the old JSON (list them in the test) is still listed for its
  backend; no backend has a duplicate id.
- codex and OpenAI models carry non-empty `reasoningEfforts`.

`RielaAppAssistantModelCatalogTests` (updated):
- `shared.models(for: .codexCLI)` equals the manifest ids of `codexAgent`.
- `defaultModel(for: .claudeCodeCLI) == "claude-sonnet-5-5"`.
- the six selectable vendors each have a non-empty list.

`Tests/RielaAppSupportTests/RielaWebAssistantConfigurationTests.swift` (new;
`ConfigurationGraphQLTests.swift` and `DaemonWorkflowNodePatchTests.swift`
are in scope only to update assertions on model lists or defaults):
- input vendor `automatic` → stored vendor `automatic`; configuration reports
  `vendor == "automatic"`, `model == ""`.
- input vendor `automatic` with `model` → `INVALID_CONFIGURATION`.
- `catalogModels` argument with a custom id → that id is in the vendor's
  catalog; without the argument → manifest ids.

`Tests/RielaCLITests/Ask/Selection/AskModelSelectionTests.swift` (new):
- settings `codex-cli` with stored model, executable present in a temporary
  `PATH` → backend `codexAgent`, that model, no warning.
- settings `automatic`, only `ANTHROPIC_API_KEY` set → `anthropicAPI`.
- settings `automatic`, nothing available → `ask_vendor_unavailable`.
- request `providerInstanceId` of a user-declared instance → its provider
  name, proxy and key environment are returned.
- unknown instance → `provider_instance_not_found`; gemini instance →
  `ask_provider_unsupported`.
- model not in the catalog → resolved with one `model_unknown:` warning.
- model `default` → `model == nil`.
- effort `ultra` on a model with efforts → `ask_option_unsupported`.
- `openai-api` without key → `ask_vendor_unavailable` naming `OPENAI_API_KEY`.

`Tests/RielaCLITests/Bots/BotCommandTests.swift` (new case):
- `bot create` with an unlisted model, text output → `stdout` ends with
  `"\n"` and contains no `model_unknown`; `stderr` is exactly one line
  starting `model_unknown:`.
- JSON output → `stdout` parses as JSON with `warnings` of one entry.

## Verification

```
mkdir -p tmp/ask-riela/ask-01-catalog-and-selection
arch -arm64 /bin/zsh -lc 'swift test --filter "ModelManifestTests|ModelCatalogTests|ProviderStoreTests|RielaAppAssistantModelCatalogTests|RielaWebAssistantConfigurationTests|ConfigurationGraphQLTests|DaemonWorkflowNodePatchTests|AskModelSelectionTests|BotCommandTests|ModelCatalogCommandTests"' > tmp/ask-riela/ask-01-catalog-and-selection/test.log 2>&1
bash -n scripts/lib/riela-web-packaging.sh > tmp/ask-riela/ask-01-catalog-and-selection/packaging-syntax.log 2>&1
```

All exit 0. Evidence: the focused test run compiles `RielaAppSupport`
without a resource bundle (it builds `RielaAppSupportTests` and
`RielaCLITests`); the suites prove the manifest ids, the catalog source, the
`automatic` rule, the selection rules and the warning line. The full
workspace build is the W1 wave gate (overview §4), not part of this plan. A
compile error in a path owned by ask-02 seen during the test build is
handled by overview §2 rule 6.

## Done criteria

- `grep -rn "assistant-models\|RielaAppAssistantModelLoader\|installedCatalogURL" Sources Package.swift Tests` prints nothing.
- `ls Sources/RielaAppSupport/Resources` fails (directory removed).
- `git diff Package.swift` shows only the removed `resources:` line.
- Verification exits 0; progress log written.
