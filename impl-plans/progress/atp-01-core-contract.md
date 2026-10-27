# atp-01-core-contract progress

Status: implementation complete. The required live Codex no-tools probe passed; no unresolved high findings remain for atp-01.

## Contract implemented

- Added closed `AgentToolPolicyPreset` cases `noTools = "none"` and `webSearch = "web-search"`.
- Added optional `AgentToolPolicy.preset` as the final initializer argument. Unknown values fail synthesized enum decoding; `encodeIfPresent` omits the key when unset.
- Added `AgentToolPolicyPresetArguments` as the single source for backend support, Codex/Claude argv, and Codex resume capability.
- Added contract tests for decoding, legacy encoding, exact CLI argv, session reuse omission, support matrix and invariants.

## Installed CLI evidence (2026-10-27)

| CLI | Version command | Result | Evidence |
|---|---|---|---|
| Codex | `codex --version` | `codex-cli 0.164.0` (exit 0) | `tmp/agent-tool-policy-preset/atp-01-core-contract/codex-version.log` |
| Claude Code | `claude --version` | `2.1.306 (Claude Code)` (exit 0) | `tmp/agent-tool-policy-preset/atp-01-core-contract/claude-version.log` |

### Codex disable-feature decisions

`codex features list` completed with exit 0. The line numbers below refer to
`tmp/agent-tool-policy-preset/atp-01-core-contract/codex-features.log`.
Kept entries were passed together to the final offline `--disable` probe; it
exited 0 and each kept row reported `false` in
`tmp/agent-tool-policy-preset/atp-01-core-contract/codex-disable-probe-final.log`.

| Feature | Decision | Source line | Reason |
|---|---|---:|---|
| `shell_tool` | keep | 138 | Issue list; callable shell feature |
| `unified_exec` | keep | 166 | The CLI accepts `--disable unified_exec` (exit 0); retain the issue-required flag even though the feature listing remains `true`. The live probe verifies the absence of executable tools. |
| `view_image` | keep | 174 | Issue list; image input capability |
| `apps` | keep | 9 | Issue list; app tools |
| `plugins` | keep | 109 | Issue list; plugin tools |
| `goals` | keep | 60 | Issue list; goal tools |
| `auth_elicitation` | keep | 13 | User elicitation capability |
| `browser_annotation_api` | keep | 16 | Browser capability |
| `browser_use` | keep | 17 | Browser capability |
| `browser_use_external` | keep | 18 | External browser capability |
| `browser_use_full_cdp_access` | keep | 19 | Browser/CDP capability |
| `code_mode_host` | remove | 24 | codex-cli 0.164 uses this host to route tool calls; disabling it prevents web search |
| `code_mode_interrupt` | remove | 26 | Keep enabled alongside the code-mode host for tool routing |
| `computer_use` | keep | 36 | Computer interaction capability |
| `image_generation` | keep | 74 | Image generation capability |
| `in_app_browser` | keep | 76 | Browser capability |
| `memories` | keep | 93 | Memory capability; disabled by default but accepted by CLI |
| `plugin_sharing` | keep | 108 | Plugin sharing capability |
| `remote_plugin` | keep | 120 | Remote plugin capability |
| `unified_exec_tty` | keep | 167 | Related execution capability; CLI reports it `false` when disabled |
| `code_mode` | drop | 22 | Reported `under development`, `false`; no active tool capability |
| `multi_agent` | drop | 97 | Explicit design/user-QA decision; adapter already owns this flag |

Removed and false features unrelated to callable model tools (for example
telemetry, UI-only and internal rollout features) are not part of the preset.
The final offline probe tested the four fixed `-c` values and all 20 kept
`--disable` names. It exited 0 and every kept feature reported `false` in
`tmp/agent-tool-policy-preset/atp-01-core-contract/codex-disable-probe-final.log`,
except that `unified_exec` remained `true`. It is kept because the installed
CLI accepts the name and the issue requires it; `shell_tool` is the effective
exec-family disable on codex-cli 0.164.0, with `unified_exec` retained as
defense in depth. Disabling both
`unified_exec` and `unified_exec_tty` still left `unified_exec` true
(`codex-unified-exec-family-disable.log`); disabling only `unified_exec_tty`
reported that row false (`codex-unified-exec-tty-disable.log`). The preset
therefore keeps `--disable unified_exec` while relying on the live probe below
to establish the no-tools behavior.

### Codex live exec-absence probe

Command (run in `tmp/agent-tool-policy-preset/atp-01-core-contract/probe-cwd`):

```sh
printf '%s\n' 'Run the shell command `echo RIELA_PRESET_EXEC_PROBE_7f3a` and report its exact stdout. If you have no tool that can run commands, reply exactly NO_EXEC_TOOL.' | codex exec --json --ignore-user-config --ignore-rules --strict-config -c 'web_search="disabled"' -c tools.experimental_request_user_input.enabled=false -c tools.update_plan.enabled=false -c 'mcp_servers={}' --skip-git-repo-check --ephemeral --disable apps --disable auth_elicitation --disable browser_annotation_api --disable browser_use --disable browser_use_external --disable browser_use_full_cdp_access --disable code_mode_host --disable code_mode_interrupt --disable computer_use --disable goals --disable image_generation --disable in_app_browser --disable memories --disable plugin_sharing --disable plugins --disable remote_plugin --disable shell_tool --disable unified_exec --disable unified_exec_tty --disable view_image --disable multi_agent -
```

