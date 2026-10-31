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

## Composable media pipeline, version `1`

The media workflow is three builtins fed by any downloader that emits the
tool-neutral `mediaDownload` contract (for example the package add-on
`media/yt-dlp-download`): `riela/audio-segments` extracts mono 16 kHz MP3 and
chooses silence-aware boundaries; `riela/video-frames` samples and deduplicates
JPEG frames and can attach them to supplied half-open segments; and
`riela/speech-to-text` transcribes one audio file. Each addon uses
only `options` and `context` in its rendered config. Speech selects a vendor
with `options.provider` (default `openai`, also used for OpenAI-compatible
servers; plus `deepgram`, `elevenlabs`, `google`, `apple` on-device on macOS,
and `command` for a local CLI). Each provider allowlists its own `addon.env`
keys (for `openai`, `OPENAI_API_KEY` and optional `OPENAI_BASE_URL`); see
`design-voice-assistant.md` for the provider table.

Frame sampling uses a 256-bit difference hash. The flat `frames` output has no
image forwarding metadata. When segment ranges are provided, each returned
segment adds image frame objects (`kind: image`, `mediaType: image/jpeg`) and
`imagePaths`, which agent adapters forward for that fanout item. Each stage has
its own options fingerprinted manifest and verifies referenced files before a
cache hit. Keep shared stage paths under the workflow working directory when
running the stages in containers.

