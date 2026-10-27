# Agent tool-policy presets (`none` / `web-search`)

Status: implemented 2026-10-27 (plans archived under
`impl-plans/completed/agent-tool-policy-presets*.md`); accepted for
implementation 2026-10-27 (issue-resolution run
`opus-luna-design-and-implement-review-loop-session-503`; the issue was
supplied through `workflowInput`, with no GitHub number). Revised after the
Step 3 review: DR-1 (the SDK `webSearch` seam, §5) and DR-2 (the nil-backend
validation row, §6). Open user decisions:
`design-docs/user-qa/qa-agent-tool-policy-presets.md`.

## 1. Problem

Workflows that run an agent with no tools (for example, summarizing untrusted
input) or with web search only repeat about 45 backend-specific argv entries
per node in `agentToolPolicy.codexArguments` / `claudeArguments`. That
knowledge is generic runtime knowledge. It belongs in Riela and must cover
Codex, Claude Code and the SDK backends (OpenAI, Anthropic, Gemini, OpenRouter).

## 2. Baseline (main @ `812bf19d`)

- `AgentToolPolicy` (`Sources/RielaCore/WorkflowModel.swift:72-125`) has
  `mode` (`backend-default` | `backend-arguments`, informational only),
  `additionalArguments`, `codexArguments`, `claudeArguments` and
  `cursorArguments`.
- `resolveAgentToolPolicy` (`Sources/RielaCore/AgentToolPolicyResolution.swift`)
  renders one-pass templates on the host and enforces the trusted-variables
  rule. Its only production caller is
  `Sources/RielaCore/DeterministicWorkflowRunner.swift:643`. It runs before
  `validateAgentNodePayload(executionPayload)` (line 657) and before
  `guardAgentPrompt`. The resolved `executionPayload` is the payload that local
  adapters, sandbox and container guests (`SandboxNodeWorker`), and remote
  workers receive.
- `agentToolPolicyArguments` (`Sources/RielaAdapters/AdapterUtilities.swift:122`)
  emits `additionalArguments + <backend>Arguments` for CLI backends only.
- `gatewayVendorArguments` (`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:597`)
  builds the CLI argv in this order: effort/sandbox/images, then tool-policy
  arguments, then the `<vendor>AdditionalArgs` variable, then (Codex only)
  `--enable|--disable multi_agent`. agent-gateway places these after its own
  fixed prefix (`codex exec --json --model M … -`; `claude -p --output-format
  stream-json … --model M …`, with the prompt sent on stdin).
- SDK vendors receive no argv. Execution goes through `GatewayAgentDefaults`,
  and the gateway builds `GatewayExecuteParams`.
- `AgentToolPolicy` is not exposed in GraphQL SDL, DTOs or any JSON schema.
  `grep codexArguments` matches only Core/Adapters sources and tests. No
  surface needs regenerating.
- `design-execution-environment-consolidation.md` plans to replace
  `AgentToolPolicy` with `policy.agent.extraArguments`. That work is proposed
  but not implemented. This design extends the current type. When the
  consolidation lands, `preset` moves to `policy.agent` with the same
  semantics (§10).

## 3. Data model

`AgentToolPolicy` gains `preset: AgentToolPolicyPreset?`.

- `AgentToolPolicyPreset` is a closed `String` enum: `none` = `"none"` and
  `webSearch` = `"web-search"`. Decoding an unknown value throws, which fails
  the payload decode and therefore the workflow load. Nothing falls back
  silently.
- Encoding uses `encodeIfPresent`, so payloads without a preset encode exactly
  as they do today.
- `mode` stays optional. With a preset, an omitted `mode` or
  `backend-arguments` is valid. `backend-default` is a validation error (§6).
- No other field is added.

## 4. Host-side resolution (the only expansion point)

`resolveAgentToolPolicy` gains the node's `executionBackend` and its session
mode as inputs (`sessionPolicy?.mode == .reuse`). The call site at
`DeterministicWorkflowRunner.swift:643` passes them from `executionPayload`.
Order inside the function:

1. Render authored templates exactly as today. Preset arguments are literal
   constants and never pass through the template renderer. This matters
   because values such as `{"mcpServers":{}}` must reach argv verbatim.
