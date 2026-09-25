# note-agent expected results

- `kaiba/note-search` retrieves direct FTS seeds without linked expansion.
- `kaiba/note-graph-neighbors` walks at most five hops under the central graph
  floor, frontier, source, and finalized-node caps.
- `kaiba/note-get` retrieves the seed and neighbor bodies selected for answering.
- The agent answer returns `answerMarkdown`, `citations[].noteId`, and `sourceNoteIds`.
- In a live run, citation note ids must resolve to Kaiba notes so UI clients can
  deep-link to the source note. The bundled mock verifies the output contract
  without connecting to a Kaiba server.
- With the bundled deterministic scenario, `sourceNoteIds` is exactly
  `["note-agent-source"]`, `citations[0].noteId` is `note-agent-source`, and
  `status` is `answered`; unsupported IDs and body-external claims are absent.

## Validate and run

```bash
riela workflow validate note-agent --workflow-definition-dir examples/note-agent
riela workflow inspect note-agent --workflow-definition-dir examples/note-agent --output json
riela workflow run note-agent \
  --workflow-definition-dir examples/note-agent \
  --mock-scenario examples/note-agent/mock-scenario.json \
  --session-store tmp/note-agent-example/sessions \
  --artifact-root tmp/note-agent-example/artifacts \
  --output json
```
