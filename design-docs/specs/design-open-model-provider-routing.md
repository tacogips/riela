# Open Model Provider Routing for CLI-Backed Agents

Status: implemented and adversarially reviewed
Issue: tacogips/riela — "Support alternate OpenAI-compatible providers for codex-agent and claude-code-agent"
Owner split: Fable authors design and implementation plan; Codex implements and reviews.

## Problem

`codex-agent` and `claude-code-agent` nodes can only talk to their default
vendor endpoints. Users cannot point a workflow node at an alternate
OpenAI-compatible provider (OpenRouter, vLLM, LM Studio, llama.cpp server,
corporate gateways) without hand-rolling `codexAdditionalArgs` or raw
`agentEnvironment` entries, which is undocumented, backend-specific, and easy
to get wrong. The workflow schema needs first-class, validated provider
identity plus provider-proxy selection while preserving byte-identical
default behavior when the new fields are unset.

## Canonical Field Names and Wire-Spelling Decision

The issue requests `provider={provider_name}` and `provider_proxy=codex`.
Authored node payload JSON in this repository uses camelCase canonical field
names only (`executionBackend`, `modelFreeze`, `agentEnvironment`), and
`design-workflow-json.md` states "authored JSON must use the canonical field
names". Decision:

- Canonical wire spelling is `provider` (object) and `providerProxy` (string).
- The snake_case spelling `provider_proxy` is **not** accepted as an alias.
  Decoding is strict; an unknown `provider_proxy` key is ignored exactly like
  any other unknown key today (no new leniency is added), and documentation
  only ever shows `providerProxy`. This is the documented compatibility
  decision: no dual-spelling support, no deprecation window needed because the
  field is new.

## Schema

`AgentNodePayload` (authored `node-{id}.json`) gains two optional fields:

```json
{
  "id": "implement",
  "executionBackend": "codex-agent",
  "model": "qwen3-coder",
  "provider": {
    "name": "openrouter",
    "baseUrl": "https://openrouter.ai/api/v1",
    "apiKeyEnv": "OPENROUTER_API_KEY"
  },
  "providerProxy": "codex",
  "promptTemplateFile": "prompts/implement.md",
  "variables": {}
}
```

### `provider` (optional object)

- `name` (required string): provider identity. Must match
  `[a-z0-9][a-z0-9_-]*` and be at most 64 characters. Recorded in run
  events and session metadata; mirrors the `model_provider` field that the
  codex rollout `SessionMeta` already carries in the reference repository
  (`../codex-agent/src/types/rollout.ts`).
- `baseUrl` (required string): OpenAI-compatible endpoint base URL. Must
  parse as an absolute URL, scheme `https`, or `http` only when the host is
  loopback (`localhost`, `127.0.0.1`, `::1`). URLs containing userinfo
  (`https://user:pass@host`), query parameters, or fragments are rejected at
  decode time so credentials can never enter persisted workflow files or argv.
- `apiKeyEnv` (optional string): name of the runtime environment variable
  holding the provider API key. Must satisfy the existing
  `isValidEnvironmentVariableName` rule and must not be a
  `reservedAgentEnvironmentNames` entry. Only the *name* is persisted and
  placed on the command line/config; the value is resolved from the runtime
  environment at process launch and flows through the existing sensitive-env
  redaction (`sensitiveAdapterEnvironmentValues` /
  `redactAdapterSensitiveText`). Inline key values are not representable in
  the schema by design.

### `providerProxy` (optional string)

Selects the CLI transport mechanism used to reach the alternate provider.

- Allowed value in v1: `"codex"`.
- Valid only when `provider` is present.
- `providerProxy: "codex"` requires `executionBackend: "codex-agent"`.
  A claude-code-agent node with `providerProxy: "codex"` is a validation
  error; routing Claude Code traffic through a Codex proxy is out of scope
  (recorded in `design-docs/user-qa/qa-open-model-provider-routing.md`).
- When `provider` is set and `providerProxy` is omitted, the backend's
  native override mechanism is used (see per-backend mapping below). For
  codex-agent the native mechanism and the `codex` proxy are the same
  mechanism, so `providerProxy: "codex"` is an explicit spelling of the
  default codex-agent behavior.

### Decode and validation rules

Enforced in `AgentNodePayload.init(from:)` plus workflow validation, in the
same style as the existing `agentEnvironment` checks:

1. `provider.name` regex/length violation → decode error.
2. `provider.baseUrl` unparsable, wrong scheme, non-loopback `http`, or
   embedded userinfo → decode error.
3. `provider.apiKeyEnv` invalid env-var name or reserved name → decode error.
4. `providerProxy` present without `provider` → decode error.
5. `providerProxy` value other than `codex` → decode error.
6. `provider` on `executionBackend` values other than `codex-agent` or
   `claude-code-agent` (`cursor-cli-agent`, all `official/*` SDK backends)
   → workflow validation error. Official SDK backends already have their own
   `baseURL`/`apiKeyEnv` configuration path and must not gain a second one.
7. `providerProxy: "codex"` with `executionBackend` other than `codex-agent`
   → workflow validation error.
8. Both fields absent → no new validation runs; existing workflows decode
   and validate unchanged.

## Per-Backend Command and Environment Construction

### codex-agent (`CodexAgentCommandBuilder` / `CodexProcessCommandBuilder`)

Provider config maps to Codex `-c` config overrides appended alongside the
existing `configOverrides` handling:

