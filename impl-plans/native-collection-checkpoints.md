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

## Preserved main checkout integration

The user requested integration of the 185-file main checkout snapshot
`backup/main-wip-20261024` (`bf707004`) with current upstream. It was applied
three-way over the native collection commits, preserving newer cancellation,
typed gateway references, pagination and example fixes. Conflicts combined
optional empty arguments with deferred typed references, finite JSON bounds,
and evidence validation with the newer cancelled status. Import preserves the
caller's explicitly selected lineage. Tests now locate the actual scratch-build
worker binary rather than assuming `.build/debug/riela`.

The common stateful dispatcher now uses registered handlers; it contains no
provider-name branches. All 31 prior handlers retain their callbacks and context.
Actual Opus 5.5 medium reviews covered both the backup integration and registry.
The final 304 focused tests pass (one opt-in real container test skipped), as do
all 71 memory tests and 110 Web tests, typecheck, lint and Web build. Eight
container source/crypto pins match Package.resolved. The Linux context now
includes the lockfile portability helper referenced by its Containerfile.

The original dirty checkout was byte-checked against all 185 backup files and
also saved in a local stash before its duplicate checkpoint commit was skipped
during rebase. Keep the remote backup and local stash. The current matching
Linux rebuild/private gate and production deployment remain separate gates:
an older test guest was correctly refused for its worker record protocol after
this host update. No production image or warm App process was changed.

## Native Gmail collector and private source graphs

The Gmail profile/list/thread/body loop now lives in a registered native
`riela/gmail-collect` handler. ART passes raw JSON options and keeps normalization,
request/source binding and content screening. The obsolete Gmail read workflow
and X read/turn workflows are removed from source and image dependency lists.

Actual Opus 5.5 medium review found retry starvation, frozen-discovery gaps,
scope loss and aggregate byte/deadline risks. The native coordinator now rotates
exact pending scans independently of fresh discovery, preserves older discovery
floors and intent-scoped metadata, retains fresh membership when old cursors
drain, and evicts only completed scope history. Per-item output reservations and
bounded SDK deadlines preserve accepted prefixes. SDK-compatible opaque account
names and deterministic deferred-ID retry turns have regression coverage.

Matching-protocol Linux host/guest builds and both ART private graph gates pass
(13 tests per source, no skips). These private gates use whole-collector offline
fixtures: they verify isolation, binding and durable source-plan behavior, not
provider SDK execution inside the guest. Native linked Gmail/X SDK execution is
covered separately with injected transports. No production image was changed.
Durable source-writer migration, Web acquisition, outer coordination, release /
install / idle cutover and two hours of real publication remain outstanding.

Final component verification: 60 selected native tests, one optional live-cursor
fixture skipped, zero failures; both 13-test ART private suites pass. Actual
Opus review plus source-only follow-up closure found no remaining material
issue in this collector chunk. The 70-profile permanent-poison regression keeps
one retry backlog while completing 35 fresh acquisitions. Focused SwiftLint has
no errors; the two collector functions retain complexity warnings. These are
component checks, not the required real post-cutover two-hour run.

## Atomic native snapshot store

`riela/snapshot-store` now owns transactional load/head/compare-and-commit of
existing tagged Riela memory. Scope digests prevent row/revision collisions
across namespaces. Native baseline installation supports pre-evolution schema-3
records; no source payload, timestamps or IDs change. ART's compatibility layer
uses the builtin via bounded stdin JSON and no longer implements update/readback
or payload/history head pairing. Existing body caches are unchanged.

Actual Opus 5.5 medium source review identified missing legacy baselines and
implicit head adoption. Baseline migration and repeated blind-write refusal are
fixed with regressions. Source-only closure also checked scope binding and
opaque CLI values through shared postprocess. Generic registry metadata avoids
rerendering CLI data as authored input templates; legacy input behavior defaults
unchanged. This chunk does not yet migrate body-manifest logic, recovery selection,
outer work coordination or Web retrieval, and is not a production cutover.

