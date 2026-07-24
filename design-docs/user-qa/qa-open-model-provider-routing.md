# User Decisions: Open Model Provider Routing

Companion to `design-docs/specs/design-open-model-provider-routing.md`.
These questions do not block implementation; the design ships with the
conservative default listed for each.

## Q1: Should non-loopback `http` base URLs be allowed?

Default shipped: no. `provider.baseUrl` must be `https`, or `http` only for
loopback hosts (`localhost`, `127.0.0.1`, `::1`). LAN-hosted inference
servers (e.g. `http://192.168.x.x:8000/v1`) are therefore rejected.
Decision needed: allow plain `http` for private-range hosts, or require an
explicit opt-in flag such as `allowInsecureBaseUrl: true`?

## Q2: Which Claude Code auth variable should `apiKeyEnv` feed?

Default shipped: `ANTHROPIC_AUTH_TOKEN` (the variable OpenAI-compatible
Claude Code gateways conventionally read alongside `ANTHROPIC_BASE_URL`).
Some deployments expect `ANTHROPIC_API_KEY` instead. Decision needed: keep
`ANTHROPIC_AUTH_TOKEN` only (with `agentEnvironment` as the manual escape
hatch), or add a `provider.authStyle` selector?

## Q3: Should `providerProxy` ever gain a value that routes claude-code-agent through Codex?

Default shipped: no. `providerProxy: "codex"` is valid only with
`executionBackend: "codex-agent"`. If a future proxy binary can front the
Claude Code CLI, `providerProxy` would gain a new enum value; nothing in the
v1 schema forecloses that.

## Q4: Should provider identity be surfaced in RielaApp UI (instances, run timeline)?

Default shipped: provider name is recorded in adapter output payload
metadata (`provider_name`) only. Surfacing it in RielaApp views is deferred
until requested.
