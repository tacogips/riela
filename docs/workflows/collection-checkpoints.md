# Incremental collection without Python

`riela/collection-checkpoint` version `1` keeps opaque pagination cursors and
item ID/version pairs in built-in durable KV. Gateway requests, cache access,
fanout and processing remain ordinary workflow nodes. This node performs no
network request, model call, hidden pagination loop or automatic retry.

Use a distinct `key` for each provider/account/query/window. For example,
`x/kenn/latest`, `gmail/personal/inbox`, or `feed/example`. `scope` defaults to
the workflow ID; `storeId` defaults to `collection-checkpoints`. `kvRoot` has
the same meaning as for the KV builtins. None of these names contains a secret.
Changing the query or a frozen backfill interval requires a separate key;
do not reuse a completed backfill cursor for a different interval.

Load before issuing a page request:

```json
{"name":"riela/collection-checkpoint","version":"1","config":{
  "action":"load","key":"x/kenn/latest"
}}
```

The payload contains `revision`, `cursor` (string or null),
`acquisitionComplete`, `pending` and `acknowledged` arrays of `{id, version}`,
`pendingCount`, and `processingComplete`. A new key has revision 0, null cursor,
acquisitionComplete false and no items. A load never creates a database.
Routing flags `acquire` and `process` indicate incomplete acquisition and
pending processing respectively; `always` is also true. Use `acquire` before
a gateway step to avoid repeating a completed fixed-window API scan.

After a successful, inspected gateway page and its cache write, record its
exact item versions and next cursor together:

```json
{"name":"riela/collection-checkpoint","version":"1","config":{
  "action":"record","key":"x/kenn/latest",
  "expectedRevision":"{{input.checkpointRevision}}",
  "items":"{{input.checkedItemVersions}}",
  "cursor":"{{input.nextCursor}}",
  "acquisitionComplete":"{{input.scanComplete}}"
}}
```

Templates preserve JSON types. `items` is an array of objects containing
exactly `id` and `version`, both nonempty strings. Source content is never
template-evaluated again. Record only a successfully obtained page; an API
failure must leave the previous checkpoint unchanged. The node cannot infer
whether a provider cursor means a page token, newest ID or timestamp, or
whether the provider completed its scan: the authored gateway mapping supplies
those values. For ordinary page-token pagination, omit `acquisitionComplete`
to derive completion from a null cursor. For watermarks such as newest IDs,
supply the completion boolean explicitly. Request pagination stays visible
in the workflow graph.

Acquiring the next page does **not** wait for pending items to be processed.
After successful downstream processing/publication, acknowledge only the
versions covered by actual completion receipts:

```json
{"name":"riela/collection-checkpoint","version":"1","config":{
  "action":"acknowledge","key":"x/kenn/latest",
  "expectedRevision":"{{input.currentRevision}}",
  "items":"{{input.completedItemVersions}}"
}}
```

Acknowledgement of an already acknowledged version is harmless; an unknown
version is rejected. Acknowledging version 1 cannot remove pending version 2
of the same ID. The node trusts the workflow's completion boundary and does
not replace the publisher's receipt validation.

Every mutation requires the revision from the latest load or mutation result.
A stale/concurrent mutation fails before changing state; reload and recompute
the metadata operation, without repeating an already performed gateway write
or publication. SQLite compare-exchange commits the cursor and pending set
atomically across runtime processes.

The state contains metadata only, never article bodies or credentials. Use a
disposable cache for bodies; a missing body is refetched by ID. Cache eviction
neither acknowledges an item nor changes a cursor. An item failure remains
pending while other items and sources proceed. Keep raw acquisition and its
screening nodes inside a private workflow when required by the application.

Limits: 10,000 pending pairs, 10,000 recently acknowledged pairs, 1,024 UTF-8
bytes per ID/version, 16 KiB encoded cursor and 8 MB encoded state. A mutation
that exceeds a pending/state limit fails without changing the checkpoint;
pending work is never silently discarded. Old acknowledged pairs age out in
insertion order, which can cause refetches but cannot discard pending work.
This source addition does not migrate an existing application's checkpoint
format or constitute an ART deployment.

## Page traversal inside a workflow

`riela/page-state` version `1` supplies provider-neutral pagination state. It
does not call a gateway or write durable memory. Keep it inside the private
workflow when its `context` or gateway response contains private data.

Start with an array of query descriptors, an explicit collection bound and
RFC 6901 pointers into the provider response:

```json
{"name":"riela/page-state","version":"1","config":{
  "action":"start","queries":["in:inbox","label:news"],"maxItems":1000,
  "itemsPath":"/edges","identityPath":"/node/id",
  "cursorPath":"/pageInfo/endCursor","hasMorePath":"/pageInfo/hasNextPage",
  "identitySyntax":"identifier","context":"{{input.privateContext}}"
}}
```

The output contains `state`, stable deduplicated string `items`, `request`
(`query` and nullable `cursor`), `complete`, and unchanged `context`.
`when.more` selects another gateway call; `when.done` selects processing.
After that call, use `action: "accept"`, passing the previous `state`, the
gateway `response`, and any current `context`. Cursor cycles, missing cursors
on a nonterminal page and exceeded limits fail without emitting new state.
Completing one query clears its cursor before the next query starts.

Defaults are `/items`, `/id`, `/nextCursor`, and a 10,000-item limit. Without
`hasMorePath`, a nonempty cursor means another page. An empty `identityPath`
selects scalar string items. `identitySyntax` is `opaque` (default),
`identifier` (ASCII letters, digits, `_`, `-`; at most 256 bytes), or `decimal`
(1–32 digits). At most 64 queries, 1,000 cursors per query and 10,000 unique
IDs are accepted. State contains descriptors, IDs and cursors; bodies belong
in the separate disposable cache. Exceeding `maxItems` is an error, not silent
truncation or proof that the source was exhausted.

## Routing and gateway arguments

`riela/json-route` version `1` selects exactly one declared transition label:

```json
{"name":"riela/json-route","version":"1","config":{
  "value":"{{input.stage}}","cases":["list","body"],"payload":"{{input}}"
}}
```

An unknown value fails. Cases must be unique labels (1–64 ASCII letters,
digits, `_`, `-`, or `.`), with 1–32 cases. The payload must be an object;
an object containing both `when` and `payload` is rejected because it could
override the selected route during output normalization.

Gateway `arguments` accepts an object or one exact typed reference such as
`"{{input.arguments}}"`. Its resolved value must be an object within the
existing gateway size and catalog limits. Source strings are never rendered
again; an argument containing literal `{{...}}` stays data. Operation names
and selection paths remain literal and catalog-validated.
