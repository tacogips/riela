# atp-07-live-smoke progress

Plan: [agent-tool-policy-presets-07-live-smoke.md](../completed/agent-tool-policy-presets-07-live-smoke.md)
Issue: `Agent tool-policy presets (none / web-search) for Codex, Claude Code and SDK backends incl. Gemini` (workflowInput issue; no GitHub number).
Workflow: `issue-resolution`; workflow execution `opus-luna-design-and-implement-review-loop-session-503`; plan `atp-07-live-smoke`; Codex agent references: installed `codex-cli 0.164.0` and `claude-code 2.1.306`.

## Completion

- T1: `swift build` passed for the shared current source tree. Source-built CLI: `.build/debug/riela`, version `0.2.77`.
- T2/T2b: Created `tmp/agent-tool-policy-preset/codex-none.json`, `tmp/agent-tool-policy-preset/claude-none.json` and executable argv wrappers `tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh`, `claude-wrapper.sh`. The workflows use `preset: none`, a read-only agent sandbox, and the exact `{ "ok": true }` JSON schema. Wrapper targets are `/opt/homebrew/bin/codex` and `/opt/homebrew/bin/claude`; environment overrides were honored.
- T3: Passed. Final Codex run used model `gpt-6.1-sol`: the installed CLI account rejected the plan's `gpt-5.5` with HTTP 400 `model_not_found`; local-example alternatives `gpt-5.4-mini` and `gpt-5.3-codex` were also rejected. `gpt-6.1-sol` is listed by `codex debug models --bundled` and completed successfully. Root output is exactly `{"ok":true}`. Final argv evidence is in `argv-codex.log`.
- T4: Passed with `sonnet`; root output is exactly `{"ok":true}`. Final argv evidence is in `argv-claude.log`.
- T5: Used wrapper argv logs as expansion evidence; session payload is not used for this assertion.
- T6: Both runs pass only when the output and ordered argv assertions pass. The assertion helper verified both root outputs and the full argv contract. Codex's 20 `--disable` pairs match `AgentToolPolicyPresetArguments.codexDisabledFeatures` in source order; `--disable multi_agent` is last before `-`.
- T7: Gemini live check not run: GEMINI_API_KEY unset.

## CLI and wrapper paths

`tmp/agent-tool-policy-preset/atp-07-live-smoke/cli-paths-and-versions.log` records:

- `.build/debug/riela` → `0.2.77`
- `/opt/homebrew/bin/codex` → `codex-cli 0.164.0`
- `/opt/homebrew/bin/claude` → `2.1.306 (Claude Code)`
- wrappers: `/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh` and `/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-wrapper.sh`

## Run records

1. Codex — command:
   `arch -arm64 /bin/zsh -lc 'RIELA_CODEX_AGENT_EXECUTABLE="/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh" .build/debug/riela workflow run tmp/agent-tool-policy-preset/codex-none.json --session-store tmp/agent-tool-policy-preset/sessions-codex --output json > tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-none.log 2>&1'`
   Exit: `0`; log: `tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-none.log`; root output: `{"ok":true}`; argv log: `tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-codex.log`; override: `RIELA_CODEX_AGENT_EXECUTABLE`.
   Excerpt (line numbers in argv log): lines 7–19 are `--ignore-user-config`, `--ignore-rules`, `--strict-config`, `-c` / `web_search="disabled"`, the request-input and update-plan disables, `-c` / `mcp_servers={}`, `--skip-git-repo-check`, `--ephemeral`. Lines 20–59 contain the 20 ordered `--disable` feature/name pairs: `apps`, `auth_elicitation`, `browser_annotation_api`, `browser_use`, `browser_use_external`, `browser_use_full_cdp_access`, `code_mode_host`, `code_mode_interrupt`, `computer_use`, `goals`, `image_generation`, `in_app_browser`, `memories`, `plugin_sharing`, `plugins`, `remote_plugin`, `shell_tool`, `unified_exec`, `unified_exec_tty`, `view_image`. Lines 60–62 are `--disable`, `multi_agent`, `-`.
