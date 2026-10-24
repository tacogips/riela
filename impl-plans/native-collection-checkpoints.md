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

## Native X page graph verified

`examples/x-window-checkpoint` uses three builtins: load checkpoint, read a
specified author's bounded recent-search page, record cursor and pending IDs.
An acquire-only transition stops a completed window before any paid API call.
Page-token completion can be inferred from a null cursor; watermark callers
retain an explicit completion boolean. Account/window keys remain separate.

The actual deterministic runner tests two pages across three executions with
two gateway transport calls, and an empty window across two executions with
one call. Fixtures use the real X SDK response projector. A credential-free
SDK invocation reaches AUTH_MISSING with requestAttempts=0, proving nullable
initial cursor parsing without contacting X. X SDK v0.1.25 fixes both nullable
optional string inputs and explicit null terminal page cursors. Its complete
68-test suite passes. Riela's 13 targeted tests and all-example static
validation pass on the updated dependency. These checks do not fetch ART data.

Next ART integration must import existing account/shard/window cursors and exact
pending item versions before replacing their Python ownership. Keep frozen
backfill bounds and already accepted receipts; do not replay a scan from zero.
Inside the private graph, native gateway/cache/batching/screening precede the
durable page record. ART-specific normalization may remain a small domain
adapter, but it must not own pagination, subprocess orchestration or generic
progress. Acquisition and article processing remain independent. The current
production pin and its older monitoring window are not final acceptance for
this migration.
