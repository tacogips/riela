# atp-02-agent-gateway-pin progress

## Implementation

- Changed only the `agent-gateway` revision in `Package.swift:72` from
  `dae69561f05b75be6d680af1267da1af9db16d13` to
  `fbb7d8519683d838d1f603480d5ec7a52700fe0e`.
- `swift package resolve` generated `Package.resolved`; its diff contains only
  the top-level `originHash` and the `agent-gateway` revision. The resolved
  checkout is `fbb7d8519683d838d1f603480d5ec7a52700fe0e`.
- v0.1.5 facts for atp-05:
  - `GatewayExecuteParams.webSearch` is public at
    `.build/checkouts/agent-gateway/Sources/AgentGateway/GatewayProtocol.swift:132`;
    the initializer defaults it to `false` at `:152`, and decoding defaults a
    missing key to `false` at `:216`.
  - `GatewayAgentDefaults` has no `webSearch` field in
    `.build/checkouts/agent-gateway/Sources/AgentGatewayAppCore/GatewayACPAgent.swift:8-41`;
    its ACP `GatewayExecuteParams` call at `:273` does not pass that field.
  - Cursor API rejects `params.webSearch == true` at
    `.build/checkouts/agent-gateway/Sources/AgentGatewayAppCore/GatewayAPIRequest.swift:161-162`.

## Verification

| Command | Exit | Log / result |
| --- | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift package resolve > tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/resolve.log 2>&1'` | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/resolve.log` |
| `git diff --stat Package.swift Package.resolved` | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/diff-stat.log`; exactly two files. |
| `git diff -- Package.resolved` | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/package-resolved-diff.log`; only `originHash` and the agent-gateway revision changed. |
| `grep -c fbb7d8519683d838d1f603480d5ec7a52700fe0e Package.swift Package.resolved` | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/new-revision-count.log`; count is 1 for each file. |
| `grep -c dae69561 Package.swift Package.resolved` | 1 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/old-revision-count.log`; expected no-match exit, count is 0 for each file. |
| v0.1.5 source inspection and checkout revision | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/source-facts.log`; records checkout HEAD and line-numbered API facts. |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/build.log 2>&1'` | 1 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/build-retry-01.log 2>&1'` | 0 | `tmp/agent-tool-policy-preset/atp-02-agent-gateway-pin/build-retry-01.log`; build passed after the sibling-owned initializer order was corrected. |

The first build attempt reported `argument 'mode' must precede argument
'preset'` in sibling-owned `Sources/RielaCore/WorkflowModel.swift:119`. This
plan did not edit that file. The owning worker corrected the initializer order;
the retry above passed on the updated shared tree.

## Completion

- [x] Package.swift and Package.resolved pin the requested v0.1.5 revision;
      old revision is absent and no other dependency moved.
- [x] v0.1.5 facts and line numbers recorded for atp-05.
- [x] Resolve completed successfully.
- [x] Build passes after the sibling-owned initializer-order correction.
