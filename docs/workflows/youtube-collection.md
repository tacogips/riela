# YouTube metadata collection

`riela/youtube-collect` reads metadata for explicitly listed public videos and
recent uploads from selected channels. It does not download video or audio.
On macOS, bind a saved `youtube-gateway` token store or an access token through
the node's `env` map:

```json
{
  "id": "youtube",
  "addon": {
    "name": "riela/youtube-collect",
    "version": "1",
    "config": { "options": "{{item.options}}" },
    "env": {
      "YOUTUBE_GATEWAY_TOKEN_STORE_JSON": {
        "fromEnv": "ART_LATEST_YOUTUBE_TOKEN_STORE_JSON",
        "required": false
      }
    }
  }
}
```

For example, set the workflow's `item.options` to:

```json
{
  "videos": ["https://www.youtube.com/watch?v=8QxKwYOyUaE&t=482s"],
  "channels": ["UCFBqEEd6cWtdCIEO0mHMluA", "@example"],
  "publishedAfter": "2026-10-20T00:00:00Z",
  "maxPerChannel": 5
}
```

`videos` accepts watch, shorts, live and youtu.be URLs or bare IDs. `channels`
accepts channel IDs, `/channel/UC…` URLs and handles. `publishedAfter` only
filters channel uploads; explicit video entries are always retained. The
result contains `videos`, `failures` and a provider request count. Each video
contains its canonical watch URL, metadata, duration in seconds, best available
thumbnail and `sources`. Duplicates merge their source list. Invalid references
and API failures appear in `failures`; successful partial metadata is returned.

Optional `likedAfter` (RFC 3339 instant) also collects the authorized account's
liked videos whose like time is at or after that instant. It reads the account's
liked-videos playlist, newest like first, and stops at the first older like, so
earlier likes are never listed. Optional `maxLiked` (1 to 500, default 50) caps
the number of liked videos. This needs an OAuth token store or access token for
the account; an API key alone cannot read likes. Liked videos carry `liked` in
`sources` and their like time in `likedAt`, follow explicit videos in the output,
and are not filtered by `publishedAt`. `videos`, `channels` or `likedAfter` must
be supplied.

The gateway is linked on macOS. Linux executions fail with a clear policy
error. Use the collector inside a private workflow when collected metadata
needs inspection before publication.

Optional `excludeLive` (boolean, default `false`) excludes videos marked `live`
or `upcoming`. Optional `maxDurationSeconds` is an integer from 1 to 604800;
it excludes longer videos and keeps videos with unknown duration. Both filters
apply to explicit videos and channel uploads after metadata collection, so a
channel may yield fewer than `maxPerChannel` videos. A video matching both
filters is attributed to live only.

When `excludeLive` is true or `maxDurationSeconds` is supplied, the result also
contains `excluded: {"count": 0, "live": [], "duration": []}`. The arrays hold
excluded video IDs in output order, and `count` is their combined length. With
neither filter enabled, including `excludeLive: false` alone, the output remains
unchanged and contains only `videos`, `failures`, and `requests`.
