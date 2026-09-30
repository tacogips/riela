# wh-06: Backend wait-signal classifier progress

## Scope and implementation

Implemented the accepted `wh-06-wait-signal` plan only. `Sources/RielaAdapters/BackendWaitSignalClassifier.swift` exposes the pinned signal, rule, classifier protocol, and table classifier API. Classification uses only event type and typed JSON metadata status; it does not inspect content. The default table enables `tool_call` and `tool_call_update` with the ACP pending status for `.codexAgent`, `.claudeCodeAgent`, and `.cursorCliAgent`. SDK backends have empty rule lists. Presence instructions include the event title, then tool name, then `unknown`. `latestSignal` examines only the final event in persisted order.

ACP evidence: resolved checkout `.build/checkouts/agent-gateway` is revision `c7f269753ec36aca92d429ec13316ba033128967`, matching the revision pinned in `Package.swift`. `Sources/ACP/ACPSessionUpdate.swift` defines `ACPToolCallStatus` cases `pending`, `in_progress`, `completed`, and `failed`; `pending` has raw value `pending`. The implementation refers directly to `ACPToolCallStatus.pending.rawValue`, rather than duplicating/inventing the status string. The source hash recorded before implementation is in `tmp/work-handover/wh-06-wait-signal/attempt-01/prehash.txt`.

`Tests/RielaAdaptersTests/BackendWaitSignalClassifierTests.swift` covers pending signal metadata and traits, completed status, misleading free text, official SDK exclusion, last-event behavior in both orders, and an empty table. The focused XCTest suite ran 6 tests with 0 failures.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-06-wait-signal/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-06-wait-signal/build.log'` — exit 0; complete log: `tmp/work-handover/wh-06-wait-signal/build.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "BackendWaitSignalClassifierTests" > tmp/work-handover/wh-06-wait-signal/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-06-wait-signal/focused.log'` — 6 tests, 0 failures, exit 0; complete log: `tmp/work-handover/wh-06-wait-signal/focused.log`.
- Changed-file strict SwiftLint used NUL manifest `tmp/work-handover/wh-06-wait-signal/attempt-01/changed-swift-files.nul` containing exactly the two changed Swift paths and command `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-06-wait-signal/attempt-01/changed-swift-files.nul` in an arm64 shell — exit 0; complete log: `tmp/work-handover/wh-06-wait-signal/swiftlint.log`.
- `git diff --check` — exit 0; complete log: `tmp/work-handover/wh-06-wait-signal/diff-check.log`.

Final source SHA-256 before this progress-log edit:

- `Sources/RielaAdapters/BackendWaitSignalClassifier.swift`: `02cddc97912c260786002056c27a8021d52fbba181e07077fbb1c06eb848fa77`
- `Tests/RielaAdaptersTests/BackendWaitSignalClassifierTests.swift`: `05fe6d6b8f7a2291589b7ecb8527a8e4f5d7ef2998474bf842dc0b601728a668`

Hashes for the plan and lint configuration are in `tmp/work-handover/wh-06-wait-signal/attempt-01/pre-progress-hash.txt`. The source/test pre-progress copies and per-edit intent are preserved in that attempt directory.

## Completion criteria

- [x] Classifier matches the pinned API and derives the default wait status from the resolved ACP enum; evidence recorded above.
- [x] `BackendWaitSignalClassifierTests` pass with a non-zero count (6 passed, 0 failed).
- [x] Required arm64 build, focused tests, changed-file strict SwiftLint, and diff check complete successfully.

Implementation is ready for downstream test-integrity, adversarial, and serial integration review. Those review and finalization steps are outside this implementation plan's assigned work.
