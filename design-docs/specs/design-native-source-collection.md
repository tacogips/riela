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
| `authorSampling` | Optional object, handle → probability in [0,1]; keys match `authorHandles` case-insensitively; see "Per-author sampling" |
| `authorDailyPostThreshold` | Optional integer 1–100000; enables automatic sampling of high-volume authors; see "Per-author sampling" |
| `referenceDepth` | Optional integer 0, 1 or 2, default 2; nested quote/repost levels in the default selection; rejected together with `select`; see "Reference depth" |

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

### Per-author sampling

X bills every returned post. A few prolific authors can fill the page budget,
crowd out the other authors and drive up cost. Sampling reads such authors in
only a fraction of runs, and only for that run's window. Handles always come
from configuration and are never hard-coded.

```json
{
  "options": {
    "expectedHandle": "me",
    "authorHandles": ["alice", "bob", "carol", "dave"],
    "start": "2026-11-10T00:00:00Z", "end": "2026-11-10T06:00:00Z",
    "earliest": "2026-11-09T00:00:00Z",
    "pageSize": 25, "maxPages": 4, "maxPosts": 100,
    "authorSampling": { "Bob": 0.25 },
    "authorDailyPostThreshold": 10,
    "previous": {}
  }
}
```

Without `authorSampling`, `authorDailyPostThreshold` and a non-default
`referenceDepth`, output keys, the selection and the checkpoint format stay
exactly as before this change. The only change on the default path is in
"UTC-day aware re-reads": it excludes historical covered ranges, and it adds
the `skip`/`segment` pending keys only when such a range exists.

**Sampled set and probability.** Each run computes the effective probability
of each author:
1. An explicit `authorSampling` entry wins. Its probability is used as given,
   including 1 (always read, outside the regular query) and 0 (never read).
2. Otherwise the frozen auto entry from the checkpoint state, described below,
   applies when `authorDailyPostThreshold` is set.
3. Otherwise the author is regular.

Sampled authors are removed from the regular author list before query packing.
The regular `from:` query, its 512-byte shards, the `author_scope` hash and the
`signatureContext.settings.author_handles` value all use only the regular
handles. Sampled authors therefore never consume regular pages, cursors or
`since_id`.

**Deterministic draw.** Let `u` be the first 8 bytes of
`SHA-256(UTF-8(lowercase(handle) + "\n" + canonicalEnd))`, read as a big-endian
UInt64 and divided by 2^64. `canonicalEnd` is `end` re-rendered as
second-precision UTC ISO-8601 (`yyyy-MM-ddTHH:mm:ssZ`, via the existing
`xInstant` and `ISO8601DateFormatter`). The author is drawn iff `u < p`.
Swift's `Hasher` is never used, so a given handle and `end` give the same
result on every process and platform. p = 0 never draws and p = 1 always draws.

**Sampled read.** The drawn handles are packed into their own `from:` groups
under the same 512-byte rule. Each group is read as a bounded window over
exactly [`start`, `end`), as follows:
- The read starts from an empty previous. It carries no cursor or `since_id`
  and never widens toward `earliest`.
- It is a regular, non-fresh-head read: one page (`maxPages` 1) of `pageSize`
  posts.
- This budget is separate from `maxPosts`. The run's post-count guard becomes
  `maxPosts + pageSize × drawnGroupCount`. The 6 MB post and 8 MB output byte
  limits are unchanged.

Cost is bounded at one extra search request and at most `pageSize` posts per
drawn group per run. A next token left on a sampled read is not persisted; the
handle is reported as `truncated`. Sampled posts go through the same accept
filter (interval, deduplication, allowed fields, `_fetched_at`, `_account_id`)
and are merged into `posts`. Run-level ID deduplication then applies.

A sampled-read failure appends a `failures` entry with `stage: "sampled"` and
does not fail the run. `complete` and `checkpoint.coverage` still describe only
the regular query. Sampled reads are best-effort by design, and their window is
never resumed.

