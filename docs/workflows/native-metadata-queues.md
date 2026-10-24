# Native metadata queues

`riela/snapshot-scan` and `riela/snapshot-rotate` (version `1`) operate on
Riela memory snapshots. They run in the embedded runtime without a filesystem
or cursor-management script. They make no provider calls and never acknowledge
successful acquisition or publication.

## Discover pending work

Declare the memory prefix and exact workflow/node/tag scope, then project the
metadata to inspect:

```json
{
  "storage": {
    "memoryPrefix": "source-work-",
    "workflowId": "news",
    "nodeId": "work",
    "tag": "checkpoint"
  },
  "valueFrom": "/state",
  "whereAny": [
    {"path": "/publication_pending", "equals": true},
    {"path": "/research_complete", "equals": false}
  ],
  "sortBy": [{"path": "/last_attempt_at", "default": ""}]
}
```

Instead of `memoryPrefix`, `storage.memoryIds` can specify up to `maxDatabases`
distinct exact memory IDs. The two options are mutually exclusive. All IDs and
paths are validated before any head is loaded; missing heads are omitted. Exact
sets never enumerate unrelated databases. `scannedCount` then counts requested
IDs, including missing heads. Different IDs that alias the same physical database
on a case-insensitive filesystem are refused without changing case-sensitive IDs.

The result contains `items: [{memoryId, head, value}]` and `scannedCount`.
Only matching scoped heads are read; source bodies outside `valueFrom` are not
returned. `nodeId: null` explicitly selects the latest matching node in a workflow.
The scope defaults to the invoking workflow/node and tag `checkpoint`.
`memoryRoot` defaults to `RIELA_MEMORY_ROOT` or the working directory's default
memory root. Relative roots resolve against the execution working directory.

For existence checks, replace `valueFrom` with e.g.
`"presence": {"pending": "/state/pending"}`. Each of at most 64 named pointers
returns `true` when the field exists and is non-null, otherwise `false`. Empty
objects, strings and arrays count as present. Source values are never returned
by this projection. The selected per-record snapshot can therefore contain a
large pending document while the scan only returns a boolean. Missing heads
remain omitted; they are distinct from a found head with `pending: false`.

Optional `valueSchema` validates the raw stored object before either projection
using Riela's supported JSON output-schema dialect. Its schema is checked before
storage IO. For a versioned journal, require its version, object state and array
records here; a corrupt envelope then refuses the probe instead of clearing a
pending barrier. Validation failures return finite errors without stored values.

Pointers use RFC 6901. `whereAny` ORs up to eight equality conditions for booleans,
strings, null or integers in the exactly representable range ±(2⁵³−1);
stored memory numbers compare numerically to integer predicates without rounding
large identities. Use strings for larger numeric IDs. Fractional predicates are
not supported. For these scalar conditions,
missing fields do not match and incompatible scalar types refuse the scan.
`sortBy` accepts up to eight string fields, compared by exact UTF-8 bytes;
missing sort fields require a declared string default. Ties use memory filename
order. A missing projection or invalid metadata refuses the operation rather
than returning a successful partial queue.

Scanning is immediate-directory only, at most 100,000 directory entries and
`maxDatabases` matching SQLite files (default/maximum 4096). Database and sidecar
symlinks, hard links and non-regular files are refused before any snapshot load.
Directory read errors refuse the operation. A missing directory returns an empty
queue without creating it. `maxPayloadBytes` bounds each stored snapshot
(default 7,990,000, maximum 64 MiB); the selected result is independently
bounded to 7,990,000 bytes. Deadline/cancellation is checked between databases.
Legacy snapshot revision baselines may be initialized on read, without changing
the payload. This is a sequence of atomic per-memory reads, not a global queue
transaction or a work lease; recheck the source head before committing work.

## Select and order metadata

`riela/array-select` (version `1`) accepts `items`, `whereAll`, `sortBy` and
`limit`. It performs no storage or provider IO. For example:

```json
{
  "items": [{"id": "work-a", "date": "2026-10-25", "source": "mail"}],
  "whereAll": [{"path": "/id", "notIn": ["already-attempted"]}],
  "sortBy": [
    {"path": "/date", "rank": ["2026-10-25"]},
    {"path": "/last_attempt", "default": ""},
    {"path": "/source", "rank": ["mail", "x"]}
  ],
  "limit": 1
}
```

All filter fields must be strings. Each condition declares `path` and exactly
one of `equals` (string), `in` or `notIn` (up to 10,000 strings). All conditions
must match. Sorting also uses string fields, with an optional string `default`
for absent fields. Without `rank`, keys compare by exact UTF-8 bytes. With
`rank`, listed values have increasing priority and all unlisted values share the
last rank; later sort fields resolve ties. Equal full keys retain input order.
Every required filter and sort field is checked even on excluded rows; invalid
metadata refuses the operation. Source strings are data, never templates or code.

