# atp-07-live-smoke: live preset runs with the installed codex and claude CLIs

```json
{
  "planId": "atp-07-live-smoke",
  "planPath": "impl-plans/active/agent-tool-policy-presets-07-live-smoke.md",
  "dependsOn": ["atp-03-core-resolution", "atp-04-core-validation", "atp-05-adapter-websearch", "atp-06-docs"],
  "wave": 3,
  "writePaths": [
    "impl-plans/progress/atp-07-live-smoke.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The acceptance criteria require a real run of a tiny temporary workflow, with
`preset: "none"` and a trivial JSON output, through the source-built `riela`:
once on codex-cli 0.164.0 and once on Claude Code 2.1.306. Gemini is not run
because `GEMINI_API_KEY` is unset. This plan writes no source code. It only
produces evidence. Design §9.

A temporary workflow is a JSON file with top-level `workflow` and
`nodePayloads` keys, passed positionally:
`riela workflow run <file.json> --session-store <dir> --output json`.
Imitate `Tests/RielaCLITests/WorkflowCommandScenarioTests.swift:558-564`
(the invocation) and `:595-638` (the JSON shape). There is no
`--workflow-json-file` flag.

Follow the shared worker protocol in
`impl-plans/completed/agent-tool-policy-presets.md`.

## Non-goals

- Do not edit any source, test or doc file. If a run fails because of the
  preset argv, record the exact CLI error and the failing argv element in the
  progress log. Serial repair changes
  `Sources/RielaCore/AgentToolPolicyPresetArguments.swift`.
- No Gemini or SDK live run. No `web-search` live run. Neither is required by
  the acceptance criteria, and both cost quota.

## Tasks

- [x] T1: Build with `arch -arm64 /bin/zsh -lc 'swift build > tmp/agent-tool-policy-preset/atp-07-live-smoke/build.log 2>&1'`
  (exit 0). Use the binary at `.build/debug/riela`, and record
  `.build/debug/riela --version`.
- [x] T2: Write `tmp/agent-tool-policy-preset/codex-none.json`:
  - one step, `smoke`, on node `smoke-node`, in workflow
    `agent-tool-policy-preset-codex-smoke`;
  - `defaults` of `{"nodeTimeoutMs": 300000, "maxLoopIterations": 1}`;
  - a node payload with:
    - `"executionBackend": "codex-agent"`;
    - `"model": "gpt-5.5"`. If codex rejects that model, use the model named
      in a working local example node and record it;
    - `"agentToolPolicy": {"preset": "none"}`;
    - `"promptTemplate": "Return exactly the JSON object {\"ok\": true} and nothing else."`;
    - `"output": {"jsonSchema": {"type": "object", "properties": {"ok": {"const": true}}, "required": ["ok"], "additionalProperties": false}}`.
- [x] T2b: Write two argv-logging wrapper scripts. They are scratch files and
  are never committed.
  1. Record `command -v codex` and `command -v claude`. Expected paths:
     `/opt/homebrew/bin/codex` and `/opt/homebrew/bin/claude`.
  2. Write `tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-wrapper.sh`
     and `claude-wrapper.sh`, each with a `#!/bin/sh` line.
  3. Each wrapper first writes every argument on its own line, using
     `printf '%s\n' "$@"`, to `argv-codex.log` or `argv-claude.log` in the same
     directory. It then runs `exec <recorded absolute CLI path> "$@"`, which
     keeps stdin, where the prompt arrives.
  4. Always use the absolute path in the `exec` line. Calling `codex` or
     `claude` by name could make the wrapper invoke itself.
  5. Run `chmod +x` on both scripts and record their absolute paths.
