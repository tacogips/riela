# Declarative data and private agent steps (0.2.37)

Use workflow nodes for data wiring, fanout, model execution and contracts. A
Python/CLI wrapper is not required for these operations.

## Typed data composition

`riela/json-compose` version `1` accepts `config.payload` (an object). Existing
add-on templates preserve exact typed values (`"{{topics}}"` can be an array).
Values substituted from application data are never rendered a second time.
Optional `config.jsonSchema` rejects invalid output before it is published.
The schema is literal (it is never template-rendered) and is checked against
the supported dialect before any work; an unsupported schema is an
`invalid_input` error, while output that breaks a valid schema is
`invalid_output`. This applies to every data add-on below.
Unknown config fields are errors. Maximum encoded output is 8 MB.

With `payload: "{{input}}"`, whole-input relays forward application fields and
omit the runtime's top-level `_rielaInput`, `upstream` and `runtime` history
views. These views are reconstructed for each step; forwarding them would copy
the preceding transcript repeatedly. Nested application fields remain exact.
To include a history view intentionally, project it explicitly, for example
`payload: {"history": "{{input.upstream}}"}`. The normal output limit still applies.

`riela/array-batch` version `1` accepts `items`, `size` (default 1), `minItems`
(default 0), `maxItems` (default 10000), and optional `uniqueBy` (a top-level string
identity field). It returns `{items: [[...], ...], itemCount, batchCount}` in
input order. An incomplete final batch is emitted immediately; empty inputs
produce no batches. Bounds and duplicate/missing identities fail before fanout.
Optional `jsonSchema` validates the entire output object. This operation does
not buffer/wait for more inputs or call a model.

## Data-dependent agent output schemas

Declare, for example:

```json
"output": {
  "jsonSchemaFrom": "/runtimeVariables/editor_schema",
  "maxValidationAttempts": 1
}
```

The JSON pointer selects an object schema from this step's merged prompt
variables. It is resolved and checked against Riela's supported schema dialect
before adapter invocation. Missing, invalid, unsupported or oversized (1 MB)
schemas fail closed. The same resolved contract reaches the adapter, prompt
guidance and accepted-output publisher. If `jsonSchema` is also declared, both
contracts apply using `allOf`; a supplied schema cannot relax the static one.
Workflow validation cannot inspect a request-bound schema. With only
`jsonSchemaFrom`, payload fields used by downstream templates or conditional
labels are not checked by `workflow validate`; they are enforced only when the
step runs. Also declare a static `jsonSchema` listing those fields to have them
proven statically. `nativeStructuredOutput` accepts only one of the two schema
sources (see docs/output-contracts.md).

Agent tool-policy argv strings also support one-pass templates. Missing/null
bindings are errors, not empty policy arguments. Each result stays one argv
element; no shell parsing or recursive template evaluation occurs.

Trust rule: tool-policy arguments choose backend behavior (for example
`["-c", "{{catalogArgument}}"]` selects a Codex config override), so their
templates bind only author- or operator-controlled data: the node's own
`variables` and the run's workflow input (also as `runtimeVariables.*`).
Upstream step output is model-produced and is never a source. A reference that
only upstream output provides fails with `template_resolution_failed`, and an
upstream value that shadows a trusted key with a different value is
`policy_blocked`. Whatever the source, a substituted value must not add a line
break, and an argument that begins with a template must not render to an option
(a leading `-`). Put a literal prefix in the template (`key={{value}}`) when the
value itself may start with `-`. Values a fanout copies into a branch's
workflow input count as workflow input, so do not fan out model output into a
tool-policy binding.

### Tool-policy presets

Set `agentToolPolicy.preset` to `"none"` to give an agent no tools, or to
`"web-search"` to allow only the vendor's hosted web search. Unknown values
fail when the workflow loads. `mode` may be omitted; a preset cannot be combined
with `mode: "backend-default"`.

| Backend | `none` | `web-search` |
|---|---:|---:|
| `codex-agent` | yes | yes |
| `claude-code-agent` | yes | yes |
| `official/openai-sdk`, `official/anthropic-sdk`, `official/gemini-sdk`, OpenRouter via the `openai-sdk` provider | yes | yes |
| `official/cursor-sdk` | yes | no |
| `cursor-cli-agent` | no | no |

The host runtime expands CLI presets to explicit arguments before dispatch, so
sandbox and container guests receive the resolved policy. Authored
`additionalArguments` follow the preset arguments, then the backend-specific
arguments. Codex ignores user config and rules, clears MCP servers, disables
tool features, selects web search `disabled` or `live`, and uses an ephemeral
session unless the node reuses its session. Claude Code limits tools to `""`
or `WebSearch` (with `--allowedTools WebSearch` for web search), uses a strict
empty MCP config, and disables slash commands. The exact argument lists are in
[`Sources/RielaCore/AgentToolPolicyPresetArguments.swift`](../../Sources/RielaCore/AgentToolPolicyPresetArguments.swift).

SDK backends send no tools for `none`. For `web-search`, the adapter enables
the vendor's hosted search: OpenAI `web_search`, Anthropic `web_search`, Gemini
`google_search`, or the OpenRouter `web` plugin. Running
`riela workflow run --supervisor-mode` re-enables Codex `multi_agent` on top of
a preset. Older Riela builds ignore the `preset` key; CLI nodes on those builds
use their default tools, so use a build that includes preset support.

```json
{
  "executionBackend": "codex-agent",
  "model": "gpt-5-codex",
  "promptTemplate": "Summarize the supplied text.",
  "agentToolPolicy": {"preset": "none"}
}
```

