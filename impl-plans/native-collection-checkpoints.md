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

## ART Gmail listing source migration

The active ART source graph now uses native `page-state` for query traversal,
deduplication, limits and cursor cycle checks, and `json-route` for fixed read
dispatch. The former Python listing loop and route phase are removed. A small
domain binder passes native IDs/state back to existing Gmail version/body and
inspection policy. Exact typed gateway argument-object references are accepted
by static validation and checked as objects before bounded SDK/catalog execution.
Literal template-looking source data is never evaluated again.

Evidence: 28 focused Riela tests pass, including actual runner X page/resume
tests and typed gateway/static validation tests. ART's Gmail domain tests use
the native CLI page node. The matching Linux guest also passed the actual
network-denied private graph test: one accepted message, one screened out,
real source plan/resume and native checkpoint write, no rejected body canary
or credential values in host session/artifact files. Provider and model calls
are offline fixtures; this is not real Gmail acquisition. Actual Opus 5.5
medium reviews found no blockers. None of this is a production cutover or the
final two-hour check.

The Linux addon image builder still pinned analytics/documents sources older
than Package.swift. Their source pins must match the package dependencies;
the existing portability adaptations were checked on copies of those exact
sources, and the Linux CLI and matching ART test guest built successfully.
Do not patch unrelated installed production images.

The private gate exposed recursive history forwarding: a read payload grew
from 20 KB to 220 KB to 2 MB, and the next route forwarded 6 MB at only 13
steps. ART read/screen/result handoffs now project only their business fields.
An actual native runner regression checks exact values and bounded output with
large unrelated input. After this correction the private/source test passes
in 29 seconds without increasing its timeout or weakening isolation.

Still required: native X account/query/window cursor ownership, Gmail remaining
generic iteration/checkpoint handling, Web acquisition/progress, source selection
and independent scheduling in the authored graph, legacy metadata import,
matching host/guest release and install, idle deployment, and two hours of real
post-cutover collection plus Notion verification. Existing production monitoring
and examples remain insufficient for those gates.

## Native X author collector and ART source migration

`riela/x-collect` now owns authenticated account verification, 512-byte author
query packing, exact legacy shard/cursor import, frozen windows, page budgets,
deduplication and independent fresh-head probes. It invokes the linked native
gateway reader through the normal addon execution path. ART's new source graph
replaces Python per-page callbacks and removes the read/turn workflows; its
remaining adapter normalizes records, binds source identity and screens content.
The new collector returns metadata for a subsequent inspected durable commit;
it does not yet replace ART's durable source writer.

Actual Opus 5.5 medium review identified three compatibility differences: original
requested start in head receipt signatures, nonfresh shard budgets below nominal
page size, and imported page sizes 5–9. These are corrected with a legacy Python
signature golden and a five-shard/small-budget cursor continuation test. Nine
focused native tests pass, including the optional real metadata-only cursor
fixture (no provider I/O). ART's domain suite passes with its private guest gate
still pending. The matching Linux runtime and guest must be rebuilt and checked
before this source change is deployed. Full remaining Gmail/Web coordination,
durable ownership, release/install, deployment and the final two-hour check
remain required for the original goal.
