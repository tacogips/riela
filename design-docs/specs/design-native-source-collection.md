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

## Inspected body cache exchange

`riela/cache-exchange` version 1 owns bounded batch admission, readback,
revision/fetch-time/integrity matching and miss classification. Its `storage`
object supplies `cacheId`, `scope`, optional `cacheRoot`, `ttlSeconds` (86400),
`maxBytes` (10485760), and `capacityProtection` (false). This is independent of
provider names and durable memory. Reserved `x-gateway-*` caches are rejected.

Actions are `configure`, `put`, `get`, `protect`, `reconcile`, and `prune`.
`put` takes normal cache `entries` (`key`, `fetchedAt`, `payload`, optional
`protectFromEviction`) and optional `retainedReferences`. It returns a
`references` map. `get` takes a references array and returns `hits`, `missing`,
and `expired`. `protect` takes that array and `enabled`; `reconcile` takes the
committed reference snapshot. As with low-level cache nodes, configure the
policy before the first read of an existing cache; reading never refreshes TTL.

Example configuration for a script-free body write:

```json
{
  "action": "put",
  "storage": {
    "cacheId": "inspected-bodies",
    "scope": "account-query-window",
    "maxBytes": 10485760,
    "capacityProtection": false
  },
  "entries": "{{checkedEntries}}"
}
```

Input can use `--variables @-`; literal template-looking strings inside data
are not rendered again. Inputs and output are bounded below the 64 MiB wire
limit, with at most 10000 entries/references and 1024 entries per SDK batch.
Admission leaves serialization headroom; a single entry must fit both the
cache and the actual serialized wire frame minus 8 KiB. Batches target half a
frame, while a wider single entry remains admissible when it fits on its own. Invalid dates, oversized entries
and duplicate keys are rejected before any batch is written. Concurrent
writers or expiration during a multi-batch operation can still cause failure;
no durable cursor is advanced by this operation.

Disposable batches can exceed total cache capacity: each admitted chunk is
read back before the next, which may evict earlier bodies. References for all
admitted bodies remain available to durable pending-work manifests. Protection
requests on disposable caches release old protection without requiring evicted
rows to still exist. Protected staging is explicit and keeps revision-CAS
failures strict. Its final readback must include the whole admitted set.

Reference wire names preserve existing metadata (`key`, `revision`,
`fetched_at`, `payload_sha256`, `byte_count`), plus `hash_format: riela-json-v1`.
A caller with an existing domain proof digest may retain it in
`payload_sha256` and carry the native digest as `integrity_sha256`. ART does
this to preserve publication/source proofs and checks both. Legacy references
without a hash format or size are accepted. For all references the built-in
recomputes the stored SHA256 revision over scope/key/fetch-time/body, avoiding
false misses caused by domain serializer differences while detecting changed
stored payloads. Native integrity digests are also checked when supplied. The
original domain hash remains the domain adapter’s responsibility. No cache miss
discards an exact pending ID/version or changes a frozen acquisition window.

ART's `RetrievalCache` now delegates its batching/readback/protection to this
node. The remaining adapter holds ART cache names/defaults, transports JSON,
and retains existing domain proof hashes; raw lookups used by older domain
callers remain available. For protected staging operations larger than one
frame, the thin adapter splits only the wire transport (16 MiB target and
reference-size-bounded responses), merges results and sends a retained snapshot
only with the first frame. Cache admission/readback and SDK batching remain
native. Thus 256 MiB staging capacity does not imply a single 256 MiB node
payload. A 69 MiB synthetic staging operation was verified end to end through
the actual native CLI, including protection across all three frames. News manifest/recovery selection and outer work
coordination are still separate migrations. This does not prove production
installation, source acquisition, or the required post-cutover two-hour gate.

### Reading a manifest across declared cache spaces

`cache-exchange` also accepts `action: "read-set"`. This action uses `stores`
instead of `storage`; each named store has the same storage configuration as
above. `requests` is an array of `{id, store, reference}`. For example:

```json
{
  "action": "read-set",
  "stores": {
    "current": {"cacheId": "current-bodies", "scope": "account-window"},
    "legacy": {"cacheId": "legacy-bodies", "scope": "account-window", "ttlSeconds": 604800}
  },
  "requests": "{{bodyRequests}}"
}
```

The result is `{results: [{id, status, payload?}]}` in request order. Status is
`hit`, `missing`, or `expired`; only hits include a payload. Logical IDs are
unique by exact UTF-8 bytes. Physical keys can coincide in distinct stores
without overwriting each other's results. At most16 stores and10000 requests
are allowed; input/output remain below64MiB. Duplicate physical keys within
one named store, unknown stores, invalid references, and conflicting policies
for aliases of one physical database fail before any cache configuration/read.
Physical aliases are compared using canonical paths and existing device/inode;
aliases of one scope must also agree on capacity protection.
All declared storage configurations are validated before IO. Used stores are
configured before reading; disposable scopes first release legacy protection
without fetching payloads, allowing LRU to shrink the capacity. This may
expire/evict bodies according to their
TTL/LRU policy. Configuration cleanup may make an expired entry appear as `missing`; neither
status acknowledges work. A read does not extend freshness. An output-budget failure does
not imply a rollback across stores and never advances a durable checkpoint.

ART supplies its current/legacy cache permissions and verifies its original
domain receipt/hash after native reads. Normal manifest hydration and commit
readback use this action; selected editorial reads retain per-record admission
and receipt checks. Disposable protection reconciliation delegates an empty
reference set directly to native storage, without loading bodies or images
just to release protection. Explicit protected staging keeps exact readback
and protection checks. Provider recovery and outer queue orchestration remain
separate work; this source migration is not deployment evidence.

