# DS179-05 GraphQL Definition Surface, Catalog Binding and SDL

**planId**: `ds179-05-graphql-definition-surface`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy + (A) GraphQL whole-workflow update with mandatory reason
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §5, §8 (GraphQL incl. `updateWorkflowDefinition`, catalog and SDL); QA Q3
**dependsOn**: `ds179-04-cli-definition-commands`
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-05-graphql-definition-surface.md`

## Intent and context

This plan gives GraphQL parity for every definition operation. The RielaApp
API uses it for force update and prompt updates. Each GraphQL operation is
a thin wrapper over plan 02's `WorkflowDefinitionService`, using the same
store selection as plan 04.

Repository patterns:

- **Executor.** Imitate `WorkflowExecutionGraphQLDocumentExecutor`
  (`Sources/RielaGraphQL/WorkflowExecutionGraphQL.swift:50-129`):
  - static `queryFields` and `mutationFields`
  - `provider` and `next`
  - input decoded via `JSONDecoder().decode(..., from: JSONEncoder().encode(JSONValue.object(inputObject)))`
  - `projectGraphQLValue`
  - errors with codes
- **Protocol and DTOs.** Imitate `Sources/RielaGraphQL/GraphQLWorkflowExecutionContracts.swift`
  (`WorkflowExecutionGraphQLProviding`) and `Sources/RielaGraphQL/RoutineGraphQL.swift`
  (`GraphQLRoutine` DTOs, `routineGraphQLSchemaTypes`).
- **Schema.** `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`:
  - the root-field map has entries like `"Mutation.createRoutine": .init(name:arguments:type:)`
    at `:627`
  - the type-block list is at `:683`, with names at `:689`

  The committed SDL is `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`.
  Regenerate it with `scripts/surface-parity/generate-sdl.sh`. Never
  hand-edit the SDL.
- **Executor chains.** These files contain chains that must include the new
  executor; follow where `RoutineGraphQLDocumentExecutor` or
  `WorkflowExecutionGraphQLDocumentExecutor` appear:
  - `Sources/RielaCLI/ServeHTTPCommand.swift:175`
  - `Sources/RielaCLI/ServeWebHost.swift:213`
  - `Sources/RielaApp/RielaAppWebGraphQL.swift:38-70`
  - `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift:44`
  - `Sources/RielaCLI/RielaLibrary.swift:136`
- **Coverage gate.** `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift`
  lists the executors' field sets (`add("Query", X.queryFields)`). Add the
  new executor there.

## Non-goals

- No web UI or Studio changes.
- No new GraphQL field for an arbitrary export path; only `writeToSource`.
- No changes to `executeWorkflow`'s input. Service mode was already set by
  plan 03.

## Pinned contract

These go in `Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift` (new).

DTOs: Codable, Equatable, Sendable. The JSON shapes mirror plan 01/02 types
but are defined in RielaGraphQL, which depends only on RielaCore.

- `GraphQLWorkflowDefinitionAuditRecord`, `GraphQLWorkflowDefinitionVersion`
  (adds `documentJSON: String`, the canonical document text) and
  `GraphQLWorkflowDefinitionDiffEntry` (`before` and `after` as JSON
  strings).
- `GraphQLWorkflowDefinitionImportPayload { outcome: String; version; diff; audit }`
- `GraphQLWorkflowDefinitionExportPayload { files: [{path, content}]; wroteToSource: Bool }`
- Inputs:
  - `UpdateWorkflowDefinitionInput { workflowName, patchJSON: String?, authoredFiles: [GraphQLWorkflowDefinitionExportedFile]?, expectedVersionId: String?, reason, evidence: [String]?, actorKind: String?, actorId: String?, storeScope: String? }`
    - Exactly one of `patchJSON` (a JSON Patch array as text, decoded in
      the provider) and `authoredFiles` (`[{path, content}]`) is required;
      otherwise `INVALID_DEFINITION_INPUT`.
    - Reuse the export file DTO `{path, content}` as the input object type.
      If the schema generator needs a distinct input type name, use
      `WorkflowDefinitionFileInput`.
  - `GraphQLWorkflowDefinitionUpdatePayload { outcome: String; versionId: String; digest: String; version: GraphQLWorkflowDefinitionVersion?; audit: GraphQLWorkflowDefinitionAuditRecord?; diff: [GraphQLWorkflowDefinitionDiffEntry] }`
  - `UpdateWorkflowDefinitionPromptInput { workflowName, nodeId, field, text, reason, expectedVersionId: String?, evidence: [String]?, actorKind: String?, actorId: String?, storeScope: String? }`
  - `RestoreWorkflowDefinitionInput { workflowName, versionId, reason, evidence?, actorKind?, actorId?, storeScope? }`
  - `ImportWorkflowDefinitionInput { workflowName, scope: String?, workflowDefinitionDir: String?, force: Bool?, reason: String?, evidence?, actorKind?, actorId?, storeScope? }`
  - `ExportWorkflowDefinitionInput { workflowName, versionId: String?, writeToSource: Bool?, storeScope? }`

`public protocol WorkflowDefinitionGraphQLProviding: Sendable` has one async
throwing method per field:

- Query `workflowDefinitionHistory(workflowName: String!, nodeId: String, limit: Int, storeScope: String): [WorkflowDefinitionAuditRecord!]!`
- Query `workflowDefinition(workflowName: String!, versionId: String, storeScope: String): WorkflowDefinitionVersion`
- Query `workflowDefinitionDiff(workflowName: String!, fromVersionId: String, toVersionId: String, againstFile: Boolean, storeScope: String): [WorkflowDefinitionDiffEntry!]!`
- Mutation `updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput!): WorkflowDefinitionUpdatePayload!`
- Mutation `updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput!): WorkflowDefinitionMutationPayload!`
- Mutation `restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput!): WorkflowDefinitionMutationPayload!`
- Mutation `importWorkflowDefinition(input: ImportWorkflowDefinitionInput!): WorkflowDefinitionImportPayload!`
- Mutation `exportWorkflowDefinition(input: ExportWorkflowDefinitionInput!): WorkflowDefinitionExportPayload!`

`WorkflowDefinitionMutationPayload` is `{ version, audit }`.

`public struct WorkflowDefinitionGraphQLDocumentExecutor: GraphQLDocumentExecuting`
has static field sets, `provider` and `next`, following the pattern above.
The error codes are:

- `INVALID_DEFINITION_INPUT`
- `DEFINITION_REASON_REQUIRED` (maps `missingReason`)
- `DEFINITION_NOT_REGISTERED` (`headMissing`)
- `DEFINITION_STALE` (`staleHead` and the service's `definition_conflict`)
- `DEFINITION_INVALID_PATCH` (`invalid_patch`)
- `DEFINITION_INVALID` (`invalid_definition`)
- `DEFINITION_VERSION_NOT_FOUND`
- `DEFINITION_OPERATION_FAILED`

The service codes `reason_required` and `definition_not_registered` map to
`DEFINITION_REASON_REQUIRED` and `DEFINITION_NOT_REGISTERED`.

## File-level changes

1. **`WorkflowDefinitionGraphQL.swift` (new).** DTOs, the protocol, the
   executor, and `workflowDefinitionGraphQLSchemaTypes` (the SDL type
   blocks).
2. **`GraphQLSchemaGenerator.swift`.** Add the 3 Query and 5 Mutation root
   fields to the root-field map. Add `workflowDefinitionGraphQLSchemaTypes`
   to the type-block list and to the names list (`:683`, `:689`).
3. **`Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift` (new).**
   `struct WorkflowDefinitionGraphQLProvider: WorkflowDefinitionGraphQLProviding`
   with `init(workingDirectory: String, sessionStoreRoot: String?, environment: [String: String])`.
   - **Store root:** if `sessionStoreRoot` is set, use it. Otherwise use
     `storeScope` with plan 04's selection rules (explicit `project` or
     `user`, else auto order).
   - **Actor:**
     - `actorKind` defaults to `api`.
     - `user` is accepted.
     - `cli`, `improvementNode` and any other value are rejected with
       `INVALID_DEFINITION_INPUT` before any store access (design §5).
   - **`updateWorkflowDefinition`:**
     - `patchJSON` decodes into a `JSONValue`; bad JSON →
       `DEFINITION_INVALID_PATCH`. It maps to `service.update(source: .patch)`.
     - `authoredFiles` maps to `.authoredFiles([path: content])`. A
       duplicate path → `INVALID_DEFINITION_INPUT`.
     - `expectedVersionId` is passed through. There is no force form here;
       the force form is `importWorkflowDefinition(force: true)`.
   - **Evidence:** parse with `WorkflowDefinitionEvidenceRef.parse`.
   - **`exportWorkflowDefinition`:** `writeToSource == true` maps to
     `.source(overwrite: true)`; otherwise the target is nil, which returns
     the files without writing them.
   - Use `WorkflowDefinitionStoreSelection.rootWithHead(...)` and
     `seedRoot(...)` from `Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift`.
     Plans 03 and 04 created them. Read the file only; do not duplicate
     the logic.
4. **Executor chains.** Insert `WorkflowDefinitionGraphQLDocumentExecutor(provider:next:)`
   into each chain listed above, with the same `workingDirectory`,
   `sessionStoreRoot` and `environment` values that the
   `WorkflowExecutionProvider` in that chain receives. In RielaApp, pass
   `daemonSessionStoreRoot(profileName:)` so app GraphQL and configured runs
   share one store.
5. **`SurfaceCatalog+Rows.swift`.** In each of the 8 `workflow.definition.*`
   rows from plan 04, remove `graphqlState: .blocked(...)` and add
   `graphql: graphQLQuery("<field>")` (for history, show and diff) or
   `graphql: graphQLMutation("<field>")`. The helpers are at
   `SurfaceCatalog+RowSupport.swift:133-137`. The mapping:
   - history → `workflowDefinitionHistory`
   - show → `workflowDefinition`
   - diff → `workflowDefinitionDiff`
   - update → `updateWorkflowDefinition`
   - update-prompt → `updateWorkflowDefinitionPrompt`
   - restore → `restoreWorkflowDefinition`
   - import → `importWorkflowDefinition`
   - export → `exportWorkflowDefinition`
6. **`SurfaceParityExecutorCoverageTests.swift`.** Add two `add(...)` lines
   for the new executor. Do not touch the known-gap allowlist.
7. **Regenerate the SDL:** `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh'`.
   This rewrites `GraphQLContractProjector+Schema.swift`.

