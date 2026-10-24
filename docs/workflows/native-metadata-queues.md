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

The result contains `items: [{memoryId, head, value}]` and `scannedCount`.
Only matching scoped heads are read; source bodies outside `valueFrom` are not
returned. `nodeId: null` explicitly selects the latest matching node in a workflow.
The scope defaults to the invoking workflow/node and tag `checkpoint`.
`memoryRoot` defaults to `RIELA_MEMORY_ROOT` or the working directory's default
memory root. Relative roots resolve against the execution working directory.

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
(default 7,990,000, maximum 8,000,000 bytes); the selected result is independently
bounded to 7,990,000 bytes. Deadline/cancellation is checked between databases.
Legacy snapshot revision baselines may be initialized on read, without changing
the payload. This is a sequence of atomic per-memory reads, not a global queue
transaction or a work lease; recheck the source head before committing work.

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
