# Instance control 09: RielaApp /reload route, port implementation and start-record provider wiring

**Status**: Planned
**planId**: instance-control-09-app-reload-route
**dependsOn**: instance-control-01-contracts, instance-control-06-parent-admission-runtime, instance-control-07-reload-support-library, instance-control-08-reload-coordinator
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 (route, request, algorithm, response, errors), §4 security
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-09-app-reload-route/

## Intent and context

This plan wires everything into the App:

- a new desktop-only route `POST /api/v1/instances/{identity}/reload`;
- the real `RielaAppInstanceReloadPorts` implementation over the App state (`daemonInstances`, `daemonState`, discovery, `daemonRuntime`, the profile session store);
- the runtime's `StartRecordProvider`, so every successful child start records what it installed.

Existing patterns to imitate:
- `Sources/RielaApp/RielaAppConfiguredRunAPI.swift`: path parse, `x-riela-profile` check, exact keys, `distributedControllerOperations.run`, `terminationShutdownStarted`.
- `Sources/RielaApp/RielaAppInstanceAPI.swift`: `instanceAPIError` envelope, revision validation, `makeDaemonStore().save`, `webRevision += 1`, `refreshDaemonWorkflowWindow()`.
- `Sources/RielaApp/EntryPoint+DaemonInstances.swift`: `relinkDaemonWorkflowInstance`, `restartDaemonWorkflowInstance`.

## Non-goals

- No change to `/actions`, `/runs` or `/environment` behaviour, and no change to the serve host (`riela serve`).
- No UI.
- Never touch the installed App or the real `~/.riela`. Tests use temp roots and fakes.

## File-level changes

### Sources/RielaApp/RielaAppInstanceReloadAPI.swift (new)

**`extension RielaApp { func webInstanceReloadResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse? }`**

- Matching: `parts.count == 5`, `api/v1/instances/<id>/reload`; anything else → nil.
- Method: non-POST → 405 `method_not_allowed`.
- Profile header must equal `daemonProfileName.rawValue`, else 409 `configuration_conflict`.
- `RielaAppInstanceReloadRequest.decodeStrict(body)` → 400 on failure.
- Run inside `distributedControllerOperations.run`. `terminationShutdownStarted` → 409 `instance_busy`.
- Call `RielaAppInstanceReloadCoordinator(ports: RielaAppReloadPorts(app: self, profile: daemonProfileName)).reload(identity:request:)`.
- Responses:
  - success → 200 with the encoded response;
  - error → `{"error":{"code","message"},"committed":Bool,"partial"?,"running"?,"queued"?}` with `code.httpStatus`.
  - The `message` passes through `WorkflowWebProjectionPolicy().safeSummary`.

**`struct RielaAppReloadPorts: RielaAppInstanceReloadPorts`** — `@MainActor` hops as the App requires; follow how `RielaAppInstanceAPI` accesses App state.

| Port | Implementation |
| --- | --- |
| `currentInstance` | `daemonInstances.first { $0.identity == identity }` → identity, workflowId, `source.id`, `source.workflowDirectory`, `source.eventRoot` |
| `validateRevision` | `validateGraphQLConfigurationRevision` (map → `configurationConflict`) |
| `discoverCandidate`, `requestedDirectory == nil` | rediscover from disk. `selected-workflow:` source → `daemonDiscovery.discoverSelectedWorkflowDirectory(instance.workflowDirectory)`. Otherwise `daemonWorkflowSources(profileName:state:)` filtered by source id. Never use the cached candidate. Nil → `invalidWorkflowSource`; `sourceChanged:false` |
| `discoverCandidate`, path given | `discoverSelectedWorkflowDirectory(path)`. Nil (no `workflow.json` / not a dir) → `invalidWorkflowSource`. `sourceChanged = (candidate.id != instance.sourceId)` |
| `validate` | `InstanceReloadSupport.validateCandidate(...)` (plan 07), with `preference.configuration.nodePatches` and the working directory from the candidate |
| `childRunning`, `installedStartRecord`, `admission` | `daemonRuntime.isChildRunning`, `installedStartRecord`, `admissionControl(identity: runtimeIdentity, frame:)`. `runtimeIdentity = profileRuntimeIdentity(profileName:localIdentity:)` |
| `importDefinition` | `InstanceReloadSupport.importDefinition(storeRoot: daemonSessionStoreRoot(profileName:), ...)` |
| `relink` | append the directory to `state.workflowDirectories` if absent; set `preference.sourceIdentity = candidate.sourceId`; save via `makeDaemonStore(profileName:).save(state)`; set `daemonState = state`; `webRevision += 1`; return `webRevision`. Preserve `preference.active`/`available` (unlike the menu relink, which sets `active=false`). The old directory entry stays |
| `refreshCache` | `refreshDaemonWorkflowWindow()` |
| `replaceChild` | `approvedDaemonWorkflowInstance(identity: runtimeIdentity)`. Nil → `instanceNotReady`. Then `daemonRuntime.replaceChild(approved.candidate, configuration: daemonRuntimeConfiguration(...), server: daemonServerConfiguration(...), sessionStoreRoot: daemonSessionStoreRoot(...))`. A `.failed` snapshot → `instanceStartFailed`. Return `snapshot.status.rawValue` |
| `profile`, `revision` | `daemonProfileName.rawValue`, `webRevision` |

