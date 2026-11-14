# instance-cancel-11 progress

Implemented the single new nested-tree test. Two event workflow runs launch nested riela processes and separate command groups; cancellation checks immediate ESRCH, both session stores and isolation of the surviving run. Fixtures and recorded processes are cleaned up in defer.

On the shared tree, `build-riela.exit`, `test.exit`, and `lint.exit` are 0; `test.log` records one executed test, zero failures and no skip. `pgrep.log` is empty. Logs and NUL lint manifest are under `tmp/instance-cancel/instance-cancel-11-nested-tree-e2e/`. The first test attempt failed to compile `RielaAppWebAPI.swift` while the sibling App cancel file appeared; the subsequent complete test runs passed. Strict lint initially found one long line, corrected before final verification. Formal review and serial combined-tree verification remain downstream.

## Continuation: overall timeout

The XCTest expectation bounds the entire nested-tree body at 120 seconds. Its outer scope cancels the owned task and kills recorded fixture PIDs on exit, including timeout. The missing-binary skip remains outside the task. On the moving shared tree, `build-continuation.log`/`build-riela.exit`, `test-continuation2.log`/`test-continuation2.exit`, and `lint-continuation2.log`/`lint-continuation2.exit` report 0; the focused test ran once with no failures or skip, and `pgrep-continuation2.log` is empty. The superseded `test-continuation.log` failed compilation due to Swift actor isolation, corrected by isolating the test class to MainActor. Formal reviews and serial integration remain downstream.
