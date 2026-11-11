# instance-cancel-02: Operator cancellation reason in the runner's terminal record

**planId**: instance-cancel-02-runner-reason
**dependsOn**: none (wave 1; uses only a `() -> String?` closure, no new types)
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C1, C6
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-02-runner-reason.md
**Evidence root**: tmp/instance-cancel/instance-cancel-02-runner-reason/

## Intent and context

A cancelled session must end with `status=cancelled`,
`failureKind=cancelled` and
`failureReason="operator_cancelled by <actor>: <reason>"`. Today
`finalizeInterruptedSessionFailed`
(`Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:9-105`)
always writes the reason `"workflow run cancelled"`, and
`request.cancellationCause` can only override the kind. `markSessionFailed`
already maps `failureKind .cancelled` to status `.cancelled` and moves running
executions to `.cancelled`. Do not change the store.

## Non-goals

- No store or schema change.
- No change to `cancellationCause` semantics or the handover path.
- No new session status.
- Do not touch event-serve, App or CLI-command files other than
  `WorkflowRunCommand.swift`.

## File-level changes

- `Sources/RielaCore/DeterministicWorkflowRunner.swift`: add
  `public var cancellationReason: (@Sendable () -> String?)?` to
  `DeterministicWorkflowRunRequest`. Add an init parameter
  `cancellationReason: (@Sendable () -> String?)? = nil` **after**
  `cancellationCause` (line ~77), so existing call sites compile unchanged,
  and assign it.
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`, in
  `finalizeInterruptedSessionFailed`. Keep the existing handover branch
  (stalled, leaseLost or cancelled from `cancellationCause`) first. In the
  `else` branch, when `isWorkflowRunCancellation(error)` and
  `request.cancellationReason?()` is non-nil, use `failureKind = .cancelled`
  and `failureReason =` that string. Otherwise keep the existing
  `workflowRunFailureKind` / `workflowRunFailureReason`. The fallback block
  that cannot persist (lines ~68-81) uses the same `failureReason` variable,
  so nothing else changes there.
- `Sources/RielaCLI/WorkflowRunCommand.swift`: add
  `var operatorCancellationReason: (@Sendable () -> String?)?` next to
  `sessionStartedObserver` (line 30). Pass it as `cancellationReason:` in the
  `DeterministicWorkflowRunRequest(...)` construction at line ~211-229. Do not
  add it to any other request construction.

Pitfalls:
- `finalizeInterruptedSessionFailed` re-enters through an unstructured `Task`
  when `Task.isCancelled`. The closure is read inside the re-entered call,
  which is fine.
- Do not read the closure for non-cancellation errors.
- Fanout and cross-workflow child requests must **not** inherit the closure;
  only the root request carries it.

## Tests

`Tests/RielaCoreTests/OperatorCancellationReasonFinalizeTests.swift` (new).
Imitate `Tests/RielaCoreTests/WorkflowCancelledStatusTests.swift`: in-memory
store, a fake adapter that blocks until cancelled.
- run cancelled with `cancellationReason` returning
  `"operator_cancelled by rielaapp-api:default: dup"` → session `.cancelled`,
  failureKind `.cancelled`, failureReason equals the string, and the running
  step execution is `.cancelled` with the same reason;
- `cancellationReason` nil, or returning nil → reason
  `"workflow run cancelled"` (unchanged);
- `cancellationCause` returns `.stalled` while the reason is set → the
  handover reason `"task handover trigger: stalled"` wins;
- an adapter failure (not cancellation) with the reason set → normal
  adapterFailure; the closure is not consulted (assert with a counter);
- the run completes, and only then does the reason closure become non-nil and
  the task get cancelled → exactly one terminal record, `.completed` (the
  design C6 single-finalization check). If this fails, report it in the
  progress log and fix it in the runner's terminal path (in this plan's files
  only).

## Invariants

- All existing `WorkflowCancelledStatusTests` pass unchanged.
- All existing initializer call sites compile without edits.

## Verification (arm64 shell; tee logs to the evidence root)

- `swift build` → exit 0 (`build.log`).
- `swift test --filter "OperatorCancellationReasonFinalizeTests|WorkflowCancelledStatusTests"`
  → exit 0, 0 failures (`test.log`).
- `swiftlint lint Sources/RielaCore/DeterministicWorkflowRunner.swift Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift Sources/RielaCLI/WorkflowRunCommand.swift Tests/RielaCoreTests/OperatorCancellationReasonFinalizeTests.swift`
  → no new violations (`lint.log`).

## Done criteria

- [x] The tests above pass (9 tests, 0 failures).
- [x] Source changes are limited to the 3 source files plus 1 new test.
- [x] The progress log has exit codes and log paths.
- Formal review and stable integration verification remain downstream.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift.
