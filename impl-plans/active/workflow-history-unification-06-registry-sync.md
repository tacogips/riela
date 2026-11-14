# whu-06-registry-sync: mutable-registry changes write definition-store history

```json
{
  "planId": "whu-06-registry-sync",
  "planPath": "impl-plans/active/workflow-history-unification-06-registry-sync.md",
  "dependsOn": [],
  "wave": 3,
  "writePaths": [
    "Sources/RielaWorkflowRegistry",
    "Sources/RielaGraphQL",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+NodeSettings.swift",
    "Tests/RielaCLITests/WorkflowRegistryDefinitionSyncTests.swift",
    "Tests/RielaCLITests/WorkflowMutableRegistryTests.swift",
    "Tests/RielaCLITests/WorkflowMutableRegistryActivationTests.swift",
    "Tests/RielaCLITests/WorkflowRegistryEvolutionTests.swift",
    "Tests/RielaGraphQLTests/GraphQLWorkflowRegistryTests.swift",
    "Sources/RielaCLI/WorkflowRegistryCLICommand.swift",
    "Sources/RielaCLI/WorkflowMutableRegistrationCommand.swift",
    "Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift",
    "impl-plans/progress/whu-06-registry-sync.md"
  ],
  "sharedPaths": [
    "Sources/RielaApp/RielaAppWebAPI.swift",
    "Sources/RielaCLI/ServeWebHost+Configuration.swift",
    "Sources/RielaCLI/ServeWebHost+Instances.swift",
    "Sources/RielaCLI/WebWorkflowRequestHandler+Launch.swift",
    "Sources/RielaCLI/WorkflowCatalogCommands.swift",
    "Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift",
    "Sources/RielaCLI/WorkflowResolution.swift",
    "Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift",
    "Tests/RielaAppSupportTests/WorkflowEditorDefinitionTests.swift",
    "Tests/RielaCLITests/ServeWebEditorTests.swift",
    "Tests/RielaCLITests/ServeWebHostTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionChangeSyncTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift",
    "Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift",
    "Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift",
    "Tests/RielaGraphQLTests/WorkflowHistoryGraphQLContractTests.swift"
  ]
}
```

The four existing test files are writable only to restore isolation if the
new sync breaks them, for example by making HOME / `RIELA_SESSION_STORE`
explicit. Their assertions must not be weakened.

## Intent and context

Design §3.1, §3.3 and §3.4 (Registry). Every mutable-registry change writes
one definition sync, attributed `registryWrite` or `registryDelete`, or the
caller's attribution through the new access overload:

- create, update, overwrite register, consolidate replace;
- delete;
- self-improve, `workflow restore` and rollback when they publish through
  registry access.

Follow the execution protocol in the index plan.

Current code (see design §1):

- `replaceLocked`: `WorkflowMutableRegistry.swift:38-110`. The
  before-snapshot is at `:64` and the publish phases follow.
- Registration: `+Registration.swift:40-80`. The before-snapshot (when
  `hadOriginal`) is at `:62`.
- Delete: `+CRUD.swift:60-110`. The before-snapshot is at `:85`.
- `finish`: `WorkflowMutableRegistry.swift:651-690`. It takes the
  after-snapshot unless deleting (`:653-656`).
- `recoverLocked`: `:408-480`. A present replacement leads to
  `finish`; a backup leads to rollback.
- `captureEvolutionSnapshot`: `+Evolution.swift`. Snapshot ids are
  `registry-before-<tx>` / `registry-after-<tx>`.
- `withWorkflowMutationAccess`: `+Access.swift:88-131`, whose publish
  closure calls `replaceLocked`.
- `WorkflowMutableRegistryTransaction`: `WorkflowMutableRegistryModels.swift:4-22`.
- GraphQL hosts construct `FileWorkflowRegistryGraphQLProvider` at:
  - `RielaApp/RielaAppWebGraphQL.swift:41`;
  - `ServeWebHost.swift:207`;
  - `ScopedParityCommands+GraphQLDocument.swift:30`;
  - `RielaLibrary.swift:121`.

  Each passes its definition provider's `sessionStoreRoot` (RielaApp:
  `daemonSessionStoreRoot(profileName:)`).
