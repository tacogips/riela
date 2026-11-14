# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-quick-memo --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-quick-memo \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-quick-memo/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"text":"# Quick memo\nRemember the Riela Note design.","notebookTitle":"Quick Memos"}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-quick-memo`.
- One note is created in a `notebook-kind:user-memo` notebook.
- The created note has the fixed `ノート` tag.
- The root output is the `riela/note-create` payload and includes `noteId` and `notebookId`.