There are at most 16 conditions, 16 sort fields and 256 distinct values in each
rank list. Input items are bounded to 10,000, and the request and response each
to 8,000,000 bytes. `limit` is 0–10,000 (default 10,000). The result contains
`items` (the selected prefix), `matchedCount` before the limit, and `inputCount`.
Selection has no side effects; callers still validate domain permissions and
recheck the selected source head before recording a work attempt.

## Reserve an attempted prefix fairly

```json
{
  "storage": {"memoryId": "recovery-turn", "workflowId": "news", "nodeId": "recovery"},
  "items": ["known-a", "known-c", "known-d"],
  "maximum": 2,
  "cursorPointer": "/state/after_id",
  "initialValue": {"version": 1, "state": {}, "records": []}
}
```

The node sorts unique nonempty IDs by exact UTF-8 bytes. Selection starts after
the persisted cursor, wraps at the end and returns at most `maximum` IDs.
Removed cursor IDs are supported: selection starts at the next greater current
ID. The result is `{items, after, context}`; optional `context` is opaque data.
IDs are limited to 1024 bytes each and 10,000 per request; `maximum` is 1–10,000.
Empty item sets are refused without reserving a turn.

`cursorPointer` must name an object field; missing object parents are created,
and array/scalar parents are refused. The rest of the persisted value is
preserved, including legacy records, source cursors and unrelated fields.
`initialValue` is used only when the scoped head is absent. A string cursor is
required when present. The request, updated value and response are each bounded
to 7,990,000 bytes before committing the cursor.

The update uses the native scoped snapshot head comparison. A conflict reloads
and recomputes selection, for at most eight attempts; exhaustion fails explicitly
so the caller can retry. Concurrent calls therefore reserve consecutive prefixes
against the persisted cursor. This reserves attempts, not exclusive ownership:
wrapping or a process failure can cause repeated fetches. An interruption after
commit can lose the returned selection, but leaves the items unacknowledged and
eligible on a later turn. Publication requires its own exact-version receipt.

## Synchronize a snapshot's cache retention set

`snapshot-scan.cacheReconciliation` optionally reads each explicitly named
snapshot and synchronizes its cache protection under the same file lease used
by writers. It replaces a script's lock → snapshot read → cache reconciliation
loop. It does not fetch bodies, modify a snapshot, publish, or acknowledge work.
Only exact `storage.memoryIds` are accepted; prefix enumeration is refused.

```json
{
  "storage": {"memoryIds": ["day-ready"], "workflowId": "news", "nodeId": "ready"},
  "valueFrom": "/state",
  "cacheReconciliation": {
    "lockDirectory": "state",
    "bindings": {
      "day-ready": {
        "lockName": "ready.lock",
        "cache": {"cacheId": "checked-artifacts", "scope": "day-one", "capacityProtection": true},
        "scopeFrom": "/state/date",
        "referencesFrom": "/state",
        "initialValue": {"state": {"date": "day-one", "entries": {}}, "records": []}
      }
    }
  }
}
```

The binding keys must exactly match the selected memory IDs. Each lease has a
unique safe leaf filename. Cache storage accepts the same policy/root fields as
`cache-exchange.read-set`; aliased stores cannot declare different byte/TTL or
protection policies, and the same physical cache scope cannot be bound twice.
The pointer `scopeFrom` must equal the configured cache scope by exact UTF-8
bytes. A legacy empty object at `referencesFrom` may omit this field; it retains
nothing in the explicitly declared cache scope. Other absent/mismatched scope
values fail without reconciling that journal. Reference validation and revision
conflicts follow the normal native reconciliation rules.

`initialValue` is used only for a missing snapshot; it must pass `valueSchema`
and the scope checks before any journal lock or cache is opened. Such snapshots
produce a row with `head: null` and the projected initial value, without creating
a memory database. Existing snapshots remain unchanged, including empty legacy
values. Reconciliation uses the full declared reference pointer before selection
filters or caller source filters, so unselected pending artifacts stay protected.

Writers must use the declared exclusive flock across their cache writes and
snapshot commit. The scan waits at most five seconds per lease, clipped to the
node deadline, observes cancellation while waiting, refuses symlink/hardlinked
lock leaves, and holds the lease across reading, validation and reconciliation.
It processes one journal at a time; this is not an atomic transaction over all
journals. An error in a later journal may follow completed maintenance of an
earlier journal. Missing/expired cache bodies remain missing and never become a
publication receipt. Cache policy changes can expire/evict entries normally.


`valueProjection` optionally applies a declarative object projection to
`valueFrom` after raw `valueSchema` validation. It uses the `json-transform`
`project` selectors (`fields`, `mapValues`, `nonEmpty`); it cannot be combined
with `presence`. Cache reconciliation still uses the complete raw
`referencesFrom`, regardless of the projected fields or subsequent filters.
Use this to return compact candidate metadata while keeping historical receipts,
full reference trees and unused generations within the store. The aggregate
projected result retains the scan's 7,990,000-byte bound; input snapshots can
still be up to the configured per-head limit. Oversized *selected metadata*
is refused explicitly rather than truncated or acknowledged.
