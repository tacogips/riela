# atp-06-docs: document tool-policy presets

```json
{
  "planId": "atp-06-docs",
  "planPath": "impl-plans/active/agent-tool-policy-presets-06-docs.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "docs/workflows/declarative-data-and-private-agents.md",
    "impl-plans/progress/atp-06-docs.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The issue asks for the preset to be documented with one Codex, one Claude Code
and one Gemini SDK example (design §8). The tool-policy template and trust
rules already live in `docs/workflows/declarative-data-and-private-agents.md`
lines 57-73.

`design-docs/specs/design-workflow-json.md` already links the design. Step 2
did that, so it is not part of this plan.

The docs describe behavior and never copy the full argv list. That list lives
only in `Sources/RielaCore/AgentToolPolicyPresetArguments.swift` (atp-01), and
copying it here would drift. This is why the plan can run in wave 1.

Follow the shared worker protocol in
`impl-plans/active/agent-tool-policy-presets.md`.

## Non-goals

- Do not edit any other doc, the design or the README.
- Do not add a version number to the heading. The maintainer releases later.

## File-level changes

Insert a `### Tool-policy presets` subsection after the trust-rule paragraph
(which ends at line 73) and before `## Container-private HOME and credential
projection`.

Content, in English prose with no emojis:

1. The `agentToolPolicy.preset` values:
   - `"none"`: no tools at all.
   - `"web-search"`: only the vendor's hosted web search.

   Unknown values fail when the workflow loads. `mode` may be omitted, and
   `mode: "backend-default"` combined with a preset is rejected.
2. A support table:

   | Backend | `none` | `web-search` |
   |---|---|---|
   | codex-agent | yes | yes |
   | claude-code-agent | yes | yes |
   | official/openai-sdk, official/anthropic-sdk, official/gemini-sdk, OpenRouter via openai-sdk `provider` | yes | yes |
   | official/cursor-sdk | yes | no |
   | cursor-cli-agent | no | no |

3. How CLI presets are expanded. The host runtime expands a CLI preset into
   explicit argv before dispatch, so sandbox and container guests receive only
   argv. Authored `additionalArguments`, then the backend's own arguments, are
   appended after the preset arguments. Summarize each backend in one line:
   - Codex: user config and rules ignored, MCP servers cleared, tool features
     disabled, web search `disabled` or `live`, ephemeral unless the node
     reuses its session;
   - Claude Code: `--tools ""`, or `--tools WebSearch` with
     `--allowedTools WebSearch`, plus strict empty MCP config and disabled
     slash commands.

   Point to `Sources/RielaCore/AgentToolPolicyPresetArguments.swift` for the
   exact list.
4. SDK backends send no tools for `none`. `web-search` enables the vendor's
   hosted search: OpenAI `web_search`, Anthropic `web_search`, Gemini
   `google_search`, and the OpenRouter `web` plugin.
5. Caveats:
   - `riela workflow run --supervisor-mode` re-enables Codex `multi_agent` on
     top of a preset;
   - a preset needs a Riela build that includes this feature, because older
     builds ignore the key.
6. Three JSON node-payload examples, each a minimal agent node payload with
   `executionBackend`, `model`, `promptTemplate` and `agentToolPolicy`:
   - `codex-agent` with `{"preset": "none"}`;
   - `claude-code-agent` with `{"preset": "web-search"}`;
   - `official/gemini-sdk` with `{"preset": "web-search"}`. Mention that
     `GEMINI_API_KEY` must be set.

## Verification

- `grep -n "### Tool-policy presets" docs/workflows/declarative-data-and-private-agents.md`
  gives exactly one match, located before `## Container-private HOME`.
- Each of the three example JSON blocks must parse. Extract them into
  `tmp/agent-tool-policy-preset/atp-06-docs/example-<n>.json` and run
  `python3 -I -m json.tool <file>`; each must exit 0. Record the results.
- `grep -c '"preset"' docs/workflows/declarative-data-and-private-agents.md`
  must be at least 3.

## Done criteria

- The subsection exists with the table, the ordering rule, the caveats and
  three valid examples.
- The progress log records the checks.