**Query change.** A sampling change can alter the regular query. The existing
checkpoint identity then applies:
- A single shard whose `author_query` differs keeps only `config_key`.
- Sharded checkpoints whose `author_scope` differs are discarded.

The stale `pending_scan` is therefore dropped before validation, which rules
out an invalid-cursor failure. The new query scans [`start`, `end`) fresh from
the caller's `start`, never `earliest`, so there is no 24 h re-read. Tests pin
this behavior. When every author is sampled, no regular search runs, and the
checkpoint is the minimal object `account_id`, `expected_handle`, `checked_at`,
`author_query: ""` with `coverage` {start, end, complete: true} for
[`start`, `end`), plus `author_sampling` when that key applies.

**Auto-sampling state** (only when `authorDailyPostThreshold` is set). The
checkpoint gains one top-level key, `author_sampling`, which the collector
removes from `previous` before building windows and re-attaches to the final
checkpoint (single or combined):

```json
"author_sampling": {
  "version": 1, "timezone": "UTC", "auto_day": "2026-11-10",
  "auto": { "bob": { "probability": 0.25, "observed_daily_volume": 40.0 } },
  "through": { "bob": "2026-11-10T06:00:00Z", "carol": "2026-11-10T06:00:00Z" },
  "pending": { "<sha256-24 of author_query>": { "start": "2026-11-10T00:00:00Z",
    "end": "2026-11-10T06:00:00Z", "posts": { "carol": 3 } } },
  "days": { "2026-11-10": { "bob": { "posts": 12, "seconds": 21600 } } }
}
```

All volume evidence follows one rule. A **count interval** is a time range
that was fully observed for a set of handles. It contributes its length in
`seconds` and, as `posts`, exactly the posts in that range. A range that is
already counted, or was not fully observed, contributes nothing.

- **Bounded state.**
  - `through[h]` is the instant up to which handle `h`'s posts have been
    counted. It only moves forward. There is one entry per handle in
    `authorHandles`.
  - `pending` holds one entry per regular query whose scan is still
    cursor-pending, keyed by the 24-hex SHA-256 of `author_query`. Each entry
    stores the scan's frozen `start`/`end` and a per-handle post tally.
  - `days` keeps only the last 7 calendar days of `end` in `options.timezone`.
  - Every map is keyed only by handles in `authorHandles`, at most 100. The
    state is therefore at most about 7×100 + 2×100 small entries.
- **Attribution.** Accepted posts (after the existing interval, ID and
  `since_id` filters) are attributed by `author.username`, matched
  case-insensitively against `authorHandles`. Posts that match no handle, or
  whose selection omits `author`, are not counted. Freshness head-probe posts
  are never counted; the backlog scan that later covers that time counts them.
- **Regular scan.** The scan has a frozen window [s, e) over handles H. For each
  h in H, let `lo(h) = max(s, through[h])`; `through` absent counts as s.
  - Each run that accepts pages of a still-pending scan adds, to that query's
    `pending.posts[h]`, the accepted posts of h with `createdAt ≥ lo(h)`.
    Nothing is added to `days` yet. A pending entry is valid only while its
    `start`/`end` equal the scan's frozen window and its key equals the shard's
    current `author_query`. Otherwise it is discarded, together with the
    reset scan.
  - The scan completes when `coverage.complete` is true: no cursor, no
    failure, no window growth. On completion, for each h, the count interval is
    [lo(h), e). If its length is > 0, add the length to `seconds` and
    `pending.posts[h]` plus this run's matching posts to `posts`. Then set
    `through[h] = max(through[h], e)` and drop the pending entry.
  - A run that ends with the scan failed or growth-pending, and no cursor,
    contributes nothing, and its tally is discarded.
- **Replays and overlaps.** Replaying a completed window, or overlapping it,
  adds zero length for the already-counted part. The `since_id`-filtered
  accepts in that part are below `lo(h)` and add nothing, so a replayed
  [s, e) with 40 posts in 86400 s stays at 40/day. A later window [s2, e2)
  with s2 < e counts only [e, e2) and the posts in it.