2. Claude Code — command:
   `arch -arm64 /bin/zsh -lc 'env -u ANTHROPIC_API_KEY RIELA_CLAUDE_CODE_AGENT_EXECUTABLE="/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-wrapper.sh" .build/debug/riela workflow run tmp/agent-tool-policy-preset/claude-none.json --session-store tmp/agent-tool-policy-preset/sessions-claude --output json > tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-none.log 2>&1'`
   Exit: `0`; log: `tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-none.log`; root output: `{"ok":true}`; argv log: `tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-claude.log`; override: `RIELA_CLAUDE_CODE_AGENT_EXECUTABLE`.
   Excerpt: lines 10–17 are `--tools`, empty argv element, `--strict-mcp-config`, `--mcp-config`, `{"mcpServers":{}}`, `--disable-slash-commands`, `--setting-sources`, empty argv element.

## Verification records

| Command | Exit | Tests / failures | Complete log |
|---|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/agent-tool-policy-preset/atp-07-live-smoke/build.log 2>&1'` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/build.log` |
| `arch -arm64 /bin/zsh -lc 'RIELA_CODEX_AGENT_EXECUTABLE="/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh" .build/debug/riela workflow run tmp/agent-tool-policy-preset/codex-none.json --session-store tmp/agent-tool-policy-preset/sessions-codex --output json > tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-none.log 2>&1'` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-none.log` |
| `arch -arm64 /bin/zsh -lc 'env -u ANTHROPIC_API_KEY RIELA_CLAUDE_CODE_AGENT_EXECUTABLE="/Users/taco/gits/tacogips/riela/tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-wrapper.sh" .build/debug/riela workflow run tmp/agent-tool-policy-preset/claude-none.json --session-store tmp/agent-tool-policy-preset/sessions-claude --output json > tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-none.log 2>&1'` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-none.log` |
| `arch -arm64 /bin/zsh -lc 'printf "riela=%s\\n" "$(.build/debug/riela --version)"; printf "codex=%s\\n" "$(/opt/homebrew/bin/codex --version)"; printf "claude=%s\\n" "$(/opt/homebrew/bin/claude --version)"; printf "codex_path=%s\\n" "$(command -v codex)"; printf "claude_path=%s\\n" "$(command -v claude)"; if [[ -n "${GEMINI_API_KEY:-}" ]]; then echo "GEMINI_API_KEY=set"; else echo "GEMINI_API_KEY=unset"; fi' > tmp/agent-tool-policy-preset/atp-07-live-smoke/cli-paths-and-versions.log 2>&1` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/cli-paths-and-versions.log` |
| `python3 tmp/agent-tool-policy-preset/atp-07-live-smoke/verify-smoke.py > tmp/agent-tool-policy-preset/atp-07-live-smoke/smoke-assertions.log 2>&1` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/smoke-assertions.log` |
| `arch -arm64 /bin/zsh -lc 'grep -c . tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-codex.log; grep -c . tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-claude.log' > tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-line-counts.log 2>&1` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-line-counts.log` (62, 15) |
| `arch -arm64 /bin/zsh -lc 'test -x tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh && test -x tmp/agent-tool-policy-preset/atp-07-live-smoke/claude-wrapper.sh && echo "both wrappers executable"' > tmp/agent-tool-policy-preset/atp-07-live-smoke/wrapper-executable-check.log 2>&1` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/wrapper-executable-check.log` |
| `arch -arm64 /bin/zsh -lc 'git diff --cached --quiet -- tmp && echo "no staged paths under tmp"' > tmp/agent-tool-policy-preset/atp-07-live-smoke/staged-tmp-check.log 2>&1` | 0 | 0 / 0 | `tmp/agent-tool-policy-preset/atp-07-live-smoke/staged-tmp-check.log` |

`smoke-assertions.log` confirms the exact output and argv assertions. Earlier smoke attempts are preserved as `codex-none-attempt-01.log` through `codex-none-attempt-05.log`; invalid workflow setup attempts and model rejection are not presented as passes. Direct Codex replay diagnostics are `codex-cli-replay.log` and `codex-cli-replay-attempt-02.log` through `codex-cli-replay-attempt-04.log`.

## Change accounting

Only this progress file is a tracked edit for atp-07. All workflows, wrappers, logs, helper and hash records are under untracked `tmp/agent-tool-policy-preset/`; no path under `tmp/` is staged.
