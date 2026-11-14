# sdwd-03: Wire the drift check into service resolution, configured launch and session diagnostics

**planId**: sdwd-03-service-resolution-integration
**dependsOn**: sdwd-02-source-drift-service (`WorkflowDefinitionService.syncFromSourceIfUntouched`, `WorkflowDefinitionSourceSyncOutcome`, the `definitionStore.*` diagnostic paths)
**Design Reference**: design-docs/specs/design-workflow-definition-store.md §3, §4 (configured launch, step 2), §4.1 (Where it runs, Configured-launch handoff, File candidate, Repeated checks, Diagnostics), §11, §12 amendment
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/sdwd-03-service-resolution-integration.md
**Evidence root**: tmp/stale-definition/sdwd-03-service-resolution-integration/

## Intent and context

Service-mode runs must pick up file edits on untouched heads (ART outage
fix 1a). They must warn on drift (1b) and on invalid files, and they must
never change or fail a run silently.

Today `DefinitionStoreWorkflowBundleResolver.lookup`
(`Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift:31-46`)
returns the stored head unconditionally. Two callers use `lookup`
directly:

- `WorkflowRunCommand.resolveRunBundle`
  (`Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift:97-99`), which
  is the root of every service run
- the configured-launch route
  (`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift:31-38`)

The configured route hands the run command
`EditorPreparedBundleResolver(bundle:)` (`Sources/RielaCLI/WebWorkflowLaunch.swift:50-56`)
as its resolver. That resolver becomes the store resolver's `inner`, and it
returns a captured stored bundle. The file candidate therefore must never
come from `inner`.

## Non-goals

- No change to `lookupOnly` callers' behavior:
  - `EventLiveServe.swift:1010`
  - `RuntimeEnvironmentPreparation.swift:50`
  - `InstanceReloadSupport.installedTriggerDefaultsFingerprint`
- No change to resume/rerun `loadPinned`, to one-time runs, or to
  `InstanceReloadSupport.importDefinition`.
- No GraphQL or SDL changes and no new event types.
- No doctor changes (sdwd-04).
- No edits to RielaWorkflowRegistry (sdwd-02 owns it).

## File-level changes

### Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift

- Add a stored property
  `let sourceFileResolver: any WorkflowBundleResolving`. The public init
  sets it to `FileSystemWorkflowBundleResolver()`. Add an
  `internal init(... sourceFileResolver:)` overload for tests. Do **not**
  default it to `inner`.
- In `lookup(_:)`, when a head is found in a root:
  - If `mode == .lookupOrSeed`, call
    `makeService(storeRoot: root, projectDirectory: options.workingDirectory).syncFromSourceIfUntouched(workflowName: options.workflowName, workingDirectory: options.workingDirectory, actor: actor, fileResolver: sourceFileResolver)`.
    Use `makeService` so the retention configuration matches seed. It may
    throw a config error; propagate it as today. Use `outcome.bundle` and
    append `outcome.diagnostics` to `bundle.diagnostics`.
  - If `mode == .lookupOnly`, keep today's `service.lookup` path unchanged.
  - Keep `appendSourceDirectoryWarning` after either branch.
- `resolve(_:)` is unchanged. It already calls `lookup` first, so callee
  resolution gets the check automatically.

### Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift

At about line 35, change the route's resolver to `mode: .lookupOnly`.
`seed(fileBundle:options:)` does not check the mode, so first-use seeding
still works. Verify this by reading `seed` before you rely on it. Keep the
409 `source_changed` workflowId and directory guards, the 422 path and the
`EditorPreparedBundleResolver(bundle:)` handoff exactly as they are. The
result is one drift check per launch, done by the run command's lookup.

### Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift

- `PreparedResolvedWorkflowRun` (line 18) gains
  `var definitionStoreWarnings: [String]`.
- In `prepareResolvedRun`, right after `resolveRunBundle`, capture the
  `definitionStore.`-prefixed diagnostics from `bundle.diagnostics`, in
  order. Format each as `"warning: \(path): \(message)"`, which is the
  format of `validateEffectiveSessionPolicies` in
  `WorkflowRunCommand.swift:331`. Return them in the struct.