- Two web REST handlers also mutate the registry, with
  `context.sessionStoreRoot` available (also used at
  `WebWorkflowRequestHandler+Launch.swift:48`):
  - `WebWorkflowRequestHandler+Definition.swift:46` (`webWorkflowEditableCopy`
    → `registerMutableWorkflow`);
  - `WebWorkflowRequestHandler+NodeSettings.swift:22-34`
    (`WorkflowRegistryService().updateEditorNodeSettings`).
- `WorkflowRegistryMutationResult` (`WorkflowRegistryService.swift:4`) has
  no warnings field today.

## Non-goals

- No coordinator, self-improve or `workflow restore` changes; whu-07 owns
  those.
- No rollback service; whu-08 owns it.
- Registry CLI commands gain no flags.
- Do not change service-run resolution: a deleted workflow keeps its store
  head (QA Q3).

## Pinned API

```swift
// WorkflowMutableRegistry
public init(hooks: WorkflowMutableRegistryHooks = WorkflowMutableRegistryHooks(),
            definitionRecorder: (any WorkflowDefinitionChangeRecording)? = WorkflowDefinitionChangeRecorder(),
            definitionActor: WorkflowDefinitionActor = WorkflowDefinitionActor(kind: .cli, id: NSUserName()),
            surfaceLabel: String = "cli")
// nil recorder is for tests that assert the pre-existing file-only behavior; production never passes nil.
package func withWorkflowMutationAccess<T>(workflowId: String, expectedDigest: String,
    attribution: WorkflowDefinitionChangeAttribution, shouldPublish: (T) -> Bool = { _ in true },
    _ body: (URL, (URL) throws -> Void) throws -> T) throws -> (result: T, definitionSync: WorkflowDefinitionSyncOutcome?)
    // NEW overload; returns the sync outcome of its publication (nil if nothing was published). The existing overload is unchanged and uses default attribution.
// WorkflowRegistryMutationResult (WorkflowRegistryService.swift:4) += warnings: [String]   (default [], omitted from JSON when empty)
//   filled with "definition_overwritten_changes: <auditId>,<auditId>" when the sync outcome is .versionWritten with non-empty overwrittenAuditIds.
// WorkflowRegistryService gains package init(definitionStoreRoot: String?, workingDirectory: String,
//   definitionActor: WorkflowDefinitionActor, surfaceLabel: String)  — builds WorkflowMutableRegistry with WorkflowDefinitionChangeRecorder(sessionStoreRoot:workingDirectory:).
// finish / replaceLocked / registration / delete return the WorkflowDefinitionSyncOutcome? up to the service layer (return values, no global state).
package func recoverWorkflow(workflowId: String) throws   // NEW: takes catalog + workflow locks (same as withWorkflowMutationAccess) and runs recoverLocked only; used by whu-08 claim recovery
// WorkflowMutableRegistryTransaction += definitionChange: WorkflowDefinitionChangeAttribution?   (optional, Codable)
// captureEvolutionSnapshot returns the snapshot id (String) instead of Void.
// FileWorkflowRegistryGraphQLProvider.init(..., definitionStoreRoot: String? = nil): builds the registry with
//   WorkflowDefinitionChangeRecorder(sessionStoreRoot: definitionStoreRoot, workingDirectory: workingDirectory),
//   definitionActor .api (id = webPrincipalId when set), surfaceLabel "graphql".
```

## File-level changes and ordering (under the registry workflow lock)

1. **Replace or overwrite-register with `hadOriginal`.** Run
   `captureBaselineIfAbsent` for the live directory before
   `captureEvolutionSnapshot(before)`. Operation = the attribution's
   operation, otherwise `registryWrite`. If the baseline throws, abort with
   `WorkflowRegistryError(.definitionBaselineFailed)`; no file has moved
   yet.