- `-c model_provider=<name>`
- `-c model_providers.<name>.name=<name>`
- `-c model_providers.<name>.base_url=<baseUrl>`
- `-c model_providers.<name>.env_key=<apiKeyEnv>` (only when `apiKeyEnv` is
  set; this is the env-var *name*, which Codex resolves from the child
  process environment)

Ordering: provider overrides are appended after effort-derived overrides and
before `additionalArguments`/`codexAdditionalArgs`, so an advanced user's
explicit `codexAdditionalArgs` can still win the last-write of a `-c` key.
No secret value ever appears in argv; argv stays safe to persist in runtime
artifacts and to echo in errors.

The default auth preflight still verifies that the Codex CLI is available, but
skips `codex login status` when `provider` is configured. Alternate providers
authenticate through `apiKeyEnv`; unrelated default Codex account state must
not block their execution.

### claude-code-agent (`ClaudeCodeAgentCommandBuilder`)

The Claude Code CLI reads its endpoint and token from environment variables,
so provider config maps to process environment, not argv:

- `ANTHROPIC_BASE_URL=<baseUrl>`
- `ANTHROPIC_AUTH_TOKEN=<value of apiKeyEnv>` resolved from the runtime
  environment at launch (only when `apiKeyEnv` is set)

These are injected in `mergedAgentProcessEnvironment` composition order:
adapter base environment, then node `agentEnvironment` bindings, then
provider-derived entries, then the reserved `RIELA_AGENT_BACKEND`. A node
that also writes `ANTHROPIC_BASE_URL` through `agentEnvironment` loses to the
structured `provider` field; validation emits a warning diagnostic for that
overlap so the conflict is visible. The token value participates in the
  provider-aware redaction list. Provider-derived values are sensitive
  regardless of length; stderr, successful output (including recursively
  decoded JSON), runner errors, and every string-bearing backend-event field
  are sanitized before they can be persisted.

### cursor-cli-agent and official SDK backends

Out of scope and rejected by validation (rule 6). Cursor-specific behavior
stays isolated in the `CursorCLIAgent` module and is untouched. Official SDK
adapters keep their existing `OfficialSDKAdapterConfiguration.baseURL` /
`apiKeyEnv` path as the single provider override mechanism for SDK backends.

## Data Flow and Runtime Forwarding

1. Author writes `provider`/`providerProxy` in `node-{id}.json`.
2. Loader decodes with the validation rules above; the fields ride on
   `AgentNodePayload` through `AdapterExecutionInput.node` unchanged, so
   every existing forwarding path (deterministic runner, dispatching
   adapter, scenario adapters, GraphQL node inspection) carries them without
   new plumbing.
3. `DispatchingNodeAdapter` routes by `executionBackend` exactly as today;
   provider handling lives entirely inside the two CLI command builders.
4. Adapter output and backend events gain `provider_name` (string) in their
   payload metadata when a provider override is active, aligning with the
   `model_provider` session metadata recorded by the Codex CLI rollout
   format. The `AdapterExecutionOutput.provider` field keeps meaning
   "backend adapter identity" (`codex-agent`, `claude-code-agent`) and is
   not repurposed.
5. Secrets: persisted artifacts (workflow files, runtime artifacts, node
   execution records, command echoes) may contain provider name, base URL,
   and env-var names — never key values.

## Defaults and Compatibility

- Both fields unset → command argv and process environment are byte-identical
  to current behavior for both backends. This is asserted by golden tests.
- No change to `model`, `modelFreeze`, `effort`, sandbox, tool-policy, or
  session semantics. `model` remains the backend/provider-specific model name.
- Existing `codexAdditionalArgs`-based overrides keep working; the structured
  field is the documented path going forward.

## Deterministic Test Plan (for Step 4 planning)

- Decoding: accept/reject fixtures for every validation rule above,
  including the snake_case `provider_proxy` non-alias behavior.
- Validation: backend-compatibility matrix (rules 6–7) and the
  `agentEnvironment` overlap warning.
- Command construction: codex-agent argv golden tests with and without
  `provider`, with and without `apiKeyEnv`; claude-code-agent environment
  golden tests; assertions that no test provider key value appears in argv.
- Runtime forwarding: `AdapterExecutionInput` round-trip carries the fields;
  backend event payloads include `provider_name` when active.
- Redaction: provider keys injected through `apiKeyEnv`, including short and
  JSON-escaped values, are replaced with `<redacted>` in simulated stderr,
  successful plain/contract output, runner errors, and all backend-event
  fields (including nested `usage` and `metadata`).

## Rollout Constraints

- Work happens only in this feature worktree; no commits, no pushes, no
  changes to the original main worktree.
- Docs/examples updated in the same change: `design-workflow-json.md`
  node-payload section (done in this step), plus an `examples/` workflow
  demonstrating a loopback OpenAI-compatible provider during implementation.
- No new external dependencies; validation must stay deterministic and
  offline.

## Risks

- Codex CLI `-c model_providers.*` key shapes may drift across Codex
  releases; golden tests pin our argv, and `codexAdditionalArgs` remains the
  escape hatch.
- Claude Code environment-variable override names (`ANTHROPIC_BASE_URL`,
  `ANTHROPIC_AUTH_TOKEN`) are vendor-controlled; if a deployment needs
  `ANTHROPIC_API_KEY` instead, `agentEnvironment` still allows manual
  wiring, and the open question is tracked in user-qa.
- Loopback-only `http` may block LAN-hosted inference servers; relaxation is
  an explicit user decision tracked in user-qa rather than a silent default.
