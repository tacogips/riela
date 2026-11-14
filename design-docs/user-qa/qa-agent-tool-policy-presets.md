# Agent Tool-Policy Presets: Open Decisions

Design: `design-docs/specs/design-agent-tool-policy-presets.md`

Implementation can go ahead with each recommended decision below. Each
question records an interpretation that the user may want to override.

## Q1: `--supervisor-mode` together with a Codex preset

`gatewayVendorArguments` appends `--enable multi_agent` after the tool-policy
arguments whenever the operator runs `riela workflow run --supervisor-mode`.
It appends `--disable multi_agent` otherwise, and that is the default. With
supervisor mode on, a `preset: "none"` Codex node can still spawn sub-agents.
The host expands the preset and removes it before dispatch, so the adapter (in
a possibly older guest) cannot see that a preset was requested.

Recommended decision: keep the operator flag authoritative and document that
`--supervisor-mode` re-enables `multi_agent` on top of any preset. Supervisor
mode is an explicit, run-wide operator opt-in that is off by default. If the
preset should win instead, the host could append `--disable multi_agent`
inside the expansion, but the adapter's later `--enable` would still come
last. A real fix would mean changing the adapter's argv order, which is outside
this issue.

## Q2: Old Riela builds and `preset`

The current `AgentToolPolicy` decoder ignores unknown keys. A Riela build
older than this change, used as the host, would therefore run a preset node
with the CLI's default tools.

Recommended decision: document that `preset` needs a Riela build that includes
this change, and add no version gate in this issue. New hosts with old guests
are safe, because CLI presets are expanded before dispatch.

## Q3: Claude `web-search` needs `--allowedTools WebSearch`

The issue lists only `--tools WebSearch`. In print mode, WebSearch can need
permission and would then be denied, which silently turns the preset into
`none`.

Recommended decision: also emit `--allowedTools WebSearch`. Because `--tools`
already limits the available set to WebSearch, this allows nothing else.
