# Expected Results

- The workflow validates as a step-addressed incremental X fetch bundle built on the built-in workflow key-value store add-ons.
- `read-cursor` uses `riela/kv-get` to read key `fetch-cursor` from store `x-posts`; on the first run the key is absent, so the payload carries `found: false` and the configured `default` value (`{"sinceId": ""}`) as `value`, and later steps can reference `{{inbox.latest.output.payload.value.sinceId}}`.
- Store entries are scoped to this workflow id by default (`scope: x-incremental-posts-kv`), so other workflows sharing the same store file never observe this cursor unless they opt in with an explicit `config.scope`.
- `fetch-posts` runs `riela/x-gateway-read` in Docker with `ghcr.io/tacogips/x-gateway:latest` and maps X credentials from environment variables only; without an installed container add-on runtime the step defers with a plain `status: ok` payload.
- `persist-cursor` uses `riela/kv-set` with a `valueTemplate` that stores the newest fetched post id from `pageInfo.newestId`; the entry is upserted, so successive runs overwrite the same `(scope, key)` row and `createdAt` is preserved while `updatedAt` advances.
- The store persists to `<kvRoot>/x-posts.sqlite`; `kvRoot` resolves from add-on `config.kvRoot`, then workflow input `kvRoot`, then the default `.riela/kv` under the working directory. Mock runs isolate the store by passing `--variables '{"workflowInput":{"kvRoot":".riela-data/x-incremental-posts-kv/kv"}}'` (top-level mock-scenario keys are node responses, so the pin must come through run variables).
- The mock scenario cans `fetch-posts` with a fixed `pageInfo.newestId` of `190002`, so a mock run persists `{"sinceId":"190002"}` and a second mock run reads it back with `found: true` — the cross-run cursor round trip is observable locally without Docker or X credentials.
- Stale cursors can be cleared with a `riela/kv-delete` node (same `storeId`/`key`), and `riela/kv-list` with `keyPrefix` enumerates persisted keys for inspection.

Validation commands:

```bash
riela workflow validate x-incremental-posts-kv --workflow-definition-dir ./examples
riela workflow run x-incremental-posts-kv --workflow-definition-dir ./examples \
  --mock-scenario ./examples/x-incremental-posts-kv/mock-scenario.json \
  --variables '{"workflowInput":{"kvRoot":".riela-data/x-incremental-posts-kv/kv"}}' \
  --output json
```
