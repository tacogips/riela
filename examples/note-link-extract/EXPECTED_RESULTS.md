# note-link-extract Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-link-extract --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

Create a temporary note root containing:

- subject note id: `<subject-note-id>`
- candidate note id: `note-candidate`
- both notes containing the phrase `project planning`

Then run:

```bash
riela workflow run note-link-extract \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-link-extract/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"noteId":"<subject-note-id>","subjectBodyMarkdown":"# Subject\nProject planning context.","query":"project planning","limit":10}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-link-extract`.
- The root output contains one `proposals` item.
- The proposal has `targetNoteId: "note-candidate"`, `linkKind: "related"`,
  and a non-empty `reason`.
- The workflow only proposes candidates; the UI or caller must still confirm
  before creating `.ai` provenance links.
