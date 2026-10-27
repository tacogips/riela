# atp-04-core-validation progress

Status: implementation complete; assigned acceptance criteria are met on the
current shared tree. Formal review and serial integration remain downstream
workflow steps.

## Changes

- Added preset diagnostics in `Sources/RielaCore/WorkflowNodeValidation.swift`
  before the provider early return. The validation reports backend-default
  mode, unsupported pinned backend, the first unsupported
  `backendPolicy.allowed` entry, missing backend selection, and Codex reuse
  only when `codexSupportsSessionReuse` is false. Existing diagnostics remain
  in their prior order.
- Added `Tests/RielaCoreTests/AgentToolPolicyPresetValidationTests.swift` for
  supported modes/backends, unsupported combinations, backend policy,
  missing selection, the no-provider placement proof, conditional Codex
  reuse, policies without a preset, and resolved CLI payloads.

## Verification

| Command | Exit | Tests | Failures | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyPresetValidationTests|OpenModelProviderRoutingTests|WorkflowBackendPolicyTests|AgentNodeOutputContractValidationTests" > tmp/agent-tool-policy-preset/atp-04-core-validation/test-final-2.log 2>&1'` | 0 | 45 | 0 | `tmp/agent-tool-policy-preset/atp-04-core-validation/test-final-2.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/agent-tool-policy-preset/atp-04-core-validation/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/agent-tool-policy-preset/atp-04-core-validation/changed-swift-files.nul; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/agent-tool-policy-preset/atp-04-core-validation/swiftlint-final.log` (empty, no violations) |

The NUL-delimited changed-file manifest is
`tmp/agent-tool-policy-preset/atp-04-core-validation/changed-swift-files.nul`.
Final source hashes are recorded in
`tmp/agent-tool-policy-preset/atp-04-core-validation/post-edit.sha256` and
`post-edit-04.sha256`.

## Superseded attempts

- `test.log` exited 1 while another SwiftPM invocation held the shared build
  directory; its build also observed atp-03 test edits in progress.
- `test-rerun.log` exited 1 on atp-03's then-current constructor argument
  order and file modification during build.
- `test-final.log` exited 1 because this test file's `XCTUnwrap` calls needed
  throwing propagation.
- `test-final-2.log` is the final-source rerun after those corrections and
  passes all 45 selected tests.

## Completion criteria

- [x] All five preset validation rules execute before the provider early
  return.
- [x] Tests cover all listed cases, including no-provider placement and
  resolved CLI payloads with no preset diagnostics.
- [x] Focused tests pass on the current shared tree (45/0).
- [x] Strict SwiftLint passes on the exact changed-file set.