## Invariants

- The SDL is byte-identical to the generator output
  (`SurfaceParityGraphQLTests.testCheckedInSDLIsByteIdenticalToTheGenerator`).
- Every new field has an executor. The coverage gate's gap set does not
  grow.
- GraphQL never writes to a client-supplied path.
- A mutation without a reason (for restore, update-prompt and force import)
  returns `DEFINITION_REASON_REQUIRED` and writes no rows.

## Pitfalls

- RielaGraphQL cannot import RielaWorkflowRegistry or RielaCLI. Keep the
  DTOs self-contained and put the conversion in the RielaCLI provider.
- Executor chain order: the new executor must sit before any fallback that
  answers "not handled" for unknown fields. Put it right after
  `WorkflowExecutionGraphQLDocumentExecutor`, in its `next` slot, and
  re-link the existing `next` behind it.
- `RielaAppWebGraphQL.swift` is in the RielaApp target. Build the app
  target (`swift build` covers it).

## Tests

- Add `Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift`. Execute
  real GraphQL documents through `CompositeGraphQLDocumentExecutor`, with
  the same composition as `ServeHTTPCommand`, and a temporary session store.
  Follow the style of `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift`.
  - `importWorkflowDefinition(force:false)` on an unregistered workflow →
    `seeded`.
  - Run it again → `unchanged`.
  - Edit the file, then import again → `differs` and no row change.
  - `updateWorkflowDefinitionPrompt` without a reason →
    `DEFINITION_REASON_REQUIRED` and no rows.
  - With reason `r` → the audit has `actor.kind == "api"` and `reason == "r"`.
  - `importWorkflowDefinition(force:true, reason:"sync")` →
    `forceUpdated`, with `overwrittenChanges.auditIds` containing the prompt
    update.
  - `restoreWorkflowDefinition` → the new version's document equals the
    restored one.
  - `workflowDefinitionHistory(nodeId:)` filters and is newest first.
  - `workflowDefinitionDiff(fromVersionId:toVersionId:)` lists the prompt
    pointer.
  - `workflowDefinition(versionId:)` returns `documentJSON`.
  - `exportWorkflowDefinition(writeToSource:false)` returns files and writes
    nothing. `writeToSource:true` rewrites the source, and a subsequent
    import → `unchanged`.
  - `actorKind: "addon"` → `INVALID_DEFINITION_INPUT`.
  - `updateWorkflowDefinition` with a `patchJSON` that replaces a prompt
    file and changes a transition, plus `reason: "r"` and `evidence:
    ["session:s1"]` → outcome `updated`, an audit with operation `update`,
    `actor.kind == "api"`, reason `r` and evidence. History shows it. A
    following `executeWorkflow` (service run) uses the new prompt.
  - `updateWorkflowDefinition` with `authoredFiles` (the exported files
    with one prompt edited) → `updated`.
  - Missing reason → `DEFINITION_REASON_REQUIRED`, no rows.
  - Both `patchJSON` and `authoredFiles`, or neither →
    `INVALID_DEFINITION_INPUT`.
  - A stale `expectedVersionId` → `DEFINITION_STALE`.
  - `actorKind: "improvementNode"` → `INVALID_DEFINITION_INPUT`, no rows.
