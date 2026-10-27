# atp-03-core-resolution progress

Status: implementation and required focused behavioral verification complete. The earlier shared-tree compile blocker was resolved by atp-04. Formal review, commit, and push remain downstream.

## Implementation

- `resolveAgentToolPolicy` now accepts defaulted `executionBackend` and `sessionReuse` parameters. It preserves existing template rendering, leaves policies without a preset unchanged, fails closed for nil or unsupported backends, expands Codex/Claude presets after rendering in preset + generic + backend-specific order, clears preset/generic arguments for CLI payloads, and retains supported SDK policies.
- `DeterministicWorkflowRunner` passes the execution backend and effective step-or-payload session reuse mode.
- Prompt spill eligibility rejects any policy with a preset.
- Added resolution coverage for Codex and Claude ordering, mode preservation, reuse, literal preset arguments, templates, SDK retention, no-preset compatibility, and unsupported backends. Added preset-only prompt-guard case.

## Changed source paths and final hashes

See `tmp/agent-tool-policy-preset/atp-03-core-resolution/final-source-sha256.txt`.

- `Sources/RielaCore/AgentToolPolicyResolution.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift`
- `Tests/RielaCoreTests/AgentToolPolicyResolutionTests.swift`
- `Tests/RielaCoreTests/AgentPromptGuardTests.swift`

## Verification

- PASS, exit 0: `arch -arm64 /bin/zsh -lc 'if [ -s tmp/agent-tool-policy-preset/atp-03-core-resolution/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/agent-tool-policy-preset/atp-03-core-resolution/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`; log `tmp/agent-tool-policy-preset/atp-03-core-resolution/swiftlint.log` (empty, 0 violations).
- PASS, exit 0: final strict changed-file SwiftLint rerun through the NUL-delimited manifest; command `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/agent-tool-policy-preset/atp-03-core-resolution/changed-swift-files.nul > tmp/agent-tool-policy-preset/atp-03-core-resolution/swiftlint-after-atp04.log 2>&1'`; log `tmp/agent-tool-policy-preset/atp-03-core-resolution/swiftlint-after-atp04.log` is empty (0 violations).
- PASS: runner call-site grep; evidence `tmp/agent-tool-policy-preset/atp-03-core-resolution/runner-callsite.log`.
- PASS: prompt-guard preset grep; evidence `tmp/agent-tool-policy-preset/atp-03-core-resolution/prompt-guard-preset.log`.
- PASS, exit 0: required focused suite rerun after atp-04 repaired its validation tests. Command `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyResolutionTests|AgentPromptGuardTests|DeterministicWorkflowRunnerDynamicWorkflowTests|DynamicWorkflowPolicyTests" > tmp/agent-tool-policy-preset/atp-03-core-resolution/test-after-atp04.log 2>&1'`; log `tmp/agent-tool-policy-preset/atp-03-core-resolution/test-after-atp04.log` reports 44 tests, 0 failures (12 resolution, 13 prompt guard, 10 dynamic runner, 9 dynamic policy).

Historical blocked run: `test-final.log` exited 1 before tests ran because the then-current atp-04 test file did not compile. It is superseded by the successful `test-after-atp04.log` run and remains recorded as a failure in the original evidence.

## Completion criteria

- [x] Pinned resolution signature and defaults implemented.
- [x] CLI expansion after rendering, authored argument ordering, clearing, SDK retention, fail-closed backend behavior implemented.
- [x] Runner passes executionBackend and effective session reuse.
- [x] Prompt spill guard treats preset as custom.
- [x] Required test cases added.
- [x] Strict changed-file SwiftLint clean.
- [x] Required focused resolution, prompt-guard, and dynamic-workflow suites pass (44 tests, 0 failures).
