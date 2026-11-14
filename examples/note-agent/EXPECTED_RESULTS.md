# note-agent expected results

- `riela/note-search` retrieves direct FTS seeds without linked expansion.
- `riela/note-graph-neighbors` walks at most five hops under the central graph
  floor, frontier, source, and finalized-node caps.
- `riela/note-get` retrieves the seed and neighbor bodies selected for answering.
- The agent answer returns `answerMarkdown`, `citations[].noteId`, and `sourceNoteIds`.
- Citation note ids must resolve to existing Riela Note records so UI clients can deep-link to the source note.
- With the bundled deterministic scenario, `sourceNoteIds` is exactly
  `["note-agent-source"]`; unsupported IDs and body-external claims are absent.

## Validate and run

```bash
riela workflow validate note-agent --workflow-definition-dir examples/note-agent
riela workflow run note-agent \
  --workflow-definition-dir examples/note-agent \
  --mock-scenario examples/note-agent/mock-scenario.json
```