2. If `preset == nil`, return the policy. Behavior is unchanged.
3. Switch on `executionBackend`:
   - `codex-agent`: set
     `codexArguments = codexPresetArguments(preset, reuse) + additionalArguments + codexArguments`.
   - `claude-code-agent`: set
     `claudeArguments = claudePresetArguments(preset) + additionalArguments + claudeArguments`.
   - For both CLI backends, set `additionalArguments = []` and `preset = nil`,
     and leave `mode` unchanged. Folding `additionalArguments` in keeps the
     final argv order "preset, then authored generic, then authored
     backend-specific", which `agentToolPolicyArguments` would otherwise put
     before the preset. It also leaves a guest with nothing to reinterpret.
   - SDK backends (`official/openai-sdk`, `official/anthropic-sdk`,
     `official/gemini-sdk`, plus `official/cursor-sdk` with `none`): return
     the policy unchanged, with `preset` kept.
   - `cursor-cli-agent`, `official/cursor-sdk` with `web-search`, or a nil
     backend: throw `AdapterExecutionError(.invalidInput, "agent tool policy
     preset '<p>' is not supported with executionBackend '<b>'")`. This is
     defense in depth behind load-time validation, and it also covers
     dynamically generated nodes (§7).

Why it happens on the host: sandbox and container guests may embed an older
Riela that does not know `preset`. After this step, a CLI payload has no
`preset` key and only explicit argv, so a guest cannot silently run with
default tools. SDK payloads keep `preset` because the adapter needs it (§5).
The current `AgentToolPolicy` decoder ignores unknown keys, so an old guest
running an SDK node drops `preset`. It then sends a request with no tools.
That loses `web-search` but never adds a tool.

The expanded payload is the `executionPayload` that the runtime records and
dispatches. Step-execution evidence therefore shows the concrete argv.
Runtime records stay owned by the runtime store.

### 4.1 Codex argv (one constant list, with a comment naming the CLI version)

The argv lives in one place, `AgentToolPolicyResolution.swift`, as a single
ordered list with a header comment recording "verified against codex-cli
0.164.0 via `codex features list` and `codex exec [resume] --help`":

```
--ignore-user-config
--ignore-rules
--strict-config
-c web_search="disabled"            # none
-c web_search="live"                # web-search (the only difference)
-c tools.experimental_request_user_input.enabled=false
-c tools.update_plan.enabled=false
-c mcp_servers={}
--skip-git-repo-check
--ephemeral                         # omitted when sessionPolicy.mode == reuse
--disable <feature>                 # one pair per feature, see below
```

- Every element is a separate argv element, with no shell quoting. For
  example, `-c` and `web_search="disabled"` are two elements, and the value
  keeps its literal TOML quotes.
- The `--disable` list starts from the issue's names: `shell_tool`,
  `unified_exec`, `view_image`, `apps`, `plugins` and `goals`. The issue elided
  the rest with "…". The implementer completes the list with every other
  tool-providing feature that `codex features list` reports on 0.164.0, and
  drops any name the CLI rejects. Every kept name must be accepted, because an
  unknown `--disable` name aborts the run. The final list and the CLI output
  that justifies it go into the implementation evidence and the code comment.
- `multi_agent` is not in the preset list. The adapter's existing
  `--disable multi_agent` already applies by default. The
  `--supervisor-mode` case is user-QA Q1.
- `--ephemeral` is left out for reuse nodes. A reuse node's first turn is a
  fresh `codex exec`, and later turns run `codex exec resume <id>`. An
  ephemeral session is not persisted and cannot be resumed.
- Resume compatibility: agent-gateway passes every non-`--sandbox` argument
  after `codex exec resume`. The implementer checks `codex exec resume --help`.
  If resume rejects any kept flag, `validateAgentNodePayload` also rejects
  `preset` combined with `sessionPolicy.mode: reuse` on `codex-agent`, and the
  rejection is documented here. Per-turn argv variants are not allowed.

### 4.2 Claude Code argv

Checked against `claude --help` of Claude Code 2.1.306 on 2026-10-27:
`--tools <tools...>` ("Use \"\" to disable all tools"), `--strict-mcp-config`,
`--mcp-config <configs...>`, `--disable-slash-commands`,
`--setting-sources <sources>` (a comma-separated list) and
`--allowedTools <tools...>` all exist.

```
none:        --tools ""  --strict-mcp-config  --mcp-config {"mcpServers":{}}  --disable-slash-commands  [--setting-sources ""]
web-search:  --tools WebSearch  --allowedTools WebSearch  --strict-mcp-config  --mcp-config {"mcpServers":{}}  --disable-slash-commands  [--setting-sources ""]
```

- `""` is one empty argv element. `--tools` and `--mcp-config` take several
  values, but each is followed by another `--` option in this list. agent-gateway
  sends the prompt on stdin, so no positional argument can be swallowed.
- `--setting-sources ""` is included only if the live smoke check shows that
  2.1.306 accepts an empty value. `--help` does not say. Otherwise it is left
  out, and the evidence records why.
