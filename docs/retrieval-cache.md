# Temporary retrieval cache

`RielaCacheStore` and `riela cache` store disposable, inspected retrieval data.
They are separate from durable workflow memory, KV storage, persona memory,
version history, pagination checkpoints, and user exports such as Notes.
No existing durable memory is expired or migrated automatically.

The default policy is a **24-hour fixed TTL and 256 MiB shared LRU budget**.
Configure the policy explicitly; it persists per cache ID and applies across
all its scopes. Accesses and puts do not reset the policy. `fetchedAt` is the
actual acquisition/inspection time, not a post's publication time. A get
updates LRU order but never changes `fetchedAt` or extends freshness. Replaying
the same put preserves revision and expiration. Older acquisitions cannot
overwrite a newer current row. Expiration is inclusive at `expiresAt`.

```sh
riela cache configure inspected-retrieval --ttl-seconds 86400 --max-bytes 268435456
riela cache put inspected-retrieval --scope x-following --entries-file -
riela cache get inspected-retrieval --scope x-following --keys-file -
riela cache prune inspected-retrieval
```

All commands accept `--cache-root DIR` (default `.riela/cache`) and print one
compact JSON value per line with sorted keys, so repeated runs print identical
bytes. Most commands print one result object. `cache keys CACHE --scope S`
prints a JSON array of keys with `--output json` (the default) and one JSON
string per key with `--output jsonl`. Every command except `maintain` needs the
positional cache ID. Use `--help` for options. TTL accepts 1...31,536,000
seconds; for *n* hours pass *n × 3600*. The live budget accepts
1...68,719,476,736 bytes. Invalid settings fail before eviction.

Cache IDs starting with `x-gateway-` are reserved for built-in runtime caches
(the X gateway user cache and API-usage cache). `configure`, `put`, `protect`,
`reconcile`, `delete` and `prune` refuse them with a usage error, and every
workflow add-on except `riela/cache-maintain` refuses them with
`policy_blocked`. Operators can still inspect them with `cache keys` and
`cache get`.

Put stdin/file JSON is an array:

```json
[{"key":"post:123","fetchedAt":"2026-10-18T12:00:00Z","payload":{"text":"inspected text","imageBase64":"..."}}]
```

The single-entry alternative is `--key KEY --fetched-at ISO8601
--payload-file FILE`. No payload command-line argument is needed. File options
accept `-` for bounded stdin. Future or already-expired acquisitions fail.
Batches contain 1...1024 unique keys. The complete put batch must fit the
policy budget and the 64 MiB frame limit, otherwise no entry is changed or
evicted. An admitted batch is retained in full; it cannot evict itself.

Get stdin/file JSON is an array of keys, or use `--key KEY`:

```json
["post:123","post:456"]
```

The response shape is:

```json
{
  "results":[
    {"key":"post:123","status":"hit","entry":{"key":"post:123","scope":"x-following","revision":"SHA256","fetchedAt":"ISO8601","expiresAt":"ISO8601","payload":{"text":"inspected text"},"byteCount":640}},
    {"key":"post:456","status":"miss","reason":"notFound"}
  ],
  "deletedCount":0,
  "stats":{"entryCount":1,"byteCount":640,"expiredCount":0,"evictedCount":0,"policy":{"ttlSeconds":86400,"maxBytes":268435456}}
}
```

Put returns `status: "stored"` and entry metadata without the payload.
Revisions bind the canonical payload, key, scope, and acquisition time.
Get returns `hit` or `miss`; a directly observed expiration has reason
`expired`. `notFound` includes never-present, previously expired, evicted,
and explicitly deleted entries. There is no unbounded tombstone history and
no older-value fallback. `--max-output-bytes` bounds get output (default and
maximum 64 MiB). Oversized reads fail and roll back LRU/pruning changes.

Optional compare-and-delete uses `--key KEY --expected-revision SHA256`, or
`--entries-file` containing `[{"key":"post:123","revision":"SHA256"}]`.
It is atomic: a changed live revision rejects the entire batch, and missing
keys succeed idempotently. Export does **not** automatically delete cache
entries; TTL/LRU controls their lifecycle.

## Disk and memory bounds

Each row's `byteCount` charges canonical JSON UTF-8 bytes, key/scope UTF-8
bytes, and 512 bytes of metadata allowance. This bounds tiny-row metadata as
well as payloads. Inline inspected image data (for example base64 PNGs) is
charged too. External file paths are just strings: the cache does not own or
reclaim files referenced by a payload. Callers must place cached media bytes
inside the bounded payload or independently bound and reclaim external files.

The byte budget is a live charged-data budget, not an exact filesystem size:
SQLite page/index overhead and a temporary rollback journal are additional.
Dedicated cache databases use `auto_vacuum=FULL`, `secure_delete=ON`, and DELETE
journaling. Successful get/put/configure/prune operations physically delete
expired rows; put/configure also remove least-recently-used rows until the
budget is satisfied. Freed pages are reclaimed at commit without a growing
WAL. Schedule `cache prune` hourly to reclaim idle caches; there is no hidden
background process. Database files are owner-only and use a cache application
identifier to refuse unrelated databases.

## Durable receipts and safe replay

Keep durable state compact: acquired IDs/version identifiers, cursors,
exported-version receipts, and destination note IDs. Do not keep unbounded
copies of full bodies/images in durable node memory or archive JSON merely
to bypass cache expiration. Cache misses must never be interpreted as empty
content, proof of deletion, or proof of successful export.

