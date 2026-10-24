# Native collection checkpoints

User request: keep source acquisition, pagination and progress in reusable Riela
builtins instead of implementing those mechanisms in ART Python. X accounts,
Gmail and Web sources need independent state, with article failures independent
of subsequent acquisition. The existing gateway, private-workflow, cache,
fanout and batching builtins remain the execution primitives.

First implementation: `riela/collection-checkpoint` stores only opaque cursors
and exact item ID/version pairs in workflow-scoped KV. JSON actions load, record
a successfully inspected page, and acknowledge exact processed versions. Cursor
and pending IDs commit atomically; acquisition completion and processing completion
are separate. Disposable cache eviction never changes a checkpoint. Callers use
a distinct key per provider/account/query/window; no ART routes or source names
belong in the runtime. Expected revisions fence concurrent/stale page commits.

Files: RielaMemory KV compare-exchange, native addon and catalog/dispatch,
focused concurrency/restart/version tests, JSON authoring documentation/example.
No live state rewrite, credentials, provider calls, model calls or retries in this
primitive. Existing ART memory must be migrated with exact checkpoint identity,
not silently reset. Gateway responses remain inside the private guest until
screened; host durable state contains metadata only.

Remaining after this chunk: move ART selection into authored priorities;
wire native checkpoint/cache and typed gateway nodes into source graphs; port
source-domain normalization only where needed; verify preserved source state;
release/install matching host/guest; idle App cutover; two-hour live acquisition
and native Notion verification. Foundation tests alone do not satisfy deployment.
