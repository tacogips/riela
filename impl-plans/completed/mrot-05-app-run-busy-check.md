# mrot-05: App run route refuses with `instance_busy` unless `allowOverlap`

**planId**: mrot-05-app-run-busy-check
**dependsOn**: mrot-02-live-root-session-probe (wave 2)
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §3.3, §3.5, §3.6, §6 (App run route row)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-05-app-run-busy-check.md
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-05/

## Intent and context

`RielaApp.webConfiguredRunResponse`
(`Sources/RielaApp/RielaAppConfiguredRunAPI.swift`) launches through
`RielaWebWorkflowRequestHandler.launchConfiguredWorkflow`
(`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`). It only
applies the global `run_limit`, so it happily starts a second execution of a
busy instance. The busy check goes inside `launchConfiguredWorkflow`. That
function is synchronous and registers the launch in `runtime.launches` within
the same call, and the route runs it inside the serialized
`distributedControllerOperations.run`. So the check and the claim are atomic
inside the App.

## Wire contract (pinned; mrot-03 consumes it)

- Request body key set: exactly `{expectedProfile, expectedRevision,
  variables}`, or that set plus `allowOverlap` (a JSON bool). Anything else is
  400 `invalid_configured_run`.
- Busy and `allowOverlap != true` → HTTP 409 with body
  `{"error":{"code":"instance_busy","runningSessionId":"<sid|pending>"}}`, and
  nothing is launched. A successful 202 body is unchanged.

## Non-goals

- Do not change the shutdown or reload `instance_busy` responses, the
  `run_limit`, the response shapes, the executions route, or event serve.
- Do not edit `LiveRootSessionProbe.swift` (mrot-02) or any CLI command file.

## File-level changes

- `Sources/RielaApp/RielaAppConfiguredRunAPI.swift`
  - `ConfiguredRunInput` gains `let allowOverlap: Bool?`.
  - Change the key-set check from equality to: the keys must be a superset of
    the 3 required keys and a subset of the 3 plus `allowOverlap`.
  - Pass `allowOverlap: input.allowOverlap ?? false` to
    `launchConfiguredWorkflow`.
- `Sources/RielaCLI/WebWorkflowLaunch.swift`
  - Add `public let identity: String?` with an init parameter
    `identity: String? = nil`, so other call sites stay unchanged.
  - Add a lock-protected internal accessor for the current `sessionId`, if
    none exists yet. Do not change `snapshot`'s keys.
- `Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`
  - Signature: `launchConfiguredWorkflow(identity:source:configuration:variables:allowOverlap: Bool = false)`.
  - After the existing stale-launch pruning and **before** the `run_limit`
    guard (busy is the more specific error), unless `allowOverlap`:
    1. In-memory blockers: `runtime.launches` values with
       `identity == identity` and status `running`, oldest `createdAt`
       first. Use their sessionId, or `"pending"` when it is unknown.
    2. Store blockers: `LiveRootSessionProbe.liveRootSessions(workflowId:
       source.workflowId, sessionStoreRoot: context.sessionStoreRoot)`, all
       kinds, not only manual ones, excluding sessionIds already listed in
       step 1. If the probe throws, continue as not busy (fail-open).
    3. If anything was found, return
       `.json(status: 409, .object(["error": .object(["code": .string("instance_busy"), "runningSessionId": .string(first)])]))`.
  - Construct the launch with `WebWorkflowLaunch(profile:identity:)`.
  - Pitfall: there must be no `await` or `Task` hop between the check and
    `runtime.launches[job.id] = job`. Keep the whole sequence synchronous, as
    it is now.

## Tests: Tests/RielaAppSupportTests/ConfiguredRunOverlapTests.swift (new)

Imitate the setup of
`Tests/RielaAppSupportTests/ConfiguredWorkflowLaunchTests.swift:testSelectedConfigurationRunsRealCommandWithExactEnvironmentDirectoryAndVariables`:
temp root under `tmp/`, `webSessionStoreRootOverride`, and a fixture
workflow. Do not edit that file.

- In-memory busy: insert a running `WebWorkflowLaunch(profile:, identity: "selected")`
  into `app.webWorkflowRuntime` launches (`@testable`), then POST → 409 with
  `instance_busy` and `runningSessionId == "pending"`, and the launch count is
  unchanged.
- Store busy: persist a `running` root session of the fixture workflowId in
  the override store, hold its lock with
  `SessionExecutionLockRegistry(...).acquire` (`@testable import RielaCLI`),
  then POST → 409 naming that sessionId.
- The same store session with its lock released (orphan) → 202.
- `allowOverlap: true` while busy → 202.
- Body with an unknown extra key → 400 `invalid_configured_run`.
- Body `allowOverlap: "yes"` (not a bool) → 400 `invalid_configured_run`.

## Invariants

- `ConfiguredWorkflowLaunchTests` passes unmodified. Its body has no
  `allowOverlap` and nothing else is running, so it must still return 202.

## Verification

- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift build'`: exit 0. RielaApp is a
  macOS target, so build the whole package.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter ConfiguredRunOverlapTests'`: all pass.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter ConfiguredWorkflowLaunchTests'`: all pass.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaApp/RielaAppConfiguredRunAPI.swift Sources/RielaCLI/WebWorkflowLaunch.swift Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift Tests/RielaAppSupportTests/ConfiguredRunOverlapTests.swift'`: clean.

Do **not** start, stop or touch the running RielaApp or `~/.riela`. The tests
use temp roots only. Record each command's exit status and log path, plus
fresh-read pre and post hashes. Stop on drift.

## Done when

- [x] Key-set rule, busy check, identity on the launch, and 409 body implemented.
- [x] Six tests green, and the existing launch test green.
- [x] Progress log complete.
