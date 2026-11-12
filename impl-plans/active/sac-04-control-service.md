# sac-04-control-service: RielaAppInstanceControlService (shared by HTTP handlers and the channel)

- planId: `sac-04-control-service`
- wave: 2, dependsOn: `sac-01-control-contract`
- design: `design-docs/specs/design-serverless-app-control.md` §3.3, §3.7 (optional `revision`), §3.10
- writePaths:
  - `Sources/RielaAppSupport/RielaAppInstanceControlService.swift` (new)
  - `Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift` (`revision` optional and the `liveRevision()` port only)
  - `Sources/RielaAppSupport/RielaAppInstanceReloadCoordinator.swift` (use `liveRevision()` in `response(...)` only)
  - `Tests/RielaAppSupportTests/RielaAppInstanceControlServiceTests.swift` (new)
  - `impl-plans/progress/sac-04-control-service.md`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-04/`

## Intent and context

Today the HTTP handlers in `Sources/RielaApp` hold the request decode, the
profile-header check, `distributedControllerOperations.run`, the shutdown
checks and the error rendering. The handlers in scope are:

- `RielaAppInstanceReloadAPI.swift` `webInstanceReloadResponse` / `reloadErrorResponse`;
- `RielaAppInstanceCancelAPI.swift` `webInstanceCancelResponse` / `cancelErrorResponse`;
- `RielaAppInstanceAPI.swift` (the environment GET, the `.reloadEnvironment`
  branch of `performWebInstanceAction`, `environmentResponse`, `instanceAPIError`);
- `RielaAppConfiguredRunAPI.swift` `webConfiguredRunResponse`.

This plan moves that host-side logic into one `RielaAppSupport` service. Its
results (`status` + JSON `body`) must be **byte-for-byte** what those handlers
return today. sac-06 then turns the HTTP handlers into thin adapters, and the
socket channel (sac-05/sac-06) calls the same service.

Read all four App files first. They are the behavioural spec for this plan.

## Non-goals

- Do not edit `Sources/RielaApp` (sac-06).
- Do not change the coordinators' algorithms, apart from the one
  `liveRevision()` line.
- No socket code.

## File-level changes

### `RielaAppInstanceReloadContract.swift`

- `RielaAppInstanceReloadResponse.revision` changes from `Int` to `Int?`.
  - The initializer parameter becomes `revision: Int?`; existing call sites
    passing `Int` still compile.
  - Encoding must omit the key when nil. Synthesized `Codable` does this; if the
    type has a custom `encode`, use `encodeIfPresent`.
  - The HTTP and channel output, where revision is always non-nil, is
    unchanged.
- Add the protocol requirement `func liveRevision() async -> Int?` to
  `RielaAppInstanceReloadPorts`, with a default implementation in a protocol
  extension returning `await revision()`. The App's `RielaAppReloadPorts`
  needs no change.

### `RielaAppInstanceReloadCoordinator.swift`

In the private `response(...)`, pass `revision: ports.liveRevision()` instead
of `ports.revision()`. No other change.

### `RielaAppInstanceControlService.swift`

```swift
public struct RielaAppInstanceControlService: Sendable {
  public init(ports: any RielaAppInstanceControlPorts)
  /// profile == nil means "no header was supplied" (HTTP /actions has no header check today).
  public func handle(_ operation: RielaAppControlOperation, profile: String?) async -> RielaAppControlResult
}
```

Per-operation behaviour. Each row copies the App handler that exists today.

**`.bootstrap`**

- 200, body `{"profile":…,"revision":…}` from `ports.bootstrap()`.
- No CSRF token; this is channel-only. The HTTP bootstrap route is not
  touched.

**`.reload(identity, body)`**

1. If `profile != nil && profile != ports.profile()`: reload error rendering
   of `.init(code: .configurationConflict)`.
2. `RielaAppInstanceReloadRequest.decodeStrict(body)`, and body >
   `RielaAppControlLimits.reloadBodyMaxBytes` → `.invalidReloadRequest`
   rendering.
3. `ports.serialized { … }`:
   - `ports.isShuttingDown()` → `.instanceBusy` rendering;
   - otherwise `RielaAppInstanceReloadCoordinator(ports: ports.reloadPorts()).reload(...)`;
   - success → 200 with the `JSONEncoder` encoding of the response decoded to
     `JSONValue`; an encode failure → `.configurationIOFailure, committed: true`.
4. Move `reloadErrorResponse` verbatim as a private `renderReloadError` that
   returns `RielaAppControlResult`: the `error.code/message` with
   `WorkflowWebProjectionPolicy().safeSummary`, `committed`, and optional
   `partial`/`running`/`queued`. The status is `error.code.httpStatus`.

**`.cancel(identity, sessionId, body)`**

- Same structure, from `webInstanceCancelResponse`.
- Profile mismatch → `.configurationConflict`; decode failure →
  `.invalidCancelRequest`; shutting down → `.instanceBusy`.
- `sessionId != nil` → `coordinator.cancel`; nil → `cancelSole`.
- Success is **202**. An encode failure → `.cancelUnavailable`.
- Move `cancelErrorResponse` verbatim (`sessionIds`, `pendingRunCount`).
- Not serialized differently from today: wrap it in `ports.serialized`
  exactly as today.

**`.environmentStatus(identity)`**

- If `profile != ports.profile()` (nil counts as a mismatch, like today's
  `request.headers[...] ==` check) or `!ports.instanceExists(identity:)` →
  409 `profile_or_instance_conflict`, message
  `Select the current profile and instance.`
- Otherwise 200 with the encoded `RuntimeEnvironmentStatus`.
- Not serialized, matching today.
- Move `environmentResponse` verbatim: an encode failure → 500
  `environment_status_unavailable` "Environment status unavailable."

**`.environmentReload(identity, body)`**

1. Profile check only when `profile != nil`: a mismatch → 409
   `configuration_conflict` "Configuration changed. Refresh before
   continuing."
2. Decode `WorkflowInstanceActionInput` from `body`. A decode failure or an
   action other than `.reloadEnvironment` → 400 `invalid_request` "Provide a
   valid configuration request, profile and revision."
3. `ports.serialized`:
   - shutting down → 409 `instance_busy` "The app is shutting down.";
   - `ports.validateRevision(...)` returns a conflict → `status/code/message`
     from the conflict;
   - `!instanceExists` → 404 `instance_not_found` "Execution configuration
     was not found.";
   - then `ports.reloadEnvironment(identity)`:

| Outcome | Result |
| --- | --- |
| `.notReady` | 422 `instance_not_ready` "Configuration is not ready." |
| `.reloaded(s)` | 200 with the encoded status |
| `.failed(s)` | 422 with the encoded status |

**`.run(identity, body)`**

- Reproduce the guard in `webConfiguredRunResponse`:
  - body ≤ `runBodyMaxBytes`;
  - `profile == ports.profile()` (nil is a mismatch);
  - the body decodes as `JSONObject`;
  - the keys are a superset of `{expectedProfile, expectedRevision, variables}`
    and a subset that additionally allows `allowOverlap`;
  - `allowOverlap` is absent or a bool;
  - the body decodes into `RielaAppConfiguredRunInput`.

  Any failure → 400 `{"error":{"code":"invalid_configured_run"}}` (no
  message).
- Then `ports.serialized { await ports.launchConfiguredRun(identity:input:) }`.
  The port owns the revision checks, readiness, environment prepare, overlap
  and launch, and returns the full result.

**`.launchStatus(launchId)`**

`ports.launchStatus(launchId:profile:)` with `profile ?? ""`, passed through
unchanged.

## Pitfalls

- **Byte compatibility.** Keep exact message strings, key names and statuses.
  Copy them from the App files; do not paraphrase.
- Bootstrap through the service is channel-only. Do not reroute the HTTP
  bootstrap route.
- `profile == nil` semantics differ per operation (listed above). Do not
  normalize them.
- `serialized` takes an `@escaping @Sendable` closure. Capture only `Sendable`
  values (`Data`, `String`, decoded structs).
- Do not import `RielaGraphQL` into `RielaAppSupport`. The revision conflict
  arrives already mapped as `RielaAppControlConflict`.

## Tests (`RielaAppInstanceControlServiceTests`, fake `RielaAppInstanceControlPorts` actor with scripted reload/cancel fake ports)

For the reload and cancel fakes, imitate
`Tests/RielaAppSupportTests/RielaAppInstanceReloadCoordinatorTests.swift` and
`RielaAppInstanceCancelCoordinatorTests.swift`.

**Reload**

| Situation | Expected outcome |
| --- | --- |
| Success | 200; body keys equal the old `RielaAppInstanceReloadResponse` encoding, including `revision` |
| Profile `"other"` | 409, code `configuration_conflict`, `committed:false` |
| Body with an extra key | 400 `invalid_reload_request` |
| 65537-byte body | 400 `invalid_reload_request` |
| Shutting down | `instance_busy` |
| Admission ack `running:1` | 409 `instance_run_in_flight` with `running`/`queued`/`committed:false` |
| Relink throws | `committed:true`, `partial:"definition"` |

**Cancel**

| Situation | Expected outcome |
| --- | --- |
| Explicit session success | 202 `{identity,profile,sessionId,owner,outcome}` |
| `cancelSole` with 2 sessions | 409 `ambiguous_running_sessions` with `sessionIds` + `pendingRunCount` |
| Decode failure | 400 `invalid_cancel_request` |

**Environment status**

| Situation | Expected outcome |
| --- | --- |
| OK | 200 status JSON with names only; a fake status holding a secret-looking value never appears, because the status type has no value field (assert the encoded keys) |
| Profile nil | 409 `profile_or_instance_conflict` |

**Environment reload**

| Situation | Expected outcome |
| --- | --- |
| `.reloaded` | 200 |
| `.failed` (lastError set) | 422 with `lastError` |
| `.notReady` | 422 `instance_not_ready` |
| Revision conflict | the conflict's status/code |
| Wrong action `start` | 400 `invalid_request` |
| Profile nil (HTTP) | proceeds |

**Run**

| Situation | Expected outcome |
| --- | --- |
| Valid | the port result is passed through |
| Unknown key / `allowOverlap:"x"` / 524289 bytes / profile mismatch | 400 `{"error":{"code":"invalid_configured_run"}}` exactly |

**Bootstrap and launch status**

- `bootstrap` → 200 `{profile,revision}`.
- `launchStatus` passes through.

**Reload contract**

- A response with `revision: nil` encodes without a `revision` key; with `3`,
  `"revision":3`.
- A coordinator test with a fake reload port overriding `liveRevision()` to
  return nil → the response omits `revision`.

## Verification (`tmp/serverless-app-control/sac-04/`)

- `mkdir -p tmp/serverless-app-control/sac-04`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-04/build.log 2>&1`
  must exit 0. This proves the App target still compiles with the optional
  revision.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'RielaAppInstanceControlServiceTests|RielaAppInstanceReload|RielaAppInstanceCancel'" > tmp/serverless-app-control/sac-04/test.log 2>&1`
  must exit 0. The existing reload and cancel contract, coordinator and route
  tests pass unmodified.
- `git diff --exit-code -- Tests/RielaAppSupportTests/RielaAppInstanceReloadCoordinatorTests.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadContractTests.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadRouteTests.swift Tests/RielaAppSupportTests/RielaAppInstanceCancelCoordinatorTests.swift`
  must exit 0.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaAppSupport/RielaAppInstanceControlService.swift Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift Sources/RielaAppSupport/RielaAppInstanceReloadCoordinator.swift Tests/RielaAppSupportTests/RielaAppInstanceControlServiceTests.swift' > tmp/serverless-app-control/sac-04/lint.log 2>&1`

## Done criteria

- The service handles all 7 operations as listed.
- The existing reload and cancel tests are unchanged and green.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.
