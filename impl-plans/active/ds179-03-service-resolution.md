# DS179-03 Service-Mode Resolution and Run Pins (RielaCLI)

**planId**: `ds179-03-service-resolution`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §1, §3 (`definitionSource.storeRoot`), §4 (store selection, configured launch, events-serve preflight, resolver steps, resume/rerun)
**dependsOn**: `ds179-02-definition-service`
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-03-service-resolution.md`

## Intent and context

Long-running service runs resolve from the SQLite store. The store is
seeded on first use, and later file changes are ignored. Every other run
reads only files. Both kinds of run record `WorkflowSession.definitionSource`.
This plan is the heart of the issue's execution-mode policy.

Repository facts (verified):

- `WorkflowRunCommand.runWithoutSpecialistMonitor`
  (`Sources/RielaCLI/WorkflowRunCommand.swift:46`):
  - `resolveRunBundle` is at `:626`. Its named-workflow branch, at `:641`,
    is `bundle = try resolver.resolve(resolution)`.
  - The temporary JSON, `--from-registry` (`:646/:686`) and task-context
    branches must stay file-based.
  - `storeRootForRun` is at `:474`.
  - The request is built at `:191` (`DeterministicWorkflowRunRequest(`).
- The callee resolver is built from `resolver` at
  `Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift:35`
  (`FileSystemWorkflowCalleeResolver(resolver: resolver, ...)`).
  `Sources/RielaCLI/WorkflowCalleeResolution.swift:32` `resolveCallee`
  builds `ResolvedWorkflowCallee`.
- `WorkflowRunOptions` is at `Sources/RielaCLI/RielaCommand.swift:308`.
- Service callers:
  - `WorkflowExecutionProvider.executeWorkflow` (`Sources/RielaCLI/WorkflowExecutionProvider.swift:27`)
  - `launchConfiguredWorkflow` (`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift:9`:
    file resolve at `:30`, guard at `:31-34`, 422 at `:60`, explicit
    `context.sessionStoreRoot` at `:40`)
  - `CLIEventWorkflowRunner` (`Sources/RielaCLI/EventLiveServe.swift:981`)
  - `CLIWorkflowTriggerDefaultsResolver` (`EventLiveServe.swift:967-977`)
  - `eventRequiredEnvironment` (`Sources/RielaCLI/RuntimeEnvironmentPreparation.swift:42`)
- Resume and rerun resolve at `Sources/RielaCLI/SessionCommands.swift:426`
  (`SessionRerunCommand`) and `:701` (`SessionResumeCommand`).
- The store root rule is `CLIWorkflowSessionStore.resolveRootDirectory`
  (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:57`); also
  `CLIWorkflowSessionResolution.resolutionForPersistence`.
- Service API (plan 02): `WorkflowDefinitionService.lookup`,
  `seedIfAbsent`, `loadPinned`, and
  `WorkflowDefinitionDocument.fileDefinitionSource(for:workflowName:)`.

## Non-goals

- No `riela workflow definition` CLI (plan 04) and no GraphQL (plan 05).
- These paths stay one-time:
  - editor draft launch (`webWorkflowEditorLaunch`)
  - task dispatch, loop, specialist, `PrivateWorkflowWorker`
  - `--workflow-json*` and `--from-registry`

  Do not add service mode to them.
- No changes to the registry, editor or activation file flows.

## Pinned contract

- In `RielaCommand.swift`, add
  `public enum WorkflowExecutionMode: Equatable, Sendable { case oneTime; case service(WorkflowDefinitionActor) }`
  and `WorkflowRunOptions.executionMode: WorkflowExecutionMode`, defaulting
  to `.oneTime` in every init.
- `Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift` (new):
  `enum WorkflowDefinitionStoreSelection`
  - `static func candidateRoots(sessionStore: String?, scope: WorkflowScope, workingDirectory: String, environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()) -> [String]`:
    - An explicit `sessionStore` or `RIELA_SESSION_STORE` gives just that
      root.
    - `.user` gives the user root; `.project` and `.direct` give the project
      root.
    - `.auto` gives `[project, user]`, deduplicated.
    - Roots are computed through `CLIWorkflowSessionStore.resolveRootDirectory`
      so the rules can never drift.
  - `static func seedRoot(sessionStore:, resolution:, fileBundle:, environment:) -> String`
    equals what `storeRootForRun` would choose for that bundle.