## Record manifests and bounded recovery sets

`riela/record-manifest` v1 is a pure metadata node composed after cache reads
and before `snapshot-store`. Its config is `{action, value}`. Each entry is
`{key, version, value}`: `key` identifies a logical item within a caller-selected
provider/account/window scope, `version` identifies its inspected revision, and
`value` is opaque metadata (for example original body references and provider
IDs). The node never fetches, acknowledges, deletes, or advances a cursor.
Entries/sets are limited to10000 items and requests/results to64 MiB minus8 KiB.
Whole typed references keep template-looking metadata literal; CLI data can use
stdin `--variables @-`. Common postprocessing remains supported.

Actions:

- `partition`: `entries`, `availableKeys`, optional `oversizedKeys`,
  `selectedKeys`, `acknowledged`, and `unavailableAcknowledgedKeys`. It returns
  `available`, `pending`, `acknowledgedMissing`, `oversized`, and `needsRecovery`
  for the selected scope. An acknowledgement is an array item `{key, version}`;
  only the exact current version exempts a missing body from recovery. Verified
  unavailable metadata outside a selected hydration slice remains metadata only.
  `needsRecovery:false` is not acquisition or publication completion.
- `merge`: `entries`, `current`, `retainKeys`. It returns the current entries
  followed by still-pending original metadata not superseded by a current key,
  plus `retainedKeys`. Unknown retained keys and ambiguous duplicates fail. A
  domain adapter can explicitly exclude a superseded domain ID when its account
  binding changes its logical key; the generic node never guesses that mapping.
- `recover`: `entries`, `requestedKeys`, `returnedKeys`, `pendingKeys`,
  `availableKeys`, `unavailableAcknowledgedKeys`, `acknowledged`, `context`, and
  `expectedContext`, with optional paired `attemptedKeys`/`deferredKeys`.
  Returned and pending must exactly partition the request. Attempts and deferred
  work also partition it, returns must have been attempted, and deferred work
  remains pending. Available, pending and exact acknowledged-unavailable rows
  must cover the entire original manifest without overlap. Changed context,
  invented IDs or incorrect acknowledged versions fail. The result preserves
  original `retainedPending`/`retainedAcknowledged` entries. `hasProgress:false`
  when no inspected return was accepted never implies a successful checkpoint.

Keys and versions compare UTF-8 bytes, including canonically equivalent Unicode
spellings. Acknowledgements use arrays to avoid Swift String dictionary-key
normalization. Context compares typed JSON equality and canonical encoded bytes;
property order is immaterial, while different string code points remain distinct.
The node validates metadata consistency only. Actual cache integrity, source
inspection, publication receipts and snapshot CAS remain their respective nodes'
contracts.

ART `NewsMemory` now delegates these set decisions, scopes acknowledgement input
to the manifest instead of the full historical receipt catalogue, and checks
builtin availability before default cache/provider setup. Its adapter retains
source-specific receipt generation, identity/time-window eligibility, selected
body size limits, legacy partition/hash format, cache-group transport and image
inspection. State persistence already uses the atomic native snapshot API.
An actual offline cache/snapshot test verifies LRU misses retain unpublished IDs,
fresh polling advances independently, and a stale writer cannot replace the new
head. This migration does not certify the remaining Web/outer-coordination,
matching Linux/release/production cutover or post-cutover two-hour gate.


## Exact-ID X body recovery

`riela/x-collect` accepts `options.mode: "lookup"` for cache-missing known roots.
It takes `ids` (at most5000 distinct numeric IDs), `expectedHandle`,
`expectedAccount`, optional `maxPosts` (1..100, default100), optional aware
`start`/`end` bounds, `includeStatusLinks` and `includeCoverageMetadata`.
The same native SDK reader handles user/usage caches and credentials. This mode
never performs timeline/search requests. Before the single bounded `posts`
request it verifies the authenticated account. An empty ID list makes no paid
request. Cancellation propagates. Invalid scope/options fail before API reads;
root response IDs/text/timestamps/bounds must match the attempted set.

The result contains `posts`, `requestedIds`, `returnedIds`, `deferredIds`,
`pendingIds`, `accountId`, `complete`, `failures`, plus the opaque caller
`context`. At most100 roots are attempted in one turn; every deferred or
unavailable root remains pending. A failed/malformed lookup preserves the whole
attempted set as pending; it is not a source cursor update or publication ACK.
Embedded quote/media data is handled as optional context by the private domain
normalizer, so invalid context does not hold unrelated accepted roots. Posts
are bounded to6MB before export and the whole output to8MB. The collector
reserves space for context and exact-ID metadata before payment; an unusable
frame is rejected before account/lookup calls. Individually oversized bodies
remain pending while fitting peers continue. Results are raw
provider data and belong inside a private acquisition workflow until inspected.

ART's specified-author private graph uses this mode for both ordinary cache
recovery and missing originals during research. ART supplies allowed author IDs,
account/window metadata and legacy logical-ID mappings. The native node owns the
actual lookup/availability partition. Existing native batch/fanout/gather nodes
inspect accepted roots in that same private graph. The host commits only checked
versions with native manifest recovery/CAS; screening rejections remain pending.
The task binds the exact original source-head token and preserves the acquisition
cursor. A resumed research turn reuses its selected ID prefix instead of rotating
its attempt journal again. The old non-native compatibility collector is not a
fallback from this native handoff. Matching guest/release/cutover and a new real
two-hour acquisition/publication audit still remain mandatory.
