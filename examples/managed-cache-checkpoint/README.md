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

The `reconcile` step and the `retainedReferences` of the `put` step reconcile
the same snapshot on purpose. The standalone `reconcile` step shows how a
transition that stores nothing new releases superseded artifacts, and its
result lists any reference that is already gone as `missing`. The `put` step
then repeats the reconciliation atomically with admitting the new entry, so a
capacity failure rolls both back. A workflow that always stores a new entry
can drop the standalone step.