- `--allowedTools WebSearch` is in the `web-search` preset only. Without it,
  print mode can deny WebSearch when it needs permission, which would turn
  `web-search` into a silent `none`. It allows no other tool, because
  `--tools` already limits the set to WebSearch.

## 5. SDK backends (agent-gateway `webSearch`)

- Move the agent-gateway pin in `Package.swift:71-72` and `Package.resolved`
  from `dae69561f05b75be6d680af1267da1af9db16d13` to
  `fbb7d8519683d838d1f603480d5ec7a52700fe0e` (tag v0.1.5). No other
  dependency moves.
- agent-gateway v0.1.5 facts (fbb7d851, confirmed by the Step 3 review):
  - `GatewayExecuteParams.webSearch` is `public var webSearch: Bool`. It
    defaults to `false` and decodes as `decodeIfPresent ?? false`
    (`Sources/AgentGateway/GatewayProtocol.swift:132,152,216`).
  - `GatewayAgentDefaults` (`Sources/AgentGatewayAppCore/GatewayACPAgent.swift:8-41`)
    has no `webSearch` field. The ACP agent's `GatewayExecuteParams(...)`
    initializer (`GatewayACPAgent.swift:273`) does not pass it, and ACP
    `_meta` does not carry it either.
  - The cursor API builder throws when `webSearch` is true
    (`Sources/AgentGatewayAppCore/GatewayAPIRequest.swift:161`). That agrees with the
    §6 rule that `official/cursor-sdk` + `web-search` is an error.
- Riela-owned seam: `GatewayTurnExecutor`
  (`Sources/RielaAdapters/GatewayTurnLifetime.swift:7-25`). It wraps the base
  executor, and its `execute(_ params: GatewayExecuteParams, …)` receives the
  final params that the ACP agent built. Data flow:
  1. `AgentGatewayNodeAdapter.execute` (`AgentGatewayNodeAdapter.swift:79-124`)
     computes `webSearch = !vendor.isCLI && input.node.agentToolPolicy?.preset == .webSearch`.
  2. `GatewayTurnRequest` (`AgentGatewayNodeAdapter.swift:224`) gains
     `var webSearch: Bool`, which defaults to `false`. The adapter sets it at
     `:115`. The direct `run(_:)` call at `:204` keeps the default `false`.
  3. `runGatewayTurn` (`:237-249`) builds
     `GatewayTurnExecutor(base: …, webSearch: request.webSearch)`.
  4. `GatewayTurnExecutor.execute` copies `params`, sets
     `params.webSearch = webSearch` and then calls `base.execute`. When the
     flag is `false` it still writes `false`, so the turn's value is decided
     only by Riela.
  No agent-gateway change is planned, and nothing is routed through ACP
  `_meta`. CLI vendors always get `webSearch == false`. Their search
  behavior is decided only by the argv from §4.
- Vendor mapping belongs to agent-gateway and is not reimplemented: OpenAI
  `web_search`, Anthropic `web_search`, Gemini `google_search`, and the
  OpenRouter `web` plugin (OpenRouter is selected by `official/openai-sdk` with
  `provider.name == "openrouter"`, see `gatewayVendor`).
- `none` on SDK backends changes nothing in the request: the API requests
  already send no tools.
- If the bump changes other agent-gateway APIs used by Riela, adapt only the
  call sites the compiler requires.

## 6. Validation (`validateAgentNodePayload`)

Errors are reported at `<path>.agentToolPolicy.preset`. They apply at load
(`WorkflowValidation`, the registry loader and `workflow validate`) and again
on the resolved payload at run time.

| Condition | Result |
|---|---|
| `preset` set and `mode == backend-default` | error: "cannot be combined with mode 'backend-default'" (path `.agentToolPolicy.mode`) |
| `preset` set and backend `cursor-cli-agent` | error: unsupported backend |
| `preset == web-search` and backend `official/cursor-sdk` | error: unsupported backend |
| `preset == none` and backend `official/cursor-sdk` | accepted (the API sends no tools) |
| `preset` set, no `executionBackend`, `backendPolicy.allowed` contains an unsupported backend | error at `.backendPolicy.allowed`, mirroring the existing `provider` rule |
| `preset` set, with neither `executionBackend` nor `backendPolicy` | error: "requires an explicit executionBackend" (mirrors the existing `provider` rule; keeps load-time validation and the §4 nil-backend throw consistent, including mock runs) |
| codex-agent, `preset` set and `sessionPolicy.mode == reuse` | error only if the §4.1 resume check finds a rejected flag |

An unknown preset value never gets this far, because decoding fails first.