### Sources/RielaApp/RielaAppWebAPI.swift

Add exactly one line before the `webConfiguredRunResponse` dispatch (line ~11): `if let response = await webInstanceReloadResponse(for: request) { return response }`.

### Sources/RielaAppSupport/RielaWebAPIRouteTable.swift

Add to `desktopOnly`: `.init(method: "POST", path: "/api/v1/instances/{identity}/reload", owner: "Sources/RielaApp/RielaAppInstanceReloadAPI.swift", ownerMarker: #"parts[4] == "reload""#)`.

- Then run `RielaAppWebAPIRouteTests`. If its gate checks owner markers in source, make sure the marker text literally appears in the new file.

### Sources/RielaApp/EntryPoint.swift

Where `daemonRuntime` is set up after init (or in `applicationDidFinishLaunching` before the first start), call `daemonRuntime.setStartRecordProvider { candidate, storeRoot in InstanceReloadSupport.startRecord(candidateDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot, storeRoot: storeRoot, workflowId: candidate.workflowId, workingDirectory: candidate.workingDirectory) }`.

- This must run before any daemon instance auto-start. Place it before the first `daemonRuntime.start` call path; check the launch flow.
- `daemonRuntime` is a `let` actor, so `setStartRecordProvider` is `await`ed.

### Contract alignment with accepted code (continuation run, 2026-11-10, step 4)

- The ports protocol is fixed in `Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift:226-241`. Implement exactly those 13 requirements and do not edit that file or `RielaAppInstanceReloadCoordinator.swift` (both accepted).
- `validate(candidate:instance:)` returns `RielaAppInstanceReloadValidated(workflowId:triggerDefaultsFingerprint:eventRootDigest:)`. Build it from plan 07's `InstanceReloadCandidateValidation`: `.bundle.workflow.workflowId`, `.triggerDefaultsFingerprint`, `.eventRootDigest`. Never use tuple element access.
- `replaceChild(identity:interrupt:)` is the port signature. Inside it, call `daemonRuntime.replaceChild(...)` (`Sources/RielaAppSupport/DaemonWorkflowSupport.swift:825`) with the approved candidate. `interrupt` is already handled by the coordinator's barrier ordering, so do not add a second stop.
- The runtime hooks to use are `setStartRecordProvider` (`DaemonWorkflowSupport.swift:807`), `installedStartRecord(identity:)` (811), `isChildRunning(identity:)` (815) and `admissionControl(identity:frame:)` (820). Always pass the runtime identity (`profileRuntimeIdentity`), never the local list identity.
- Tests must build `RielaApp` only with temp app/session roots, as `ConfiguredWorkflowLaunchTests` does. Running `RielaApp()` against defaults writes into the real `~/.riela/rielaapp` (known leak), so a test that cannot isolate roots must not be written.

