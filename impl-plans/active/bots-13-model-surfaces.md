# bots-13-model-surfaces: `riela model`, `riela provider`, GraphQL catalog, live reports, validation warning

```json
{
  "planId": "bots-13-model-surfaces",
  "planPath": "impl-plans/active/bots-13-model-surfaces.md",
  "dependsOn": ["bots-05-model-catalog-core", "bots-12-activity-surfaces"],
  "wave": 5,
  "writePaths": [
    "Sources/RielaCLI/ModelCatalog",
    "Sources/RielaGraphQL/Bots",
    "Sources/RielaCLI/Bots",
    "Tests/RielaCLITests/ModelCatalog",
    "Tests/RielaGraphQLTests/Bots",
    "Sources/RielaCore/BotActivity",
    "Tests/RielaCoreTests/BotActivity",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "impl-plans/progress/bots-13-model-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/BotActivity", "intendedEdit": "SQLiteWorkflowActivityRecorder.swift only: after a configOptions or reportedModel update is recorded, call BotStore.mergeReportedConfig for the instance id equal to the state's backend. No other change in this directory."},
    {"path": "Sources/RielaCLI/Bots", "intendedEdit": "BotsGraphQLProvider.swift (new provider methods) and BotsService.swift create/update validation only (model_unknown warning, providerInstanceId existence)."},
    {"path": "Sources/RielaCLI/RielaClientCommandRouter.swift", "intendedEdit": "Register passthrough routes `model` and `provider`."},
    {"path": "Sources/RielaCLI/RielaCommand.swift", "intendedEdit": "ScopedCommandKind cases `model`, `provider` and their route branches."},
    {"path": "Sources/RielaCLI/ScopedParityCommands.swift", "intendedEdit": "Dispatch cases for `.model` and `.provider`."},
    {"path": "Sources/RielaCLI/CLISurfaceEnumeration.swift", "intendedEdit": "Expansion cases and expandedRoutes entries for `model` and `provider`."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §7.2 (live update), §7.3 (warning), §7.4 (passive probe), §7.5.
Plan 05 built the catalog core. This plan exposes it, runs the passive probe
on request, feeds backend-reported options into the catalog while sessions
run, and makes bot create/update warn on unknown models.

Current code: `BackendCapabilityProbe` (`Sources/RielaAdapters/BackendCapabilityProbe.swift`,
`probe`, `probeAll`), used from `Sources/RielaCLI/HostCapabilityResolver.swift`
(the calling pattern to copy). Surface family pattern: plan 10.

## Non-goals

- No session, MCP server, hook or login flow is ever started by a probe.
- No network model listing; no change to the RielaApp assistant model picker
  (`RielaAppAssistantModelLoader`).
- No web (plan 20). No remote forwarding (plan 19).
- No change to how a node's own model is resolved, other than the sentinel
  already handled in plan 04.

## Changes

### CLI (`Sources/RielaCLI/ModelCatalog/ModelCatalogCommands.swift`, new)

Action enums `ModelClientAction { list }` and
`ProviderClientAction { list, show, refresh, add, update, remove }` in
`RielaClientFamilyArguments.swift`.

| Command | Behaviour |
| --- | --- |
| `riela model list [--provider <instanceId>]` | catalog models per instance: id, sources, options, `observedAt` |
| `riela provider list` | instances with account, availability, authentication, version, probe age |
| `riela provider show <instanceId>` | one instance with its models and last report |
| `riela provider refresh [<instanceId>]` | runs the passive probe for one or all instances, stores it, prints the result |
| `riela provider add --id I --driver D [--label] [--account] [--provider-name] [--provider-proxy] [--api-key-env NAME] [--custom-model ID ...]` | saves a user instance |
| `riela provider update <instanceId> ...` | same options; `--custom-model` replaces the list; `--clear-custom-models` |
| `riela provider remove <instanceId>` | removes a user instance |

Common options: `--session-store`, `--scope`, `--working-dir`,
`--output json|text`. Reads print the last report and never probe.

### Service (`Sources/RielaCLI/ModelCatalog/ModelCatalogService.swift`, new)

- `catalog()`, `instances()`, `instance(id:)` from `BotStore` +
  `ModelCatalog.build`.
- `refresh(instanceId: String?)`: for each selected instance run
  `BackendCapabilityProbe` for its driver with the process environment (plus
  the instance's `apiKeyEnvironment` presence check), then
  `BotStore.recordProbe`. Build the probe the way
  `HostCapabilityResolver.swift` does. Unknown instance →
  `provider_instance_not_found`.
- `save`, `remove` → `BotStore` (plan 05).

### GraphQL (`Sources/RielaGraphQL/Bots/ModelCatalogGraphQL.swift`, new file; same executor)

- `Query.modelCatalog(providerInstanceId: String, remote: String): ModelCatalogPayload!`
- `Query.providers(remote: String): ProviderListPayload!`
- `Query.provider(instanceId: String!, remote: String): ProviderPayload!`
- `Mutation.refreshProviders(input: RefreshProvidersInput!): ProviderListPayload!`
- `Mutation.saveProviderInstance(input: SaveProviderInstanceInput!): ProviderPayload!`
- `Mutation.removeProviderInstance(input: RemoveProviderInstanceInput!): ProviderListPayload!`
- Types: `CatalogModel { id, label, sources, reasoningEfforts, serviceTiers, modes, observedAt }`,
  `ProviderInstance { instanceId, driver, label, account, builtIn, availability, authentication, version, failures, probedAt, models, origin }`.

Extend `BotsGraphQLDocumentExecutor` field sets and `BotsGraphQLProviding`.

### Live reports (`Sources/RielaCore/BotActivity/SQLiteWorkflowActivityRecorder.swift`)

In `record(...)`, for `.configOptions` and `.reportedModel` updates, after
the events are written, call
`BotStore.mergeReportedConfig(instanceId: state.backend ?? skip, ...)` in a
separate write. A failure is ignored (same logging rule as the recorder).

### Bot validation (`Sources/RielaCLI/Bots/BotsService.swift`)

On `create` and `update`: `providerInstanceId`, when set, must exist
(`provider_instance_not_found`). `defaultModel` unknown for the driver →
the bot is saved and the result carries a warning string
`model_unknown: ...` (`BotMutationPayload.warnings: [String!]!`, and one
stderr line on the CLI). Never an error.

### Registries

Catalog rows for `model.list`, `provider.list|show|refresh|add|update|remove`
(same defaults as the bot family; `add` and `update` both bind
`saveProviderInstance`), schema descriptors, SDL, help text.

## Imitate

- Plan 10's files for the family skeleton.
- `Sources/RielaCLI/HostCapabilityResolver.swift` for probe invocation.

## Pitfalls

- `provider refresh` is the only code path that probes. `list`, `show`,
  `model list`, GraphQL queries and catalog builds must not start processes.
- The probe must not start a session: use only what
  `BackendCapabilityProbe.probe` already does (executable lookup, version,
  credential environment).
- `default` appears in every instance's list and must not be flagged unknown.
- `mergeReportedConfig` runs on the activity hot path: one small write, never
  inside the event transaction, never throwing.
- An instance id may contain `/` (driver ids such as `official/openai-sdk`);
  it is an argument value, not a path.

## Tests

`Tests/RielaCLITests/ModelCatalog/ModelCatalogCommandTests`:
- `model list --output json` on an empty store → one built-in instance per
  driver, each with `default` first.
- `provider add --id work-codex --driver codex-agent --custom-model x1` →
  `model list --provider work-codex` contains `x1` with source `custom`.
- `provider add --id codex-agent ...` → `provider_instance_reserved`.
- `provider refresh` with an injected probe (make the probe a parameter of the
  service) → report stored; `provider show` prints availability and probe time.
- `provider list` after refresh does not invoke the probe (injected probe
  counts calls).
- `provider remove work-codex` → gone; removing a built-in →
  `provider_instance_reserved`.
- `bot create --name B --backend codex-agent --model nope` → exit success,
  stderr contains `model_unknown`; `--model default` → no warning.
- `bot create --provider missing` → `provider_instance_not_found`.

`Tests/RielaGraphQLTests/Bots/ModelCatalogGraphQLTests`: each field reaches
the stub provider and encodes the declared shape.

`Tests/RielaCoreTests/BotActivity/ActivityCatalogReportTests`:
- recorder receives `stepStarted(backend: "codex-agent")` then a
  `configOptions` update with a model option → `providerReport("codex-agent")`
  lists that model; a `reportedModel` update sets `currentModel`.

## Verification

```
mkdir -p tmp/bots-overview/bots-13-model-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-13-model-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "ModelCatalogCommandTests|ModelCatalogGraphQLTests|ActivityCatalogReportTests|ActivityRecorderTests|BotCommandTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-13-model-surfaces/test.log 2>&1
```

Both exit 0. Evidence: catalog and provider commands work, reads do not
probe, live reports reach the catalog, parity gates are green.

## Done criteria

- `grep -rn "BackendCapabilityProbe" Sources/RielaCLI/ModelCatalog` shows it only in the refresh path.
- Verification exits 0; progress log written.