2. **Persist attribution.** Set `record.definitionChange` = the attribution.
   The default reason is `registry update via <surfaceLabel>` (or `registry
   create via …` when `!hadOriginal`), with `definitionActor`. The record
   is written by the first `publish(record)`.
3. **`finish(record)`.**
   - After the after-snapshot, build the intent with `prepareIntent(
     stagingDirectory: live, liveDirectory: live, transactionId:
     record.transactionId, bundleSnapshotBefore: hadOriginal ?
     "registry-before-<tx>" : nil, bundleSnapshotAfter:
     "registry-after-<tx>", attribution: record.definitionChange ??
     default)`, then call `sync(intent)`.
   - For delete, call `recordDelete` with `bundleSnapshotBefore`.
   - Only then remove backup, staging and record.
4. **Sync failure.**
   - A failure inside `finish` after publication surfaces as
     `WorkflowRegistryError(.definitionSyncFailed, message: "file change
     committed; definition history pending: …")`.
   - The transaction record stays, so the next access's `recoverLocked` →
     `finish` replays the sync idempotently through the whu-05 completion
     predicate.
   - In `replaceLocked`, registration and delete, do not treat this error
     as a publication failure. Do not call `recoverLocked` for it, because
     the files are committed. Rethrow it unchanged.
5. **Rollback claim release in recovery.** In `recoverLocked`, when the
   backup is restored (the change did not commit) and
   `record.definitionChange?.rollbackProposalId` is set, call
   `WorkflowRollbackProposalStore(rootDirectory: recorder.storeRoot(...)).transition(from: [.applying], to: .pending, …)`.
   Ignore `rollbackProposalNotPending`.
6. **Access overload.** The new `withWorkflowMutationAccess(attribution:)`
   passes the attribution into `replaceLocked`. The old signature
   delegates with nil, which means the default attribution.
7. **Host wiring (WHU-R5-02).** `WorkflowRegistryService` and
   `FileWorkflowRegistryGraphQLProvider` pass the recorder settings
   through. All **six** mutating host sites pass the host's store root:
   - the four GraphQL hosts:
     - `RielaApp/RielaAppWebGraphQL.swift:41`, passing
       `daemonSessionStoreRoot(profileName:)`;
     - `ServeWebHost.swift:207`, `ScopedParityCommands+GraphQLDocument.swift:30`
       and `RielaLibrary.swift:121`, each passing the `sessionStoreRoot` it
       gives `WorkflowDefinitionGraphQLProvider`;
   - `WebWorkflowRequestHandler+Definition.swift:46` (`webWorkflowEditableCopy`):
     `FileWorkflowRegistryGraphQLProvider(workingDirectory:, webPrincipalId:
     context.principalId, definitionStoreRoot: context.sessionStoreRoot)`;
   - `WebWorkflowRequestHandler+NodeSettings.swift:22` (node-settings
     save): `WorkflowRegistryService(definitionStoreRoot:
     context.sessionStoreRoot, workingDirectory:
     context.workingDirectory.path, definitionActor: .init(kind: .api, id:
     context.principalId), surfaceLabel: "web")`.

   Read-only handlers (editor definition load, settings load) need no
   change. Do not add routes or change response shapes.
8. **Overwrite warnings (WHU-R5-03, QA Q1 write-and-warn).**
   - `WorkflowRegistryService` maps the returned sync outcome into
     `WorkflowRegistryMutationResult.warnings`.
   - `WorkflowRegistryGraphQLProvider` appends those warnings to the
     **existing** registry mutation payload `diagnostics` field. Do not
     change the SDL.
   - Never refuse or roll back the file change.
   - With no overwritten changes, JSON output is byte-identical to before.

## Pitfalls

- Exactly one sync per change. The baseline is a separate row with
  `baselineTransaction` and never satisfies completion.
