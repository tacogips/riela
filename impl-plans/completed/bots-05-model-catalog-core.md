# bots-05-model-catalog-core: provider instances, model manifest, catalog merge

```json
{
  "planId": "bots-05-model-catalog-core",
  "planPath": "impl-plans/active/bots-05-model-catalog-core.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/ModelCatalog",
    "Tests/RielaCoreTests/ModelCatalog",
    "Sources/RielaCore/WorkflowBackendPolicy.swift",
    "impl-plans/progress/bots-05-model-catalog-core.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/WorkflowBackendPolicy.swift", "intendedEdit": "ONE edit in WorkflowBackendPolicyValidation.diagnostics (line 64-65): the 'is not known for this backend' diagnostic becomes severity warning with message 'model_unknown: is not known for this backend'."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §7.1–§7.4 (data and merge only). A runtime-owned catalog of provider
instances and models: bundled manifest + what backends reported + custom
models. Unknown models warn, never fail.

Current code: `BackendCapability` (`Sources/RielaCore/BackendCapability.swift`)
is the neutral probe observation; the probe itself is in RielaAdapters and is
called by plan 13, not here. `WorkflowBackendPolicyValidation.diagnostics`
(`Sources/RielaCore/WorkflowBackendPolicy.swift:27-70`) has the only
unknown-model check; no caller passes `knownModels` today and no test asserts
its message.

## Non-goals

- No probing, no CLI, no GraphQL, no web (plan 13).
- No network model listing.
- No `Package.swift` resource; the manifest is Swift source.

## Changes (new files in `Sources/RielaCore/ModelCatalog/`)

### `ModelManifest.swift`

- `public struct CatalogModelOptions: Codable, Equatable, Sendable { reasoningEfforts: [String]; serviceTiers: [String]; modes: [String] }`
  (each array may be empty).
- `public struct ManifestModel: Codable, Equatable, Sendable { id, label: String?, options: CatalogModelOptions }`
- `public enum ModelManifest { public static let models: [NodeExecutionBackend: [ManifestModel]] }`
  with a short list per driver. Take model ids from names already present in
  this repository (search `Sources/RielaAppSupport` for `modelSuggestions`
  and the examples' node payloads). Do not invent ids that appear nowhere in
  the tree. Reasoning efforts come from `NodeReasoningEffort.allCases`.

### `ProviderInstance.swift`

- `public struct ProviderInstance: Codable, Equatable, Sendable`:
  `instanceId` (`^[a-z0-9][a-z0-9/_-]{0,63}$`), `driver: NodeExecutionBackend`,
  `label: String?`, `account: String?`, `providerName: String?`,
  `providerProxy: String?`, `apiKeyEnvironment: String?`,
  `customModels: [ManifestModel]`, `builtIn: Bool`.
- `static func builtIn(_ driver: NodeExecutionBackend) -> ProviderInstance`
  (`instanceId == driver.rawValue`).
- `validate()`: a user instance id must not equal any driver raw value
  (`provider_instance_reserved`); `apiKeyEnvironment` must look like an
  environment variable name (`^[A-Z_][A-Z0-9_]*$`), never a secret value
  (`provider_instance_invalid`).
- `public struct ProviderReport: Codable, Equatable, Sendable`:
  `instanceId`, `observedAt: Date`, `reportedModels: [ManifestModel]`,
  `currentModel: String?`, `availability`, `authentication`, `version`,
  `failures: [String]` (the four probe fields mirror `BackendCapability`;
  they are nil until a probe ran), `probedAt: Date?`.

### `ProviderStore.swift`

`extension BotStore`:
- `providerInstances() throws -> [ProviderInstance]`: every driver's built-in
  instance first (in `NodeExecutionBackend.allCases` order), then user rows by id.
- `providerInstance(id:)`, `saveProviderInstance(_:)` (validates; built-in
  ids are rejected), `removeProviderInstance(id:)` (`provider_instance_not_found`;
  built-in → `provider_instance_reserved`; also deletes its report).
- `providerReport(instanceId:)`, `providerReports()`.
- `mergeReportedConfig(instanceId:configOptions:reportedModel:at:)`: upsert
  the report from ACP data. From `configOptions` entries (JSON objects with
  `id`, `category`, `currentValue`, `values`): category `model` values become
  reported model ids; `mode` → `modes`; `thought_level` → `reasoningEfforts`;
  `model_config` values whose option id contains `tier` → `serviceTiers`.
  `reportedModel` adds that id if missing and sets `currentModel`. Probe
  fields are preserved.
- `recordProbe(instanceId:capability: BackendCapability, at:)`: stores
  availability, authentication, version, failures, `probedAt`; reported
  models are preserved.

### `ModelCatalog.swift` (pure)

- `public struct CatalogModel: Codable, Equatable, Sendable { id, label, options, sources: [String], observedAt: Date? }`
  (`sources` ⊆ `manifest`, `reported`, `custom`, sorted).
- `public struct CatalogInstance { instance: ProviderInstance; report: ProviderReport?; models: [CatalogModel] }`
- `public enum ModelCatalog`
  - `static func build(instances: [ProviderInstance], reports: [String: ProviderReport]) -> [CatalogInstance]`
  - `static func isKnown(model: String?, driver: NodeExecutionBackend, catalog: [CatalogInstance]) -> Bool`
  - `static func diagnostics(nodeModels: [(path: String, driver: NodeExecutionBackend, model: String?)], catalog: [CatalogInstance]) -> [WorkflowValidationDiagnostic]`

Merge rules:
- Every instance starts with the entry `default` (`sources: ["manifest"]`,
  empty options) as its first model.
- Then manifest models for the instance's driver, then reported, then custom.
  Same id → one entry; `sources` is the union; options: reported values
  replace manifest values per option list when the reported list is not
  empty; custom values fill lists that are still empty.
- An option list no source provides stays empty (skipped, not an error).
- `isKnown`: nil, empty or `default` → true; otherwise true when any instance
  of that driver lists the id.
- `diagnostics`: one `warning` per unknown model with message
  `model_unknown: '<model>' is not in the catalog for <driver>`; never an error.

### `WorkflowBackendPolicy.swift`

The single edit in the sharedPathNotes. Use the `WorkflowValidationSeverity`
warning case (read `Sources/RielaCore/WorkflowValidation.swift`).

## Imitate

- `Sources/RielaCore/RoutineStore.swift` for JSON rows.
- `Sources/RielaCore/BackendCapability.swift:merge` for combining declared and
  observed data.

## Pitfalls

- `default` is a catalog entry on every instance but is never a real model id;
  do not let a custom model named `default` replace it (reject it in
  `validate()` with `provider_instance_invalid`).
- `mergeReportedConfig` must tolerate missing keys and unknown categories
  (ignore them).
- Catalog reads must not write and must not probe.
- Do not store secrets; `apiKeyEnvironment` is a variable name only.

## Tests (`Tests/RielaCoreTests/ModelCatalog/`)

`ModelCatalogTests`:
- no rows → one built-in instance per driver, each starting with `default`.
- reported model equal to a manifest id with reasoning efforts → one entry,
  sources `manifest, reported`, reported efforts win.
- custom model on a user instance → appears only on that instance.
- provider reports no service tiers → `serviceTiers` empty.
- `isKnown("default")`, `isKnown(nil)` → true; unknown id → false.
- diagnostics for an unknown model → one warning containing `model_unknown`.

`ProviderStoreTests` (temporary session store root):
- save a user instance, list → built-ins then the user instance.
- save with a driver raw value as id → `provider_instance_reserved`.
- `apiKeyEnvironment: "sk-abc"` → `provider_instance_invalid`.
- `mergeReportedConfig` with model and mode options → report lists them;
  a later `recordProbe` keeps the models and adds probe fields.
- remove → instance and report gone.

`WorkflowBackendPolicyWarningTests`:
- `knownModels` without the model → exactly one diagnostic, severity warning,
  message contains `model_unknown`.

## Verification

```
mkdir -p tmp/bots-overview/bots-05-model-catalog-core
arch -arm64 /bin/zsh -lc 'swift test --filter "ModelCatalogTests|ProviderStoreTests|WorkflowBackendPolicyWarningTests|WorkflowBackendPolicyTests"' > tmp/bots-overview/bots-05-model-catalog-core/test.log 2>&1
```

Exit 0; new suites pass; any existing `WorkflowBackendPolicyTests` still pass.

## Done criteria

- `grep -rn "URLSession\|Process()" Sources/RielaCore/ModelCatalog` prints nothing.
- Verification exits 0; progress log written.
