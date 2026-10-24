# Native source collection

Collection nodes own provider pagination, continuation validation and bounded
acquisition. Workflows retain source-specific inspection and presentation.
Use them inside a private workflow when provider content requires screening;
their output is raw provider content until inspected.

Stateful addon dispatch uses a handler registry. Each feature declares its name
and callback next to its implementation; enum-based families register all their
cases. The common dispatcher only looks up the handler and forwards the resolver,
input and execution context. Adding a collector must not introduce a provider
name branch there. Registry tests check unique registrations, public catalog
membership and unknown-addon fallback; normal collector tests exercise dispatch.

## Specified X authors: `riela/x-collect`, version `1`

```json
{
  "name": "riela/x-collect",
  "version": "1",
  "config": {
    "options": "{{input.collection_options}}",
    "context": "{{input.domain_context}}",
    "userCache": true,
    "usageCache": true,
    "usageScope": "my-x-app"
  }
}
```

Bind credentials through the same addon `env` contract as
`riela/x-gateway-reader`. The collector invokes that linked SDK reader through
the ordinary addon execution path, including postprocessing, cancellation,
deadline handling, user cache and usage accounting. No subprocess, custom REST
client, nested container or model is used. Caches default to disabled unless
enabled in the node. User and usage caches remain separate from article caches.

`options` is an object with these fields:

| Field | Contract |
| --- | --- |
| `expectedHandle` | Authenticated account username, 1–15 ASCII username characters; checked before search |
| `authorHandles` | 1–100 distinct usernames; only `from:` recent search queries, packed to 512 bytes |
| `start`, `end`, `earliest` | ISO timestamps; earliest ≤ start < end ≤ current time; exact half-open collection interval |
| `requestedStart` | Optional original start before a policy floor clamp; defaults to start; used in head receipt identity |
| `bounded` | Default true; imported frozen start must match start when true |
| `maxPosts` | 5–5000, default 100; total budget divided between author query shards |
| `maxPages` | 1–1000 per query, default 1 |
| `pageSize` | 10–100, default 25; actual page budget is min(pageSize, shard budget) |
| `freshPage` | Default false; one independent latest page ahead of a pending older window; requires maxPages=1 and capacity for both pages |
| `timezone` | Valid timezone, default UTC; controls when a requested interval is a closed day |
| `previous` | Previous checkpoint object, default empty; includes all author shards and frozen pagination state |
| `select` | Optional SDK response selection object; default includes author, media, references and two quote/repost levels |
| `includeStatusLinks`, `includeCoverageMetadata` | Default false; extend default SDK selection |
| `signatureContext` | Optional settings/fields metadata for legacy receipt identity; never executed |

The result contains `posts`, `checkpoint`, `complete`, finite `failures` and
the unchanged opaque `context`. Exact token, account, query, frozen window,
page count, visited token hashes and recent IDs are validated before search.
Legacy 5–9-post cursor budgets are accepted; SDK maxResults is at least ten,
and oversized responses are rejected atomically rather than skipping posts.
IDs use decimal string comparisons without integer truncation. Pages outside
the requested interval and previously seen IDs are filtered. Cursor cycles,
malformed pages and oversized payloads never advance the checkpoint.

A failed head probe does not prevent backlog acquisition. A failed query does
not prevent the other author queries from returning their accepted pages.
Cancellation propagates. `complete` describes acquisition coverage, never
Notion publication or processing completion. Closed-day head receipts avoid
repeating an already inspected probe with the same scope/settings.

The collector returns checkpoint metadata; it does not durably commit raw data
or acknowledge processing. After inspection, use `riela/collection-checkpoint`
to atomically record exact item ID/version pairs and cursors. Acknowledge only
versions whose downstream processing actually completed. Disposable body-cache
eviction never acknowledges an item or resets its cursor.

Configuration/context and final output are limited to 8 MB, posts to 6 MB.
Provider response text and credentials are excluded from failure summaries.
Do not forward unrelated runtime input/history through context. Preserve
source/account/query/window identity and pending versions during migration.

## Verification and rollout scope

XCollectionTests exercises the real linked SDK addon with an injected transport,
exact cursor continuation, account fences, page-cycle atomicity, independent
query/head failures, small legacy page budgets and a legacy Python signature
golden. An optional metadata-only fixture checks actual old cursor import
without contacting the provider or changing production state.

These tests do not prove deployment. ART integration must preserve its private
screening boundary, durable metadata and original fetched timestamps; release
and install matching host/guest binaries, cut over when idle, then observe real
collection and publication for two hours after the final migration.
