# atp-05-adapter-websearch: SDK webSearch through GatewayTurnExecutor (RielaAdapters)

```json
{
  "planId": "atp-05-adapter-websearch",
  "planPath": "impl-plans/active/agent-tool-policy-presets-05-adapter-websearch.md",
  "dependsOn": ["atp-01-core-contract", "atp-02-agent-gateway-pin"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
    "Sources/RielaAdapters/GatewayTurnLifetime.swift",
    "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
    "impl-plans/progress/atp-05-adapter-websearch.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

For SDK backends (OpenAI, Anthropic, Gemini, and OpenRouter through
openai-sdk), `preset: "web-search"` must set the vendor's hosted search. It
does this through `GatewayExecuteParams.webSearch = true`. Design §5 and D7.

At agent-gateway v0.1.5, `webSearch` exists only on `GatewayExecuteParams`.
`GatewayAgentDefaults` and the ACP agent's params init do not carry it. Riela
owns the wrapper that receives the final params: `GatewayTurnExecutor`
(`Sources/RielaAdapters/GatewayTurnLifetime.swift:7-25`).

CLI vendors always get `webSearch == false`. Their behavior comes only from
the argv expanded by atp-03.

Follow the shared worker protocol in
`impl-plans/completed/agent-tool-policy-presets.md`.

## Non-goals

- No agent-gateway change and no ACP `_meta` routing.
- No change to `gatewayVendorArguments` argv order, `AdapterUtilities.swift`
  or `agentToolPolicyArguments`.
- Fix API drift from the v0.1.5 bump only in these two source files, and only
  as far as the compiler requires.

## File-level changes

`Sources/RielaAdapters/GatewayTurnLifetime.swift`:

- `GatewayTurnExecutor` gains `private let webSearch: Bool` and
  `init(base: any GatewayExecuting, webSearch: Bool = false)`.
- `execute` copies `params` into a `var`, sets `params.webSearch = webSearch`
  unconditionally (so Riela alone decides the value), and passes the copy to
  `base.execute`.
- Keep the task and cancellation logic exactly as it is.

`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`:

- `GatewayTurnRequest` (line 224) gains `var webSearch: Bool = false` as its
  **last** stored property. The memberwise init keeps working, and `run(_:)`
  at line 204 stays as it is with `false`.
- In `execute`, near line 79, after `let vendor = try gatewayVendor(input.node)`:
  - Fail closed: if `vendor.isCLI && input.node.agentToolPolicy?.preset != nil`,
    throw `AdapterExecutionError(.invalidInput, "agent tool policy preset must be expanded by the host runtime before CLI dispatch")`.
    This enforces design §4's invariant that CLI guests never receive a raw
    preset.
  - Compute `let webSearch = !vendor.isCLI && input.node.agentToolPolicy?.preset == .webSearch`
    and pass `webSearch:` into the `GatewayTurnRequest` at line 115.
- `runGatewayTurn` (line 249):
  `GatewayTurnExecutor(base: executorFactory(request.environment), webSearch: request.webSearch)`.

Pitfall: compare with `== .webSearch`. Never compare
`preset == .none`, which is `Optional.none`; the enum case is `noTools`.

## Tests (`Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift`)

Write swift-testing `@Test` functions named `agentToolPolicyPreset…`. Use the
file's `GatewayStubExecutor` (line 14) and read the captured params with
`params()`. Imitate the OpenRouter provider setup near lines 143-190 and the
vendor table near line 290.

- With `agentToolPolicy: AgentToolPolicy(preset: .webSearch)`, each of these
  → `params.webSearch == true`:
  - official/openai-sdk;
  - official/anthropic-sdk;
  - official/gemini-sdk;
  - official/openai-sdk with an `openrouter` provider. Also assert
    `params.vendor == .openRouter`.
- The same four with `preset: .noTools`, and with no policy →
  `webSearch == false`.
- codex-agent and claude-code-agent with an already-expanded policy (preset
  nil, `codexArguments` or `claudeArguments` holding the preset argv) →
  `webSearch == false`, and `params.arguments` contains that argv in order.
- codex-agent with an unexpanded `preset: .webSearch` → throws
  `.invalidInput`, and `executor.params() == nil` (the vendor is never
  called).
- All existing tests in the file still pass unchanged.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAdaptersTests" > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/test.log 2>&1'`
  must exit 0 with 0 failures. Record the swift-testing counts.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaAdapters/AgentGatewayNodeAdapter.swift Sources/RielaAdapters/GatewayTurnLifetime.swift Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/swiftlint.log 2>&1'`
  must report 0 violations.

If atp-02 logged `blocked: network` and the checkout is still at `dae69561`,
`params.webSearch` will not compile. Record `blocked: dependency-pin` and stop;
serial reconciliation resumes.

## Done criteria

- `grep -n "params.webSearch = webSearch" Sources/RielaAdapters/GatewayTurnLifetime.swift`
  matches.
- `grep -n "webSearch: request.webSearch" Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`
  matches.
- The new tests pass, with records in the progress log.
