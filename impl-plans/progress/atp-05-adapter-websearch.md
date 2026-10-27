# atp-05-adapter-websearch progress

Status: implementation complete and required behavioral verification passed on the current shared source. Formal integration review and serial branch finalization remain downstream workflow steps.

## Implementation

- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`: fail closed with `.invalidInput` if a CLI vendor receives an unexpanded preset; compute SDK `webSearch` only for `.webSearch`; carry it in `GatewayTurnRequest` (default false); pass it from `runGatewayTurn` into `GatewayTurnExecutor`.
- `Sources/RielaAdapters/GatewayTurnLifetime.swift`: store the turn's webSearch value and assign `params.webSearch` unconditionally before calling the base executor. Task and cancellation ownership are unchanged.
- `Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift`: added swift-testing coverage for web-search on OpenAI, Anthropic, Gemini, and OpenRouter; false for none/no policy; expanded Codex/Claude argv preservation; and raw CLI preset rejection before vendor invocation.

## Current-source verification

| Command | Exit | Tests | Failures | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build --target RielaAdapters > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/build-target.log 2>&1'` | 0 | 0 | 0 | `tmp/agent-tool-policy-preset/atp-05-adapter-websearch/build-target.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/agent-tool-policy-preset/atp-05-adapter-websearch/changed-swift-files-step6.nul > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/swiftlint-step6-final.log 2>&1'` | 0 | 0 | 0 | Exact changed-file set in `changed-swift-files-step6.nul`; empty log at `tmp/agent-tool-policy-preset/atp-05-adapter-websearch/swiftlint-step6-final.log`. |
| `grep -n 'params.webSearch = webSearch' Sources/RielaAdapters/GatewayTurnLifetime.swift > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/websearch-assignment-step6.log` | 0 | 0 | 0 | Match at line 22. |
| `grep -n 'webSearch: request.webSearch' Sources/RielaAdapters/AgentGatewayNodeAdapter.swift > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/websearch-request-step6.log` | 0 | 0 | 0 | Match at line 258. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAdaptersTests" > tmp/agent-tool-policy-preset/atp-05-adapter-websearch/test-step6-final.log 2>&1'` | 0 | 30 | 0 | `test-step6-final.log`: 30 tests passed, including the new preset adapter tests. |

Current adapter source hashes: `AgentGatewayNodeAdapter.swift` `190f80fae6bf97e8e3cb002e455da4395f66104dd64bd822cc32c0499734276d`; `GatewayTurnLifetime.swift` `300e5b3c031692faeb659a029fc0454240cd416cc01bc7fdf4b3cec11d8887bf`; `AgentGatewayNodeAdapterTests.swift` `47e425c9c276985d4c914c22c739d0922c5e07e3afdd97e4c54630bc8982b468`.

`changed-swift-files.nul` contains exactly the three Swift paths owned by this plan. Strict lint completed with an empty log (0 violations).

## Earlier attempts (superseded)

The first focused suite attempt, `tmp/agent-tool-policy-preset/atp-05-adapter-websearch/test.log`, exited 1 because two new test initializers had `provider` before `agentToolPolicy`. The argument order was corrected. Subsequent attempts reached sibling validation test compile errors; atp-04 repaired those errors. `test-final.log` remains a historical failed attempt and is superseded by the successful current-source `test-step6-final.log` above.

## Handoff

Implementation handoff is complete. No formal review, shared docs, staging, commit, or push work is claimed here; those belong to later workflow steps.
