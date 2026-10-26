# atp-03-core-resolution: host-side preset expansion and prompt-spill guard (RielaCore)

```json
{
  "planId": "atp-03-core-resolution",
  "planPath": "impl-plans/active/agent-tool-policy-presets-03-core-resolution.md",
  "dependsOn": ["atp-01-core-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/AgentToolPolicyResolution.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift",
    "Tests/RielaCoreTests/AgentToolPolicyResolutionTests.swift",
    "Tests/RielaCoreTests/AgentPromptGuardTests.swift",
    "impl-plans/progress/atp-03-core-resolution.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

CLI presets must be expanded on the host into explicit argv before dispatch.
Sandbox and container guests may embed an older Riela that ignores `preset`,
and expanding first means tools are never silently enabled. SDK payloads keep
`preset` so the adapter can set `webSearch`. Design §4, decisions D1, D2 and
D4, and §7.

Today `resolveAgentToolPolicy` (`Sources/RielaCore/AgentToolPolicyResolution.swift`)
renders templates only. Its single production caller is
`Sources/RielaCore/DeterministicWorkflowRunner.swift:643`. That call runs
before `validateAgentNodePayload(executionPayload)` (line 657) and before
`guardAgentPrompt`.

The adapter sees the effective session policy
`step.sessionPolicy ?? executionPayload.sessionPolicy` (runner line 686).
Expansion must use the same value.

This plan uses only the atp-01 contract: `AgentToolPolicyPreset`,
`AgentToolPolicy.preset`, and `AgentToolPolicyPresetArguments.cliArguments`
and `.isSupported`.

Follow the shared worker protocol in
`impl-plans/active/agent-tool-policy-presets.md`.

## Non-goals

- Do not edit `WorkflowNodeValidation.swift` (atp-04), adapters (atp-05),
  `AdapterUtilities.swift`, `WorkflowModel.swift` or
  `AgentToolPolicyPresetArguments.swift`. Never add or change argv literals
  here; consume `cliArguments`.
- Do not change `DeterministicWorkflowRunner+DynamicWorkflow.swift`. Stamping
  the raw policy is correct (design §7).

## File-level changes

### `Sources/RielaCore/AgentToolPolicyResolution.swift`

The new signature is pinned. The defaults keep every existing call compiling:

```swift
public func resolveAgentToolPolicy(
  _ policy: AgentToolPolicy?,
  executionBackend: NodeExecutionBackend? = nil,
  sessionReuse: Bool = false,
  variables: JSONObject,
  trustedVariables: JSONObject? = nil
) throws -> AgentToolPolicy?
```

Do the steps in this order:

1. Render the four authored arrays exactly as today. Do not change the
   trusted-variable, line-break or option-injection rules.
2. `guard let preset = policy.preset else { return policy }`. Without a preset,
   nothing else changes, and in particular `additionalArguments` is **not**
   folded.
3. Fail closed on unsupported input. If `executionBackend == nil`, or
   `!AgentToolPolicyPresetArguments.isSupported(preset, backend:)`, throw
   `AdapterExecutionError(.invalidInput, "agent tool policy preset '<raw>' is not supported with executionBackend '<raw or none>'")`.
4. Expand CLI backends. If `cliArguments(preset, backend:, sessionReuse:)`
   returns argv for codex or claude:
   - codex-agent: set `codexArguments = argv + additionalArguments + codexArguments`;
   - claude-code-agent: set `claudeArguments = argv + additionalArguments + claudeArguments`;
   - in both cases set `additionalArguments = []` and `preset = nil`, and
     leave `mode` and `cursorArguments` unchanged.
5. Otherwise the backend is a supported SDK backend. Return the rendered
   policy with `preset` kept.

Pitfalls to avoid:

- Never pass preset literals through `renderPromptTemplate`. They contain `{}`
  and `{"mcpServers":{}}`.
- Expand after rendering, never before. Otherwise the option-injection check
  sees preset `-` arguments.

### `Sources/RielaCore/DeterministicWorkflowRunner.swift` (call at line 643)

Pass these two arguments:

- `executionBackend: executionPayload.executionBackend`
- `sessionReuse: (step.sessionPolicy ?? executionPayload.sessionPolicy)?.mode == .reuse`

Change nothing else in the function.

### `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift` (`promptSpillFilesAreAccessible`, line 149)

Also return `false` when `policy.preset != nil`. Add one conjunct; keep the
rest of the expression.

## Tests

`Tests/RielaCoreTests/AgentToolPolicyResolutionTests.swift`: add methods named
`testPreset…` and keep every existing test unchanged.

- Codex `none`, no authored arrays → `codexArguments == AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .codexAgent, sessionReuse: false)`,
  `preset == nil`, `additionalArguments == []`, and `mode` preserved (both nil
  and `.backendArguments`).
- Codex `web-search` with `additionalArguments: ["--a"]` and
  `codexArguments: ["--b"]` → `codexArguments == presetArgv + ["--a", "--b"]`.
- Claude `web-search` with `additionalArguments: ["--a"]` and
  `claudeArguments: ["--c"]` → `presetArgv + ["--a", "--c"]`. The
  `codexArguments` array is untouched.
- Codex `none` with `sessionReuse: true` → the argv contains no
  `--ephemeral`.
- Authored codex template `"-c"`, `"key={{x}}"` with `x` in trusted variables
  → the rendered value is appended after the preset. The preset elements
  `mcp_servers={}` and, for claude, `{"mcpServers":{}}` stay verbatim.
- SDK backends with the `web-search` preset → the returned policy equals the
  input, with `preset` kept and the arrays unchanged.
- Codex with authored arrays and **no** preset → the same output as before,
  with `additionalArguments` not folded.
- These throw `.invalidInput`:
  - `official/cursor-sdk` with `web-search`;
  - `cursor-cli-agent` with `none`;
  - preset with `executionBackend: nil`.
- `official/cursor-sdk` with `none` → returned unchanged.

`Tests/RielaCoreTests/AgentPromptGuardTests.swift`: in
`testOverBudgetWithoutGuaranteedFileAccessRejectsWithoutSpills` (line 186),
add a `presetOnly` payload (codex-agent,
`AgentToolPolicy(preset: .noTools)`) to the loop. It must reject without
spills, like `restricted`. An extra test method is also acceptable.

## Invariants

- Payloads without a preset resolve exactly as before.
- After resolution, a CLI payload never carries `preset`.
- Final adapter argv order is preset, then authored generic, then authored
  backend-specific.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyResolutionTests|AgentPromptGuardTests|DeterministicWorkflowRunnerDynamicWorkflowTests|DynamicWorkflowPolicyTests" > tmp/agent-tool-policy-preset/atp-03-core-resolution/test.log 2>&1'`
  must exit 0 with 0 failures. The dynamic-workflow suites prove that
  stamping is unaffected.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCore/AgentToolPolicyResolution.swift Sources/RielaCore/DeterministicWorkflowRunner.swift Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift Tests/RielaCoreTests/AgentToolPolicyResolutionTests.swift Tests/RielaCoreTests/AgentPromptGuardTests.swift > tmp/agent-tool-policy-preset/atp-03-core-resolution/swiftlint.log 2>&1'`
  must report 0 violations.

## Done criteria

- `grep -n "executionBackend: executionPayload.executionBackend" Sources/RielaCore/DeterministicWorkflowRunner.swift`
  matches.
- `grep -n "preset == nil" Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift`
  matches.
- Every test case above exists and passes, with records in the progress log.