- Registry create (`!hadOriginal`) captures no baseline. The sync seeds the
  head with operation `registryWrite` and no parent.
- Delete without a head writes nothing and never captures a baseline.
- `Thread`-local catalog locks are unchanged. The sync runs inside the
  existing lock scope, so no new lock is introduced.
- The recorder must use the registry's environment via
  `CLIRuntimeEnvironment.mergedProcessEnvironment()`. Test layouts that set
  `environment: ["HOME": …]` (`WorkflowMutableRegistryTests.swift:734`)
  therefore stay isolated.

## Tests (`WorkflowRegistryDefinitionSyncTests`; input → expected)

- **Create.** Create W → one version, operation `registryWrite`, parent
  nil, evidence `fileTransaction:<tx>` + `bundleSnapshotAfter`. It is
  visible in `WorkflowDefinitionService.history`.
- **Untracked update.** A pre-existing W with no head, then update →
  baseline B (`import`, `baselineTransaction`), then I (`registryWrite`,
  parent B) with before/after snapshot evidence and a non-empty diff.
- **No-op collapse.** An identical replace ×3 → zero new versions and
  exactly one audit-only `registryWrite` row, carrying the **first**
  replace's `fileTransaction:<tx1>` plus its bundle snapshot refs (Q7
  collapse; whu-05 pre-check uses predicate (a) only).
- **Overwrite warning (WHU-R5-03).** A store-only `update` U, then a
  registry update →
  - the audit has `overwrittenChanges`;
  - `WorkflowRegistryMutationResult.warnings` contains
    `definition_overwritten_changes:` and U's audit id;
  - the GraphQL registry mutation payload `diagnostics` contains the same
    text.

  A registry update with no store-only changes → `warnings` is empty and
  the JSON has no `warnings` key.
- **Host store root (WHU-R5-02).** Each of the following, with the context
  `sessionStoreRoot = <tmp>/host-store` and HOME = `<tmp>/home`, writes a
  `registryWrite` version into `<tmp>/host-store`, with actor kind `api`
  and nothing in `<tmp>/home/.riela/sessions`:
  - the node-settings save handler (`WebWorkflowRequestHandler` with a
    test context);
  - the editable-copy handler (`webWorkflowEditableCopy`).
- **Delete.** With a head → an audit-only `registryDelete` row with
  `bundleSnapshotBefore`, and the head is unchanged. Without a head → zero
  rows.
- **Overwrite.** A store-only `update` then a registry update → the audit
  has `overwrittenChanges`.
- **Sync failure injection** (a recorder stub that throws once) → the call
  throws `definition_sync_failed`, the files are the new content, and the
  transaction record exists. The next `withWorkflowMutationAccess` /
  mutation recovers and writes exactly one `registryWrite` audit for that
  transaction.
- **Attributed publish.** `withWorkflowMutationAccess(attribution:
  selfImprove…)` → a single `selfImprove` version, not `registryWrite`.
- **Claim release.** A rollback attribution where the publish is
  interrupted before commit (hook `afterPhase(.prepared)` throws) →
  recovery restores the backup and the proposal goes from `applying` back
  to `pending`.
- **Recovery entry point.** `recoverWorkflow` with a pending transaction
  record whose sync previously failed → writes the history exactly once
  and removes the record. With no record → no-op.
- **GraphQL.** A GraphQL registry update via
  `FileWorkflowRegistryGraphQLProvider(definitionStoreRoot: tmp)` → a
  version with actor kind `api` in `tmp`.

## Verification (logs under `tmp/workflow-history-unification/whu-06/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-06/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowRegistryDefinitionSyncTests|WorkflowMutableRegistryTests|WorkflowMutableRegistryActivationTests|WorkflowRegistryEvolutionTests|GraphQLWorkflowRegistryTests|RielaAppWebRegistryProviderTests|WorkflowEditorDefinitionTests|WorkflowHistoryGraphQLContractTests"' > tmp/workflow-history-unification/whu-06/tests.log 2>&1; echo exit=$?`
  → `exit=0`.
