# note-link-extract Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-link-extract --workflow-definition-dir examples/note-link-extract
riela workflow inspect note-link-extract --workflow-definition-dir examples/note-link-extract --output json
```

Expected result: the workflow is valid.

## Run

The bundled mock scenario supplies the subject and candidate payloads without
connecting to a Kaiba server. Run:

```bash
riela workflow run note-link-extract \
  --workflow-definition-dir examples/note-link-extract \
  --mock-scenario examples/note-link-extract/mock-scenario.json \
  --session-store tmp/note-link-extract-example/sessions \
  --artifact-root tmp/note-link-extract-example/artifacts \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-link-extract`.
- The root output contains one `proposals` item.
- The proposal has `targetNoteId: "note-candidate"`, `linkKind: "related"`,
  and a non-empty `reason` (`Depth-two graph path from the subject note.` in
  this deterministic scenario).
- Candidate generation is fixed to `depth: 2` and consumes the service-provided
  graph score/path rather than prompt-side scoring.
- The workflow only proposes candidates; the UI or caller must still confirm
  before creating `.ai` provenance links.