Amended 2026-10-30 by `design-youtube-processing-builtins.md` §E.
The former built-in `riela/media-download` was removed because it was tied to
one downloader tool; a workflow that still names it fails validation like any
unknown add-on. The tool-neutral `mediaDownload` contract is documented, and
yt-dlp ships as the package container add-on `media/yt-dlp-download`. The other
three stages stay built-in; `riela/video-frames` also reports
`videoFrames.sourcePath`.

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
100; the maximum number of in-flight per-thread reads, clamped to an effective
concurrency of `min(maxThreads, 16)`; it never limits how many threads a run
lists or processes and never enters the scope identity), `lookbackHours`
(1–168, default 24), optional `window` (two ordered ISO
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

Exact original-body recovery uses the same addon with `options.mode` set to
`message-bodies`. This mode takes `accountId`, `expectedMailboxHash` (the existing
24-character lowercase SHA-256 prefix of the profile email address), `messageIds`
(1–128 distinct IDs in request order), `maxMessages` (1–128, default 16),
`providerBodyMetadata` and `minRequestIntervalSeconds`. It verifies the mailbox
before reading any body and calls `messageBodyBytes` directly, without listing
threads, changing normal collection cursors, or persisting body content.

The result contains raw `bodies`, finite per-message `failures`, exact ordered
`pendingMessageIds`, `attemptCount`, `requestCount`, `complete` and opaque
`context`. `complete` means no unattempted or frame-deferred IDs remain; inspect
`failures` separately for unavailable bodies. One failed body does not block
other IDs. The caller keeps ownership of inspection, version binding and queue
acknowledgement. Output overflow preserves the accepted prefix and leaves the
overflowing ID pending. A body too large for an empty frame instead produces a
finite `body-frame-too-large` failure so smaller peers can continue. Counts refer
to logical gateway reads, not provider billing resources. Deadline exhaustion
during a rate wait leaves the
undispatched ID pending; cancellation always propagates. Like ordinary Gmail
collection, run this mode inside the private workflow and inspect bodies before
exporting them across that boundary.

One bounded scan runs per invocation. `pending_scans` retains each exact frozen
listing/cursor, original mailbox version, cutoff, completed IDs and failed IDs.
Exhausted listings coalesce unresolved IDs into one retry backlog, without
multiplying scans for the same poison item. A changed profile can start a fresh
scan on alternating turns; failed old scans
cannot monopolize discovery. Failed IDs rotate deterministically even when only
one thread read fits in a run. A conservative discovery watermark retains older scan floors
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

### Full listing, concurrent thread reads and early-stop reasons

A scan lists every page of every query until the provider reports no next page.
Each listing request asks for 50 items (`min(50, 10_000 − listed)` only when the
existing 10,000-item hard limit is within one page); the size never depends on
`maxThreads`. The listing stays sequential because each page needs the previous
cursor. The pending `listing.maximum` stays 10,000, and the `pending_collection`
key set is unchanged, so saved production checkpoints resume as before.
Each page is accepted atomically: IDs and the cursor advance together only
after cursor, page-count, item-count and encoded-state limits pass. A rejected or
oversize page leaves the previous cursor and item prefix intact, so a later run
can resume from that checkpoint. A nil cursor is omitted from persisted
page-state JSON to preserve the previous wire format. The encoded listing state
is capped at 7,000,000 bytes.

Only the per-thread phase is concurrent. One thread read is the sequence of
requests for one queued ID: the optional version check, the full thread read
and any requested `messageBodyBytes` reads. At most `min(maxThreads, 16)` thread
reads run at once. The look-ahead window is the same size: a new read starts
only while fewer than that many queued IDs are launched but not yet accepted, so
memory and wasted work after a stop are bounded. The queue order is unchanged:
never-attempted IDs in listing order, then failed IDs rotated after
`retry_after`. A thread read only fetches and validates its thread (identity,
message account/thread fields, complete body contract) and returns an outcome.
It never changes the checkpoint.

All provider requests in one scan (profile, listing, thread reads) take a start
slot from one shared rate limiter. The first slot is `now`. Each later slot is
`max(now, previous slot + minRequestIntervalSeconds)`, so request starts are
spaced across all workers rather than per worker. The limiter refuses a slot
that is not strictly before the collector deadline. This deadline check runs
before every request start, and a refused request is not counted in
`requestCount`. It reserves the slot before sleeping for `slot − now` through
the injectable `wait`, using the injectable `clock`, so tests stay deterministic.
When the coordinator has already read the profile, that read counts as the first
granted slot, which keeps today's spacing and `requestCount`.

The parent task accepts outcomes one at a time in queue order, so `threads` and
`invalidated` stay in listing/queue order. It applies the existing checks:

- An unchanged version completes the ID without output.
- A fetched thread must fit the output budget, reserved together with the full
  proposed continuation metadata, before it is accepted. Accepting it advances
  the thread's version, completion and found bodies.
- A thread-read failure records stage `thread` with the ID and defers the ID.
- Each processed ID becomes `retry_after`, exactly as in the sequential order.
  Processed IDs are accepted, unchanged, failed, oversized, or interrupted by
  the deadline after a request started.

An outcome that is not accepted never advances thread versions, completion or
found bodies. The mailbox version stays frozen as before.

Early stops are the only way a run ends with `complete: false` and a resumable
`pending_collection`. Each stop records a finite failure that names its reason:

| Stop | Stage | Effect |
| --- | --- | --- |
| Limiter refuses a slot during listing or a thread read | `deadline` (recorded once) | The limiter declines slots with less than four seconds before the collector deadline, covering the adapter's three-second child-deadline buffer. No new reads start. Started requests finish within their child deadline. A thread read refused before its first request stays pending, not deferred. A read refused after at least one of its requests started is deferred and becomes `retry_after`, as the sequential collector does today, so a slow item cannot monopolize runs. |
| An outcome cannot fit the conservative output reservation | `output-budget` (with `threadId`) | The ID is deferred, including unchanged and failed outcomes whose checkpoint IDs would exceed the budget. Fetched thread bytes are encoded once and reserved with a conservative allowance for checkpoint metadata. No new reads start. Completed look-ahead outcomes are still evaluated in order. |
| Listing reaches 10,000 items with more pages | `listing-limit` | Listed IDs are still processed. Recorded even if every listed ID is accepted, because the listing is incomplete. |
| Listing provider failure | `listing` (unchanged) | Listed prefix is still processed. |
| Thread provider/validation failure | `thread` (unchanged) | Other threads continue. |
| Listing complete and all IDs complete, but a requested body is missing | `requested-body` (unchanged) | — |
| Cancellation | — | Pending reads are cancelled and `CancellationError` propagates. No partial result is returned. |

There is no generic `budget` stage. IDs that were never launched, or whose read was
refused before its first request, stay in neither `completed` nor `deferred`, so
the next run resumes them first. Removing the per-run cap means
large mailboxes can now stop on `output-budget` or `deadline` instead. A mailbox
whose listing and threads fit both bounds completes in one run whatever
`maxThreads` is.

Concurrency uses Swift 6 strict checking with no unchecked escapes in the
production code. The `fetch` closure taken by the scan, the coordinator and the
adapter is `@Sendable`, and so are the injectable `clock` and `wait`. The rate
limiter state lives in an actor. The coordinator passes its already-read
profile into the scan directly instead of capturing a mutable "used" flag. Its
retry-backlog, scope and failure-stage behavior is otherwise unchanged. The
adapter's per-call child gateway execution, with a 30-second child deadline, is
already independent per call, so concurrent calls are safe. Message-bodies mode
and the other collectors keep their sequential behavior.

GmailCollectionTests covers:

- one-run completion of a multi-page listing with `maxThreads: 1`;
- a concurrency high-water mark of `≤ 4`, and `16` for larger values;
- in-order `threads` and `invalidated`;
- slot spacing through the injected clock and wait;
- each stop stage, with exact resume.

The resume and rotation tests that relied on `maxThreads: 1/2` are rewritten to
stop via deadline or output budget. The scope-hash golden tests stay unchanged.

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

### Independent producer/consumer revisions

A producer may advance its checkpoint while a consumer publishes an older
checked batch. The same builtin supports three metadata-only operations:

- `retain`: requires `label` and the exact non-null `expectedHead`; creates a reference to
  the current scoped head or renews an existing exact historical reference using
  one SQLite transaction. References are durable by default; optional
  `expiresInSeconds` explicitly selects ephemeral retention bounded to 60–604800.
  Optional `retainedLabels` is the caller-owned complete live label set for this
  storage scope; unused labels are atomically released before capacity admission.
  The newly retained label is always included. A live label cannot be rebound
  to a different revision, and each memory database admits at most 256 live labels.
- `load-retained`: requires `label`; returns the exact retained `{head,value}`
  without changing the current head. Missing/expired labels return `found:false`;
  they never fall back to a newer version. The usual payload budget applies.
- `release`: requires `label` and its exact non-null `expectedHead`. It returns
  `released:true` only for the matching retained revision; a missing reference
  is idempotent. An old consumer cannot release a reused label's newer revision.

Storage scope remains memory root, memory ID, workflow, node and tag. Retention
adds metadata in memory schema 6, not a second payload copy or a cache protection
flag. Explicit history retirement refuses to discard an actively retained older
revision. Explicit ephemeral expiry removes no source record, cursor, receipt or history; expired
retention metadata is bounded and pruned on the next retain operation. Article
TTL/LRU caches stay independently disposable. Workflows must still acknowledge
only the exact item versions actually published, independently of newer arrivals.

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


Structured collector cursors remain literal bounded JSON (16 KiB), including
per-author last IDs, independent page cursors and coverage metadata. Only `null`
implicitly signals acquisition completion; a provider may explicitly set
`acquisitionComplete`. Exact version acknowledgements never alter that cursor.

## YouTube: `riela/youtube-collect`, version `1`

The native collector uses the macOS-only `YouTubeGatewayCore` package to read
metadata for explicitly listed public videos and recent uploads from listed
channels. Bind `YOUTUBE_GATEWAY_ACCESS_TOKEN` or
`YOUTUBE_GATEWAY_TOKEN_STORE_JSON` through `addon.env`; the collector passes
only those allowlisted values to the client. Linux execution fails with a
policy error because the linked gateway is macOS-only.

`options.videos` accepts YouTube watch, shorts, live and youtu.be URLs or bare
video IDs. `options.channels` accepts channel IDs, channel URLs and handles.
Malformed references become finite failure records. Optional
`publishedAfter` filters channel uploads by their publication instant;
explicit video references are never filtered. `maxPerChannel` defaults to 10
and is limited to 1–50. Each channel is resolved to its uploads playlist, one
playlist page is inspected, and selected video IDs are enriched in batched
`videos.list` requests of at most 50 IDs.

The output is `{videos, failures, requests}` with the opaque input `context`
preserved by the node. Explicit videos appear first in input order, followed by
channel uploads newest first. Duplicate IDs merge their `sources` entries.
Partial channel and video API failures return alongside successful metadata;
failure messages never include provider responses or credentials. The complete
configuration and output are capped at 8 MB.

Amended 2026-10-30 by `design-youtube-processing-builtins.md` §D.
`excludeLive` and `maxDurationSeconds` filter enriched records and report them
under `excluded`. The default output is unchanged. §A adds the
`riela/youtube-gateway-read` request-level reader.