- `rg -n -e 'NSHomeDirectory' -e 'homeDirectoryForCurrentUser' Tests/RielaCLITests/WorkflowRegistryDefinitionSyncTests.swift`
  → no matches (exit 1). The new tests build HOME and store roots only
  from temp directories.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] Every registry mutation path writes exactly one sync, or audit-only
      or nothing per design §3.3. All tests above pass.
- [ ] Existing registry suites are green without weakened assertions.

## Operator decision (2026-11-02): recorder resolver seam

Use caller injection. Construct `WorkflowDefinitionChangeRecorder` through the accepted whu-05 `fileResolver:` API; RielaCLI hosts pass `FileSystemWorkflowBundleResolver`. Align the pinned whu-06 recorder API to that. whu-06 may edit the whu-05 recorder/resolver files listed in sharedPaths when the seam needs it. Keep editable-copy behavior while recording the API actor, and make a first mutable-registry head carry mutable provenance.

## Operator amendment (2026-11-02, resume #6)

whu-06 now owns `Sources/RielaCLI/WorkflowRegistryCLICommand.swift` and `Sources/RielaCLI/WorkflowMutableRegistrationCommand.swift`, and may edit the registry-mutation call sites, web-host configuration and instance files and registry test suites listed in sharedPaths. Finish caller injection of `FileSystemWorkflowBundleResolver` into the CLI update, delete, consolidate and registration paths; registration, deletion attribution, outcome propagation, warnings; the web-host `sessionStoreRoot` sites; mutable provenance; and `WorkflowRegistryDefinitionSyncTests.swift`. Do not edit whu-07 files (WorkflowSelfImproveVersioning.swift, WorkflowSnapshotService.swift).

## Operator decision (2026-11-02): GraphQL overwrite warnings

Option 2. Add an additive payload-level warnings field to `WorkflowMutationPayload` (e.g. `warnings: [WorkflowRegistryWarning!]!`, empty by default) in `WorkflowRegistryGraphQL.swift` and `WorkflowRegistryGraphQLSchema.swift`, and populate it for register/update/delete/consolidate overwrite warnings. whu-11 regenerates the SDL.

## Operator standing directive (2026-11-02)

When an acceptance criterion needs an API-shape or naming choice that is additive and can be made inside this plan's writePaths/sharedPaths, choose the minimal additive option, record the decision in the progress file, and continue. Block only when the work truly needs a path outside this plan or contradicts the design.

## Operator amendment (2026-11-02, resume #8)

whu-06 owns the whole `Sources/RielaWorkflowRegistry` and `Sources/RielaGraphQL` directories, including `WorkflowRegistryGraphQLValidation.swift` (add `warnings` to the `validateWorkflowRegistryRootFields` WorkflowMutationPayload shape). Finish all remaining whu-06 work in this dispatch.

## Operator amendment (2026-11-02, resume #9): WHU-INT-02 and fresh dispatch

- WHU-INT-02 is now owned by whu-06. In `Sources/RielaGraphQL/GraphQLVariableValidation.swift`, merge the generated root argument types into `graphQLInputSchemaIndex`, so that the 7 whu-03 history operations get variable-type validation. Make the negative test `Tests/RielaGraphQLTests/WorkflowHistoryGraphQLContractTests.swift:70` pass, and verify the integer `limit` argument fix. Add the suite `WorkflowHistoryGraphQLContractTests` to the focused filter. The plan may edit that test file (sharedPaths).
- This is a fresh dispatch. Earlier continuation entries in the progress file do not count toward any continuation limit.

## Operator amendment (2026-11-02, resume #10)

whu-06 owns `Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift`. Store-first service lookup must enforce registry deactivation, so that a registry-seeded definition head never lets a service run resolve a deactivated workflow (`Tests/RielaCLITests/WorkflowMutableRegistryTests.swift:349`). The host and editor test suites are sharedPaths for the missing acceptance coverage.