- A first-use seed (`pendingDefinitionSeed`) has no drift warnings.

### Sources/RielaCLI/WorkflowRunCommand.swift

- **stderr.** Prepend `definitionStoreWarnings` to the stderr output on
  every path where `gatewayValidationWarnings` is printed: success
  rendering (about line 1012) and `renderRunFailure` (about line 803).
  Prefer appending them to the local `gatewayValidationWarnings` array
  right after line 76 (`gatewayValidationWarnings = prepared.gatewayValidationWarnings`).
  That is a one-line change that covers both paths.
- **Persistence.** Add `var definitionStoreWarnings: [String]` to the run
  context struct (about line 934, next to `gatewayValidationWarnings`) and
  populate it where the context is built. After `try afterTerminalPersistence?()`
  and **before** `dispatchLoopNotificationsAfterTerminalPersistence`
  (about line 1000), call the new
  `persistDefinitionStoreWarningsAfterTerminalPersistence`.

### Sources/RielaCLI/WorkflowRunCommand+DefinitionStoreDiagnostics.swift (new)

```swift
extension WorkflowRunCommand {
  func persistDefinitionStoreWarningsAfterTerminalPersistence(warnings: [String], sessionId: String, storeRoot: String)
}
```

- Imitate `dispatchLoopNotificationsAfterTerminalPersistence` in
  `Sources/RielaCLI/WorkflowRunCommand+LoopOperations.swift:61-86`.
- Return early if `warnings` is empty. Otherwise build
  `SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot))`,
  load the snapshot by session id, append each warning that is not
  already present, and save. Best-effort: use `try?`.

### docs/workflow-definition-store.md

- Update the service-mode policy row (line 13), which says later edits are
  "ignored until an explicit import or update".
- Add a "Source drift and auto-sync" section:
  - an untouched head auto-syncs at service run start, with an audited
    `import` and actor id `service-auto-sync`
  - an edited head is kept, with a `definitionStore.sourceDrift` warning
    and the remediation commands
  - an invalid or missing source keeps the head, with a warning
  - warnings appear on stderr and in the session snapshot diagnostics
  - `riela doctor` reports drift (behavior from sdwd-04, per design §8)
  - `riela instance reload` and `import --force` are unchanged
- Keep the wording consistent with design §4.1.

### Tests/RielaCLITests/WorkflowDefinitionSourceDriftResolutionTests.swift (new)

- Build the fixture like `makeFixture()` in
  `WorkflowDefinitionServiceResolutionTests`. Put it under
  `tmp/stale-definition/sdwd-03-service-resolution-integration/fixture-<uuid>`.
  Use `defaults.nodeTimeoutMs: 3300000` and a command node (`/bin/echo`)
  or a mock scenario so the runs complete.
- Imitate `makeProvider` and `testConfiguredLaunchUsesStoredDefinitionAfterSourceBreaks`
  for the two entry paths.
- Load diagnostics from the session store with
  `SQLiteWorkflowRuntimePersistenceStore(rootDirectory:).load(sessionId:).diagnostics`.

Cases:

- **(a) Ordinary service run** (`WorkflowExecutionProvider.executeWorkflow`):
  seed by a first run, edit `workflow.json` to 21600000, run again. Then:
  - The pinned `definitionSource.versionId` is a new `.import` version.
  - Its stored document has `runtime.workflow.defaults.nodeTimeoutMs == 21600000`,
    and `authoredFiles["workflow.json"]` contains `21600000`.
  - There is exactly one `import` audit with actor id `service-auto-sync`.
  - The session snapshot diagnostics contain `definitionStore.autoSynced`.

  A third run with the file unchanged writes zero new versions or audits
  and has no `autoSynced` diagnostic.
- **(b) Configured launch** (`launchConfiguredWorkflow`): the same
  assertions. In addition, after an unchanged second launch there is
  still exactly one `import` audit. Count rows before and after.
- **Both paths, invalid file** (`workflow.json` = `{`): the run succeeds on
  the stored version, writes zero rows, and the session diagnostics
  contain `definitionStore.sourceInvalid`.