Snapshot component verification: the full Memory package passes 77 tests;
15 focused CLI/registry/stdin tests pass, including a real declared three-node
workflow over two executions with no scripts. ART acquisition/news work/cache/
source-pipeline suites pass 74 tests. Both private source suites pass 13 each
with the offline whole-collector fixtures and native host snapshot storage.
Focused SwiftLint is clean. The final source review closure has no material
findings. Production and the installed CLI remain unchanged; deployment and
post-final-cutover two-hour evidence are still absent.

## Native inspected cache exchange

Added `riela/cache-exchange` with a feature-local registry registration and
`RielaMemory` implementation for cache admission, SDK batching, matching
readback, exact revision/fetch-time validation and explicit miss/expiry results.
The default is disposable 10 MiB/24-hour LRU; capacity protection is a separate
explicit setting, without provider-name branches. Loss or replacement of a
body never acknowledges a provider ID or changes acquisition completion.

ART delegates these operations through its existing cache adapter. Remaining
Python consists of its cache naming/defaults, domain proof hashes, low-level
legacy lookups, finite diagnostics and bounded wire framing. Native readback
checks an independent integrity digest, while Python preserves existing domain
proofs. Legacy references are validated by recomputing the stored SHA revision
(scope/key/fetch-time/body), avoiding dependence on domain serializer choices.

One actual Opus 5.5 medium review found protected prior batches being released,
a whole-operation frame regression for large staging, and legacy digest
compatibility. All were fixed: retained snapshots apply only at the first
native batch and first transport frame; large staging is transmitted in bounded
frames and merged; legacy revisions remain cryptographically verified. Own
closure also moved all JSON/wire validation before sending any frame, with a
late-NaN regression proving no preceding frame is sent. No extra paid review.

Validation: all 84 Memory tests and eight CLI/registry/snapshot tests pass;
13 ART suites total 111 tests with zero failures/skips. Focused SwiftLint and
diff checks pass. An actual offline CLI proof round-trips 69 MiB of protected
staging across three frames without releasing any, plus a 35 MiB individual
entry, using separate temporary synthetic caches. No credentials, provider API
or production store is used by these tests. A broader X editorial fixture
suite has six failures/four errors/one skip, identically reproduced with the
unchanged HEAD cache adapter; it is not counted as a successful gate.

This chunk is source integration only. The native Linux guest, installed CLI
and production pin have not been updated. Live App root322 was observed running
with root321/320 completed. News body manifests/recovery selection, Web/HN/feed
and outer progress orchestration still need migration before the final matching
release/install/deploy and a new two-hour real acquisition/Notion proof.

## Native record manifest decisions

Moved missing/available/oversized/exact-acknowledged partitioning, pending metadata
retention and bounded recovery-set/context validation to `riela/record-manifest`.
The node is provider-independent and composes cache-exchange with snapshot-store;
it does not infer cache misses are acknowledgements or acquisition completion.
Original refs/frozen metadata remain opaque. ART adapts its source/ID/account
receipts and retains the existing wire partition format for publication.

Actual Opus5.5medium review identified four compatibility edges: domain IDs whose
account binding changes their logical key, an unscoped >10000 historical ACK
catalogue, Swift Unicode canonical equivalence, and missing-builtin preflight.
All were fixed with focused regressions and source-only own closure, no second
paid call. Native identity/version sets use UTF8 Data, ACKs are key/version arrays,
and contexts also compare encoded bytes. Default source cache setup exercises an
empty manifest partition before any acquisition work. Test fixtures now reflect
the already-current snapshot head API and route only native metadata calls past
mocked inspector processes. The forbidden-process inventory test explicitly
mocks this dependency; a separate real CLI/cache/CAS test covers that boundary.

The source refactor still leaves cache IO, domain receipt/eligibility and legacy
publication partition serialization in Python. Remaining Web/HN/feed and outer
coordination work, matching release/install/Linux guest and idle production
cutover precede a new7200s real-acquisition/Notion verification period.

Final gates for this chunk:17 native CLI/manifest/registry/snapshot/cache tests
and125 ART tests across16 suites, all passed with zero skips. Focused SwiftLint
and diff checks are clean. The actual temporary cache/snapshot integration gate
passes independently of inspector/metadata-only mocks. Production root323 was
observed running while322/321 were completed; warm App/CLI/pin19 are unchanged.
