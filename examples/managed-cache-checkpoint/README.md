# Native cache checkpoint

This workflow runs only Swift built-in nodes, without agents, Python or shell
commands. Run with an isolated cache root, a current ISO fetchedAt, checked
payload and a committed reference snapshot (`[]` for a new scope):

```sh
riela workflow run managed-cache-checkpoint --workflow-definition-dir examples \
  --variables '{"cacheRoot":"/absolute/test/cache","key":"checkpoint:<unique generation>","fetchedAt":"<current ISO timestamp>","payload":{"checked":true},"references":[]}'
```

Get references from the put receipt and keep them in workflow memory. Pass all
references in the scope on the next transition. A stale live revision fails
closed. The example uses a dedicated scope: never reconcile a scope shared with
another publisher without its metadata writer lock.