- **Sampled read.** This is a drawn group over [start, end) with handles G.
  - Complete read (no next token, no failure): for each h in G, the count
    interval is [lo(h), end), with lo(h) = max(start, through[h]).
  - Truncated read (next token present): the page holds the newest posts of
    the whole group in descending time. So the only fully observed range is
    [t_old, end), where t_old is the oldest accepted `createdAt` on the page.
    For each h in G, the count interval is [max(t_old, through[h]), end), with
    the group's posts at or after that bound. Seconds are never added for
    [start, t_old). If the page holds no accepted posts, nothing is counted.
    Example: a 25-post page covering 1.5 h records 25 posts over 5400 s, which
    is 400/day. It does not record 25 posts over 86400 s.
  - A failed read counts nothing. Each counted interval sets
    `through[h] = max(through[h], end)`.
- **Bucket and order.** A count interval's `posts` and `seconds` go into the
  bucket for the calendar day of its end. Per run the order is:
  1. validate and load the state;
  2. prune buckets older than 7 days before `end`'s day;
  3. recompute the auto set if needed;
  4. run the regular and sampled reads;
  5. apply regular shards in index order, then sampled groups in index order;
  6. prune again and attach the state to the checkpoint.
- **Volume.** observedDailyVolume(h) = Σposts / Σseconds × 86400 over the
  retained buckets. It is evaluated only when Σseconds ≥ 86400.
- **Recompute, at most once per day.** The auto set is recomputed only when
  `end`'s day differs from `auto_day`, or when no state exists yet. It uses
  the state from before this run's observations. For a handle without an
  explicit entry:
  - if its volume is evaluable and above the threshold, it gets
    p = min(1, threshold / volume), for example threshold 10 at 40/day gives
    p = 0.25;
  - if its volume is evaluable and not above the threshold, it becomes
    regular;
  - if its volume is not evaluable, the handle keeps its previous auto entry,
    if any. A rarely drawn author therefore stays sampled instead of dropping
    back to the regular query.

  Between recomputes, the set and its probabilities stay frozen as stored, so
  the regular query changes at most once per day.

**Output metadata.** The output gets a top-level `sampling` object only when
either option is present:

```json
"sampling": { "version": 1, "threshold": 10, "day": "2026-11-10",
  "handles": [ { "handle": "bob", "source": "explicit", "probability": 0.25,
    "observedDailyVolume": 40.0, "status": "drawn", "fetchedCount": 7, "truncated": false } ] }
```

- `handles` lists only sampled authors, sorted by lowercase handle, so it has
  at most 100 entries.
- `source` is `explicit` or `auto`, and `status` is `drawn` or `skipped`.
- `observedDailyVolume` is null when no threshold is set or there is not
  enough observation.
- The object counts toward the existing 8 MB output limit.

**Validation.** The following are rejected with the standard invalid-input
error, before any provider call:
- `authorSampling` that is not an object;
- keys that are not in `authorHandles` (case-insensitive) or that duplicate
  each other case-insensitively;
- values that are not a JSON number in [0,1];
- `authorDailyPostThreshold` that is not an integer in 1…100000;
- `referenceDepth` that is not an integer in 0…2, or that is combined with
  `select`;
- a malformed `previous.author_sampling` when the threshold is set.

### Reference depth

X may bill the quoted and reposted posts and their authors that a selection
pulls in. Whether X bills these included objects separately is not documented,
so the collector assumes it may. `referenceDepth` lets a caller request fewer
of them. The option only shapes the default selection that the collector
passes to the linked SDK reader. The SDK derives the provider fields and
expansions from that GraphQL selection, so riela never builds `tweet.fields`
or `expansions` itself.

Number the post levels from 0, the returned post itself. With depth `d`, the
level-`k` post selection is:
- always `id`, `text`, `createdAt`, `author {id username name}` and
  `media {kind contentType sourceUrl previewImageUrl}`, plus `urlEntities` and
  the coverage fields when `includeStatusLinks`/`includeCoverageMetadata` ask
  for them;
- `references {id relation}` when `k == 0` or `k < d`;
- `quote` and `repost`, each the level-`k+1` selection, when `k < d`.