- `Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift` (new):
  `public struct DefinitionStoreWorkflowBundleResolver: WorkflowBundleResolving`
  - Fields: `inner: any WorkflowBundleResolving`, `sessionStore: String?`,
    `environment`, `actor: WorkflowDefinitionActor`, and
    `mode: Mode { lookupOrSeed, lookupOnly }`.
  - `public func lookup(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle?`
    — candidate roots in order; the first head wins.
  - `public func seed(fileBundle:, options:) throws -> ResolvedWorkflowBundle`
  - Every bundle returned from a lookup hit or a seed carries
    `definitionSource.storeRoot` = the absolute root of the store that holds
    the head. It comes from plan 02's `resolvedBundle(head:version:storeRoot:)`;
    do not recompute it.
  - `resolve(options)` is `lookup ?? (mode == .lookupOnly ? inner.resolve : seedOrPassThrough(inner.resolve))`.
    `seedOrPassThrough` returns the inner bundle unchanged if it already has
    `definitionSource?.kind == .store`; otherwise it seeds it.
  - On a lookup hit with `options.workflowDefinitionDir != nil`, and when
    the head's source directory is neither equal to nor inside that path,
    append a `.warning` `WorkflowValidationDiagnostic` to
    `bundle.diagnostics`:
    - path: `definitionStore.sourceDirectory`
    - message: `"using stored definition seeded from <dir>; request names <defDir>"`

## File-level changes

1. **`WorkflowRunCommand.swift`.**
   - At the start of `runWithoutSpecialistMonitor`, compute
     `effectiveResolver`. In service mode it is
     `DefinitionStoreWorkflowBundleResolver(inner: resolver, sessionStore: options.sessionStore, actor:, mode: .lookupOrSeed)`;
     otherwise it is `resolver`.
   - Use `effectiveResolver` only in the `:641` branch, and pass it to the
     callee resolver construction. If needed, add a parameter to the
     `+KaibaPreflight` helper.
   - After resolve, set
     `definitionSource = bundle.definitionSource ?? WorkflowDefinitionDocument.fileDefinitionSource(for: bundle, workflowName: options.target)`.
     Pass it into `DeterministicWorkflowRunRequest(definitionSource:)`. Do
     this for temporary, from-registry and task-context bundles too; they
     get file sources.
   - One-time mode must not construct `WorkflowDefinitionStore` or
     `WorkflowDefinitionService` anywhere. Add the comment
     `// one-time runs never open definition tables (issue #179 policy)`.
2. **`WorkflowRunCommand+KaibaPreflight.swift`.** Build the callee resolver
   from the effective resolver.
3. **`WorkflowCalleeResolution.swift` (RielaCLI).** Pass
   `bundle.definitionSource ?? fileDefinitionSource(...)` into
   `ResolvedWorkflowCallee(definitionSource:)`.
4. **`WorkflowExecutionProvider.swift`.** Set
   `options.executionMode = .service(.init(kind: .api, id: nil))`. The
   provider's `sessionStoreRoot` is already passed as `sessionStore`;
   confirm this by reading the file.
5. **`WebWorkflowRequestHandler+ConfiguredLaunch.swift`.** Replace the `:30`
   file resolve:
   - Build the resolver:
     `let storeResolver = DefinitionStoreWorkflowBundleResolver(inner: FileSystemWorkflowBundleResolver(), sessionStore: context.sessionStoreRoot, actor: .init(kind: .api, id: "configured-run"), mode: .lookupOrSeed)`.
   - **`storeResolver.lookup(resolution)` hits:** check only
     `bundle.workflow.workflowId == source.workflowId` (409 `source_changed`
     on mismatch). A source-directory mismatch is the step 2 warning, not
     a 409.
   - **No hit:** do the file resolve plus the existing workflowId and
     directory guard (409 unchanged), then call `storeResolver.seed(fileBundle:)`.
   - Pass the resulting bundle to `EditorPreparedBundleResolver` and set
     `options.executionMode = .service(.init(kind: .api, id: "configured-run"))`.
   - The 422 stays for any thrown resolve or decode error.
6. **`EventLiveServe.swift`.**
   - `CLIEventWorkflowRunner` sets
     `executionMode = .service(.init(kind: .cli, id: "events-serve"))`.
   - `CLIWorkflowTriggerDefaultsResolver` uses
     `DefinitionStoreWorkflowBundleResolver(inner: WorkflowRunCommand().resolver, sessionStore: <the serve session store if available>, actor: ..., mode: .lookupOnly)`.
     Read how the runner gets `sessionStore` and use the same value.
7. **`RuntimeEnvironmentPreparation.swift`.** `eventRequiredEnvironment`
   wraps `FileSystemWorkflowBundleResolver()` in a `.lookupOnly`
   `DefinitionStoreWorkflowBundleResolver` (`parsed.sessionStore`) and
   passes the wrapper as the `resolver:` argument as well.
8. **`SessionCommands.swift`.** In rerun (`:426`) and resume (`:701`): when
   the loaded persisted session's `session.definitionSource?.kind == .store`
   and `versionId != nil`, replace `resolver.resolve(resolution)` with
   `WorkflowDefinitionService(storeRoot: definitionSource.storeRoot ?? <this command's resolved store root>, fileResolver: resolver).loadPinned(versionId:)`.
   `storeRoot` is authoritative: the head can live in a different store
   from the session under `auto` scope (design §3, §4).
   - For callee resolution in those runs, use a `.lookupOrSeed` wrapper with
     actor `.cli` and id `session-resume`.
   - The new session or continued run must carry the same `definitionSource`.
   - File-origin sessions keep today's path exactly.

## Invariants

