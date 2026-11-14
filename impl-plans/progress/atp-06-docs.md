# atp-06-docs implementation progress

Status: implementation complete; ready for downstream review.

Issue: `Agent tool-policy presets (none / web-search) for Codex, Claude Code and SDK backends incl. Gemini` (workflow input issue; no GitHub number).
Workflow mode: full issue-resolution. Plan: `impl-plans/completed/agent-tool-policy-presets-06-docs.md`.

## Changes

Added one `### Tool-policy presets` subsection to
`docs/workflows/declarative-data-and-private-agents.md` before the container
HOME section. It documents accepted values and validation, the support table,
host-side CLI expansion and argument order, SDK hosted search mapping, the
Codex supervisor and old-build caveats, and three JSON examples. The examples
cover Codex `none`, Claude Code `web-search`, and Gemini SDK `web-search` with
the `GEMINI_API_KEY` requirement. The exact CLI argv remains in
`Sources/RielaCore/AgentToolPolicyPresetArguments.swift`.

## Verification

All assigned documentation checks passed on the current source:

| Command | Result | Log |
|---|---|---|
| `python3 -I tmp/agent-tool-policy-preset/atp-06-docs/extract_examples.py` | exit 0; extracted 3 examples | `tmp/agent-tool-policy-preset/atp-06-docs/extract.log` |
| `grep -n '### Tool-policy presets' docs/workflows/declarative-data-and-private-agents.md` | exit 0; one match at line 75, before container HOME section | `tmp/agent-tool-policy-preset/atp-06-docs/heading.log` |
| `grep -c '"preset"' docs/workflows/declarative-data-and-private-agents.md` | exit 0; count 3 | `tmp/agent-tool-policy-preset/atp-06-docs/preset-count.log` |
| `python3 -I -m json.tool tmp/agent-tool-policy-preset/atp-06-docs/example-1.json` | exit 0 | `tmp/agent-tool-policy-preset/atp-06-docs/example-1-json.log` |
| `python3 -I -m json.tool tmp/agent-tool-policy-preset/atp-06-docs/example-2.json` | exit 0 | `tmp/agent-tool-policy-preset/atp-06-docs/example-2-json.log` |
| `python3 -I -m json.tool tmp/agent-tool-policy-preset/atp-06-docs/example-3.json` | exit 0 | `tmp/agent-tool-policy-preset/atp-06-docs/example-3-json.log` |

No behavioral tests apply to this documentation-only plan. Formal review,
review-dependent repository documentation, staging, commit, and push are owned
by later workflow steps.
