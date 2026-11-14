# JSON input and postprocessing

The `riela/x-gateway-reader` version 1 add-on supports JSON operations as an
alternative to `queryTemplate`. This surface uses the linked read-only X SDK;
no Python, shell, external gateway executable, or query language is required.
These additions target Riela 0.2.39; older installed runtimes do not support them.

```json
{
  "name": "riela/x-gateway-reader",
  "version": "1",
  "env": {"X_GW_TOKEN": {"fromEnv": "ART_X_TOKEN"}},
  "config": {
    "operation": "homeTimeline",
    "arguments": {"maxResults": 25, "paginationToken": "{{input.cursor}}"},
    "selection": [
      "posts.id", "posts.text", "posts.createdAt",
      "posts.author.username", "pageInfo.nextToken"
    ],
    "postprocess": [
      {"pick": "/data/homeTimeline/posts"},
      {"unique": "/id"},
      {"map": {"id": "/id", "text": "/text", "authorId": "/author/username",
               "publishedAt": "/createdAt"}}
    ]
  }
}
```

Arguments keep their JSON types. Strings are encoded as data, including quotes,
newlines, and template-looking text received from upstream. `selection` lists
field paths. Nested `select` remains a compatibility alias for existing X
workflows; migrate each true leaf to its dot-path entry. Operation names,
argument names, and selected fields must be plain GraphQL identifiers; the SDK
validates the operation and argument types against its read schema. JSON mode
cannot be combined with query/variable templates. Existing query-template mode
still works. Set `providerFailure: "output"` to branch on structured X provider
failures; see the [gateway JSON reference](../builtin-gateway-json.md#x-provider-failure-output).

The normal gateway output remains available, including
`data.homeTimeline.pageInfo.nextToken`; transformed data is returned as
`processed`. A workflow passes the cursor to its next retrieval step. One node
execution performs one SDK attempt; it does not hide a retry or pagination loop.
The example retains raw data in the node output: use it inside a private workflow
when source bodies must remain within the guest, and export only reviewed data.

The same operations are available independently with `riela/json-transform`:

```json
{
  "name": "riela/json-transform",
  "version": "1",
  "config": {
    "input": "{{input.posts}}",
    "steps": [
      {"filter": {"path": "/eligible", "equals": true}},
      {"unique": "/id"},
      {"map": {
        "id": "/id",
        "authorId": {"path": "/author/username", "default": "unknown"},
        "reviewRequired": {"literal": true}
      }},
      {"take": 100}
    ]
  }
}
```

Standalone results are returned as `value`. Each step has exactly one operation:

| Operation | Argument | Behavior |
| --- | --- | --- |
| `pick` | JSON pointer | Select a required value from the current value. |
| `filter` | `path`, `equals` | Keep array entries with an exact typed match. Missing differs from null. |
| `map` | Output fields | Construct one object per array entry. A pointer copies a value; `path` with optional `default` handles missing fields; `literal` inserts a constant. |
| `unique` | JSON pointer | Keep the first entry for each string or integer identity; missing identities fail. |
| `take` | Nonnegative integer | Retain the first entries, preserving order. |

Pointers start with `/`; use `/author/username` for nested fields, `/0` for an
array index, `~1` for a slash inside a key, and `~0` for a tilde. The empty pointer
selects the current value. A missing map field becomes null unless a default is
specified; an explicit null remains null. Empty arrays remain empty.

There are no embedded expressions, scripts, subprocesses, or recursive template
evaluation. Pipelines allow at most 32 steps, array operations at most 10,000
entries, and values at most 8 MiB (8,388,608 bytes) of encoded JSON at each boundary. Optional standalone
`config.jsonSchema` validates the final `{ "value": ... }` output envelope.
Editorial decisions (for example, preserving an opinion as an opinion and adding
an unverified-context notice) belong to the review/workflow nodes rather than
being inferred by these data operations.

## Batches and one shared join context

`riela/array-batch` accepts an optional `context`, copied unchanged once alongside
`items`, including when the input is empty. `size` remains a maximum rather than
a minimum: short final batches are emitted immediately. Optional `maxBatchBytes`
(2–8,000,000) also limits each encoded JSON array, including its brackets and
commas. Order is preserved; an individually oversized item fails before dispatch
rather than being dropped. The complete output, context included, still has the
existing 8,000,000-byte bound.

```json
{
  "name": "riela/array-batch",
  "version": "1",
  "config": {
    "items": "{{input.records}}",
    "size": 15,
    "maxBatchBytes": 180000,
    "uniqueBy": "id",
    "context": "{{input.checkpoint}}"
  }
}
```

A transition's `fanout.contextFrom` optionally selects a required JSON Pointer
from its accepted source payload. It is returned once as `fanoutJoin.context`,
separate from branch items and outputs. It is not inserted into branch variables
or interpreted as a template. Use it to retain a proposed checkpoint while the
runtime dispatches and joins independently inspected record batches:

```json
{
  "toWorkflowId": "inspect-record-batch",
  "toStepId": "inspect",
  "resumeStepId": "accept",
  "fanout": {
    "groupId": "record-inspection",
    "itemsFrom": "/items",
    "contextFrom": "/context",
    "itemVariable": "records",
    "concurrency": 2,
    "joinStepId": "accept",
    "failurePolicy": "collect-all",
    "resultOrder": "input",
    "writeOwnership": { "mode": "read-only" }
  }
}
```

The pointer is bounded to 1024 bytes and its resolved value to 8,000,000 bytes;
a missing/oversized context fails before any branch runs. Omission preserves the
previous join shape. Context survives an empty fanout and durable source replay.
A zero-selected wave (empty input or dependency-completed items) publishes one
fenced parent receipt without child reservations;
a changed replay conflicts instead of overwriting that receipt. After an
interruption before delivery, recovery evaluates the original route and dependency
wave, then reconstructs the zero-selected join from the accepted source without
re-running the provider. Untaken conditional routes are not reconstructed. These additions require the
updated runtime in both the host and any private guest.

`array-batch.bindItems: true` requires `uniqueBy`. It emits a native `receipt`
containing the identity key, canonical digest of each original batch and the
caller context. Context is carried once inside the receipt. Set the fanout's
`contextFrom` to `/receipt`, then use `riela/array-gather` at the join:

```json
{
  "name": "riela/array-gather",
  "version": "1",
  "config": {
    "join": "{{input.fanoutJoin}}",
    "groupId": "record-inspection",
    "selectedIdsFrom": "/safe_ids"
  }
}
```

Gather requires a complete join of the expected group. It checks batch count,
unique/contiguous branch indices, terminal success and exact original batch
versions before selecting IDs. Unknown and cross-batch IDs fail; repeated
selected IDs are harmless and never duplicate records. Results preserve source
order, regardless of worker completion order. No worker-supplied replacement
item is returned. Omit `selectedIdsFrom` to gather all original items.

For optional work, set `allowPartial: true` explicitly and use a fanout with
`failurePolicy: "collect-partial"`. Gather still validates every original batch
and branch index, including failed batches. It returns original items selected
by completed branches, plus `failedItemIds` (all original identities belonging
to failed branches) and `failedBatchCount`. Failed outputs are never interpreted
as selections or successful model receipts. Cancellation, running or missing
branches, inconsistent completion flags and modified failed batches are rejected.
The default remains a complete successful join. This option is available in
Riela 0.2.62 and later.

The result is `{items, itemCount, selectedCount, context}`. Empty input returns
zero items and its original context without invoking workers or waiting for a
minimum count. Failed/missing/modified branches cannot advance the joined
checkpoint. The join is bounded to 16 MB including runtime metadata, at most
10,000 branches/items, and the assembled output to 8 MB. The receipt is runtime
binding metadata, not a signature for arbitrary caller-supplied JSON: preserve
it on the trusted fanout context path, outside worker/model output.


## Project nested metadata without copying private or historical fields

The `project` operation is also available to gateway `postprocess` pipelines.
It starts from an object and keeps only explicitly named fields:

```json
{"project": {
  "cursor": "/cursor",
  "groups": {"from": "/groups", "mapValues": {
    "source": "/source",
    "hasItems": {"nonEmpty": "/items"},
    "status": {"from": "/summary", "fields": {"complete": "/complete"}}
  }}
}}
```

A string selector is a JSON Pointer. Missing selected fields are omitted;
explicit nulls stay null. `fields` projects one nested object; `mapValues`
projects each object in a dictionary while retaining its keys. `nonEmpty`
returns a boolean for arrays/objects (missing/null gives false); scalar inputs
are refused. Unknown selectors, expressions, malformed pointers and extra keys
are rejected before processing data. Template-looking source strings remain
literal. Declaration depth is at most 16, with at most 256 fields per level;
a dictionary has at most 10,000 entries and projection visits at most 100,000
objects and selected fields. Standard intermediate/final JSON byte bounds remain in force.
Projection shapes data; it does not prove source completeness or publication.