| `referenceDepth` | Nested posts and authors requested |
| --- | --- |
| 2 (default) | Two quote/repost levels. The selection is byte-identical to today's `postFields(depth: 0, …)` output |
| 1 | One level: the quoted/reposted post and its author, with no further nesting |
| 0 | None. The root keeps `references {id relation}`, so callers still see which posts were quoted or reposted and can recover them through exact-ID lookup |

Rules:
- `referenceDepth` together with `select` is rejected as invalid input, since a
  caller-supplied selection already decides the depth.
- Sampled reads and the freshness head probe use the same selection as the
  regular query.
- Lookup mode (`mode: "lookup"`) keeps its current full selection. Exact-ID
  recovery is out of this option's scope.
**Depth identity.** Depth is part of each window's continuation identity,
next to `account_id` and `author_query`:
- A window checkpoint gets `reference_depth` (0 or 1) only when the effective
  depth is not 2. With depth 2, or with a custom `select`, the key is never
  written. Checkpoints without the key, which includes every legacy checkpoint,
  are read as depth 2. The default path therefore stays byte-identical.
  Existing custom-`select` behavior is unchanged: a changed `select` still
  keeps the cursor as before.
- The key lives where `author_query` lives. That is the top level of a
  single-shard checkpoint, and each `author_shards[i]` object of a sharded
  checkpoint. The combined sharded wrapper does not carry it.
- When a window's previous depth (absent = 2) differs from the effective
  depth, the window is handled like an `author_query` change
  (`XCollectionWindow.init`). Only `config_key` is kept, and `pending_scan`,
  `since_id`, `coverage`, `fresh_head_receipt` and the scan counters are
  dropped. The new scan covers [`start`, `end`) fresh from the caller's
  `start`. It never reuses a stale token and never widens to `earliest`. No
  provider token is ever sent with a selection other than the one it was
  issued for, so nothing depends on X accepting tokens across selections.
  The previous `coverage` is dropped too, so the UTC-day exclusion below does
  not apply to the first scan at the new depth: that scan re-reads
  [`start`, `end`) at the new depth, as item 5 requires.
- The `author_sampling` state (see "Per-author sampling") is separate from the
  window and survives a depth change.
- With an unchanged depth, continuation is exactly as today.

Required regression assertions:
- A depth-2 checkpoint with `pending_scan` run with depth 0 makes its first
  request with `startTime` = wire(`start`), no `nextToken` and no `sinceId`,
  and writes `reference_depth: 0`.
- A completed depth-2 checkpoint run with depth 1 behaves the same: a fresh
  request from `start` with no `since_id` narrowing.
- A depth-0 pending checkpoint run again with depth 0 continues its exact
  token.
- An absent `referenceDepth` and an explicit 2 both continue a legacy pending
  token and produce a checkpoint without `reference_depth`, byte-identical to
  today's.
- The closed-day head receipt signature includes the selection, so the default
  depth gives the same signature as today.

### UTC-day aware re-reads

X deduplicates billed reads only within a UTC day, which resets at UTC
midnight. Reading a post again on a later UTC day is billed again. This holds
whatever `timezone` the options use, which only decides when a requested
interval counts as a closed day. The collector therefore must not re-request
the part of a window that an earlier completed scan covered on a previous UTC
day.

**Billing boundary.** `D` is 00:00:00 UTC of the execution clock's UTC day.
It is read once, from the collector's injected `clock()`, at the start of
`collect`, and stays frozen for the whole run: every shard, segment and resume
decision in that run uses the same `D`. Neither the requested `end` nor
`options.timezone` decides `D`.

**When it applies.** The rule applies when a regular window starts a fresh scan,
that is, when there is no `pending_scan` to resume and the account,
`author_query` and reference depth are unchanged. It needs the previous
window checkpoint's `coverage` C to be an object with `complete: true`, the
same `account_id` and parseable `start`/`end` (cs, ce). The historical
covered range is

`H = [max(cs, start), min(ce, end, D))`