- **Both paths, edited head**: `updatePrompt` then a file edit. The run
  pins the `updatePrompt` version, writes zero rows, and the session
  diagnostics contain `definitionStore.sourceDrift`.
- **Configured launch guards**: a stored head whose `workflowId` differs
  from the source still returns 409 `source_changed`. An unregistered
  workflow seeds on first launch (`seed` audit).
- **Prepared-resolver isolation**: construct
  `DefinitionStoreWorkflowBundleResolver(inner: EditorPreparedBundleResolver(bundle: <stale stored bundle>), …, mode: .lookupOrSeed)`
  and call `lookup` after a file edit. Both runtime and authoredFiles carry
  21600000.
- **lookupOnly**: the same resolver with `.lookupOnly` and an edited file
  returns the stored head and writes zero rows.
- **Callee**: imitate `testServiceRunCalleeChildCarriesStorePinAndOneTimeRunStaysFileOnly`
  and `makeCrossWorkflowFixture`. An untouched callee whose file changed
  is pinned in the child session to its new `.import` version.
- **One-time `riela workflow run`** after an edit leaves zero
  `definition_*` rows (re-assert).

### Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift (adjust only if needed)

Run it unchanged first. If a test fails **only** because a valid post-seed
file edit is now auto-synced (an intended behavior change, design §11), do
two things:

- update that expectation to the new semantics
- record, in the progress log, the test name, the old assertion, the new
  assertion and the design reference

Never delete or weaken an assertion for any other reason. Known cases
(`{` invalid workflow.json at lines 87, 235, 263) stay `sourceInvalid` and
must keep passing unchanged.

## Pitfalls

- Using `inner` or `WorkflowDefinitionService(fileResolver: inner)` for the
  file side reintroduces review finding D1. Pass `sourceFileResolver`
  explicitly.
- Running the check in the configured route **and** in the run would give
  two checks per launch, and diagnostics would land outside the session.
  The route must be `.lookupOnly`.
- Do not throw from `lookup` for file problems. sdwd-02 returns them as
  diagnostics.
- Persist warnings after terminal persistence. Saving the snapshot before
  the run's own save would be overwritten.

## Invariants

- `lookupOnly` reads and writes exactly as before.
- Pinned resume/rerun is unchanged.
- The import paths for `riela instance reload` and `riela workflow definition import`
  are untouched.

## Acceptance criteria

- [x] All listed cases exist and pass.
- [x] `WorkflowDefinitionServiceResolutionTests` passes, and any
      expectation changes are logged with justification.
- [x] `grep -n "lookupOrSeed" Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`
      returns nothing.
- [x] The docs section exists.

## Verification (arm64; logs plus `.exit` files under the evidence root)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/stale-definition/sdwd-03-service-resolution-integration/build.log 2>&1; echo $? > tmp/stale-definition/sdwd-03-service-resolution-integration/build.exit'`
   → 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionSourceDriftResolutionTests|WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionSourceDriftTests|InstanceReloadSupportTests|EventLiveServe" > tmp/stale-definition/sdwd-03-service-resolution-integration/test.log 2>&1; echo $? > tmp/stale-definition/sdwd-03-service-resolution-integration/test.exit'`
   → 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/WorkflowRunCommand+DefinitionStoreDiagnostics.swift Tests/RielaCLITests/WorkflowDefinitionSourceDriftResolutionTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift > tmp/stale-definition/sdwd-03-service-resolution-integration/lint.log 2>&1; echo $? > tmp/stale-definition/sdwd-03-service-resolution-integration/lint.exit'`
   → 0.

## Concurrency and drift protocol

Wave 2 runs alongside sdwd-04 (DoctorCommand) and sdwd-05 (adapters).
Their files are disjoint from yours. Re-read each file before editing it
and record pre/post sha256. If WorkflowRunCommand.swift shows edits that
are not yours, stop and record the drift. A build break in a sibling's file
gets logged and re-run, never fixed by you.

## Progress log expectations

`impl-plans/progress/sdwd-03-service-resolution-integration.md` holds the
commands, exit codes, log paths, hashes, any test-expectation changes with
justification, and the checked acceptance list.
