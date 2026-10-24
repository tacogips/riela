# Public Web collection

`riela/web-collect` version `1` owns bounded HN/feed/public-index acquisition. It discovers
candidates, reads stories/articles with up to four concurrent requests, preserves
legacy identity/update metadata and returns a proposed checkpoint. It makes no
publication or acknowledgement decision and does not persist that checkpoint;
inspect outputs and compose cache/snapshot nodes before committing it.

```json
{
  "addon": {
    "name": "riela/web-collect",
    "version": "1",
    "config": {
      "options": {
        "kind": "feed",
        "url": "https://example.com/feed.xml",
        "start": "2026-10-25T00:00:00+09:00",
        "end": "2026-10-26T00:00:00+09:00",
        "timezone": "Asia/Tokyo",
        "maximumItems": 20,
        "fetchArticles": false,
        "previous": "{{previousFeedState}}"
      },
      "context": "{{domainContext}}"
    }
  }
}
```

The response contains `records`, `state`, `scan`, `acquisition_complete`,
`has_progress`, `status` and unchanged `context`. Records contain `identity`,
`title`, `text`, `url`, `published_at`, `fetched_at` and `content_scope`. They are
untrusted source data: execute this node inside the private inspection workflow.
Its checkpoint is acquisition metadata, not evidence of inspection/publication.
No minimum batch size is required.

Options shared by all kinds:

- Required `start`/`end` are timezone-aware ISO timestamps, with an exclusive end.
- `previous` is the caller-owned checkpoint object. A native scope marker binds
  URL/provider and effective selection/page settings; legacy unmarked state is
  imported. Concurrency and window changes do not discard valid seen versions.
- `maximumItems` is 1–20, default 20. For feeds it is a per-day cap in `timezone`
  (default UTC); for HN it caps the popularity candidates before low-score items
  are filtered. HN does not fill the cap from lower-ranked stories.
- `maxConcurrency` is 1–4, default 4. One unavailable story remains pending while
  siblings complete. Cancellation returns no proposed advanced checkpoint.
- `fetchArticles` defaults true. `pageOptions` uses the public-web `options`
  format. Optional article failure preserves the title/excerpt and yields
  `partial_failed`; it does not block acquisition or erase acquired siblings.
- `selectionPolicy`, `selectionKeyPrefix` and `selectionSignature` carry authored
  domain labels/identity mapping. Source eligibility and instruction screening
  remain the caller's responsibility.

`kind: "feed"` accepts RSS 2.0 or Atom and requires a public HTTPS `url`. It
supports `blockedHosts`. DTD/external entities and unknown named entities are
refused. `xmlEntities` optionally supplies at most 2500 explicit name/value
mappings (names at most 64 ASCII bytes, values 1–8 scalars). Those names are
converted to numeric references outside CDATA; the five XML predefined names
remain unchanged. This supports feeds with undeclared HTML entities without
network entity resolution or custom parsing scripts. Keep publisher-specific
permission/origin rules in authored configuration.

Dates preserve their original offset, accept aware minute-precision ISO values,
and normalize fractional seconds to six
places for compatibility with legacy fingerprints. Naive, unknown-timezone,
malformed and future entries are skipped/reported. Deterministic invalid entries
are reported as `rejected_entries`, outside the eligible candidate cap; they do
not make the bounded scan permanently pending. Dedup uses the first identity
in publisher order. Changed title/body/publication versions are fetched again.
Conditional ETag/Last-Modified requests are used only for the same bounded window
when no deferred or future entries need reconsideration. A changed
window forces a body read; unsolicited 304 replies are refused. A feed spanning
several days admits at most 200 bodies per call. Wire capacity can defer more
entries; omitted entries never enter `seen` and disable conditional skipping on
the next call. The returned scan does not claim archive completeness.

`kind: "hackernews"` uses the official public Firebase topstories/item endpoints.
`minimumPoints` defaults 20 (range 0–10000). `historical: true` uses one empty-query
Algolia popularity search for the fixed window (at most 25 hours), then retrieves
unseen stories through Firebase. Existing ranked/seen metadata is preserved;
old exhaustive interval queues remain inert. Returned item IDs must match their
requested identity. Known non-story and null items are filtered without entering
`seen`, so they can be reconsidered on a later poll. Neither mode is an exhaustive history crawler. Other source
URLs, credentials and global X requests are not accepted by this adapter.

