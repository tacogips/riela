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
those values. Request pagination stays visible in the workflow graph.

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
