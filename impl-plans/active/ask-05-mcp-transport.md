# ask-05-mcp-transport: `mcpServers` on the adapter input, `riela ask tool-server`, `mcp` policy argv

```json
{
  "planId": "ask-05-mcp-transport",
  "planPath": "impl-plans/active/ask-05-mcp-transport.md",
  "dependsOn": [
    "ask-04-surfaces"
  ],
  "wave": 4,
  "writePaths": [
    "Sources/RielaAdapters",
    "Sources/RielaCLI/Ask",
    "Sources/RielaCore/Ask",
    "Sources/RielaCore/AdapterContracts.swift",
    "Sources/RielaCore/AgentToolPolicyPresetArguments.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsAsk.swift",
    "Sources/RielaCLI/BotRuntime/BotMemoryRuntime.swift",
    "Sources/RielaCLI/CLISubcommandHelp.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift",
    "Tests/RielaAdaptersTests",
    "Tests/RielaCLITests/Ask",
    "Tests/RielaCoreTests/Ask",
    "Tests/RielaCoreTests/AgentToolPolicyPresetContractTests.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Tests/RielaCLITests/SubcommandHelpTests.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift",
    "impl-plans/progress/ask-05-mcp-transport.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCLI/BotRuntime/BotMemoryRuntime.swift",
      "intendedEdit": "Only to expose the secret-name rule of `redactionRules(environment:)` as one reusable function (for example `static func isSecretName(_:) -> Bool`) that `redactionRules` itself calls; no behaviour change."
    },
    {
      "path": "Sources/RielaCore/AdapterContracts.swift",
      "intendedEdit": "Add `AdapterMCPServer` and `AdapterExecutionInput.mcpServers` (default empty, decoded with a default)."
    },
    {
      "path": "Sources/RielaCore/AgentToolPolicyPresetArguments.swift",
      "intendedEdit": "Add a `keepClientMCPServers: Bool = false` parameter to `cliArguments` and the codex and claude helpers."
    },
    {
      "path": "Sources/RielaCore/SurfaceCatalog+RowsAsk.swift",
      "intendedEdit": "Add the `ask.tool-server` row."
    },
    {
      "path": "Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift",
      "intendedEdit": "Only to make the existing bundled `riela` lookup (line 235) callable from the RielaApp host; no behaviour change."
    },
    {
      "path": "Sources/RielaCLI/ServeWebHost.swift",
      "intendedEdit": "Pass the running executable's absolute path into `AskHost`."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2. Design: §1 (gateway facts),
§5.3 (`mcp`), §10.1, §13 (`ask.tool-server`), §15.

## Intent and context

codex and claude can call tools themselves when the gateway hands them a
stdio MCP server. This plan gives them the same `AskToolExecutor` through
that mechanism, so tool use is native for those two backends. Every other
backend keeps the `rounds` transport from plan 03.

Facts (verified):

- The pinned gateway hands client stdio MCP servers to the vendor CLI only
  for `claudeCode` and `codex`
  (`.build/checkouts/agent-gateway/Sources/AgentGatewayAppCore/GatewayACPMCP.swift:20`).
- `ACPNewSessionRequest(cwd:mcpServers:...)` and
  `ACPV2NewSessionRequest(cwd:additionalDirectories:mcpServers:...)` both
  accept servers. Riela passes `mcpServers: []` in
  `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:371` and passes none
  in `Sources/RielaAdapters/AgentGatewayACPV2Turn.swift:38`.
- The `none` preset empties the vendor MCP configuration:
  `Sources/RielaCore/AgentToolPolicyPresetArguments.swift:71` (codex
  `-c mcp_servers={}`) and `:89-91` (claude `--strict-mcp-config`
  `--mcp-config {"mcpServers":{}}`).
- `AskAgentPolicy.payload` (plan 03) resolves the preset to argv with
  `resolveAgentToolPolicy`.

## Non-goals

- No pin change, no gateway patch.
- No MCP for cursor or API backends.
- No MCP features beyond `initialize`, `tools/list`, `tools/call` (and the
  `notifications/initialized` notification, which is accepted and ignored).
- Workflow nodes never set `mcpServers`; no workflow schema change.
- No deterministic test of a live vendor CLI.

## Changes

### 1. Adapter input (`Sources/RielaCore/AdapterContracts.swift`, `Sources/RielaAdapters`)

- `public struct AdapterMCPServer: Codable, Equatable, Sendable { name: String, command: String, arguments: [String], environment: [String: String] }`.
- `AdapterExecutionInput.mcpServers: [AdapterMCPServer]`, default `[]`, last
  parameter of the initializer with a default, decoded with
  `decodeIfPresent ?? []` so stored or remote inputs without the key still
  decode.
- `AgentGatewayNodeAdapter` maps the list to the gateway stdio server type
  in both `session/new` requests (v1 line 371, v2 in
  `AgentGatewayACPV2Turn.swift:38`). A relative `command` →
  `AdapterExecutionError(.invalidInput, ...)` before any request. Backends
  whose gateway vendor does not connect to MCP servers and a non-empty list →
  `invalidInput` (the engine never does this; the check keeps a wrong caller
  from silently losing its tools).

### 2. Policy argv (`AgentToolPolicyPresetArguments.swift`, `Sources/RielaCLI/Ask/Engine`)

- `cliArguments(_:backend:sessionReuse:keepClientMCPServers:)`: with `true`
  and preset `none`, codex omits the `-c mcp_servers={}` argument; claude
  keeps `--strict-mcp-config` and omits the empty `--mcp-config` argument
  pair (the gateway supplies its own `--mcp-config`). Default `false` keeps
  today's output byte for byte.
- `AskAgentPolicy.payload(... transport: .mcp ...)`: builds the policy from
  `cliArguments(.noTools, backend:, sessionReuse: false, keepClientMCPServers: true)`
  directly into `codexArguments` / `claudeArguments` (no preset left on the
  payload); for claude it also appends `--allowedTools` with the ask tool
  names in the form the claude CLI uses for MCP tools
  (`mcp__riela-ask__<tool>`, comma separated). Sandbox stays read-only.
- Verify the flags against the CLI versions noted at the top of
  `AgentToolPolicyPresetArguments.swift`; record what was checked in the
  progress log. If a flag cannot be confirmed from that file or the vendor
  `--help` output, keep the argument set above and list it under
  `Open items` for the operator's live check.

### 3. Transport selection (`Sources/RielaCLI/Ask/Engine`)

- `AskHost.rielaExecutablePath: String?` (absolute). CLI hosts: the running
  executable resolved to an absolute path. RielaApp: the bundled `riela`
  from the existing lookup in `DaemonWorkflowEventServeProcess.swift:235`;
  `nil` when it does not exist.
- `AskToolTransportSelection.select(backend:rielaExecutablePath:environment:) -> AskToolTransport`:
  `mcp` when the backend is `codexAgent` or `claudeCodeAgent`, the path is
  non-nil and absolute, `RIELA_ASK_TOOL_TRANSPORT != "rounds"`, and
  `RIELA_ASK_SCRIPTED_BACKEND` is unset; otherwise `rounds`. The result is
  stored on the turn.
- `mcp` turn: one adapter call. `mcpServers` holds one server:
  name `riela-ask`, command = the path, arguments
  `["ask", "tool-server", "--session-store", <root>, "--working-dir", <dir>, "--conversation", <id>, "--turn", <turnId>, "--redaction-values", <file>]`
  plus `"--scope", <scope>` when the host has a scope, and the environment
  hand-off below. The system prompt for this transport drops the
  line-protocol section and says the tools are available as MCP tools; the
  rest is the same constant text. Backend `activity` events (message,
  thought, plan, usage, stop) are recorded as is. The answer is the output
  text of the call. Tool-call activity comes from the tool-server process
  through the store, not from the backend.

### 3a. Host parity hand-off (`Sources/RielaCLI/Ask/Engine`)

The tool server must read the same records and redact the same values as
the in-process path. Hosts keep their effective environment in a dictionary
(`AskHost.environment`) that differs from the real process environment:
`Sources/RielaApp/RielaAppWebGraphQL.swift:33-36` sets `HOME` and
`RIELA_WORKFLOW_HOME`, `Sources/RielaCLI/ServeWebHost+Configuration.swift:33-36`
sets `RIELA_WORKFLOW_HOME`, and
`CLIRuntimeEnvironment.mergedProcessEnvironment()`
(`Sources/RielaWorkflowRegistry/CLIRuntimeEnvironment.swift:8-16`) adds
captured and override values. The gateway forwards only variables listed on
the server entry.

- `AskToolServerHandoff.environment(from host: [String: String]) -> [String: String]`
  builds `AdapterMCPServer.environment`: `HOME`, `RIELA_WORKFLOW_HOME`, and
  every other key that starts with `RIELA_` or `XDG_`, taken from
  `AskHost.environment`. A key is excluded when it is secret-named by the
  rule of `BotMemoryRuntime.redactionRules(environment:)`
  (`Sources/RielaCLI/BotRuntime/BotMemoryRuntime.swift:14`): split the
  upper-cased name on `_`; any part equal to `KEY`, `TOKEN`, `SECRET`,
  `PASSWORD` or `CREDENTIAL` excludes it. Reuse that rule through one shared
  function; do not write a second list. Also excluded:
  `RIELA_ASK_SCRIPTED_BACKEND` and `RIELA_ASK_TOOL_TRANSPORT`.
- Scope: the scope value the host used to build `AskReadProviders` is passed
  as `--scope`; the session store root and working directory are passed as
  today. The tool server calls
  `AskReadProviders.local(workingDirectory:sessionStore:scope:environment:)`
  with the same four inputs as the in-process path.
- Redaction values file: before the adapter call the host writes the secret
  values that `BotMemoryRuntime.redactionRules(environment: AskHost.environment)`
  binds (value and variable name pairs, JSON) to
  `<scratchRoot>/redaction/<conversationId>-<turnId>.json`. The directory is
  created with mode 0700, the file with mode 0600 and `O_NOFOLLOW`, written
  before the path is handed out. It is outside the turn working directory,
  so the model's read-only sandbox directory never contains it. Its path is
  the `--redaction-values` argument. The file is removed on every terminal
  path of the turn (completed, cancelled, timeout, provider error) in the
  same `defer` that removes the working directory, and by stale-turn
  recovery (`failStaleAskTurn` returning `true` removes the file of that
  turn). No secret value is placed in `AdapterMCPServer.environment`, in
  the arguments, or in any vendor configuration; only the path is.
- `rounds` turns write no values file.

### 4. Tool server (`Sources/RielaCLI/Ask/ToolServer/`, new)

- `riela ask tool-server --session-store <root> --working-dir <dir> --conversation <id> --turn <turnId> [--scope <scope>] [--redaction-values <file>]`:
  reads newline-delimited JSON-RPC 2.0 from stdin, writes responses to
  stdout, nothing else on stdout. Exits 0 when stdin closes.
- Effective environment: the process environment, which already holds the
  handed-off variables because the vendor CLI starts the server with them
  (§3a). Read providers and redaction are built from that environment; the
  server never substitutes a default `HOME` or registry root of its own.
- Redaction: rules = `BotMemoryRuntime.redactionRules(environment:)` of the
  effective environment merged with the pairs read from
  `--redaction-values`. Extend `AskRedaction` with an
  `additionalValues: [String: String]` input for this; the in-process path
  passes none. The file is read once at startup; a path that is given but
  unreadable → exit non-zero with `redaction_values_unavailable` on stderr
  (never run with weaker redaction). The values are held in memory only and
  never written to stdout, stderr or activity.
- Startup: the conversation's turn must be `running` with that id, else exit
  non-zero with `turn_not_running` on stderr.
- `initialize` → protocol version echo, `capabilities: { tools: {} }`,
  `serverInfo { name: "riela-ask", version: <riela version> }`.
- `tools/list` → every descriptor of `AskToolSet.all` (read tools and
  proposal tools) with a JSON Schema built from the descriptor.
- `tools/call` → `AskToolExecutor.execute` with a generated tool call id;
  result as one text content item holding the JSON of `AskToolResult`;
  `isError` mirrors `!ok`. Unknown method → JSON-RPC error `-32601`;
  malformed request → `-32600`.
- It builds the executor from `AskReadProviders.local(...)` with the
  handed-off scope, the store and the effective environment, with the same
  inputs as the in-process path. No mutation surface is constructed in this
  process.
- Catalog row `ask.tool-server`: kind stream, CLI `ask tool-server`,
  GraphQL excluded ("local stdio process started by the vendor CLI"),
  options `--session-store`, `--working-dir`, `--conversation`, `--turn`,
  `--scope`, `--redaction-values`.
  Wire the verb in enumeration, help and dispatch (hidden from the short
  help summary if the help file supports that; otherwise one line).

## Imitate

- `Tests/RielaAdaptersTests/GatewayScriptedAgentTests.swift` and
  `AgentGatewayACPV2Tests.swift` for scripted ACP agents asserting request
  content.
- `Tests/RielaCoreTests/AgentToolPolicyPresetContractTests.swift` for argv
  assertions.
- Any existing stdio JSON line loop in `Sources/RielaCLI`
  (`grep -rn "readLine" Sources/RielaCLI`) for reading stdin.

## Pitfalls

- The default argv (`keepClientMCPServers: false`) must not change; workflow
  nodes depend on it.
- Never write logs to stdout in the tool server; stdout is the protocol.
- Budgets and the "turn is running" check happen in the store, so a tool
  server that outlives its turn can do nothing.
- The host environment dictionary is not the process environment (`HOME`,
  `RIELA_WORKFLOW_HOME` differ under `riela serve` and RielaApp). A tool
  server that resolves from its inherited environment alone reads the CLI's
  `~/.riela` instead of the host profile and answers about the wrong
  records.
- Redaction must be identical in both transports for the same host. A
  secret that exists only in `AskHost.environment` must still be redacted
  by the tool server; that is what the values file is for.
- Never put a secret value in `AdapterMCPServer.environment`, in the
  tool-server arguments or in vendor configuration: they appear in vendor
  argv and process listings. Only non-secret routing variables and the
  values file path are handed over.
- Remove the values file on every terminal path; a leftover file is a
  stored copy of secrets.
- `RIELA_ASK_TOOL_TRANSPORT=rounds` and the scripted backend must both force
  `rounds`, otherwise the example and the engine tests change behaviour on a
  machine that has codex installed.
- Do not fall back from `mcp` to `rounds` inside a turn; the transport is
  chosen once and recorded.

## Tests

`Tests/RielaAdaptersTests` (new cases in the scripted-agent suites):
- input with one `AdapterMCPServer` → the v1 `session/new` params carry it
  (name, command, args); same for v2.
- empty list → request equal to today's.
- relative command → `invalidInput`, no request sent.
- decoding an `AdapterExecutionInput` JSON without `mcpServers` → `[]`.

`AgentToolPolicyPresetContractTests`:
- codex `none` with `keepClientMCPServers: true` → no argument contains
  `mcp_servers`; every other argument equals the default output.
- claude `none` with `true` → contains `--strict-mcp-config`, contains no
  `--mcp-config`.
- both with `false` → equal to the existing expected arrays.

`Tests/RielaCLITests/Ask/ToolServer/AskToolServerTests.swift` (pipes, real
store with a running turn):
- `initialize` then `tools/list` → 17 tools, each with an `inputSchema`.
- `tools/call session_status` → text content parses to `ok == true`; one
  `toolCall` activity pair recorded under `ask:<id>`.
- `tools/call` for an unknown tool → content with `tool_unknown`,
  `isError == true`.
- turn not running at startup → non-zero exit, `turn_not_running`.
- `toolCallsPerTurn = 1`: one call in process, then one through the server →
  `budget_exceeded`.
- unknown method → error `-32601`.
- registry-root parity: the server is started with `RIELA_WORKFLOW_HOME`
  pointing at a temporary registry that differs from the test process
  default and holds one workflow → `tools/call workflow_list` returns that
  workflow and none from the default root.
- redaction parity: a session log line holds a secret value that is absent
  from the tool-server process environment and present in the
  `--redaction-values` file → the value is not in the `tools/call
  session_logs` result; the same fixture through the in-process executor
  with the secret in `AskHost.environment` gives an equal result.
- `--redaction-values` pointing at a missing file → non-zero exit,
  `redaction_values_unavailable`, no response written.

`Tests/RielaCLITests/Ask/Engine/AskTransportTests.swift`:
- `mcp` turn with `AskHost.environment` holding `HOME`,
  `RIELA_WORKFLOW_HOME`, `RIELA_API_TOKEN=s3cr3t-value` and
  `OPENAI_API_KEY=sk-test-value`: the server entry's environment has `HOME`
  and `RIELA_WORKFLOW_HOME` with the host's values and no secret-named key;
  no environment value and no argument equals either secret value; the
  arguments contain `--redaction-values` with a path under
  `<scratchRoot>/redaction`, and `--scope` when the host has a scope.
- during the capturing adapter call the values file exists with mode 0600
  and holds both secret values; after the turn settles (completed, and
  again for cancelled and for an adapter error) the file does not exist.
- stale-turn recovery of an `mcp` turn removes its values file.
- a `rounds` turn creates no file under `<scratchRoot>/redaction`.
- codex with a path → `mcp`; with `RIELA_ASK_TOOL_TRANSPORT=rounds` →
  `rounds`; with the scripted backend variable → `rounds`; without a path →
  `rounds`; `officialOpenAISDK` → `rounds`.
- `mcp` turn with a capturing adapter: `input.mcpServers` has the one
  server with the expected arguments; payload codex arguments contain no
  `mcp_servers`; the turn stores `toolTransport == mcp`.
- `AskAgentPolicy.payload` for claude `mcp` → `--allowedTools` lists only
  `mcp__riela-ask__` names.

## Verification

```
mkdir -p tmp/ask-riela/ask-05-mcp-transport
arch -arm64 /bin/zsh -lc 'swift test --filter "AskToolServerTests|AskTransportTests|AskAgentPolicyTests|AskTurnEngineTests|AskPromptInjectionTests|AskCommandTests|AskExampleWalkthroughTests|AgentToolPolicyPresetContractTests|AgentToolPolicyResolutionTests|AgentGatewayNodeAdapterTests|AgentGatewayACPV2Tests|GatewayScriptedAgentTests|SurfaceCatalogTests|SurfaceParityCLITests|SubcommandHelpTests|CommandParsingTests"' > tmp/ask-riela/ask-05-mcp-transport/test.log 2>&1
```

Exit 0. Evidence: the server reaches the gateway request on v1 and v2, the
tool server speaks the three methods against a real store with shared
budgets, reads the host's registry root, redacts host-only secrets, no
secret is in the server entry, and the default policy argv is unchanged.

## Done criteria

- `git diff Package.swift Package.resolved` is empty.
- `grep -rn "mcpServers: \[\]" Sources/RielaAdapters` prints nothing.
- Progress log lists the vendor flags that were confirmed and those left for
  the operator's live check.
- Verification exits 0; progress log written.