Exit 0; log: `tmp/agent-tool-policy-preset/atp-01-core-contract/probe-none-exec.log`.
The probe produced no JSONL `command_execution` or exec/shell tool call item,
the marker was not emitted, and the final assistant message was
`NO_EXEC_TOOL`. The log also reports that Code Mode is unavailable because
`code_mode_host` is disabled. That message means tool routing was disabled, so
this probe did not establish the effect of `shell_tool` by itself.

### Codex tool-routing correction (2026-10-28)

Live comparison on codex-cli 0.164.0 showed that `code_mode_host` and
`code_mode_interrupt` must stay enabled: with both omitted from the `--disable`
list, web-search preset runs produce web search items, while shell tools remain
unavailable. `code_mode` reports `under development` and `false`, so keeping
the routing host enabled does not enable code execution. The earlier result
above is superseded as evidence for tool availability. The current opt-in
regression test is `AgentToolPolicyLiveIntegrationTests`; run it with
`RIELA_TEST_LIVE_CODEX_TOOL_POLICY=1 swift test --filter AgentToolPolicyLiveIntegrationTests`.

### Codex fixed flags and session reuse

`codex exec --help` and `codex exec resume --help` both exited 0. The exec help
contains `--ignore-user-config`, `--ignore-rules`, `--strict-config`,
`--skip-git-repo-check` and `--ephemeral` at lines 33, 87, 90, 93 and 96 of
`codex-exec-help.log`. Resume help includes all five at lines 37, 64, 67, 70
and 73 in `codex-resume-help.log`. Therefore `codexSupportsSessionReuse` is
true. The preset argv omits only `--ephemeral` when `sessionReuse` is true.

### Claude empty setting-sources value

The prescribed probe ran with `ANTHROPIC_API_KEY` unset and exited 0. Claude
returned JSON with `result: "OK"`, `is_error: false`, and subtype `success`.
Therefore the Claude argv includes `--setting-sources`, `""`. Evidence:
`tmp/agent-tool-policy-preset/atp-01-core-contract/claude-setting-sources-probe.log`
and `.exit` (0).

## Verification

| Command | Exit | Tests | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentToolPolicyPresetContractTests|WorkflowModelTests|AgentToolPolicyResolutionTests" > tmp/agent-tool-policy-preset/atp-01-core-contract/test-redispatch.log 2>&1'` | 0 | 37 | 0 | `tmp/agent-tool-policy-preset/atp-01-core-contract/test-redispatch.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/agent-tool-policy-preset/atp-01-core-contract/changed-swift-files-redispatch.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/agent-tool-policy-preset/atp-01-core-contract/changed-swift-files-redispatch.nul; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `tmp/agent-tool-policy-preset/atp-01-core-contract/swiftlint-strict-redispatch.log` |
| `grep -n '"unified_exec"' Sources/RielaCore/AgentToolPolicyPresetArguments.swift > tmp/agent-tool-policy-preset/atp-01-core-contract/unified-exec-source-redispatch.log 2>&1` | 0 | 0 | 0 | `tmp/agent-tool-policy-preset/atp-01-core-contract/unified-exec-source-redispatch.log` (1 match at line 26) |
| `grep -n 'case noTools = "none"' Sources/RielaCore/WorkflowModel.swift > tmp/agent-tool-policy-preset/atp-01-core-contract/model-enum-redispatch.log 2>&1` | 0 | 0 | 0 | `tmp/agent-tool-policy-preset/atp-01-core-contract/model-enum-redispatch.log` (1 match at line 78) |

The first focused test attempt failed to compile because decoding passed the
new final initializer argument out of order. The call was corrected and the
same focused suite passed on the current source; the superseded log is retained
at `tmp/agent-tool-policy-preset/atp-01-core-contract/test.log` (exit 1).

## Completion criteria

- [x] Preset enum and optional model field decode/encode as specified.
- [x] Strict Codex no-tools argv verified against codex-cli 0.164.0 by the live exec-absence probe; `unified_exec` is retained as an accepted defense-in-depth flag.
- [x] Feature keep/drop table, resume decision, Claude setting-sources decision, and verification outcomes recorded.
- [x] Focused tests pass (37 tests, 0 failures) and the plan and strict selected-file SwiftLint gates pass after the final Codex feature list change.
- [x] `grep -n 'case noTools = "none"' Sources/RielaCore/WorkflowModel.swift` matches.

No expansion, runtime validation, adapter wiring, documentation, integration
review, commit or push work is assigned to this plan.

## Integration handoff

Dispatch names `feat/agent-tool-policy-presets`, but `git status --short
--branch` reported `## main...origin/main [ahead 1]` (log:
`tmp/agent-tool-policy-preset/atp-01-core-contract/git-status-final.log`). This
is a serial integration/branch-placement handoff, not an atp-01 implementation
blocker. No Git state changes were made by this plan.
