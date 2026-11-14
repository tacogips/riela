# Node output contracts

Declare `output.jsonSchema` in the node payload. Riela appends that authored schema to the agent's system prompt after rendering workflow and persona templates. Schema strings such as `{{example}}` remain literal. Keep persona prompts focused on the task; duplicating the output shape there is unnecessary. The agent should return the JSON object directly, without prose or fences. When authored instructions require routing metadata, the existing `{ "when": { "condition": true }, "payload": {...} }` envelope remains supported: the schema validates `payload`, not the envelope. If an agent returns a valid boolean `when` map but places its business fields beside it instead of under `payload`, Riela normalizes those sibling fields (excluding `when` and `completionPassed`) as the payload, records a routing diagnostic on the accepted output (also on the in-process agent-gateway path), and still validates them against the schema. A non-object `payload` or a non-boolean `when` value is still rejected. Because of this, a top-level `when` key is reserved for routing: a schema property named `when` that holds a boolean map, without a `payload` beside it, is treated as routing and removed from the payload. Name such a business field differently.

Both workflow bundle validation and runtime preflight use the same dialect checker as output publication. Invalid or unsupported contracts fail before an adapter runs, including unsupported keywords nested in properties, items, additional properties, or combinators.

Supported keywords are `$schema`, `title`, `description`, `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`, `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `minItems`, `maxItems`, `uniqueItems`, `anyOf`, `oneOf`, and `allOf`. `$schema` is metadata, not a dialect selector. Subschemas must be objects; boolean schemas, references, and conditional keywords (`if`, `then`, `else`) are unsupported. `additionalProperties` additionally accepts a boolean.

Output payloads are always top-level JSON objects. Preflight rejects contracts excluding objects, incompatible finite const/enum candidates, required properties forbidden by `additionalProperties: false`, and combinator branches that clearly exclude objects. These are bounded static checks, not a general satisfiability solver: constraints across complex branches can still be impossible, and every produced payload is validated at publication.

## Agent execution and downstream payload use

Agent nodes using `codex-agent`, `claude-code-agent`, or `cursor-cli-agent`
must declare `agentSandbox` explicitly. API-backed nodes must not declare it,
because those backends do not consume the sandbox setting. Validation rejects
both omissions and ignored declarations before execution.

An `output` block selects the strict envelope path. Riela tolerantly extracts
one JSON object from a direct answer, balanced prefix, fenced block, or
embedded object; malformed extraction or envelope shape is a validation
rejection. An undeclared `maxValidationAttempts` defaults to 2 for every node
with an `output` block, including description-only contracts. A node without
an `output` block gets one attempt and its full answer is always published as
`{"text": ...}`; it is never interpreted opportunistically as an envelope.
When every attempt is rejected, the session fails with failureKind
`adapterFailure`, so `riela session resume <session-id> --retry-failed-step`
can retry that step after the prompt or contract is fixed.

Declare `output.jsonSchema` whenever a downstream add-on config/input template
reads the payload (`{{field}}`, `{{input.field}}`, or
`{{inbox.latest.output.payload.field}}`) or a step uses conditional transition
labels. Validation walks backward through payload-forwarding add-ons to the
agent producer and checks that each referenced first-segment field appears in
`schema.properties`.

Add-on config and inputs resolve payload references strictly before the add-on
body runs. A missing field fails with `template_resolution_failed`, naming the
delivering step, template path, consumer step, and add-on. Optional context
namespaces—`event`, `workflowInput`, `runtime`, `upstream`, and `_rielaInput`
(including runtime roots under `input`)—remain lenient and render missing
values as an empty string. Agent prompt templates remain lenient.

## Data-dependent schemas and native structured output

`output.jsonSchemaFrom` reads an object schema from the step's merged prompt
variables at run time. When a static `output.jsonSchema` is also declared,
both apply through a root `allOf`. Static validation cannot inspect a
request-bound schema: when a node declares only `jsonSchemaFrom`, payload
fields that downstream templates or conditional labels use are checked only at
run time. Declare a static `jsonSchema` for the fields you want proven by
`workflow validate`.

`output.nativeStructuredOutput: true` hands the schema to Codex as
`--output-schema`. It requires a fresh `codex-agent` session (validation also
checks a step-level `sessionPolicy`) and exactly one schema source: combining
`jsonSchema` with `jsonSchemaFrom` would give the vendor a root `allOf`, which
strict structured output does not accept, so validation and the runtime both
reject it.
