# Node output contracts

Declare `output.jsonSchema` in the node payload. Riela appends that authored schema to the agent's system prompt after rendering workflow and persona templates. Schema strings such as `{{example}}` remain literal. Keep persona prompts focused on the task; duplicating the output shape there is unnecessary. The agent should return the JSON object directly, without prose or fences. When authored instructions require routing metadata, the existing `{ "when": { "condition": true }, "payload": {...} }` envelope remains supported: the schema validates `payload`, not the envelope.

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
