# note-selection-question Expected Results

Stable assertions for deterministic verification with the bundled mock scenario.
Ignore `sessionId`, timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-selection-question --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-selection-question \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-selection-question/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"noteId":"note-1","bodyMarkdown":"# Project Plan\n\n- Draft next milestone.","question":"What is this milestone?","selectedText":"Draft next milestone.","selectionStart":15,"selectionEnd":36}}' \
  --output json
```

Expected stable result:

- `status` is `completed`.
- `workflowId` is `note-selection-question`.
- The root output contains `answerMarkdown` and `summary`.
- `answerMarkdown` answers the question about the selected text only; it never returns the rewritten note body.
- The caller persists the answer as a note comment; the workflow does not persist note changes.

Recorded mock dry run (2026-07-07): `status` `completed`, `transitions` `1`, `nodeExecutions` `2`,
root output `{"answerMarkdown":"The selected milestone is the next deliverable; confirm its owner
before scheduling.","summary":"Explained the selected milestone and owner."}`.
