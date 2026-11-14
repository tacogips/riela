# note-agent expected results

- `riela/note-search` retrieves candidate notes from `noteRoot` using `workflowInput.query`.
- The agent answer returns `answerMarkdown`, `citations[].noteId`, and `sourceNoteIds`.
- Citation note ids must resolve to existing Riela Note records so UI clients can deep-link to the source note.