- [x] T3: Run the Codex workflow through the wrapper. Remove any old
  `argv-codex.log` first.

  ```
  arch -arm64 /bin/zsh -lc 'RIELA_CODEX_AGENT_EXECUTABLE=<abs path>/codex-wrapper.sh .build/debug/riela workflow run tmp/agent-tool-policy-preset/codex-none.json --session-store tmp/agent-tool-policy-preset/sessions-codex --output json > tmp/agent-tool-policy-preset/atp-07-live-smoke/codex-none.log 2>&1'
  ```

  The adapter reads that override in
  `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:gatewayVendorExecutable`.
  If `argv-codex.log` stays empty or missing after the run, set
  `"variables": {"codexExecutable": "<abs path>/codex-wrapper.sh"}` in the
  scratch node payload, which the same function reads first, and rerun. Record
  which mechanism worked.

  Expected:
  - exit 0, with root output `{"ok": true}`;
  - `argv-codex.log` contains these elements as separate lines, in this
    relative order:
    1. `--ignore-user-config`, `--ignore-rules`, `--strict-config`;
    2. `-c`, `web_search="disabled"`;
    3. `-c`, `tools.experimental_request_user_input.enabled=false`;
    4. `-c`, `tools.update_plan.enabled=false`;
    5. `-c`, `mcp_servers={}`;
    6. `--skip-git-repo-check`, `--ephemeral`;
    7. one `--disable`, `<name>` pair for each entry of
       `AgentToolPolicyPresetArguments.codexDisabledFeatures`, in file order;
    8. `--disable`, `multi_agent`, appended by the adapter.

  If atp-01 dropped any fixed flag, check against its recorded list instead.
  Record the excerpt as line numbers plus content.
- [x] T4: Repeat with `claude-none.json`: `"executionBackend":
  "claude-code-agent"`, `"model": "sonnet"`, and the same policy, prompt and
  schema.

  Run it as
  `env -u ANTHROPIC_API_KEY RIELA_CLAUDE_CODE_AGENT_EXECUTABLE=<abs path>/claude-wrapper.sh .build/debug/riela workflow run tmp/agent-tool-policy-preset/claude-none.json --session-store tmp/agent-tool-policy-preset/sessions-claude --output json`.
  Wrap it the same way as T3 and redirect output to `claude-none.log`. If the
  environment variable is not honored, fall back to `variables.claudeExecutable`
  as in T3.

  Expected:
  - exit 0, with `{"ok": true}`;
  - `argv-claude.log` contains, in this relative order:
    1. `--tools`;
    2. an empty line, which is the empty argv element;
    3. `--strict-mcp-config`, `--mcp-config`, `{"mcpServers":{}}`;
    4. `--disable-slash-commands`;
    5. `--setting-sources` and an empty line, if atp-01 kept that option.
- [x] T5: Do not use the session's step-execution records as expansion
  evidence. The published step record holds the raw base payload
  (`DeterministicWorkflowRunner.swift:697-704` publishes `basePayload`). The
  invocation snapshot (`Sources/RielaCore/WorkflowInvocationSnapshot.swift`)
  has no node policy. A raw `preset` key in those records is expected and is
  not a defect. The argv logs are the only expansion evidence.
- [x] T6: Pass and blocked rules.
  - A run passes only when **both** of these hold: exit 0 with `{"ok": true}`,
    and the argv-log assertions.
  - Exit 0 alone is never a pass.
  - If a run cannot reach the vendor (network, auth or sandbox), or the
    wrapper cannot be executed, record `blocked: <reason>` with the exact
    command, exit status and log path. Serial integration reruns the same
    commands.
  - If the CLI rejects a preset argv element, record the CLI error and the
    element. Serial repair changes
    `Sources/RielaCore/AgentToolPolicyPresetArguments.swift`.
- [x] T7: Record `Gemini live check not run: GEMINI_API_KEY unset` in the
  progress log.

## Verification evidence

Record one entry per run:
`{command, logPath, exitStatus, rootOutput, argvLogPath, argvExcerpt, executableOverride}`.

- `codex-none.log` and `claude-none.log` are complete, with exit 0 and root
  output `{"ok": true}`.
- `argv-codex.log` and `argv-claude.log` satisfy the ordered assertions in T3
  and T4.

## Done criteria

- The progress log has:
  - the build record;
  - the resolved CLI paths and wrapper paths;
  - two run records, with complete log paths and argv excerpts that satisfy
    the T3 and T4 assertions (or `blocked:` records);
  - the Gemini not-run note.
- `grep -c . tmp/agent-tool-policy-preset/atp-07-live-smoke/argv-codex.log`
  is greater than 0, and so is the count for `argv-claude.log`.
- Nothing under `tmp/` is staged.
