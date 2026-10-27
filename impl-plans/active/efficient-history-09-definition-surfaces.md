# eh-09-definition-surfaces: `workflow definition undo|redo`, retention flags, GraphQL, catalog rows, SDL, two-store conformance

```json
{
  "planId": "eh-09-definition-surfaces",
  "planPath": "impl-plans/active/efficient-history-09-definition-surfaces.md",
  "dependsOn": ["eh-03-memory-history", "eh-04-definition-history"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/WorkflowDefinitionArguments.swift",
    "Sources/RielaCLI/WorkflowDefinitionCommand.swift",
    "Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift",
    "Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift",
    "Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift",
    "Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift",
    "Tests/RielaCLITests/WorkflowImprovementNodeTests.swift",
    "Tests/RielaGraphQLTests/WorkflowDefinitionGraphQLContractTests.swift",
    "Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift",
    "impl-plans/progress/eh-09-definition-surfaces.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §4 ("Read errors", "Undo and redo"), §9 and QA Q2. This plan exposes
the following through the existing `riela workflow definition` family and
GraphQL, at the place where restore is exposed today:

- undo/redo;
- `--history-retention`;
- the `retained` audit flag;
- `definition_version_not_retained`.

It also adds the acceptance-required **two-store conformance suite**: the
same assertions run against the memory store and the definition store.

Pinned eh-04 APIs:

- `WorkflowDefinitionService` gains `undo`/`redo` (restore-like parameters
  plus `expectedRevision`/`expectedVersionId`) and `historyRetention:` on
  import/update/updatePrompt/restore.
- Its init gains `defaultHistoryRetention:`.
- The audit record gains `retained`.
- The error code is `definition_version_not_retained`.

Pinned eh-03 APIs: the memory `undoRecord`/`redoRecord`/`recordDiff` and
`historyRetention:`.

Current code:

- **Parser.** `WorkflowDefinitionArguments.swift`; the per-operation flags
  are at `:128-139`.
- **Command.** `WorkflowDefinitionCommand.swift`. Errors are
  `{accepted:false, error:{code,message}}`. The text diff prints `op path`
  (`:313-315`).
- **GraphQL.**
  - The protocol and SDL types are in
    `Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift:191-199,336-404`.
    `RestoreWorkflowDefinitionInput` is at `:397`.
  - The provider is `Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift`
    (restore at `:94-108`).
  - The descriptors are in `GraphQLSchemaGenerator.swift:620-632`.
  - The committed SDL is `GraphQLContractProjector+Schema.swift`.
- **Catalog.** Rows `workflow.definition.*` are in
  `Sources/RielaCore/SurfaceCatalog+Rows.swift:173-212`.
- **SDL regeneration.** `scripts/surface-parity/generate-sdl.sh`.

## Non-goals

- The legacy registry snapshot commands (`workflow versions`, `version`,
  `restore`) are unchanged (QA Q2).
- No top-level `riela workflow undo` alias.
- No `SurfaceCatalog+RowsCLI.swift` and no `RielaCLIApplication.swift`
  edits; eh-11 owns those.

## Contract

**CLI:**

```
riela workflow definition undo <workflow> --reason <r> [--expected-revision <n> | --expected-version <id>] [--evidence <kind:id>]... [--actor <id>] [--session-store <dir> | --scope project|user] [--output text|json]
riela workflow definition redo <workflow> (same flags)
riela workflow definition import|update|update-prompt|restore ... [--history-retention <0...10000>]
```

- undo/redo JSON is `{version, audit}`, the same as restore.
- A missing reason → `reason_required`.
- The engine codes pass through: `nothing_to_undo`, `nothing_to_redo`,
  `stale_revision` (map to the existing `definition_conflict` when the CAS
  came from `--expected-version`), and `definition_version_not_retained`.
- The text diff prints `op path` followed by one `before:` line and one
  `after:` line of JSON.

**GraphQL:**

- New mutations:
  - `undoWorkflowDefinition(input: UndoWorkflowDefinitionInput!): WorkflowDefinitionRestoreResult!`
  - `redoWorkflowDefinition(input: RedoWorkflowDefinitionInput!)`
- Inputs: `{workflowName!, storeScope, reason!, expectedRevision: Int,
  expectedVersionId: String, evidence, actorKind, actorId}`.
- `historyRetention: Int` is added to the update, update-prompt, restore and
  import inputs.
- The audit type gains `retained: Boolean!`.

**Catalog:** `workflow.definition.undo` and `workflow.definition.redo` rows
(kind `.mutation`, `cli` + `graphql`), imitating the
`workflow.definition.restore` row at `SurfaceCatalog+Rows.swift:199`. Add
`--history-retention` to the cliOptions of the four write rows. Because this
plan owns `SurfaceCatalog+Rows.swift`, it also appends
`--abandoned-after-hours` to the `session.reconcile` row's `cliOptions`
(`:253-257`). eh-07 adds that flag in the same wave; this is a catalog-only
edit.

**Config:** `WorkflowDefinitionHistoryConfiguration.resolve(homeDirectory:,
projectDirectory:, environment:) -> Int` reads `workflowDefinitions.historyRetention`
from the project `.riela/config.json` (wins), then the user one, with
default 10.

- Values outside 0...10000 → a config error, which is a usage error on the
  CLI and a GraphQL error.
- Unknown keys inside `workflowDefinitions` → an error.
- Pass it as `defaultHistoryRetention:` wherever a `WorkflowDefinitionService`
  that may WRITE is constructed in RielaCLI:
  - `WorkflowDefinitionCommand.swift:104`;
  - `WorkflowDefinitionGraphQLProvider.swift:125,154`;
  - `DefinitionStoreWorkflowBundleResolver.swift:40,59`;
  - `ProductionNodeAdapter+WorkflowImprovementAddon.swift:81,134` (the
    self-improve apply path writes `update`, so it must honor the config).
  - Read-only lookups need no change and are not owned here:
    `WorkflowDefinitionStoreSelection.swift:21` (`lookup`) and
    `SessionCommands.swift:23` (`loadPinned`). Leave them on the init default.
  - Re-grep `WorkflowDefinitionService(` before finishing; any other writing
    hit outside `writePaths` is logged as outOfScope, never edited.

## Tests

- **`WorkflowDefinitionCommandTests`:**
  - import plus 3 updates → `undo --reason r` gives the previous version;
    `redo` gives it back;
  - undo past the oldest → `nothing_to_undo`, exit non-zero;
  - `--history-retention 2` then 3 updates → `show --version <dropped>`
    gives `definition_version_not_retained`;
  - `history` JSON has `retained`;
  - the text diff has `before:`/`after:` lines.
- **`WorkflowDefinitionGraphQLTests`:** the undo/redo mutations round-trip,
  and a missing reason is an error.
- **`WorkflowDefinitionGraphQLContractTests`:** the SDL contains both
  mutations and `retained`.
- **`VersionedHistoryConformanceTests`** (RielaCoreTests), parameterized
  over the memory store (temp memory root) and the definition store (temp
  session store):
  - the same diff output key set and the same entries for equivalent JSON
    changes;
  - undo/redo;
  - a write after undo drops the redo branch;
  - an R=3 window after 6 writes keeps 3 versions;
  - orphan rows are removed: the engine row count equals the retained
    count.
- **`WorkflowImprovementNodeTests`:** adjust only if eh-04's retention
  changed its setup. Add one case: a project `.riela/config.json` with
  `{"workflowDefinitions": {"historyRetention": 2}}`; prepopulate 4 versions
  through `WorkflowDefinitionService(..., now:)` with a clock 30 days in the
  past, +25 h per commit; then one self-improve apply at the real clock →
  the two oldest non-last-file versions are dropped (proves the adapter
  passes the resolved default).
- **Clock rule (all window tests in this plan, including the CLI
  `--history-retention 2` case and the conformance suite's definition
  side).** eh-04's 24-hour former-head pin keeps every recent head, so
  prepopulate history through the eh-04 `now:` seam with commits in the past
  spaced 25 h apart, and assert retained sets, not bare counts.
- **Config resolver** (in `WorkflowDefinitionCommandTests`): project value
  wins over user value; `10001` and an unknown key inside
  `workflowDefinitions` → usage error; no config → 10.

## Verification

```
arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh' > tmp/efficient-history/eh-09-definition-surfaces/sdl.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests|VersionedHistoryConformanceTests|WorkflowImprovementNodeTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests"' > tmp/efficient-history/eh-09-definition-surfaces/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files except the generated SDL file>'
```

Expected: exit 0, and the SDL diff contains only the new types and fields.

**Expected interim CLI-gate failure (EH5-F1).** The new
`workflow.definition.undo` / `workflow.definition.redo` catalog rows have a
`cli` value, but `CLISurfaceEnumerator` learns the `undo`/`redo` commands
only in wave 5, when eh-11 adds them to `WorkflowDefinitionClientSubcommand`
(`Sources/RielaCLI/RielaClientFamilyArguments.swift:71`). So between wave 3
and wave 5, `SurfaceParityCLITests` reports "declared but not actual" for
`workflow definition undo` and `workflow definition redo`. That suite is
deliberately NOT in this plan's filter. If you run it anyway, log the
failure as `outOfScope: SurfaceParityCLITests workflow definition undo/redo
(eh-11 owns the enumerator)`. Do not edit `CLISurfaceEnumeration.swift`,
`RielaClientFamilyArguments.swift` or `SurfaceParityCLITests.swift`, and do
not remove the `cli` value from the rows to make the suite pass.

## Done criteria

- [ ] The undo/redo CLI and GraphQL work. The SDL is regenerated and
      committed in the working tree.
- [ ] The conformance suite runs against both stores.
- [ ] The listed suites pass. The progress log is complete.