```json
{
  "executionBackend": "claude-code-agent",
  "model": "claude-sonnet-4-5",
  "promptTemplate": "Search the web for the latest release.",
  "agentToolPolicy": {"preset": "web-search"}
}
```

```json
{
  "executionBackend": "official/gemini-sdk",
  "model": "gemini-2.5-flash",
  "promptTemplate": "Search the web for the latest release.",
  "agentToolPolicy": {"preset": "web-search"}
}
```

The Gemini SDK example requires `GEMINI_API_KEY` to be set.

## Container-private HOME and credential projection

```json
"sandbox": {
  "backend": "container",
  "networkPolicy": "egress-allowed",
  "ephemeralHome": true,
  "credentialEnvironment": {"MODEL_AUTH_JSON": ".codex/auth.json"},
  "container": {"runtime": "apple-container", "image": "trusted-agent-image:local"}
}
```

The trusted image must contain `/opt/riela/riela` and the selected vendor CLI.
Riela creates HOME in the container's `/tmp` tmpfs, starts the model in `/tmp`,
and mounts no host workspace/session HOME. Additional explicit read-only mounts
are permitted. Writable host mounts, file credential projections and session
reuse are rejected in this mode.

The worker's stdin request carries the complete adapter input: rendered prompts,
merged variables, resolved `agentEnvironment` bindings (merged into the vendor
process environment in the guest) and the selected `credentialEnvironment`
values. Credential values are not resolved from article input, put into the
authored node, sent on argv, forwarded to the container client's environment or
written to host credential files. The worker creates the selected relative HOME
files with owner-only permissions. Missing credentials fail before a container
starts. Names listed in `sandbox.environment` are different: their values are
passed as `-e NAME=VALUE` on the container `run` argv and are visible to `ps`
and container inspect. Never list secrets in `sandbox.environment`; use
`credentialEnvironment` for anything sensitive.
Removal of the owned container discards model state and refreshed credentials.
The init process runs only a bounded sleep. The model worker runs through an
attached exec pipe, keeping private stdio out of Apple Container init logs.
The exact owned container is deleted on success, failure and cancellation; the
sleep deadline also bounds its lifetime if the controller disappears. Docker/
Podman persistent logging is disabled. The trusted image also needs /bin/sleep.

If the controller crashes, its admission slot is released by the kernel at once,
but the detached guest keeps running until its sleep ends (node deadline plus 30
seconds). A shared pool can therefore briefly run more guests than its capacity
after a crash. Without a node deadline an ephemeral agent is capped at 600
seconds. Ephemeral agent guests get no Riela-imposed resource bounds: `/tmp` is
an unsized tmpfs and no `--memory` or `--pids-limit` is added (only the private
workflow worker sizes `/tmp`, at 256 MiB). Set runtime-level memory/pids limits
for images that process untrusted input.

This is an agent execution boundary. It does not make arbitrary input already
stored by a caller disappear, nor does it run an entire private collection graph
inside the guest. Workflows which prohibit raw acquisition data in controller
state must retain that boundary until the whole private graph is migrated.

Ephemeral agents require an explicit output JSON schema. The guest validates the
final payload before it leaves the container; the controller validates it again
before publication. Provider/tool events, echoed prompts and raw provider usage
metadata stay in the guest. Failure messages contain only a finite error code
and a fixed message. Routing labels must match `^[A-Za-z0-9_.-]{1,64}$` with at
most 32 entries, and vendor-reported provider/model strings outside a bounded
identifier pattern are replaced by the configured model or `unreported`; the
guest enforces both and the controller re-checks them. Version 0.2.36 was an
unpublished draft and must not be used for this private boundary.

Output-contract rejections (unparseable agent text, a schema-invalid payload or
`completionPassed: false`) cross the worker boundary as a dedicated `rejected`
record, so sandboxed and ephemeral nodes get the normal `maxValidationAttempts`
retry (default 2 when `output` is declared). Ephemeral guests send only a fixed
rejection text; non-ephemeral workers send the real reason.


## Explicit prompt inputs and native Codex schema (0.2.38)

Set `includeRuntimeVariablesInPrompt: false` on an agent node to send only the
rendered authored templates and normal contract/memory/review guidance. Templates,
`jsonSchemaFrom`, tool arguments and internal runtime variables still resolve;
the complete runtimeVariables object is no longer appended to the system prompt.
The default preserves the existing automatic inclusion behavior. This is a prompt
size control, not a controller-state redaction or input isolation boundary.

Set `output.nativeStructuredOutput: true` with `jsonSchema` or `jsonSchemaFrom`
to give a fresh Codex turn the exact resolved schema through `--output-schema`.
Riela creates a private directory/file next to the vendor execution, removes it
on every exit and still validates the final output normally. With ephemeral agent
execution the schema lives in guest tmpfs. Other backends, session reuse and an
additional authored `--output-schema` flag fail before vendor execution. No retry
without the schema occurs. Use a schema supported by Codex's structured-output
dialect; this option does not rewrite or relax the authored schema.

Isolated worker protocol v4 lists capabilities explicitly (`ephemeral-home`,
`native-structured-output`, `validation-rejection`); the worker refuses any
request whose capability set does not match what the node needs, so a guest
never ignores an option it does not understand. A v4 worker answers v1-v3
requests with a fixed `policyBlocked` failure in the old record format, and a
v4 host refuses records from older workers with a fixed "update the worker
image" error, both before a model starts.