For an unexported entity, verify that a cache hit has the expected revision.
If absent or mismatched, refetch when authorized or stop with an explicit
missing-body state before marking it saved or advancing its checkpoint.
For an already-exported version, the durable export receipt prevents duplicate
writes even after eviction. To update a monthly destination, preserve its
verified historical contents instead of rebuilding it solely from the current
cache. Verify migration/export before deleting legacy local bodies or media.
Bound durable receipt/index growth separately; cache pruning does not delete
those records. Cache-get output may also be copied into workflow journals,
logs, or caller artifacts. Those copies are outside the cache database and
are not expired by cache TTL/LRU. Prefer bounded ephemeral CLI pipes for
retrieval bodies, keep durable node outputs compact, and configure journal
and artifact retention separately. An add-on cache hit is not a promise of
ephemeral workflow-result persistence.

## Built-in add-ons and Swift API

All cache add-ons are version `1` and return the same JSON shape as the CLI:

| Add-on | Config beyond `cacheId`, `cacheRoot`, `scope` |
| --- | --- |
| `riela/cache-configure` | `ttlSeconds`, `maxBytes` |
| `riela/cache-put` | `entries` or `key`/`fetchedAt`/`payload`; optional `retainedReferences` |
| `riela/cache-get` | `keys` or `key`; `maxOutputBytes` |
| `riela/cache-delete` | `entries` or `key`/`expectedRevision` |
| `riela/cache-prune` | none |
| `riela/cache-protect` | `entries` of `{key, revision, protectFromEviction}` |
| `riela/cache-reconcile` | `references` |
| `riela/cache-maintain` | `cacheIds` array, optional `maxDurationSeconds` (no `cacheId`/`scope`) |

`cacheId` defaults to `retrieval-cache` and `scope` to the workflow ID. The
reference and maintenance add-ons are described below. Settings apply only to
explicitly selected cache operations, never to memory or persona add-ons.

Swift callers use `RielaCacheStore(rootDirectory:clock:)`, with an injectable
clock for deterministic expiry tests. `configure`, `put`, `get`, `delete`, and
`prune` execute inside SQLite transactions; monotonic access sequences resolve
LRU order deterministically even when the clock does not advance.

## Managed reference lifecycle (0.2.35)

`riela/cache-reconcile` takes `cacheId`, `cacheRoot`, `scope` and `references`.
The references are a committed metadata object/array containing nested `{key,
revision}` cache references. Riela protects the referenced live revisions and
releases capacity protection on other entries **in that scope only**. It does
not delete payloads or extend their TTL or LRU timestamps. Missing/expired
references remain missing, and the result lists each of them as
`{"key":…,"status":"missing","reason":"notFound"}` after the changed rows
(`protected`/`released`). A changed live revision rejects the entire operation.
Hold the metadata producer's exclusive lock through reconciliation. Do not pass
an incomplete projection of a shared scope.

Any object with both `key` and `revision` members is treated as a cache
reference, and its revision must be a SHA256 hex digest. Keep unrelated
metadata (for example a git revision) out of that shape. An object whose string
`scope` member names another scope, such as a put receipt from a different
scope, is ignored, so receipts can be stored and passed back verbatim.

`riela/cache-put` additionally accepts `retainedReferences`. Its reconciliation
and new-entry admission share one SQLite transaction: capacity rejection or an
invalid reference rolls everything back. New entries use their ordinary
`protectFromEviction` setting. Commit the returned reference to metadata before
the next transition. A crash before that commit leaves an unreferenced artifact
that the next reconciliation releases. Existing `put` callers are unchanged.
The CLI equivalent is `cache put ... --request-file -`, with a bounded JSON
`{entries, retainedReferences}` request on stdin. `cache reconcile ...
--references-file -` accepts the snapshot alone.

`riela/cache-protect` exposes explicit revision-checked protection changes.

`riela/cache-maintain` takes an explicit `cacheIds` array, `cacheRoot` and
optional `maxDurationSeconds` (default 120, fractions allowed). It prunes
existing owned stores using their own policies and never creates a missing
store. It returns finite aggregate counts plus:

- `skippedCacheCount`: missing, foreign, symlinked or hard-linked stores, so a
  typo in `cacheIds` is visible.
- `deferredCacheCount`: stores left for a later run because the time budget was
  used up or another writer held the store past the 5-second busy timeout.
- `failedCacheCount` and `failedCacheIds`: stores that could not be maintained,
  such as a corrupt database. At most 32 IDs are listed.

`status` is `failed` when any store failed, `deferred` when any store was
deferred, and `ok` otherwise. A `failed` status fails the add-on node
(`completionPassed: false`) and makes the CLI exit non-zero while still
printing the summary. `deferred` is a success. The time budget is checked
before each store, not inside one: a store that starts within the budget
finishes its expire/evict pass even if that overruns the budget. No Python or
shell node is needed. The CLI equivalent is `cache maintain CACHE_ID` for one
store or `cache maintain --cache-ids-file -` with a JSON array on stdin.

Cache stores are not touched by `riela gc` or automatic retention (see
[terminal-retention.md](terminal-retention.md)). Schedule `cache maintain` or a
cron-triggered workflow with `riela/cache-maintain` to reclaim idle caches.

See `examples/managed-cache-checkpoint` for a workflow made entirely of built-in
nodes. Application-specific generation checks and publication acknowledgements
remain with the publisher; TTL expiration is never a publication receipt.