The builtin bounds a call to 120 seconds, or the shorter parent deadline.
The collector shares public-web's pinned public HTTPS checks, byte/deadline
limits and optional Riela-owned renderer. Its overall output is bounded to 8 MB,
including context. Admission reserves 1 MB of metadata growth and 400 KB for at
least one maximum-sized record; an oversized initial state/context is refused
before HTTP rather than producing an endlessly empty deferred result. A successful result with `partial_failed` must be saved and
reported as partial; it is not permission to drop pending identities or mark
publication complete. Generic durable work scheduling/recovery still composes
with the separate checkpoint, manifest, cache and snapshot nodes.

For inspection, compose `riela/array-batch` (a count and optional byte cap) with
runtime fanout. Keep the proposed checkpoint in the batch `context`, then set
`fanout.contextFrom: "/context"`. The join retains that checkpoint once even
when no records were found. Branches receive only their record batch; a domain
acceptance step must still bind the reviewed IDs/versions before persisting the
checkpoint. No script needs to count batches, wait for a minimum, or advance an
inspection-loop cursor. See [JSON batching](json-data-processing.md).


`kind: "index"` discovers a publisher-ordered candidate set from a public HTTPS
listing, then independently reads up to `index.maximumArticles` (1–20, default
20) per call with the shared 1–4 concurrency bound. `maximumItems` selects the
first 1–20 recognized listing URLs before article requests. Required
`index.linkPattern` is an anchored path regex (at most 512 bytes); only HTTPS
links on the configured listing origin without credentials or nonstandard ports
are admitted. Queries/fragments and trailing slashes are removed for identity.
Navigation links are filtered before the listing link bound. No publisher names,
application adapters, auth or custom scripts are embedded in the collector.

`index.metadataOnly: true` reads head title/lead/date metadata and verifies any
canonical URL against the requested article. It does not expose article bodies
or body metadata. Otherwise the ordinary public-page reader supplies text/date.
`index.publicationJSONLDType` optionally requires one explicit schema type,
`mainEntityOfPage` of type `WebPage` with an exact final article URL, and an aware
ISO `datePublished`. This mode forces HTTP, reads at most ten valid JSONLD
scripts of at most 200 KB each, and does not return raw scripts. Conflicting or
invalid bound dates remain undated; unrelated types/pages, `dateModified`, body
text and acquisition times never supply a missing publication date. JSONLD and
metadata-only policies are mutually exclusive. Keep publisher route/type
permissions in the application config, for example:

```json
{
  "kind": "index",
  "url": "https://example.com/newest",
  "start": "2026-10-25T00:00:00+09:00",
  "end": "2026-10-26T00:00:00+09:00",
  "maximumItems": 20,
  "index": {
    "linkPattern": "^/post/[A-Za-z0-9-]+$",
    "maximumArticles": 5,
    "publicationJSONLDType": "BlogPosting"
  },
  "previous": "{{previousIndexState}}"
}
```

Index state imports existing `seen`, `after_window` and `article_attempts`
metadata. Failed/undated URLs rotate behind untouched candidates; peer results
remain usable. Earlier-than-start dates become metadata tombstones, while dates
at/after the exclusive end remain deferred and are reconsidered when the window
grows. Future publication dates are never tombstoned. Wire-capacity omissions
never enter `seen`. An unrecognized/empty listing fails without advancing state.
`acquisition_complete` describes the bounded candidate scan, never an exhaustive
archive: remaining budget, unavailable or undated URLs produce `partial_failed`.
The returned checkpoint still requires domain inspection before durable commit.

Index terminal `seen` hints are bounded by `index.maximumSeenEntries` (20–10000,
default 1000). Current listing candidates take priority; remaining hints retain
the most recent `last_seen_at`/`seen_at`, with deterministic identity tie breaks.
Evicted hints allow refetch and never acknowledge pending work. Pending receipts,
provider cursors and unrelated state fields are preserved. Compaction occurs
before record-capacity admission and after a successful scan. Other opaque,
oversized input/state still fails within the existing 8 MB transport bound.

For a large legacy checkpoint, call the same addon with
`action: "compact-state"` and ordinary index `options` before constructing a
larger private task/context. This pure operation returns `kind:
"web-collection-state"`, compacted `state` and unchanged `context`. It performs
no HTTP, browser, provider, persistence, publication or acknowledgement work.
The default action remains `collect`; other kinds cannot use `compact-state`.
This avoids duplicating a large legacy seen map into both native options and
private inspection context. Applications can use the node's JSON result directly.