When H is empty, the rule does not apply. The scan, its keys and its requests
are exactly as today; this includes current-day overlaps (ce > D), where
the existing `since_id` narrowing applies. When H is non-empty, the window
[`start`, `end`) splits into at most two uncovered segments around H:
- **suffix** `[he, end)`, where `he = H.end`. It is requested newest first, as
  today. `since_id` narrowing applies: `search_start =
  wire(max(he, searchStart(since_id, start: he, end: end)))`, sent as
  `startTime` without `sinceId` exactly as today. The `since_id` accept filter
  applies.
- **prefix** `[start, hs)`, where `hs = H.start`. It is non-empty only for a
  widened window with `start < cs`. It is requested with `startTime =
  wire(start)` and `endTime = wire(hs, upper)`, with no `sinceId`, no
  `search_start` and no `since_id` accept filter, because its posts are older
  than `since_id` by construction. The interval filter and the
  `recent_ids`/run ID deduplication still apply.

H itself is never requested.

**Order and continuation.** The suffix runs first, then the prefix. A segment
with zero length is skipped. If both are empty, the whole window was covered
on a previous UTC day: no search request is made, the scan completes with zero
pages and `coverage.complete` true for [`start`, `end`), and `since_id` keeps
its value.

Both segments share one `pending_scan`, which is the same window, query and
cursor owner as today. They also share the per-run budgets (`maxPages`, the
shard post budget, the 6 MB post limit), which the run counts in memory
(`pages`, `fetched`, `bytes`) and never resets at a segment switch. The
`recent_ids` deduplication history and `max_id` also stay shared. The token
history is per segment, because the two segments are independent provider
pagination sequences: `visited_tokens` and `page_count` describe only the
active segment. When H is non-empty, the fresh `pending_scan` gains two keys:
- `skip`: `{"start": hs, "end": he}` holds the excluded historical range. It is
  retained evidence of the earlier completed coverage, needed after `coverage`
  is overwritten by the pending state.
- `segment`: `"suffix"` or `"prefix"` names the segment that owns
  `next_token`.

**Segment switch.** When the suffix ends without a token and the prefix is
non-empty, the scan switches to the prefix:
- `segment` is set to `"prefix"`;
- `next_token` is set to null;
- `visited_tokens` is set to [] and `page_count` to 0;
- `search_start` is removed.

The prefix's first request, which carries no token, therefore never collides
with the suffix's recorded hash of the empty initial token. Cycle detection
stays strict within each segment: a repeated token in the same segment is
still rejected. The switch happens in the same run while the in-memory page
and post budget allow another page. Otherwise the switched state, an unstarted
prefix, is persisted and the next run resumes it. A page-limited suffix or
prefix persists its token under its segment and resumes it exactly. A pending
scan never recomputes H, because `skip` is authoritative.

**Failure.** While `skip` is present and the scan is not complete, the window
result always persists `pending_scan`. This includes a failure before any page
of the active segment was accepted, where today's unsegmented finalization
writes no `pending_scan`. The persisted scan keeps:
- `skip` and `segment`;
- the active segment's token state. A failed first request leaves an unstarted
  segment: null token, `page_count` 0, `visited_tokens` [];
- `max_id`, the progress of completed segments. A finished suffix stays
  finished: after a prefix failure, `segment` stays `"prefix"`;
- the committed `since_id`, unchanged until completion.

`coverage.complete` is false, and `scan_stop_reason` is `gateway-failure` or
`page-budget`, as today. A retry resumes exactly the unfinished segment and
never requests H or a completed segment.

**Validation of a pending scan with `skip`.** It replaces the legacy
token/`page_count` rule only for these scans:
- `start ≤ hs ≤ he ≤ end` as instants, and `segment` is `"suffix"` or
  `"prefix"`;
- `visited_tokens.count == page_count` with `page_count` in 0…10000, and
  visited hashes are distinct;
- the token is null if and only if `page_count == 0` (an unstarted segment).
  Otherwise it is non-empty, ≤ 8192 bytes and its hash is not in
  `visited_tokens`;
