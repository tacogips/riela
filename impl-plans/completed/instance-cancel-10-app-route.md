# instance-cancel-10: App cancel routes, ports implementation and route-table entries

**planId**: instance-cancel-10-app-route
**dependsOn**: instance-cancel-07-app-child-channel (`RielaAppDaemonWorkflowRuntime.sessionControl`), instance-cancel-08-app-launch-registry (`RielaWebWorkflowRuntime.cancelLaunch` / `liveLaunchInventory`), instance-cancel-09-cancel-coordinator
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C4, C4b, §4
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-10-app-route.md
**Evidence root**: tmp/instance-cancel/instance-cancel-10-app-route/

## Intent and context

Expose two desktop-only routes and wire the real ports:

- `POST /api/v1/instances/{identity}/executions/{sessionId}/cancel`
- `POST /api/v1/instances/{identity}/cancel`

Imitate `Sources/RielaApp/RielaAppInstanceReloadAPI.swift`, which shows the
whole pattern: path split, method guard, `x-riela-profile` check,
strict decode, `distributedControllerOperations.run`,
`terminationShutdownStarted` → busy, the error envelope, and a `@MainActor`
ports struct.

## Non-goals

- No change to the `/reload`, `/runs` or projection handlers, or to existing
  route entries.
- No serve-host (`riela serve`) route.
- No GraphQL.

## File-level changes

