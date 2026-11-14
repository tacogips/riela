# Document Inbox → Markdown → Riela Notebook

Drop a `.pdf` or `.epub` into a watched inbox directory and riela converts it
to Markdown through the external [`anydoc-swift`](https://github.com/tacogips/anydoc-swift)
converter, then saves the result as an imported-material riela notebook with
the original document attached as the notebook's source document.

The trigger is a `file-change` event source: `riela events serve` snapshots the
inbox at startup (existing files never dispatch), then polls for created files,
waits for the write burst to settle (`stabilityWindowMs`), and dispatches
`file.change.created` to the bound workflow.

## Pieces

- `.riela-events/sources/document-inbox.json` — watches `inbox/` for created
  `.pdf`/`.epub` files (suffix match is case-insensitive).
- `.riela-events/bindings/document-inbox-to-notebook.json` — maps the event's
  `file.absolutePath`/`file.name` into the workflow input.
- `workflow.json` — `riela/file-markdown-convert` (anydoc-swift) followed by
  `riela/notebook-ingest-pages`; each converted document becomes one notebook
  page note.

## Requirements

- `anydoc-swift` 0.1.1+ on `PATH` (or `ANYDOC_SWIFT_BIN`):
  `brew install tacogips/tap/anydoc-swift` or build from source.
- A riela note root. The workflow uses `RIELA_NOTE_ROOT` when set, otherwise
  `~/.riela/note`.

## Run live

From the repository root:

```bash
riela events serve \
  --workflow-definition-dir ./examples \
  --event-root ./examples/document-inbox-notebook/.riela-events \
  --artifact-root ./tmp/document-inbox-notebook/workflow-artifacts
```

In another shell, drop a document:

```bash
cp ~/Documents/paper.pdf examples/document-inbox-notebook/inbox/
```

Within a few seconds the serve loop dispatches the workflow. Verify the
notebook:

```bash
riela note notebook list --note-root "${RIELA_NOTE_ROOT:-$HOME/.riela/note}" --output json | head
```

Add `--limit 1` to `events serve` to exit after the first dispatched event.

## Deterministic run (no converter, no watcher)

The mock scenario replaces the converter output; `riela/notebook-ingest-pages`
still writes a real notebook into the note root you pass:

```bash
riela workflow run document-inbox-notebook \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/document-inbox-notebook/mock-scenario.json \
  --variables '{"noteRoot":"./tmp/document-inbox-notebook/note-root","workflowInput":{"path":"/mock/inbox/sample.pdf","title":"sample.pdf"}}' \
  --output json
```

See `EXPECTED_RESULTS.md` for the stable assertions.
