# memory-consolidation expected results

Recorded from the bundled deterministic scenario with scratch stores
(`memoryRoot` and `noteRoot` pointed at a temporary directory). Only
`summarize-memories` is mocked; both memory stores are written for real.

## Validate and run

```bash
riela workflow validate memory-consolidation --workflow-definition-dir examples

riela workflow run memory-consolidation \
  --workflow-definition-dir examples \
  --mock-scenario examples/memory-consolidation/mock-scenario.json \
  --variables '{"memoryRoot":"./tmp/memory-consolidation/memory","noteRoot":"./tmp/memory-consolidation/notes","workflowInput":{"text":"Kickoff review settled the project-atlas scope.","actor":"taco","conversationId":"example-conversation","consolidationKey":"memory-consolidation-example-2026-08-01"}}'
```

## First run

- The session completes; all six steps reach `completed`.
- `riela/memory-save` writes one short-term record to
  `<memoryRoot>/chat-memory.sqlite` and reports `record.recordId: 1`.
- `riela/memory-load` returns that record as
  `recordsText: "#1 <timestamp> [chat-event] Kickoff review settled the project-atlas scope."`.
- `kaiba/memory-consolidate` reports `entriesWritten: 1`,
  `idempotentReplay: false`, and one `noteIds` entry prefixed
  `note-long-term-memory-`.
- `kaiba/memory-recall` reports `resultCount: 1` with
  `results[0].isAssociation: false`.
- The workflow output carries the consolidation counts forward through the
  recall node's `passthrough`: `entriesWritten: 1`, `idempotentReplay: false`,
  `consolidatedNoteIds`, `notebookId`, `associations`, plus the recall keys
  `resultCount`, `noteIds`, `results`, and `recallText`.
- `recallText` starts with
  `#note-long-term-memory-… [direct] project-atlas kickoff decisions: # project-atlas kickoff decisions …`.

## kaiba store after the first run

```
sqlite3 <noteRoot>/note-store.sqlite \
  "select count(*) from notes;" \
  "select notebook_id, title from notebooks;" \
  "select t.name, t.class_id from note_tags nt join tags t on t.tag_id = nt.tag_id;"
```

- `notes` count is `1`.
- The notebook is `Kaiba Long-Term Memory`.
- The note carries the tag `project-atlas` in the `topic` tag class.
- The note's `metaJSON` is
  `{"entryKind":"long-term-memory","longTermMemoryVersion":1,"periodEnd":"2026-08-08T00:00:00.000Z","periodStart":"2026-08-01T00:00:00.000Z","sourceMemoryRecordIds":[1],"sourceNoteIds":[],"unresolvedRelatedNoteIds":[]}` —
  the riela short-term record id lives in metadata, and `sourceNoteIds` is
  empty because record ids are not kaiba notes.

## Second run with the same `consolidationKey`

- `entriesWritten: 1` and `idempotentReplay: true`, with the same
  `consolidatedNoteIds` as the first run.
- `associations` is `[]`: association linking is skipped on a replay.
- The kaiba `notes` count is still `1`.
- The riela short-term store now holds `2` records — every tick is recorded
  short-term even when the long-term memory is a replay.

## Third run with a different `consolidationKey`

- `entriesWritten: 1` and `idempotentReplay: false`; a second long-term note is
  appended (kaiba `notes` count `2`).
- `associations` is
  `[{"noteId":"<new note>","linkedNoteIds":["<first note>"]}]`, and
  `note_links` contains one `memory-association` row between the two notes.
- `kaiba/memory-recall` reports `resultCount: 2` and `recallText` lists both
  notes, each marked `[direct]`.
