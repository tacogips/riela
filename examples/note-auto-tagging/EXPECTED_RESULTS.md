# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-auto-tagging --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

Create a note in a temporary note root, then run:

```bash
riela workflow run note-auto-tagging \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-auto-tagging/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","noteId":"<created-note-id>","noteBodyMarkdown":"# Field report\nBody","trigger":"note-created"}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-auto-tagging`.
- The target note receives AI-provenance tags `research` and `auto-tagged`.
- The root output is the `riela/note-tag-apply` payload and includes the target `noteId`.
