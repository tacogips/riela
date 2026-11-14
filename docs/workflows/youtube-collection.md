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

The gateway is linked on macOS. Linux executions fail with a clear policy
error. Use the collector inside a private workflow when collected metadata
needs inspection before publication.