- in the suffix, `search_start` equals the formula above recomputed from
  `skip` and `since_id`. In the prefix, `search_start` is absent;
- `segment: "suffix"` requires a non-empty suffix, and `segment: "prefix"`
  requires a non-empty prefix;
- the existing `since_id`, `page_size`, `recent_ids`, `max_id`, `wire_*` and
  `bounded` checks apply unchanged.

Any mismatch is invalid input, as today. Pending scans without `skip` are
validated exactly as today: a token is required and `page_count` is 1…10000.

**Completion.** The scan is complete when both segments have finished with no
token and no failure. Then `since_id` = `max_id` (prefix posts never raise
it), `pending_scan`, `skip` and `segment` are removed, and `coverage` is
{`start`, `end`, complete: true}. This is truthful: [`start`, `end`) is the
union of prefix, H (covered by the earlier complete scan) and suffix. Until
then, coverage stays incomplete. Failures follow the Failure rule above, and
growth handling is as today. The reported `scan_page_count` is the active
segment's `page_count`, and `page_count` (this run's pages) counts both
segments.

**Scope.**
- The rule is not tied to an option. It only changes request bounds when a
  complete previous coverage overlaps an earlier UTC day. The `skip`/`segment`
  keys appear only in that case, so checkpoints that never meet it are
  unchanged.
- Sampled reads start from an empty previous (see "Per-author sampling") and a
  window reset by a query or depth change has no previous coverage, so neither
  is affected.

**Required regression assertions** (frozen clock 2026-11-11T12:00:00Z,
D = 2026-11-11T00:00:00Z):
1. **Historical partial-day replay.** Coverage and request are both
   [2026-11-10T01:00Z, 2026-11-10T06:00Z), with `since_id` at 05:00Z. The run
   makes zero search requests, coverage is complete and `since_id` is retained.
2. **Historical closed-day replay.** Coverage and request are both a full
   2026-11-09 day. The run makes zero requests.
3. **Current-day overlap.** Coverage is [2026-11-11T01:00Z, 05:00Z) and the
   request is [2026-11-11T01:00Z, 08:00Z). H is empty, so the requests are
   today's (`since_id` narrowing) and the uncovered current-day suffix is
   collected.
4. **Suffix only.** Coverage is [2026-11-10T00:00Z, 2026-11-10T12:00Z) and the
   request is [2026-11-10T00:00Z, 2026-11-11T06:00Z). There is one segment
   with `startTime` ≥ 2026-11-10T12:00Z.
5. **Both sides.** Coverage is [2026-11-09T12:00Z, 2026-11-10T00:00Z), the
   request is [2026-11-09T00:00Z, 2026-11-11T06:00Z), and `since_id` is at
   2026-11-09T18:00Z. The suffix requests start at 2026-11-10T00:00Z, the
   prefix requests are [2026-11-09T00:00Z, 12:00Z) with no `sinceId`, and no
   request touches [12:00Z 11-09, 00:00Z 11-10).
6. **Prefix plus a current-day covered tail.** Coverage is [2026-11-09T12:00Z, 2026-11-11T06:00Z) and the
   request is [2026-11-09T00:00Z, 2026-11-11T06:00Z). With D = 11-11 00:00Z,
   H ends at D, so the suffix is [D, 06:00Z) under `since_id` narrowing and
   the prefix is [00:00Z, 12:00Z 11-09).
7. **Page-limited resume.** In case 5 with `maxPages` 1, a suffix token
   persists with `segment: "suffix"` and `skip`. The next run (with a later
   clock) resumes that exact token, then the prefix, and never requests H.
8. **Default path.** Existing XCollectionTests stay green unchanged.
9. **Both sides within one run.** Case 5 with `maxPages` 2 and a suffix that
   ends on page 1 without a token. Page 2 is the prefix's first request
   (no `nextToken`, [2026-11-09T00:00Z, 12:00Z)). It is accepted, the scan
   completes, and coverage is [`start`, `end`) complete.
