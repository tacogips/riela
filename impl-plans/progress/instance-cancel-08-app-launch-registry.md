# instance-cancel-08 implementation progress

Implemented per-identity registries, synchronous first-session registration,
cancel-before-handle storage, and unregister/endRun after launch completion.
The tests exercise identity isolation, concurrent runs, repeated and unknown
cancellation, session reason, launch snapshot keys and callback reentrancy.
Early 429/409/422 returns occur before beginRun by inspection.

Final shared-tree evidence under `tmp/instance-cancel/instance-cancel-08-app-launch-registry/`:
- `build.log`, `build.exit`: `arch -arm64 /bin/zsh -lc 'swift build'`, exit 0.
- `test.log`, `test.exit`: `swift test --filter "ConfiguredLaunchCancelTests|WorkflowDefinitionServiceResolutionTests"`, exit 0, 9 tests, 0 failures. `pgrep-before.log` and `pgrep-after.log` are empty.
- `lint.log`, `lint.exit`: strict, no-cache SwiftLint via `changed-swift.nul`, exit 0.
- `test-initial.log`: earlier compile interrupted by concurrent modification of sibling `EventOperatorCancelTests.swift`; superseded by final aggregate.

The shared tree was moving during verification; serial integration must rerun gates.
Formal test-integrity and adversarial review are downstream.
