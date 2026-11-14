# note-edit-rewrite Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-edit-rewrite --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-edit-rewrite \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-edit-rewrite/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"noteId":"note-1","bodyMarkdown":"# Project Plan\n\n- Draft next milestone.","instruction":"Clarify the plan and owner"}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-edit-rewrite`.
- The root output contains `rewrittenMarkdown` and `summary`.
- `rewrittenMarkdown` is the full replacement note body when no selected text is provided.
- For selection-scoped calls, `rewrittenMarkdown` is only the replacement for the selected text.
- The UI or caller must still review and save the draft; the workflow does not persist note changes.
