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

## Gmail: `riela/gmail-collect`, version `1`

```json
{
  "name": "riela/gmail-collect",
  "version": "1",
  "config": {
    "options": "{{input.gmail_options}}",
    "context": "{{input.domain_context}}"
  }
}
```

The feature registers its handler locally and calls `riela/gmail-gateway-reader`
through normal native dispatch. Bind the ordinary Gmail credential environment
on this addon. No Python, models, subprocess gateway or REST client is involved.
Run it inside a private workflow when mailbox content requires inspection.

Options are `accountId` (nonempty opaque configured account name, at most 256
UTF-8 bytes), `queries` (1–64 nonempty strings), `maxThreads` (1–10000, default
100), `lookbackHours` (1–168, default 24), optional `window` (two ordered ISO
instants) or `receivedAfter`, `bodyMessageIds` (up to 32 distinct message IDs),
`providerBodyMetadata` (default false), `minRequestIntervalSeconds` (0–60,
default 2.5) and `previous` (checkpoint object). A fixed window replaces relative
Gmail date predicates with conservative epoch bounds; lookback scans freeze
their cutoff. Empty-body scopes preserve the legacy canonical query/window
hash. Explicit body requests and explicit cutoffs have distinct scope identities.

Results contain raw `threads`, metadata-only `checkpoint`, `invalidated` thread
IDs, `complete`, finite `failures`, `requestCount` and unchanged opaque `context`.
The native collector owns profile checks, mailbox/thread versions, pagination,
body-byte reads, cancellation and rate/deadline bounds. Account, thread and
message identities and complete body contracts are checked before accepting a
thread. An item failure leaves that item's prior version unacknowledged, while
other valid threads return immediately. Returned versions are acquisition
metadata, never evidence of downstream inspection or publication.

One bounded scan runs per invocation. `pending_scans` retains each exact frozen
listing/cursor, original mailbox version, cutoff, completed IDs and failed IDs.
Exhausted listings coalesce unresolved IDs into one retry backlog, without
multiplying scans for the same poison item. A changed profile can start a fresh
scan on alternating turns; failed old scans
cannot monopolize discovery. Failed IDs rotate deterministically even with a
one-thread budget. A conservative discovery watermark retains older scan floors
across long-running lookbacks. Finishing an old scan preserves newer fresh
thread membership and versions; a subsequent clean fresh pass acknowledges the
current mailbox. At most 32 pending scans are retained; capacity exhaustion is
explicit partial progress rather than fabricated coverage.

Scope changes archive exact pending metadata under `collection_scopes`, including
body-request changes. Up to 64 archived scopes fit the global byte bound;
completed scope history is evictable, unresolved scopes are retained. Mailbox
identity changes reset the selected mailbox state. No thread body is persisted
in these checkpoints. Article caches remain separate disposable LRU storage.

The whole output, including context and continuation/archive metadata, is at
most 8 MB. Each candidate thread is checked against the remaining output budget
before its version advances; an oversized item cannot discard the accepted
prefix. Failure summaries are capped and contain finite codes/IDs, never provider
error text or credentials. Native SDK calls have a 30-second ceiling and finish
before the outer deadline, leaving time to return partial progress. These bounds
do not make a hung or failing provider complete.

`riela/page-state` also supports `action: "resume"` with an unchanged saved
`state`, validates it and returns derived request/items/completion without I/O.

## Durable snapshots: `riela/snapshot-store`, version `1`

```json
{
  "name": "riela/snapshot-store",
  "version": "1",
  "config": {
    "action": "commit",
    "storage": {
      "memoryId": "source-window",
      "workflowId": "source-poll",
      "nodeId": "collect",
      "tag": "checkpoint"
    },
    "expectedHead": "{{input.loaded_head}}",
    "value": "{{input.checked_snapshot}}"
  }
}
```

Use `action: "load"` without `expectedHead`/`value` first. Results are `found`,
`head` (record ID, evolution version and scope digest), `value`, and unchanged
optional `context`. `expectedHead: null` means create only if no matching record
exists. An update requires the exact head read from the same storage namespace.
The namespace digest covers the canonical memory root, memory/workflow/node IDs
and tag, so equal row/revision numbers in separate databases cannot authorize a
cross-scope update. The default root follows `RIELA_MEMORY_ROOT` or the ordinary
Riela memory root. An explicit `nodeId: null` selects the workflow-wide view;
omitting it selects the current node. Omit `workflowId` to use the current workflow.

The native store selects the latest matching tagged memory record, reads its
payload and revision atomically, and performs compare-and-commit with readback
under one SQLite write transaction. Existing records, tags, attachments, row IDs
and evolution history remain in place. Legacy schema-3 records without evolution
metadata get a baseline v1 atomically without changing source data or timestamps.
Missing retired history fails closed. Storage directories/files are private;
provider content, cache ownership and processing/publication ACKs are not inferred.

The node defaults to a 7,990,000-byte payload budget and an 8 MB frame. An explicit
`maxPayloadBytes` supports existing larger metadata snapshots up to 64 MiB minus
4 KiB, reserving the transport envelope. The whole response is bounded, including
context, before a commit. This is a metadata/transport limit, not article cache
capacity. Disposable bodies still use their independently configured normal LRU.

`node run ... --variables @-` accepts UTF-8 JSON directly on stdin, bounded to
64 MiB. Whole typed configuration references retain literal template-looking
strings in snapshot data. The snapshot feature declares that CLI variables are
data rather than authored addon input bindings; the generic node runner reads
this registration metadata. Workflow-authored bindings and common postprocess
remain supported. No provider-name branch is added to common dispatch.

ART's compatibility client now uses this native operation for snapshot reads,
revision fences and commits. Read-only inspection does not refresh a writer's
observed head. Updating an existing snapshot requires an explicit prior load;
blind writes never adopt a new head implicitly. The remaining ART body-manifest,
missing-body recovery selection and outer coordination still need migration.

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