- Add a focused decode or projection test to `Tests/RielaGraphQLTests/`,
  following the `RoutineGraphQLTests.swift` style. Name it
  `WorkflowDefinitionGraphQLContractTests.swift`. It checks that the
  executor routes all 8 fields and rejects malformed input.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/05-build.log'`
- `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh 2>&1 | tee tmp/ds179/05-sdl.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests" 2>&1 | tee tmp/ds179/05-test.log'`.
  Record testsRun and failureCount.
- `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity 2>&1 | tee tmp/ds179/05-parity.log'`
  must pass: the CLI, GraphQL, DTO-schema and executor-coverage gates.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowExecutionGraphQLTests|RoutineGraphQLTests|WorkflowExecutionProviderTests" 2>&1 | tee tmp/ds179/05-regression.log'`
  is a regression check on the re-linked chains.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <every changed .swift file except the generated SDL>'`
  must print no violations.

## Done criteria

- `grep -n "importWorkflowDefinition" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
  matches, and so does `grep -n "updateWorkflowDefinition(" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`.
- `grep -n "graphQLMutation(\"importWorkflowDefinition\")" Sources/RielaCore/SurfaceCatalog+Rows.swift`
  matches.
- `grep -c "WorkflowDefinitionGraphQLDocumentExecutor" Sources/RielaCLI/ServeHTTPCommand.swift Sources/RielaCLI/ServeWebHost.swift Sources/RielaApp/RielaAppWebGraphQL.swift`
  gives at least 1 for each file.
- All verification commands exit 0, and each is logged with exitStatus,
  testsRun, failureCount and the log path.

## Progress log expectations

Log each edit in `impl-plans/progress/ds179-05-graphql-definition-surface.md`
with the pre-edit and post-edit sha256. Record the SDL regeneration command,
its exit code, and the diff stat of
`git diff --stat Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`.


## Operator amendment 1 (after session-494 blocked wave)

- ds179-01-store-core is accepted and committed in 6337aa24. The definition store API now returns
  `WorkflowDefinitionCurrent` (struct with head/version/document) from `current(workflowName:)`, and
  `WorkflowDefinitionDiffEntry.Op` was renamed to `WorkflowDefinitionDiffEntry.Operation`.
- Known pre-existing failures on main f4fcf68c (not caused by this work; exclude them from gates with
  `--skip` and never treat them as blockers): `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`,
  `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`, `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`.
  `DeterministicWorkflowRunnerFanoutTests.testProductionCollectPartialPersistsCancelledChildBeforePublishingJoin` is timing-flaky under
  full-suite load and passes in isolation.
