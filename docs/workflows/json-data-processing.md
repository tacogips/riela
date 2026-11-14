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
    "select": {
      "posts": {"id": true, "text": true, "createdAt": true,
                "author": {"username": true}},
      "pageInfo": {"nextToken": true}
    },
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
newlines, and template-looking text received from upstream. `select` uses `true`
for leaf fields and nested objects for child fields. Operation names, argument
names, and selected fields must be plain GraphQL identifiers; the SDK validates
the operation and argument types against its read schema. JSON mode cannot be
combined with query/variable templates. Existing query-template mode still works.

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
entries, and values at most 8 MB at each boundary. Optional standalone
`config.jsonSchema` validates the final `{ "value": ... }` output envelope.
Editorial decisions (for example, preserving an opinion as an opinion and adding
an unverified-context notice) belong to the review/workflow nodes rather than
being inferred by these data operations.
