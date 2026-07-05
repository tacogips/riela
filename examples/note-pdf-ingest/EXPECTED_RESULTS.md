# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-pdf-ingest --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-pdf-ingest \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-pdf-ingest/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"title":"Imported PDF","sourceDocumentRef":"file:///<absolute-tmp-note-root>/source.pdf"}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-pdf-ingest`.
- One imported-material notebook is created.
- Two page notes are created from the mock OCR pages.
- The root output is the `riela/notebook-ingest-pages` payload and includes `pageCount: 2`.
