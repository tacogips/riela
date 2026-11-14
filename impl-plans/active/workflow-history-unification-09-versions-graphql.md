# whu-09-versions-graphql: provider implementation of `workflowVersions`, `workflowVersionDiff`, `restoreWorkflowVersion`

```json
{
  "planId": "whu-09-versions-graphql",
  "planPath": "impl-plans/active/workflow-history-unification-09-versions-graphql.md",
  "dependsOn": [
    "whu-07-coordinator-sync"
  ],
  "wave": 4,
  "writePaths": [
    "Sources/RielaCLI/WorkflowDefinitionGraphQLProvider+Versions.swift",
    "Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift",
    "Tests/RielaCLITests/WorkflowVersionsGraphQLTests.swift",
    "impl-plans/progress/whu-09-versions-graphql.md"
  ],
  "sharedPaths": [
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLVariableValidation.swift",
    "Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift",
    "Sources/RielaGraphQL/WorkflowHistoryGraphQLContracts.swift",
    "Tests/RielaGraphQLTests/WorkflowHistoryGraphQLContractTests.swift"
  ]
}
```

## Intent and context

Design §4.3. GraphQL parity for the bundle-snapshot file-restore auxiliary.
`restoreWorkflowVersion` is a dry run unless `apply: true`. An applied
restore records its `snapshotRestore` definition version through whu-07.
Follow the execution protocol in the index plan.

Code:

- `WorkflowDefinitionGraphQLProvider` (`Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift`).
  Its stored properties are `workingDirectory`, `sessionStoreRoot` and
  `environment` (`:7-30`). Its existing methods, such as
  `undoWorkflowDefinition` at `:128`, show how errors become
  `WorkflowDefinitionGraphQLError` and how `actorKind` is validated.
- whu-02 / whu-07: `WorkflowSnapshotService` (`list`, `show`, `diff`,
  `restore` with `recorder:`) and `WorkflowSnapshotTargetRequest`.
- whu-03: the protocol methods, DTOs and `WorkflowHistoryGraphQLErrorCode`
  constants.

## Non-goals

- No rollback provider methods; whu-10 adds them.
- No catalog rows or SDL regeneration; whu-11 does those.
- No behavior change to existing provider methods. The only edit to the
  main provider file is changing stored-property access from `private` to
  internal, so the extension can read them.

## File-level changes

1. **`WorkflowDefinitionGraphQLProvider.swift`.** Change `private let
   workingDirectory / sessionStoreRoot / environment` to `let`. Nothing
   else.
2. **`WorkflowDefinitionGraphQLProvider+Versions.swift` (new).** Implement
   the three protocol methods.
   - **Request.**
     `WorkflowSnapshotTargetRequest(workflowName, scope: WorkflowScope(rawValue: scope ?? "auto"),
     workflowDefinitionDir: nil, workingDirectory: workingDirectory)`. An
     unknown scope → `INVALID_DEFINITION_INPUT`.
   - **Recorder.** `WorkflowDefinitionChangeRecorder(sessionStoreRoot:
     sessionStoreRoot, workingDirectory: workingDirectory, environment:
     environment)`, passed to `restore(recorder:)`.
   - **`workflowVersions`.** Map `list` to `GraphQLWorkflowVersionsPayload`,
     with `limit` defaulting to 100 and validated to 1...1000.
   - **`workflowVersionDiff`.** Map `diff(…, includeContent: includeContent
     ?? false)`.
   - **`restoreWorkflowVersion`.**
     - Actor: `actorKind` must be `user` or `api` (default `api`); anything
       else → `INVALID_DEFINITION_INPUT`. `reason`, if present, must be
       non-empty after trim.
     - Not found: call `show(snapshotId)` first, and on failure throw
       `WORKFLOW_VERSION_NOT_FOUND`.
     - `apply != true` → `restore(approved: false)` → the payload has
       `dryRun: true`.
     - `apply == true`:
       1. Run a dry run first. Non-empty `dirtyConflicts` → throw
          `WORKFLOW_RESTORE_DIRTY_CONFLICTS`, listing the paths in the
          message, and do not apply.
       2. Otherwise `restore(approved: true, reason:, actor:)`. A
          `definitionSyncError` → throw `DEFINITION_SYNC_FAILED` with the
          message "files restored; definition history pending".
          Otherwise map `definitionVersionId`, `definitionAuditId` and
          `definitionWarnings` into the payload.
       3. Map `WorkflowRegistryError.immutableWorkflow` →
          `WORKFLOW_IMMUTABLE` and `.definitionSyncPending` →
          `DEFINITION_SYNC_PENDING`.

## Pitfalls

- A missing or false `apply` must never modify files or rows.
- Do not accept a filesystem path argument. The scope argument only
  selects the registry scope (design §4.3).
- The dirty-conflict pre-check is advisory. The apply path itself still
  refuses conflicts, as the existing service does.

## Tests (`WorkflowVersionsGraphQLTests`; input → expected)

- A project workflow with two snapshots → `workflowVersions` returns both,
  newest first, and the second's `parentSnapshotId` equals the first's
  id.
- `workflowVersionDiff(from: s1, to: "current", includeContent: true)` →
  `content.unified` for a modified prompt. Without `includeContent` →
  `content` is null.
- `restoreWorkflowVersion` without `apply` → `dryRun: true`, files
  unchanged, zero definition rows.
- `apply: true, reason: "r"` → files restored, `definitionVersionId` set,
  and the definition history shows `snapshotRestore` with reason `r`.
- **Overwrite warning (WHU-R5-03).** A store-only `definition update` U,
  then `restoreWorkflowVersion(apply: true)` → the payload's
  `definitionWarnings` contains U's audit id, mapped from
  `WorkflowRestoreCommandResult.definitionWarnings`. Without overwritten
  changes it is null.
- Unknown snapshot → `WORKFLOW_VERSION_NOT_FOUND`.
- An untracked file at a restored path → `WORKFLOW_RESTORE_DIRTY_CONFLICTS`,
  with nothing changed.
- `actorKind: "system"` → `INVALID_DEFINITION_INPUT`.
- Run the documents through `WorkflowDefinitionGraphQLDocumentExecutor`
  with the real provider and temp roots, imitating
  `WorkflowDefinitionGraphQLTests`.

## Verification (logs under `tmp/workflow-history-unification/whu-09/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-09/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowVersionsGraphQLTests|WorkflowDefinitionGraphQLTests|WorkflowHistoryGraphQLContractTests"' > tmp/workflow-history-unification/whu-09/tests.log 2>&1; echo exit=$?`
  → `exit=0`.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] The three operations work end to end through the GraphQL executor.
- [ ] Dry run is the default. All tests above pass.

## Operator standing directive (2026-11-02)

When an acceptance criterion needs an API-shape or naming choice that is additive and can be made inside this plan's writePaths/sharedPaths, choose the minimal additive option, record the decision in the progress file, and continue. Block only when the work truly needs a path outside this plan or contradicts the design.
