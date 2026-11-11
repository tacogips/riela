# instance-cancel-08: Cancellable App-process manual runs (per-identity launch registry)

**planId**: instance-cancel-08-app-launch-registry
**dependsOn**: instance-cancel-01-contracts (`LiveSessionCancelRegistry`, `OperatorCancellation`, `WorkflowServeSessionCancelOutcome`), instance-cancel-02-runner-reason (`WorkflowRunCommand.operatorCancellationReason`)
**Design Reference**: design-docs/specs/design-instance-cancel.md §2 (App manual runs row), §3 C2 item 2, C5 (App launch)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-08-app-launch-registry.md
**Evidence root**: tmp/instance-cancel/instance-cancel-08-app-launch-registry/

## Intent and context

Manual runs (`POST /instances/{id}/runs`) execute inside the App as
`runtime.launchTasks[job.id] = Task.detached { … WorkflowRunCommand.run … }`
(`Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift:64-78`).
`WebWorkflowLaunch.append` learns the sessionId from the JSONL stream
(`Sources/RielaCLI/WebWorkflowLaunch.swift:20-27`). Make each such run
cancellable by `(identity, sessionId)` and enumerable per identity.

## Non-goals

- The launch snapshot JSON (`id`, `status`, `sessionId`, `error`) stays
  byte-identical, and there is no new status. A cancelled run reads `failed`.
- No change to the 4-running or 40-launch caps.
- No route code.

## File-level changes

- `Sources/RielaCLI/RielaWebWorkflowRuntime.swift` (`@MainActor final class`):
  - Add `var launchCancelRegistries: [String: LiveSessionCancelRegistry] = [:]`,
    keyed by instance identity, with an accessor that creates on demand.
  - Add `public func cancelLaunch(identity: String, sessionId: String, reason: String, actor: String) -> WorkflowServeSessionCancelOutcome`.
    No registry → `.notFound`.
  - Add `public func liveLaunchInventory(identity: String) -> (sessionIds: [String], pendingRunCount: Int)`.
    No registry → `([], 0)`.
- `Sources/RielaCLI/WebWorkflowLaunch.swift`: add an internal
  `var onFirstSessionId: (@Sendable (String) -> Void)?`, set before the task
  starts. Call it exactly once, outside the lock, when `sessionId` is first
  assigned in `append`. The snapshot is unchanged.
- `Sources/RielaCLI/WebWorkflowRequestHandler+ConfiguredLaunch.swift`, in
  `launchConfiguredWorkflow`:
  - Get `registry = runtime.registry(for: identity)` and an
    `OperatorCancellation`, and call `registry.beginRun()` just before
    creating the task.
  - Set `job.onFirstSessionId = { registry.register(sessionId: $0, cancellation:, cancel: { handleBox.cancel() }) }`,
    where `handleBox` is a lock box holding the `Task` handle. If cancel
    arrives before the handle is stored, the box cancels on store; imitate
    the `TaskHandleBox` idea from plan 06, but declare it privately in this
    file.
  - Inside the task, set
    `command.operatorCancellationReason = { cancellation.failureReason }`
    next to `configuredInstanceOverride`.
  - After `job.finish(result)`, call `registry.unregister(sessionId:)` (if
    one was seen) and `registry.endRun()`. This happens inside the detached
    task, so it is not MainActor; the registry is lock-based and safe.
  - The early-return error paths (429, 409, 422) never call `beginRun`.

Pitfalls:
- `Task.detached` does not inherit cancellation, so cancel through the stored
  handle (which `shutdown()` already does).
- Do not call MainActor APIs from the registry's cancel closure.
- Never let a cancel for identity A reach a launch of identity B; registries
  are per identity.

## Tests: Tests/RielaCLITests/ConfiguredLaunchCancelTests.swift (new)

Imitate the configured-launch setup in
`Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift`: a temp
store and a temp workflow dir with one command node `sleep 300` that writes a
ready file.
- Launch with identity I, then wait for the sessionId and ready →
  `liveLaunchInventory(I)` is `([sid], 0)`;
  `cancelLaunch(I, sid, "dup", "rielaapp-api:default")` → `.cancelRequested`;
  the launch snapshot becomes `failed`; the store session is `cancelled` with
  failureReason `operator_cancelled by rielaapp-api:default: dup`; the
  inventory becomes `([], 0)`.
- `cancelLaunch(J, sid, …)` for another identity → `.notFound`, and the run
  continues.
- A second cancel → `.alreadyRequested`.
- An unknown session → `.notFound`.
- Two concurrent launches for I; cancel one → the other is still running,
  then cancel it in cleanup.
- The snapshot JSON key set is unchanged: exactly `{id, status, sessionId, error}`.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "ConfiguredLaunchCancelTests|WorkflowDefinitionServiceResolutionTests"`
  → exit 0, 0 failures, no leftover `sleep 300` (`pgrep` before and after,
  logged).
- `swiftlint lint` on the changed and new files → no new violations.

## Done criteria

- The tests pass.
- The diff is limited to the 3 sources plus 1 test.
- The progress log has exit codes and log paths.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift. `WebWorkflowRequestHandler+ConfiguredLaunch.swift` may be touched by
branch fix/manual-overlap-terminal-reserve; keep the edits additive.
