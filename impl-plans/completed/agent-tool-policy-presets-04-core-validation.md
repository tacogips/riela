# atp-04-core-validation: preset validation diagnostics (RielaCore)

```json
{
  "planId": "atp-04-core-validation",
  "planPath": "impl-plans/active/agent-tool-policy-presets-04-core-validation.md",
  "dependsOn": ["atp-01-core-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/WorkflowNodeValidation.swift",
    "Tests/RielaCoreTests/AgentToolPolicyPresetValidationTests.swift",
    "impl-plans/progress/atp-04-core-validation.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Unsupported preset combinations must fail when the workflow loads:
`WorkflowValidation.swift:168`, the registry loader, `workflow validate`, and
inheritance all call `validateAgentNodePayload`. Validation runs again at run
time on the resolved payload (`DeterministicWorkflowRunner.swift:657`), so it
must also accept a payload whose CLI preset has already been expanded and
removed. Design §6 table and D10.

The atp-01 contract supplies `AgentToolPolicyPresetArguments.isSupported` and
`.codexSupportsSessionReuse`.

Follow the shared worker protocol in
`impl-plans/completed/agent-tool-policy-presets.md`.

## Non-goals

- Do not change any existing diagnostic or its order.
- Do not edit resolution, adapters or the model.
- Do not apply the session-reuse rule to `backendPolicy`-selected backends.

## File-level changes

### `Sources/RielaCore/WorkflowNodeValidation.swift` (`validateAgentNodePayload`, lines 3-110)

Add one block guarded by `if let policy = payload.agentToolPolicy, let preset = policy.preset`.

**Place it before `guard payload.provider != nil else { return diagnostics }`
at line 72.** A careless placement after that guard silently skips every check
for payloads without a provider, which is the common case.

Use the file's private `error(_:_:)` helper.

The block emits these diagnostics, with the path written relative to `path`:

1. `policy.mode == .backendDefault` → `.agentToolPolicy.mode`: "cannot be
   combined with agentToolPolicy.preset".
2. `executionBackend` set and `!isSupported(preset, backend:)` →
   `.agentToolPolicy.preset`: "preset '<raw>' is not supported with
   executionBackend '<raw>'".
3. `executionBackend == nil` and `backendPolicy != nil`: for the first
   backend in `backendPolicy.allowed` that is not supported, emit
   `.backendPolicy.allowed`: "backend '<raw>' does not support agentToolPolicy
   preset '<raw>'". This mirrors the `provider` rule at lines 88-93.
4. `executionBackend == nil` and `backendPolicy == nil` →
   `.agentToolPolicy.preset`: "requires an explicit executionBackend".
5. `executionBackend == .codexAgent`, `payload.sessionPolicy?.mode == .reuse`
   and `!AgentToolPolicyPresetArguments.codexSupportsSessionReuse` →
   `.agentToolPolicy.preset`: "cannot be combined with sessionPolicy mode
   'reuse' on codex-agent".

## Tests (`Tests/RielaCoreTests/AgentToolPolicyPresetValidationTests.swift`, XCTest class `AgentToolPolicyPresetValidationTests`)

Imitate `Tests/RielaCoreTests/OpenModelProviderRoutingTests.swift` for
constructing payloads and asserting diagnostics. Assert on the path and the
severity `.error`.

- codex-agent + `none` → no preset diagnostics. The same holds for `mode:
  backend-arguments` and for `mode` omitted.
- codex-agent + `none` + `mode: backend-default` → error at
  `node.agentToolPolicy.mode`.
- cursor-cli-agent + `none`, and cursor-cli-agent + `web-search` → error at
  `.agentToolPolicy.preset`.
- official/cursor-sdk + `web-search` → error. official/cursor-sdk + `none` →
  no error.
- openai, anthropic and gemini SDKs, and claude-code-agent, each with
  `web-search` → no error.
- No backend + `backendPolicy.allowed: [codex-agent, cursor-cli-agent]` +
  preset → error at `.backendPolicy.allowed`. The same with `allowed:
  [codex-agent, claude-code-agent]` → no error.
- No backend and no backendPolicy + preset → error at
  `.agentToolPolicy.preset`.
- A payload with no provider and an unsupported preset still produces the
  error. This proves the block sits before the provider early return.
- codex-agent + reuse + preset → error exactly when
  `codexSupportsSessionReuse == false`. Assert against the constant so the
  test holds either way.
- A policy with no preset (authored arrays only, any backend) → no new
  diagnostics.
- A resolved CLI payload (preset nil, expanded `codexArguments`) → no preset
  diagnostics.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyPresetValidationTests|OpenModelProviderRoutingTests|WorkflowBackendPolicyTests|AgentNodeOutputContractValidationTests" > tmp/agent-tool-policy-preset/atp-04-core-validation/test.log 2>&1'`
  must exit 0 with 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCore/WorkflowNodeValidation.swift Tests/RielaCoreTests/AgentToolPolicyPresetValidationTests.swift > tmp/agent-tool-policy-preset/atp-04-core-validation/swiftlint.log 2>&1'`
  must report 0 violations.

## Done criteria

- All five rules are implemented before line 72's early return.
- Every test above passes.
- The progress log holds the records.
