# Native cache maintenance

This workflow runs one Swift built-in node, `riela/cache-maintain`, without
agents, Python or shell commands. It expires and evicts rows in the listed
existing cache stores using each store's own policy. It never creates a missing
store and never changes a stored policy.

```sh
riela workflow run managed-cache-maintenance --workflow-definition-dir examples \
  --variables '{"cacheRoot":"/absolute/project/.riela/cache","cacheIds":["managed-example"]}'
```

The node output reports `cacheCount`, `skippedCacheCount` (missing, foreign or
linked stores, so a typo is visible), `deferredCacheCount` (time budget used up
or store busy) and `failedCacheCount` with up to 32 `failedCacheIds`. A failed
store fails the node. Deferred stores are retried on the next run.

`.riela-events` holds an hourly cron source and a binding. Replace
`REPLACE_WITH_ABSOLUTE_CACHE_ROOT` and the cache ID list, then serve it with
`riela events serve`. Cache stores are outside `riela gc` and automatic
retention, so schedule this workflow (or `riela cache maintain`) to reclaim idle
caches. Built-in `x-gateway-*` caches may be listed: maintenance only applies
their stored policy.
