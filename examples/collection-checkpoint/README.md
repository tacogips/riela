# Native collection checkpoint fixture

This example makes no provider/model calls and creates no articles. It records
fixture IDs and an opaque cursor in workflow-scoped built-in KV. Pending IDs
remain pending across executions; this example never pretends to publish them.

From the Riela checkout:

```sh
riela workflow validate collection-checkpoint --workflow-definition-dir examples
riela workflow run collection-checkpoint --workflow-definition-dir examples \
  --variables '{"fixtureItems":[{"id":"fixture-1","version":"1"}],"fixtureCursor":"page-2","fixtureComplete":false}' \
  --output jsonl
```

Repeat the run with another fixture ID. Both pending versions remain, while the
revision increments. State uses `.riela/kv/collection-checkpoints.sqlite` under
the working directory. This fixture requires a runtime containing the new
`riela/collection-checkpoint` addon; it is not evidence of an ART migration.
For real sources, place the authored gateway/cache/screening graph between load
and record; keep raw responses inside the application's private boundary.
See [the contract](../../docs/workflows/collection-checkpoints.md).