Done-criteria evidence:
- `grep -n "/api/v1/instances/{identity}/reload" Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` matches exactly once.
- `grep -n "webInstanceReloadResponse" Sources/RielaApp/RielaAppWebAPI.swift` matches exactly once.
- `grep -n "setStartRecordProvider" Sources/RielaApp/EntryPoint.swift` matches once.
- `git diff --stat` for the three sharedPaths shows only additions of those lines.

## Key pitfalls

- Security: the profile header, Host/Origin/CSRF guards and JSON content type come from the router (`RielaAppWebRouter.securityRejection`) for every `/api/v1` POST. Do not bypass them, and do not register the route anywhere that skips the router.
- `workflowDirectory` must contain the same `workflowId` (plan 07 enforces this). Do not add arbitrary-workflow registration.
- Do not log environment values or request bodies.

## Tests

**Tests/RielaAppSupportTests/RielaAppInstanceReloadRouteTests.swift (new)**. Imitate `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift` and `ConfiguredWorkflowLaunchTests.swift`, which construct a `RielaApp` with temp roots.

| Situation | Expected |
| --- | --- |
| Route table contains `/reload` in `desktopOnly` with the right owner | present |
| Bad body (extra key) | 400 `invalid_reload_request` |
| Wrong profile header | 409 |
| GET | 405 |
| Unknown identity | 404 `instance_not_found` |
| Temp profile with a `selected-workflow` instance and a valid workflow dir with no running child: reload | 200, `handoff:none`, `definition.outcome:"seeded"` (fresh store under the temp profile session root) |
| Same, second reload | `unchanged` |
| `workflowDirectory` pointing at a new valid copy with the same workflow id | `sourceChanged:true`; `daemon-workflows.json` (temp) contains the new directory and a new `sourceIdentity`; revision incremented |
| `workflowDirectory` with a different workflow id | 422 `workflow_id_mismatch`; temp `daemon-workflows.json` byte-identical and store version count unchanged |
| Provider wiring: a fake runtime start with the provider installed | `installedStartRecord` non-nil |

Running-child respawn paths are covered by plan 08 (coordinator) and plan 06 (runtime). Do not spawn real `events serve` children here.

## Verification

1. `mkdir -p tmp/instance-control/instance-control-09-app-reload-route && arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppInstanceReloadRouteTests|RielaAppWebAPIRouteTests|ConfiguredWorkflowLaunchTests" 2>&1 | tee tmp/instance-control/instance-control-09-app-reload-route/test.log; exit ${pipestatus[1]}'` — 0 failures.
2. `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/instance-control/instance-control-09-app-reload-route/build.log; exit ${pipestatus[1]}'`
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaApp/RielaAppInstanceReloadAPI.swift Sources/RielaApp/RielaAppWebAPI.swift Sources/RielaAppSupport/RielaWebAPIRouteTable.swift Sources/RielaApp/EntryPoint.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadRouteTests.swift 2>&1 | tee tmp/instance-control/instance-control-09-app-reload-route/lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Fresh-read before each edit; record the pre- and post-edit sha256.
- `RielaAppWebAPI.swift`, `RielaWebAPIRouteTable.swift` and `EntryPoint.swift` are sharedPaths limited to the single additions above.

## Completion criteria

- [ ] Route live.
- [ ] Ports implemented.
- [ ] Provider wired.
- [ ] Tests, build and lint exit 0.
- [ ] Progress log written.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.

## Amendment 2026-11-10 (blocked-wave-scope-or-contract, round 1)

**Why.** This plan is not blocked yet, but it would hit the same blocker: its `swift test` and `swift build` write SwiftPM build output.

**Change.**
- `writePaths` and `artifactRoots` add `.build`.
- `dependsOn` is unchanged. Through 06 (lane B tail) and 07 (lane A tail, after 04 and 05), it already runs after both build lanes, so it is the sole `.build` user at its level.
- The verification commands in `## Verification` are unchanged and authorized as written.

**Rules:**
- Never pass `--scratch-path`.
- Never touch or delete `tmp/instance-control/swiftpm-lane-b`.
- Never run `swift package clean`, `reset`, `update`, or anything that rewrites `Package.resolved`.
- If dependency resolution fails, record `dependency-resolution` and stop.
- Wait on a held `.build` lock.
