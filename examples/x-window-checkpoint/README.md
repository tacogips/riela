# Specified-author X pages with native checkpoints

The graph uses only built-in nodes. It fetches at most one 25-post recent-search
page per execution for `from:authorHandle`, remembers its cursor and pending IDs,
and skips the API after the fixed window completes. It never reads the home or
following timeline and never invokes a model. `userCache` and `usageCache` use
their separate built-in cache spaces.

```sh
riela workflow run x-window-checkpoint --workflow-definition-dir examples \
  --variables '{"accountScope":"personal","authorHandle":"kenn","windowStart":"2026-10-24T00:00:00Z","windowEnd":"2026-10-24T01:00:00Z"}' \
  --output json
```

Supply X credentials through the existing environment bindings. Keep
`accountScope` stable for one authenticated account; use another scope when
switching accounts. **This command
uses the paid API** for an incomplete window. The automated test replaces the
gateway transport with fixture responses and makes no provider requests.

Repeat with the same window to resume its next page. Use a new window for the
next poll; frozen backfills keep their original bounds. ID is the immutable X
post version here (edits receive new IDs). Pending IDs are not publication ACKs.
This example demonstrates acquisition metadata: a real application adds its
body cache and screening/processing nodes before committing the page and uses
the publisher's receipts to acknowledge items. Missing cache bodies can be
refetched by ID. Raw responses remain in the calling runtime, so ART must place
its reader and screening graph inside its existing private boundary before
using this pattern. This example is not an ART deployment.
