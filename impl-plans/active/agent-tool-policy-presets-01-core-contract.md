# atp-01-core-contract: preset enum, model field and verified CLI argv constants (RielaCore)

```json
{
  "planId": "atp-01-core-contract",
  "planPath": "impl-plans/active/agent-tool-policy-presets-01-core-contract.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaCore/AgentToolPolicyPresetArguments.swift",
    "Tests/RielaCoreTests/AgentToolPolicyPresetContractTests.swift",
    "impl-plans/progress/atp-01-core-contract.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Workflows need a one-word way to run an agent with no tools (`none`) or with
web search only (`web-search`). Today they repeat about 45 argv entries.
Design: `design-docs/specs/design-agent-tool-policy-presets.md` §3 (data
model), §4.1 (Codex argv) and §4.2 (Claude argv).

This plan pins the shared contract that atp-03 (resolution), atp-04
(validation) and atp-05 (adapter) build on:

- the enum and the model field;
- one source of truth for the CLI argv and for the backend-support matrix,
  checked against the installed CLIs (codex-cli 0.164.0, Claude Code 2.1.306).

Follow the shared worker protocol in
`impl-plans/active/agent-tool-policy-presets.md`.

## Non-goals

- No expansion logic, no runner change, no validation diagnostics, no adapter
  change. Those belong to atp-03, atp-04 and atp-05.
- No change to `mode` semantics, `cursorArguments` or `AgentNodePayload.swift`.
  The payload decodes `AgentToolPolicy` through its own `init(from:)`, so it
  needs no edit.
- No GraphQL SDL or DTO changes.

## File-level changes

### `Sources/RielaCore/WorkflowModel.swift`

Add the enum next to `AgentToolPolicyMode` (line 72):

```swift
public enum AgentToolPolicyPreset: String, Codable, CaseIterable, Hashable, Sendable {
  case noTools = "none"
  case webSearch = "web-search"
}
```

The Swift case is `noTools`, not `none`. A case named `none` on an Optional
enum makes `policy.preset == .none` compare against `nil`, and the compiler
only warns. The JSON value stays `"none"`.

Changes to `AgentToolPolicy` (lines 77-125):

- Add `public var preset: AgentToolPolicyPreset?`.
- Add an init parameter `preset: AgentToolPolicyPreset? = nil` as the **last**
  parameter, so existing calls like `AgentToolPolicy(mode:codexArguments:)`
  still compile.
- Add `preset` to `CodingKeys`.
- Decode with `decodeIfPresent`. An unknown raw value throws
  `DecodingError.dataCorrupted`; never catch or soften that.
- Encode with `encodeIfPresent`. A policy without a preset must encode with no
  `preset` key.

### `Sources/RielaCore/AgentToolPolicyPresetArguments.swift` (new)

Use a namespace enum with static members. Imitate
`Sources/RielaCore/WorkflowBackendPolicy.swift:WorkflowBackendPolicyValidation`.
Pinned contract:

```swift
public enum AgentToolPolicyPresetArguments {
  public static let codexDisabledFeatures: [String]        // verified names, file order = argv order
  public static let codexSupportsSessionReuse: Bool         // false only if `codex exec resume` rejects a kept flag
  public static func isSupported(_ preset: AgentToolPolicyPreset, backend: NodeExecutionBackend) -> Bool
  public static func cliArguments(_ preset: AgentToolPolicyPreset, backend: NodeExecutionBackend,
                                  sessionReuse: Bool) -> [String]?   // nil for every non-CLI-expandable backend
}
```

`isSupported` matrix (design §6):

| Backend | `none` | `web-search` |
|---|---|---|
| codex-agent, claude-code-agent, official/openai-sdk, official/anthropic-sdk, official/gemini-sdk | true | true |
| official/cursor-sdk | true | false |
| cursor-cli-agent | false | false |

`cliArguments` returns argv only for `.codexAgent` and `.claudeCodeAgent`, and
`nil` for every other backend. Each element is one argv element. There is no
shell quoting, so `-c` and `web_search="disabled"` are separate elements and
the TOML quotes are literal characters.

Codex argv, in this order (design §4.1):

1. `--ignore-user-config`
2. `--ignore-rules`
3. `--strict-config`
4. `-c`, then `web_search="disabled"` for `none` or `web_search="live"` for
   `web-search`
5. `-c`, `tools.experimental_request_user_input.enabled=false`
6. `-c`, `tools.update_plan.enabled=false`
7. `-c`, `mcp_servers={}`
8. `--skip-git-repo-check`
9. `--ephemeral`, **only when `sessionReuse == false`**
10. `--disable`, `<name>` for each entry in `codexDisabledFeatures`

Put a header comment above `codexDisabledFeatures` that names codex-cli
0.164.0, the date, and the commands used to verify it.

Claude argv (design §4.2):

- `none`: `--tools`, `""` (one empty element), `--strict-mcp-config`,
  `--mcp-config`, `{"mcpServers":{}}`, `--disable-slash-commands`. Append
  `--setting-sources`, `""` only if task T3 proves that value is accepted.
- `web-search`: `--tools`, `WebSearch`, `--allowedTools`, `WebSearch`, then the
  same tail as `none`.

Neither list contains `multi_agent`. The adapter already appends
`--disable multi_agent` (design D6).

## Tasks

- [ ] T1: Record the CLI versions in your progress log: `codex --version`,
  `claude --version`.
- [ ] T2: Build the Codex feature list. Run `codex features list` and save the
  full output to `tmp/agent-tool-policy-preset/atp-01-core-contract/codex-features.log`.
  - Start from the issue's names: `shell_tool`, `unified_exec`, `view_image`,
    `apps`, `plugins`, `goals`.
  - Add every other listed feature that gives the model a callable tool or an
    external capability: shell or exec, file editing or apply_patch, images,
    web or browser, apps, plugins, connectors, MCP, memory, goals, js/repl,
    and similar.
  - Exclude `multi_agent`, and exclude pure UI or telemetry features.
  - Drop any issue name that the list does not contain.
  - Write the kept and dropped decision for each name in the progress log,
    citing the features-list line.
- [ ] T2b: Probe acceptance offline. Run
  `codex <each -c pair> <each --disable pair> features list` and confirm it
  exits 0 and shows every kept feature as disabled. If `--disable` or `-c` is
  not accepted before `features list`, record that. The live run in atp-07 is
  then the acceptance check. Never keep a name the CLI rejects.
- [ ] T2c: Check the flags against the help output. Run `codex exec --help` and
  `codex exec resume --help` and save both logs.
  - If `codex exec --help` does not show one of the fixed flags (items 1-3, 8
    and 9), drop that flag and log it.
  - Set `codexSupportsSessionReuse = false` only if `codex exec resume --help`
    lacks a kept flag other than `--ephemeral`. Log which flag.
- [ ] T3: Probe Claude `--setting-sources ""` once:

  ```
  env -u ANTHROPIC_API_KEY claude -p --output-format json --tools "" --strict-mcp-config \
    --mcp-config '{"mcpServers":{}}' --disable-slash-commands --setting-sources "" \
    'Reply with the single word OK'
  ```

  Save the log and exit status.
  - Include `--setting-sources ""` only if the probe exits 0 with a result.
  - If the probe rejects the option value, or is blocked by network, auth or
    the sandbox, omit it and log the reason. Leaving it out cannot abort runs;
    an unproven option could.
- [ ] T4: Implement the enum, the field, and the new file.
- [ ] T5: Add the tests. Run the verification commands and record the results.

## Tests (`Tests/RielaCoreTests/AgentToolPolicyPresetContractTests.swift`, XCTest class `AgentToolPolicyPresetContractTests`)

Decoding and encoding:

- `{"preset":"none"}` → `.noTools`, `mode == nil`, every argv array empty.
- `{"preset":"web-search","mode":"backend-arguments"}` → `.webSearch` and
  `.backendArguments`.
- `{"preset":"shell"}`, `{"preset":"None"}` and `{"preset":""}` → each throws.
- An `AgentNodePayload` JSON whose `agentToolPolicy.preset` is `"shell"` →
  decode throws.
- A policy without a preset, encoded and re-decoded as `JSONObject` → no
  `preset` key.
- `AgentToolPolicy(preset: .webSearch)` → survives an encode/decode round trip.

Codex arguments:

- `cliArguments(.noTools, .codexAgent, sessionReuse: false)` equals the full
  literal list written out in the test. Do not build the expected value from
  `codexDisabledFeatures`, because the test must pin the exact argv.
- The same call with `sessionReuse: true` equals that list minus
  `--ephemeral` only.
- `.webSearch` on codex-agent differs from `.noTools` only in the
  `web_search="live"` element.

Claude arguments:

- `none` and `web-search` each equal their exact literal list.
- `""` is one element of length 0.

Other backends and invariants:

- `cliArguments` is `nil` for all five other backends and both presets.
- `isSupported` matches the 7 × 2 table above.
- `codexDisabledFeatures` has no duplicates, does not contain `multi_agent`,
  and is not empty.

## Invariants

- A payload without `preset` decodes and encodes byte-for-byte as before.
- There is exactly one place that lists Codex and Claude preset argv: this file.

## Verification (record each as `{command, logPath, exitStatus, testsRun, failureCount}`)

- `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyPresetContractTests|WorkflowModelTests|AgentToolPolicyResolutionTests" > tmp/agent-tool-policy-preset/atp-01-core-contract/test.log 2>&1'`
  must exit 0 with 0 failures. `AgentToolPolicyResolutionTests` is unchanged
  here, which proves the existing init calls still compile.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/AgentToolPolicyPresetArguments.swift Tests/RielaCoreTests/AgentToolPolicyPresetContractTests.swift > tmp/agent-tool-policy-preset/atp-01-core-contract/swiftlint.log 2>&1'`
  must report 0 violations.

## Done criteria

- `grep -n "case noTools = \"none\"" Sources/RielaCore/WorkflowModel.swift`
  matches.
- The new file exists with the four pinned members.
- The progress log contains:
  - the CLI versions;
  - the keep or drop table for each feature, with its source;
  - the resume decision;
  - the `--setting-sources` decision, with its evidence log path;
  - passing verification records.
