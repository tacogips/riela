# Public Web collection

`riela/web-collect` version `1` owns bounded HN/feed acquisition. It discovers
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

Options shared by both kinds:

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

Dates preserve their original offset and normalize fractional seconds to six
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