- `riela workflow run` (oneTime) creates zero rows in `definition_heads`,
  `definition_versions`, `definition_blobs` and `definition_change_audit`.
  The tables may exist and be empty.
- A service run whose head exists reads no workflow, node or prompt file.
  This covers the configured-launch pre-resolve and the events-serve
  preflight.
- A service run's session is persisted in the same DB as the head it used
  (`storeRootForRun` with the stored bundle's `sourceScope`, or the explicit
  session store).
- Instance node patches and runtime variables still apply on top of the
  pinned bundle.

## Pitfalls

- Do not wrap the resolver inside `WorkflowRunCommand.init`. Wrap per run
  and only in service mode.
- `EditorPreparedBundleResolver` (`WebWorkflowLaunch.swift:50`) falls back to
  the file resolver for other names. With the wrapper on top, callees still
  go through the lookup.
- Do not seed from the events-serve preflight or from trigger defaults.
- A broken stored document must fail the run. Never fall back to the file.
- Concurrent cron fires: seeding goes through plan 01's insert-or-read
  commit. Do not add extra locking.
- The session store for events serve may be implicit. Use exactly the root
  the run will persist into.

## Tests

Add `Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift`.
Use a temporary project with a one-agent-node workflow whose
`promptTemplateFile` is `prompts/a.md`, and a mock scenario. Imitate
`Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` for GraphQL
`executeWorkflow` and `EventLiveServeCronTests.swift` /
`EventLiveServeTestSupport.swift` for event and cron runs. The rendered
prompt is the step execution's `inputSnapshot["promptText"]`
(`Sources/RielaCore/WorkflowInvocationSnapshot.swift`).

- **First GraphQL `executeWorkflow` (provider).**
  - 1 head exists.
  - The session's `definitionSource.kind == .store` and its versionId
    equals the head's current version.
  - Its `definitionSource.storeRoot` equals the standardized temporary
    session-store root that holds the head.
  - `promptText` contains the file text.
- **`WorkflowDefinitionService.updatePrompt(...)` to `"STORE"`, then a
  second provider run.** `promptText` contains `STORE`, the pin is the new
  version, and the file was not modified (sha equal).
- **Rewrite `prompts/a.md` to `"FILE2"` and break `workflow.json` (invalid
  JSON), then run the provider.** It succeeds with `STORE` and the pin is
  unchanged.
- **Same broken file, then a configured launch (`launchConfiguredWorkflow`)
  after a lookup hit, with `workflowId` changed in the broken file.** It
  returns 202, the run completes, and the pin is the stored versionId. Use
  the handler test harness that existing configured-launch tests use:
  `grep -rln "launchConfiguredWorkflow\|instances/.*/runs" Tests/RielaCLITests`.
- **An event run via `CLIEventWorkflowRunner` / cron fire with an existing
  head.** It uses the stored prompt and records the pin.
- **Events-serve preflight** (`eventRequiredEnvironment`, trigger defaults)
  with a broken file and an existing head. It succeeds and the row counts
  are unchanged.
- **One-time `WorkflowRunCommand().run` (`riela workflow run`) on the same
  directory, after a fresh copy and with no store.**
  - `promptText` contains the file text, never `STORE`.
  - `definitionSource.kind == .file` and its digest equals
    `fileDefinitionSource(...).digest`.
  - All four `definition_*` tables have `COUNT(*) == 0` in that run's store.
- **One-time run in a store that already has a head with a `STORE` prompt.**
  It still uses the file text, and the counts are unchanged.
- **Two concurrent first service runs** (`async let` provider calls). They
  produce exactly 1 head and 1 seed audit, and both sessions pin the same
  versionId.
- **Resume or rerun of a store-pinned session after another `updatePrompt`.**
  It uses the pinned version, not the head.
- **A cross-workflow call step in a service run.** The child session's
  `definitionSource.kind == .store`.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/03-build.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionServiceResolutionTests 2>&1 | tee tmp/ds179/03-test.log'`.
  Record testsRun and failureCount.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowExecutionProviderTests|EventLiveServeCronTests|EventLiveServeTests|WorkflowDefinitionServiceTests" 2>&1 | tee tmp/ds179/03-regression.log'`.
  Failures in these existing suites that come from the new policy (a test
  that rewrites a workflow between service runs) must be fixed in the test
  by giving it a fresh session store, and recorded. Any other failure is
  reported as a residual risk with the exact test name.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <every changed .swift file>'`
  must print no violations.

## Done criteria

- `grep -n "executionMode" Sources/RielaCLI/WorkflowExecutionProvider.swift Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`
  matches all three files.
- `grep -n "FileSystemWorkflowBundleResolver().resolve(resolution)" Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`
  appears only on the no-head path.
- All verification commands exit 0, and the progress log has
  exitStatus, testsRun, failureCount and log paths.

## Progress log expectations

Log each edit in `impl-plans/progress/ds179-03-service-resolution.md` with
the pre-edit and post-edit sha256. `RielaCommand.swift` is edited again by
plan 04, so re-read it fresh and record its hash. List every existing test
you changed, and why.
