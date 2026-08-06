# Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate document-inbox-notebook --workflow-definition-dir ./examples
riela events validate --workflow-definition-dir ./examples --event-root ./examples/document-inbox-notebook/.riela-events
```

Expected result: the workflow and the event configuration are valid.

## Run

```bash
riela workflow run document-inbox-notebook \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/document-inbox-notebook/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"path":"/mock/inbox/sample.pdf","title":"sample.pdf"}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `document-inbox-notebook`.
- One imported-material notebook titled `sample.pdf` is created.
- One page note is created from the mocked converted document and its body
  starts with `# Mock Document`.
- The root output is the `riela/notebook-ingest-pages` payload and includes
  `pageCount: 1`.
