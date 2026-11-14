# instance-cancel-02 progress

Implementation complete for the root cancellation-reason seam. Handover causes retain precedence; non-cancellation errors do not read the reason. Child requests do not inherit it. The focused tests cover actual task cancellation, both nil fallbacks, handover, adapter failure, and one terminal event after completion.

Verification on the shared moving tree (arm64):
- `swift build`: exit 0, `tmp/instance-cancel/instance-cancel-02-runner-reason/build.log`.
- `swift test --filter "OperatorCancellationReasonFinalizeTests|WorkflowCancelledStatusTests"`: exit 0, 9 tests, 0 failures, `tmp/instance-cancel/instance-cancel-02-runner-reason/test.log`.
- Selected-file `swiftlint lint --quiet`: exit 0, `tmp/instance-cancel/instance-cancel-02-runner-reason/lint-final.log`.
- Selected-file strict lint through NUL manifest: exit 0, `tmp/instance-cancel/instance-cancel-02-runner-reason/lint-strict-final.log`.

Pre/post edit hashes and final source hashes are in the evidence directory. Formal review, stable integration verification, commit and push remain downstream.