## 7. Other touch points

- `promptSpillFilesAreAccessible`
  (`DeterministicWorkflowRunner+PromptGuard.swift:149`): a policy also counts
  as custom when `preset != nil`. CLI presets have already been expanded into
  non-empty argv, so this matters for any non-expanded path, and the issue
  asks for it explicitly.
- Dynamic workflows (`DeterministicWorkflowRunner+DynamicWorkflow.swift:99`)
  copy the emitter's raw, unexpanded `agentToolPolicy` onto generated nodes.
  Each generated node expands it against its own backend when it runs. An
  unsupported generated backend throws in §4 step 3. No change is needed.
- `agentToolPolicyArguments` and the codex/claude command builders stay
  unchanged.

## 8. Docs

Add a "Tool-policy presets" subsection to
`docs/workflows/declarative-data-and-private-agents.md`, after the tool-policy
trust rule, with three examples: Codex `none`, Claude Code `web-search`, and
Gemini SDK (`official/gemini-sdk`) `web-search`. Also cover the
backend-support table, the "authored arguments come after the preset" rule,
and the host-expansion and guest rule. Update the `agentToolPolicy` bullet in
`design-workflow-json.md` to mention `preset` and link here.

## 9. Verification

Unit tests. Resolution and validation tests are XCTest in `RielaCoreTests`.
Adapter tests use swift-testing functions named `agentToolPolicyPreset…`.

- `AgentToolPolicyResolutionTests`: exact codex argv for `none` and
  `web-search`, plus the reuse variant without `--ephemeral`; exact claude argv
  for both; authored `additionalArguments` and backend arguments appended after
  the preset in that order; `preset == nil` and `additionalArguments == []`
  after CLI resolution; SDK policy returned unchanged; cursor-cli, cursor-sdk
  `web-search` and nil backend throw; templates in authored arguments still
  resolve, and preset literals are not template-rendered.
- New `AgentToolPolicyPresetValidationTests`: every row of the §6 table;
  unknown preset (`"shell"`) fails `JSONDecoder` decode of `AgentToolPolicy`
  and of `AgentNodePayload`; preset round-trips through encoding.
- `AgentPromptGuardTests`: a preset-only policy is custom.
- `RielaAdaptersTests` swift-testing functions named `agentToolPolicyPreset…`.
  `GatewayStubExecutor` (`Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift:14`)
  captures the `GatewayExecuteParams` that reach the base executor through
  `GatewayTurnExecutor`.
  - `params.webSearch == true` for `official/openai-sdk`,
    `official/anthropic-sdk`, `official/gemini-sdk` and `official/openai-sdk`
    with `provider.name == "openrouter"` when the preset is `web-search`.
  - `params.webSearch == false` for the same SDK vendors with `none` and with
    no preset.
  - `params.webSearch == false` for CLI vendors (`codex-agent`,
    `claude-code-agent`).

Commands, run from the repo root:

- `arch -arm64 /bin/zsh -lc 'swift build'`
- `arch -arm64 /bin/zsh -lc "swift test --filter '[Aa]gentToolPolicy|AgentPromptGuardTests|WorkflowBackendPolicyTests|OpenModelProviderRoutingTests'"`
- `arch -arm64 /bin/zsh -lc 'swiftlint'`

Live smoke checks. Workflows and logs go in `tmp/agent-tool-policy-preset/`
and are never committed.

- `codex-none.json`: a codex-agent node with `preset: "none"` and output
  schema `{"ok": true}`. Run it with
  `riela workflow run --workflow-json-file …` and the source-built binary.
  It must succeed on codex-cli 0.164.0.
- `claude-none.json`: the same check with claude-code-agent on Claude Code
  2.1.306. Run it once with `--setting-sources ""` to decide §4.2.
- Gemini: not run, because `GEMINI_API_KEY` is unset. The final report must
  say so.

Not in scope: VERSION bump, release, other dependency bumps, SDL
regeneration (none is affected), and cursor support.

## 10. Rollout constraints

- `preset` is additive, and payloads without it behave and encode exactly as
  before.
- A new host with an old guest is safe. CLI presets are expanded and removed
  before dispatch, and an SDK guest that ignores `preset` only loses web
  search (§4).
- An old host (a Riela build older than this change) ignores the unknown
  `preset` key, so it runs a CLI node with that CLI's default tools. Workflows
  that rely on `preset` therefore need a Riela build that includes this change.
  Version gating is out of scope (user-QA Q2).
- When `design-execution-environment-consolidation.md` lands, `preset` moves
  to `policy.agent` with this design's semantics. Nothing is designed for
  that move now.
