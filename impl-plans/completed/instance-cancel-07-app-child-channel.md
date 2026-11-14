# instance-cancel-07: App-side session-control channel to the instance child

**planId**: instance-cancel-07-app-child-channel
**dependsOn**: instance-cancel-01-contracts (`WorkflowServeSessionControlFrame`, `WorkflowServeSessionControlAcknowledgement`, `WorkflowServeSessionControlError`)
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C3 (parent side)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-07-app-child-channel.md
**Evidence root**: tmp/instance-cancel/instance-cancel-07-app-child-channel/

## Intent and context

The App reaches the child through this chain:
`RielaAppDaemonWorkflowRuntime.admissionControl(identity:frame:)`
(`Sources/RielaAppSupport/DaemonWorkflowSupport.swift:820`) →
`WorkflowServingController.admissionControl` (`Sources/RielaServer/WorkflowServingController.swift:110`) →
`WorkflowServeEventSourceHandle.admissionControl` → the event-serve handle
(`DaemonWorkflowEventServeProcess.swift:375`) → the process
(`DaemonWorkflowEventServeProcess.swift:475-505`), which writes the frame and
polls `admissionAcknowledgements`, filled in `appendOutput` (lines 563-581).

Add a parallel `sessionControl` along the same chain.

## Non-goals

- No change to admission or environment frames, their timeouts or their
  parsing order beyond adding one decode branch.
- No route or coordinator code.

## File-level changes

- `Sources/RielaServer/WorkflowServingController.swift`:
  - Protocol `WorkflowServeEventSourceHandle` gains
    `func sessionControl(_ frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement`,
    with a default extension that throws
    `WorkflowServeSessionControlError.unsupported`, like `admissionControl`
    at line 31.
  - `WorkflowServingController.sessionControl(_:)`: no active generation →
    throw `.childExited`. Otherwise, over every handle:
    - `session-cancel`: return the first ack whose outcome ≠ notFound, else
      the last ack, else throw `.noAcknowledgement`;
    - `session-list`: merge — the sorted union of ids and the summed
      `pendingRunCount`, with the requestId of the frame.

    `.unsupported` from a handle counts as no ack for that handle. If every
    handle is unsupported, throw `.unsupported`.
- `Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift`:
  - The `RielaAppDaemonEventServeProcessHandle` protocol (line ~33) gains
    `sessionControl(_:)`, with a default that throws `.unsupported`.
  - The event-source handle (around line 375) forwards to the process.
  - The process implementation copies `admissionControl` (lines 475-505): the
    `frameWriteInProgress` claim loop, `writeFrame` and a poll of
    `sessionControlAcknowledgements[requestId]`, with the same
    `admissionTimeoutSeconds`. Error mapping: no `inputPipe` →
    `.unsupported`; not running → `.childExited`; deadline →
    `.noAcknowledgement`.
  - `appendOutput`: in the stdout-ack loop, decode
    `WorkflowServeSessionControlAcknowledgement.decodeLine` **before** the
    environment-ack decode, into `sessionControlAcknowledgements` (cleared
    when the count reaches 64, like admission).
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`: add
  `public func sessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement`,
  mirroring `admissionControl(identity:frame:)` at line 820. An unknown
  identity throws `.childExited`.

Pitfalls:
- Keep `frameWriteInProgress` shared with admission and environment writes,
  so frames never interleave.
- Always release the claim on write failure.
- Never block the reader handler.

## Tests: Tests/RielaAppSupportTests/DaemonSessionControlTests.swift (new)

Imitate `Tests/RielaAppSupportTests/DaemonAdmissionRuntimeTests.swift`
(`AdmissionTestHandle`, `AdmissionTestFactory`).
- A handle returning a cancel ack → the runtime returns it.
- Two handles, notFound and cancelRequested → cancelRequested.
- List merge: handles return `[b]`/1 and `[a]`/0 → `[a,b]` and 1.
- A handle without an override → `.unsupported`.
- An unknown identity → `.childExited`.
- `WorkflowServingController` with no active generation → `.childExited`.
- Parent parsing: a session ack line and an admission ack line arriving in one
  chunk are both routed correctly. Use the process-level parsing if it is
  reachable through `@testable`; otherwise test it through a fake handle and
  record the reason in the progress log.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "DaemonSessionControlTests|DaemonAdmissionRuntimeTests|WorkflowServeAdmissionTests"`
  → exit 0, 0 failures.
- `swiftlint lint` on the changed and new files → no new violations.

## Done criteria

- The tests pass.
- The diff is limited to the 3 sources plus 1 test.
- The progress log has exit codes and log paths.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift.

## Amendment 2026-11-11 (integration-paths-outside-writePaths, round 1)

Source: integration review comm-000054 (IR-SCOPE-FIXTURE-ROOTS), routed by
dispatch-plans comm-000056 (`amendment_required`). This is a bounded scope
amendment only; there is no design change.

- **Fixture root.**
  `tmp/instance-control/instance-control-06-parent-admission-runtime/fixtures`
  is added to writePaths **and** artifactRoots, for verification only.
  `DaemonAdmissionRuntimeTests` writes its fixtures there
  (`Tests/RielaAppSupportTests/DaemonAdmissionRuntimeTests.swift:22`). Do not
  edit that test.
- **Shared build output.** The worktree `.build` written by `swift build` and
  `swift test` from the worktree root is authorized shared build output. It is
  untracked and does not count as a write-scope violation. A private
  `--scratch-path` may be used in addition to the plan commands, never instead
  of them.
- **Corrected list-merge example.** `[b]`/1 and `[a]`/0 merge to `[a,b]` with
  pendingRunCount **1**, because the pending counts are summed.
- **Still required.** Create
  `Tests/RielaAppSupportTests/DaemonSessionControlTests.swift`, then run the
  plan's build, test and lint commands.
- **Transient test byproducts.** Some existing suites create
  `tmp/<prefix>-<UUID>` directories and delete them themselves. Those are
  authorized byproducts of verification. Do not edit those tests.
- **Dispatch manifest.** `impl-plans/active/instance-cancel-dispatch.json` is
  regenerated by the dispatch flow. Workers never edit it.