10. **Prefix startup after a budget stop.** Case 5 with `maxPages` 1. The suffix
    ends without a token, so the persisted state is `segment: "prefix"`, null
    token, `page_count` 0 and `visited_tokens` []. That state validates, and
    the next run's first request is the prefix's initial request. Within a
    segment, a provider token that repeats a visited hash is still rejected.
11. **Initial suffix failure.** Case 5 where the first suffix request fails.
    The result keeps `pending_scan` with `skip`, `segment: "suffix"`, null
    token, `page_count` 0 and the unchanged `since_id`, and coverage is
    incomplete. The retry requests only the suffix (and then the prefix) and
    never H.
12. **Initial prefix failure.** Case 5 where the suffix completes and the first
    prefix request fails. The persisted `segment` is `"prefix"` with the
    suffix's `max_id` kept. The retry requests only the prefix, never the
    suffix or H, and on completion `since_id` = `max_id`.

### Daily usage read (`usageTweets`)

Every X call goes through the linked x-gateway SDK (`Package.swift` pins
`x-gateway` exactly). The SDK SDL `type Query` is the operation authority:
`XGatewayOperationCatalog.queryOperationNames` parses it, and
`riela/x-gateway-reader` already forwards any operation in it, under the
existing reader output limits and with
`postprocess`. The collector design rules out a custom REST client, a
subprocess or a second HTTP path in riela. So `GET /2/usage/tweets` is
exposed only if the pinned SDK already has a Query field for it.

The decision is made at implementation time by a credential-free check: run
the in-process `x-gateway-reader graphql schema` (the same call
`XGatewayOperationCatalog` makes) and look for a usage Query root field.
- **Present:** document the `riela/x-gateway-reader` JSON-mode recipe
  (`operation: "<sdk field name>"`, a minimal `select`, a `pick` postprocess) in
  the add-on docs. Add a fixture test through `XGatewayReaderSDK.invocationOverride`
  that checks the document, the selection and that the existing output byte
  limit rejects oversized usage output. riela adds no new operation code.
- **Absent:** riela does not implement it. Changing the SDK is outside this
  repository, and adding a REST path would break the single-SDK-path rule
  above. Record the outcome here, with the pinned version and the checked SDL
  root names, and leave ART's monitor without daily usage until an SDK release
  adds the field.

Implementation outcome: **present** as `apiUsage(days: Int)` in x-gateway
0.1.27. The pinned SDL and `/2/usage/tweets` mapping were checked with
`grep -rn -i usage .build/checkouts/x-gateway/Sources`; evidence:
`tmp/x-collect-author-sampling/xs-04-usage-and-docs/usage-grep-final.log`.

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

Per-author sampling tests in `XCollectionTests` use the injected transport only
and cover the following:
- the draw is deterministic for a given handle and `end`, and lands at about
  25% over many `end` values when p = 0.25;
- sampled handles are absent from the regular `query`;
- a drawn read uses [`start`, `end`) with no `nextToken`, no `sinceId` and no
  `earliest` widening;
- auto p = 0.25 at threshold 10 and 40/day, and an explicit entry overrides it;
- the auto set is frozen within a day;
- accounting regressions:
  - replaying a completed window with 40 posts over 86400 s through its own
    checkpoint keeps the volume at 40/day and the next-day p at 0.25;
  - an overlapping window counts only [previous through, new end) and its
    posts;
  - a regular scan finished over several runs via a cursor counts each
    accepted post and the window length exactly once, at completion;
  - a pending tally is discarded when its query or window resets;
  - after a seeded reliable 400/day estimate, a truncated sampled page with
    25 posts spanning 1.5 h of a 24 h window records 5400 s rather than
    86400 s, and the estimate stays at about 400/day;
  - a failed read counts nothing;
  - a handle that is not evaluable keeps its prior auto entry;
- a query change with a stale `pending_scan` scans fresh from `start` without
  an error;
- the `sampling` metadata;
- validation rejections;
- an unchanged checkpoint and output when the options are absent.

Gate commands: `swift build --build-tests`, then
`swift test --skip-build --filter 'XCollect|XCollection|XLookup'`, and
swiftlint on the changed files, all run from an arm64 shell.

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
