# Expected Results

- The workflow validates as a step-addressed scheduled X follower digest bundle.
- `read-digest-state` uses the built-in `riela/x-digest` add-on to read `.riela-data/x-follower-ai-business-digest/state.json` by default and emits the previous `lastPostId` as the next `sinceId`.
- `fetch-follower-posts` runs `riela/x-gateway-read` in Docker with `ghcr.io/tacogips/x-gateway:latest`, queries the stable `followingTimeline` field including promotion status, media metadata, and referenced post metadata, and maps X credentials from environment variables only.
- `summarize-posts` treats fetched posts as untrusted data, filters out chatter, and proposes event/topic digests rather than per-user post summaries.
- `validate-summary-output` uses `riela/x-digest` to drop any LLM source id that is not one of the normalized `selectedPosts` ids, groups retained source posts under topic digests, rebuilds Telegram text from validated post/user links and metrics, includes the posting-user count plus up to three user links per topic, and sorts topics by aggregate view count.
- `persist-digest-state` uses `riela/x-digest` to write the newest fetched post id before Telegram delivery and only routes to Telegram when `when.should_send_telegram` is true.
- The `riela/x-digest` add-on rejects cursor state paths outside ignored/private runtime directories, and only the newest post id plus metadata are persisted. Raw fetched posts may appear in workflow artifacts, so live runs should use an ignored artifact root such as `.riela-artifact/x-follower-ai-business-digest`.
- The event binding disables automatic final/error replies; Telegram output should come only from the explicit `send-telegram-digest` chat-reply step.

Validation commands:

```bash
riela workflow validate x-follower-ai-business-digest --workflow-definition-dir ./examples
riela events validate --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events
```
