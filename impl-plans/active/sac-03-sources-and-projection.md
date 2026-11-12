# sac-03-sources-and-projection: shared profile source discovery, session-store path, executions projection

- planId: `sac-03-sources-and-projection`
- wave: 1, dependsOn: none
- design: `design-docs/specs/design-serverless-app-control.md` §3.3 (last two paragraphs), §3.7 (executions list and detail)
- writePaths:
  - `Sources/RielaAppSupport/RielaAppProfileWorkflowSources.swift` (new)
  - `Sources/RielaAppSupport/RielaAppInstanceExecutionsProjection.swift` (new)
  - `Sources/RielaAppSupport/RielaWebAPIProjection.swift` (`webExecutions` body only)
  - `Tests/RielaAppSupportTests/RielaAppProfileWorkflowSourcesTests.swift` (new)
  - `impl-plans/progress/sac-03-sources-and-projection.md`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-03/`

## Intent and context

In local mode the CLI must resolve an App instance's workflow directory and
read its executions from the profile session store **without** the App.
Resolution and projection must match the App's exactly. This plan moves three
pieces of App-only logic into nonisolated `RielaAppSupport` functions:

- the App's source discovery: `Sources/RielaApp/EntryPoint.swift:657`
  `daemonWorkflowSources(profileName:state:)`;
- the session-store path: `Sources/RielaApp/EntryPoint+Environment.swift:106`
  `daemonSessionStoreRoot`;
- the executions list projection: `Sources/RielaAppSupport/RielaWebAPIProjection.swift`
  `webExecutions`.

The App call sites are switched over by sac-06; this plan does not edit
`Sources/RielaApp`.

## Non-goals

- Do not edit any file under `Sources/RielaApp/` (sac-06 owns them).
- Do not change the executions JSON shape.
- Do not change `Tests/RielaAppSupportTests/RielaAppInstanceExecutionsProjectionTests.swift`;
  it must stay green, unmodified.

## File-level changes

### `RielaAppProfileWorkflowSources.swift`

**`public enum RielaAppProfileWorkflowSources`**

- `public static func discover(appRootURL: URL, profileName: RielaAppProfileName, state: RielaAppDaemonWorkflowState, projectRoot: URL?) -> [RielaAppDaemonWorkflowCandidate]`
  is the same composition as `EntryPoint.swift:657-675`:
  `RielaAppDaemonWorkflowDiscovery(projectRoot:).discoverUserDaemonWorkflows(appWorkflowRoot: RielaAppProfileStore.workflowRootURL(...), appPackageRoot: RielaAppProfileStore.packageRootURL(...), projectDirectories: state.projectDirectories, additionalWorkflowDirectories: state.workflowDirectories)`.
- `public static func resolveSource(sourceIdentity: String, appRootURL: URL, profileName: RielaAppProfileName, state: RielaAppDaemonWorkflowState) -> RielaAppDaemonWorkflowCandidate?`:
  - if `sourceIdentity` has the prefix `selected-workflow:`, return
    `RielaAppDaemonWorkflowDiscovery(projectRoot: nil).discoverSelectedWorkflowDirectory(<remainder>)`;
  - otherwise return the first candidate from `discover(..., projectRoot: nil)`
    whose `id == sourceIdentity`;
  - nil if none.

**`extension RielaAppProfileStore`**

- `public static func sessionStoreRootURL(homeDirectory: URL, profileName: RielaAppProfileName) -> URL`
  returns `<home>/.riela/profiles/<profile>/sessions` (a directory URL),
  byte-identical to the path `daemonSessionStoreRoot` builds today.

### `RielaAppInstanceExecutionsProjection.swift`

**`public enum RielaAppInstanceExecutionsProjection`** (nonisolated)

- `public static func list(identity: String, workflowDirectory: String, sessionStoreRoot: String, revision: Int?) -> JSONObject`.
  Move the body of `RielaWebAPIProjection.webExecutions` (lines ~117-170)
  **verbatim**: the `loadBounded` call with `maximumSessionCount: 101`, the
  first 100 items, `truncated`, `diagnostics` (first 20 through
  `WorkflowWebProjectionPolicy().persistedSummary`), and the error-branch
  object. Then:
  - `revision` non-nil → emit `"revision"` exactly as today;
  - nil → omit the key.
- `public static func detailStatus(workflowDirectory: String, sessionStoreRoot: String, sessionId: String) -> (sessionId: String, status: String, updatedAt: String)?`.
  Use `WorkflowViewerLoader().loadBounded(WorkflowViewerLoadRequest(workflowDirectory:sessionStoreRoot:selectedSessionId:), maximumSessionCount: 1)`,
  following `Sources/RielaApp/RielaAppInstanceCancelAPI.swift` `storedSessionState`.
  It returns nil when the session is absent. `updatedAt` is ISO-8601, using
  the same formatter as the list.

### `RielaWebAPIProjection.swift`

`webExecutions(identity:)` keeps its instance lookup and the
`instance_not_found` 404. The success and error JSON comes from
`RielaAppInstanceExecutionsProjection.list(identity:workflowDirectory: instance.source.workflowDirectory, sessionStoreRoot: webSessionStoreRootPath, revision: webRevision)`,
wrapped with the existing `webJSON`. No other function in the file changes.

## Pitfalls

- `RielaWebAPIProjection` is `@MainActor`. The new enums must **not** be
  `@MainActor`, because the CLI calls them from async non-main contexts.
- Keep key order and the item construction identical. Existing tests compare
  values.
- Do not introduce `projectRoot` discovery of the App launch option in
  `resolveSource`. The design accepts `invalid_workflow_source` for sources
  only the running App can see.
- `RielaAppProfileName.rawValue` is the path component. Do not lowercase it
  or encode it.

## Tests (`RielaAppProfileWorkflowSourcesTests`, temp root `/tmp/rac-<8hex>`, temp HOME URL passed explicitly)

| Situation | Expected outcome |
| --- | --- |
| A fixture app workflow under `RielaAppProfileStore.workflowRootURL(appRootURL:profileName:storageDirectory:)` with a valid `workflow.json` | `discover` returns a candidate whose id `resolveSource` finds by id |
| `selected-workflow:<dir>` with a valid bundle | resolves to `workflowDirectory == dir` |
| Unknown id | nil |
| `sessionStoreRootURL(homeDirectory: /tmp/rac-x/home, profileName: "p")` | `/tmp/rac-x/home/.riela/profiles/p/sessions` |
| `list(..., revision: nil)` on an empty session store | an object with `items == []`, `truncated == false`, and no `revision` key; with `revision: 3`, `revision == 3` |
| `detailStatus` on an absent session | nil |

For the fixture `workflow.json`, copy the minimal bundle that an existing
RielaAppSupport test uses; grep for `discoverSelectedWorkflowDirectory` in
`Tests/RielaAppSupportTests`.

## Verification (`tmp/serverless-app-control/sac-03/`)

- `mkdir -p tmp/serverless-app-control/sac-03`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-03/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'RielaAppProfileWorkflowSourcesTests|RielaAppInstanceExecutionsProjectionTests|RielaAppWebAPIRouteTests'" > tmp/serverless-app-control/sac-03/test.log 2>&1`
  must exit 0.
- `git diff --exit-code -- Tests/RielaAppSupportTests/RielaAppInstanceExecutionsProjectionTests.swift Sources/RielaApp`
  must exit 0 (both unchanged).
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaAppSupport/RielaAppProfileWorkflowSources.swift Sources/RielaAppSupport/RielaAppInstanceExecutionsProjection.swift Sources/RielaAppSupport/RielaWebAPIProjection.swift Tests/RielaAppSupportTests/RielaAppProfileWorkflowSourcesTests.swift' > tmp/serverless-app-control/sac-03/lint.log 2>&1`

## Done criteria

- The symbols exist as specified.
- The existing executions projection tests pass unmodified.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.
