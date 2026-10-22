# Declarative data and private agent steps (0.2.37)

Use workflow nodes for data wiring, fanout, model execution and contracts. A
Python/CLI wrapper is not required for these operations.

## Typed data composition

`riela/json-compose` version `1` accepts `config.payload` (an object). Existing
add-on templates preserve exact typed values (`"{{topics}}"` can be an array).
Values substituted from application data are never rendered a second time.
Optional `config.jsonSchema` rejects invalid output before it is published.
Unknown config fields are errors. Maximum encoded output is 8 MB.

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
Agent fields used for downstream routing/templates must still be declared in a
static schema so workflow validation can prove those dependencies.

Agent tool-policy argv strings also support one-pass templates. Missing/null
bindings are errors, not empty policy arguments. Each result stays one argv
element; no shell parsing or recursive template evaluation occurs.

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

Only the named runtime environment values enter the worker's stdin request.
They are not resolved from article input, put into the authored node, sent on
argv, forwarded to the container client's environment or written to host
credential files. The worker creates the selected relative HOME files with
owner-only permissions. Missing credentials fail before a container starts.
Removal of the owned container discards model state and refreshed credentials.
The init process runs only a bounded sleep. The model worker runs through an
attached exec pipe, keeping private stdio out of Apple Container init logs.
The exact owned container is deleted on success, failure and cancellation; the
sleep deadline also bounds its lifetime if the controller disappears. Docker/
Podman persistent logging is disabled. The trusted image also needs /bin/sleep.

This is an agent execution boundary. It does not make arbitrary input already
stored by a caller disappear, nor does it run an entire private collection graph
inside the guest. Workflows which prohibit raw acquisition data in controller
state must retain that boundary until the whole private graph is migrated.

Ephemeral agents require an explicit output JSON schema. The guest validates the
final payload before it leaves the container; the controller validates it again
before publication. Provider/tool events, echoed prompts and raw provider usage
metadata stay in the guest. Failure messages contain only a finite error code
and a fixed message. Private worker protocol v2 rejects older guest workers
before starting a model. Version 0.2.36 was an unpublished draft and must not be
used for this private boundary.


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

Native structured output uses isolated worker protocol v3 so older guest workers
reject the request before starting a model instead of ignoring the new option.
