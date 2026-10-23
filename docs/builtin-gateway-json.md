# Built-in gateway JSON requests

Available in Riela 0.2.45, tracked by issue #176. The complete ART migration,
validation/catalog reconciliation and production cutover remain unfinished.

Gateway nodes can receive typed JSON and shape their results without a Python,
shell or JavaScript helper. The workflow still owns pagination, retries,
concurrency and per-item failure handling.

## Available input surfaces

| Add-on family | JSON request | Selection | Execution boundary |
| --- | --- | --- | --- |
| `riela/x-gateway-reader` | literal `operation`, object `arguments` | required field-path `selection`, or compatibility nested `select` | linked read-only SDK; host or private worker |
| `riela/x-gateway-read` | same X JSON contract | same X fields | existing reader container and explicit environment framing |
| `riela/gmail-gateway-reader`, `-draft`, `-sender` | literal `operation`, object `arguments` | optional field paths, literal selection set, or catalog default | fixed-mode async SDK; host or Linux worker |
| `riela/gmail-gateway-read` | same reader JSON contract | same reader selections | existing reader container; validated typed values become document literals |
| `riela/wrike-gateway-read`, `-write`, `-admin` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-tier linked gateway |
| `riela/google-analytics-gateway-read`, `-write`, `-admin` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-tier linked gateway, macOS build |
| `riela/notion-gateway-read`, `-write` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-role SDK, macOS build |
| `riela/google-docs-gateway-read`, `-write`; `google-sheet-gateway-read`, `-write`; `google-drive-gateway-read`, `-write` | literal catalog command in `operation`, object `arguments` | no selection; shape the result with postprocess | fixed-role SDK argv construction and existing command runner, macOS build |
| `riela/google-service-gateway-read`, `-write` | literal operation such as `services.get`, object `arguments` | no selection; shape the result with postprocess | existing typed service client |
| `riela/apple-gateway-graphql` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | macOS SDK; container requests are prepared on the host and use its existing exact-argv bridge |
| Apple Notes, Mail, Calendar, Reminders, notifications and clock product nodes | operation fixed by add-on name; existing JSON `config`/`inputs` | fixed SDK query and output projection | existing native boundary and scoped host bridge |
| named `kaiba/*` nodes | operation fixed by add-on name; object `arguments` | existing typed result projection | preflight-captured HTTP client; host or worker |
| Kaiba GraphQL compatibility nodes | `arguments` containing `query` and optional `variables` | authored GraphQL document | same preflight-captured HTTP client |

The matrix describes execution support. Core catalog discovery and validation
reconciliation are still acceptance work; structural workflow validation alone
does not prove that every operation exists in an installed gateway image.
Availability of a host SDK does not make it available in a Linux guest: only
Gmail, Wrike and X in this matrix have portable linked execution, while native
Apple operations use the host bridge. Existing provider authorization still
applies.

For catalog-backed gateways, `operation` and `selection` are literal authored
values. `arguments` renders once: exact placeholders preserve numbers, booleans,
arrays, objects and null. A substituted source string containing `{{...}}` is
not evaluated again. Unknown operations, invalid fields and type errors are
rejected before provider execution. Legacy Gmail reader documents are rechecked
after type-aware literal serialization, including enum values. Legacy container
JSON documents are limited to 120,000 UTF-8 bytes to fit a Linux argv entry.

Existing GraphQL `queryTemplate`, Docs command/flags and fixed product-node
inputs remain available. Do not mix them with a JSON operation request. Google
Service and Kaiba nested arguments exclude flat config and explicit addon input
overrides. In nested Kaiba GraphQL arguments, `query`, `document` and
`operationName` must remain literal; template data only inside `variables`.
Select the Kaiba instance through top-level `kaibaInstanceId`, not
through argument data; endpoint and authentication remain captured by preflight.

## Example: X posts and their authors

```json
{
  "name": "riela/x-gateway-reader",
  "version": "1",
  "config": {
    "operation": "homeTimeline",
    "arguments": {"maxResults": 25, "paginationToken": "{{input.cursor}}"},
    "selection": ["posts.id", "posts.text", "posts.author.username", "pageInfo.nextToken"],
    "postprocess": [
      {"pick": "/data/homeTimeline/posts"},
      {"map": {"id": "/id", "text": "/text", "authorId": "/author/username"}}
    ]
  }
}
```

Bind the X credential variables explicitly through `addon.env`. Supply a null
cursor for the initial page when its gateway schema permits it. The workflow
can read the original `data.homeTimeline.pageInfo.nextToken`; shaping does not
discard pagination metadata or fetch the next page implicitly.

## Finite postprocess

Every built-in resolver accepts optional `config.postprocess`, using the same
finite operations as `riela/data-transform`:

| Instruction | Meaning |
| --- | --- |
| `{"pick":"/data/items"}` | select a JSON Pointer |
| `{"map":{"id":"/id","author":"/author/username"}}` | project each array element into named fields |
| `{"filter":{"path":"/enabled","equals":true}}` | retain matching array elements |
| `{"unique":"/id"}` | keep the first element for each pointer value |
| `{"take":25}` | retain at most that many array elements |

Limits are 32 instructions, 8 MiB intermediate values and 10,000 array entries,
with bounded paths and mapping fields. No expression evaluation, script or
implicit provider retry is available. JSON Pointer rules include `/` and `~`
escaping. Missing `map` field paths project as null; missing `pick` or `unique`
paths fail shaping. `unique` keys must be strings or integers.

The original provider payload remains present. Shaped output is
`payload.processed`. Success sets `postprocessPassed`; a data-dependent failure
sets `postprocessFailed` and returns `postprocess.status: failed` with
`retryProvider: false`. Branch on those flags before consuming `processed`.
This also applies to X reads: shaping failure no longer implicitly fails and
retries their provider operation.

Instruction syntax is compiled before provider effects. After a completed
write, shaping failure preserves the provider result, completion state and
internal finalization receipt. Container dispatch strips the program from its
leaf request so it runs once. Mock-scenario responses use the same shaping path.

Docs operation construction retains its existing command runner; it does not
add the SDK `invoke` file-access policy or execution limits. Apple preparation
retains explicit write-retry metadata and its existing workspace/mount rules.

An executable single-node example with a credential-free mock scenario lives
in [`examples/builtin-gateway-json`](../examples/builtin-gateway-json/README.md).