- `Sources/RielaApp/RielaAppInstanceCancelAPI.swift` (new):
  - `func webInstanceCancelResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse?`.
    It matches 7 parts with `parts[4] == "executions" && parts[6] == "cancel"`
    (explicit session, using `removingPercentEncoding`), or 5 parts with
    `parts[4] == "cancel"` (no session). Any other shape returns nil.
    - A non-POST method → 405 `method_not_allowed` (same body as reload).
    - Header profile mismatch → `configuration_conflict`.
    - Decode failure → `invalid_cancel_request`.
    - Run inside `distributedControllerOperations.run`; termination shutdown
      → `instance_busy`.
    - Call the coordinator `cancel` or `cancelSole`.
    - Success → 202 with the encoded response.
    - Errors use the envelope `{"error":{"code","message"}}` (message through
      `WorkflowWebProjectionPolicy().safeSummary`). For
      `ambiguous_running_sessions`, add the top-level `sessionIds` and
      `pendingRunCount`.
    - Telemetry: one log `riela.instance.cancel` with
      `instance.identity`, `session.id` (when known), `owner` and
      `outcome` or `error_code`. Use the App's existing telemetry recorder if
      one is reachable from `RielaApp`; otherwise skip it and note that in the
      progress log. **Never** include the reason.
  - `@MainActor struct RielaAppCancelPorts: RielaAppInstanceCancelPorts`:
    - `profile` → `daemonProfileName.rawValue`.
    - `instanceExists` → `app.daemonInstances` contains the identity.
    - `cancelAppLaunch` / `appInventory` → the App's
      `RielaWebWorkflowRuntime` (find the instance that serves `/runs` in
      `Sources/RielaApp/RielaAppConfiguredRunAPI.swift` and use the same
      one), keyed by the **same identity string** that
      `launchConfiguredWorkflow` receives there.
    - `childRunning` / `childSessionControl` →
      `app.daemonRuntime.isChildRunning` / `sessionControl`, using
      `app.profileRuntimeIdentity(profileName:localIdentity:)` exactly as in
      `RielaAppReloadPorts.runtimeIdentity`.
    - `storedSessionState` → the same lookup as `webExecutionDetail`
      (`WorkflowViewerLoader().loadBounded` with `selectedSessionId`, the
      instance's workflow directory and `webSessionStoreRootPath`). No
      session → `.absent`; `completed|failed|cancelled` → `.terminal`;
      otherwise `.nonTerminal`.
- `Sources/RielaApp/RielaAppWebAPI.swift`: insert
  `if let response = await webInstanceCancelResponse(for: request) { return response }`
  after the reload line (line 11), so it runs **before** the shared
  projection, which would otherwise answer 404.
- `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` (`desktopOnly`,
  after the `/runs` entry): append two entries with owner
  `"Sources/RielaApp/RielaAppInstanceCancelAPI.swift"`:
  - method POST, path
    `/api/v1/instances/{identity}/executions/{sessionId}/cancel`, ownerMarker
    `#"parts[6] == "cancel""#`;
  - method POST, path `/api/v1/instances/{identity}/cancel`, ownerMarker
    `#"parts[4] == "cancel""#`.

  Both marker strings must appear verbatim in the owner file. Surface-parity
  tests may check this.

Pitfalls:
- The 5-part `/cancel` path must not collide with
  `/reload`, `/runs`, `/actions` or `/environment`; match the literal
  "cancel".
- Percent-decode both the identity and the sessionId.
- Do not encode the reason anywhere in a response.

## Tests: Tests/RielaAppSupportTests/RielaAppInstanceCancelRouteTests.swift (new)

Imitate `Tests/RielaAppSupportTests/RielaAppInstanceReloadRouteTests.swift`.
- `RielaWebAPIRouteTable.desktopOnly` contains both paths with method POST.
- Neither path is in `sharedProjection` or `instanceWrites`.
- The existing reload and runs entries are unchanged (compare their count and
  paths).

The RielaApp target has no XCTest target, so the handler is verified by
compiling it and by plans 09 and 11. Record this in the progress log.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0. This compiles RielaApp.
- `swift test --filter "RielaAppInstanceCancelRouteTests|SurfaceParityWebAPITests|SurfaceParity"`
  → exit 0, 0 failures.
- `swiftlint lint` on the changed and new files → no new violations.

## Done criteria

- Build and tests pass.
- The diff is limited to 1 new App file, a 1-line edit in
  `RielaAppWebAPI.swift`, 2 appended route entries and 1 new test.
- The progress log has exit codes and log paths.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift. `RielaWebAPIRouteTable.swift` may be touched by branch
fix/manual-overlap-terminal-reserve; append only.

## Amendment 2026-11-11 (integration-paths-outside-writePaths, round 1)

Source: integration review comm-000054 (IR-SCOPE-10-WEB-CATALOG), routed by
dispatch-plans comm-000056 (`amendment_required`). This is a bounded scope
amendment only; there is no design change.

- **Catalog file.** `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift` is
  added to writePaths. Add two catalog rows, one per new route:
  - `webRoute("POST", "/api/v1/instances/{identity}/executions/{sessionId}/cancel")`
  - `webRoute("POST", "/api/v1/instances/{identity}/cancel")`

  Copy the family and kind from the existing `/runs` row (around line 162).
  Do not change existing rows, and do not add a row for the baseline
  `/reload` route.
- **Verification change.** `RielaAppInstanceReloadRouteTests` is removed from
  the filter. It writes random `tmp/reload-*` directories, and its purpose
  (reload and runs entries stay unchanged) is covered by
  `RielaAppInstanceCancelRouteTests`. The new filter is
  `RielaAppInstanceCancelRouteTests|SurfaceParityWebAPITests|SurfaceParity`.
- **Allowed web parity failures.** Only the two baseline assertions listed in
  plan 05's amendment may remain, and no cancel route may appear in any
  violation.
- **Shared build output.** The worktree `.build` written by `swift build` and
  `swift test` from the worktree root is authorized shared build output. It is
  untracked and does not count as a write-scope violation. A private
  `--scratch-path` may be used in addition to the plan commands, never instead
  of them.
- **Dispatch manifest.** `impl-plans/active/instance-cancel-dispatch.json` is
  regenerated by the dispatch flow. Workers never edit it.

## Implementation progress 2026-11-11

The cancel handler, real ports, desktop route entries, catalog rows and route-table test are implemented. The arm64 build and strict selected-file lint passed. The focused route test passed; the aggregate has exactly the two preimplementation baseline web parity assertions, with comparison evidence under the plan evidence root. Formal review and serial reconcile remain downstream.
