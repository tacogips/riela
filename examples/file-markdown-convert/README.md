# File Markdown Convert

This example converts local documents to GitHub-Flavored Markdown through the
built-in `riela/file-markdown-convert` add-on. The add-on invokes the external
`anydoc-swift` executable once per document as:

```bash
anydoc-swift convert <path> --json [--format <format>]
```

Supported inputs are the formats [anydoc](https://github.com/firecrawl/anydoc)
handles: `pdf`, `doc`, `docx`, `ppt`, `pptx`, `excel` (xls/xlsx), `odt`, `ods`,
`odp`, `rtf`, `epub`, and `csv`. Scanned or image-only PDFs need OCR, which
anydoc does not do; they fail with the `unsupported` error kind.

## Setup

Nothing to install: the converter is the `anydoc-swift` package's `AnydocKit`
library, linked into `riela` and called in-process. There is no `anydoc-swift`
executable to put on `PATH`, no `ANYDOC_SWIFT_BIN`, and no `binaryPath`
add-on config — a leftover `binaryPath` is refused rather than ignored.

## Run

Validate the bundle:

```bash
swift run riela workflow validate file-markdown-convert --workflow-definition-dir examples
```

Convert one document:

```bash
swift run riela workflow run file-markdown-convert \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"path":"/abs/path/report.pdf"}}'
```

Convert several in one step:

```bash
swift run riela workflow run file-markdown-convert \
  --workflow-definition-dir examples \
  --variables '{"workflowInput":{"paths":["/abs/report.pdf","/abs/notes.docx"]}}'
```

## Output

The root output carries the joined Markdown plus per-document detail:

```json
{
  "status": "ok",
  "markdown": "# Report\n\n...\n\n---\n\n# Notes\n\n...",
  "documentCount": 2,
  "convertedCount": 2,
  "failedCount": 0,
  "fileMarkdown": {
    "documents": [
      {
        "status": "ok",
        "path": "/abs/report.pdf",
        "fileName": "report.pdf",
        "format": "pdf",
        "inputByteCount": 90060,
        "markdown": "# Report\n\n...",
        "markdownByteCount": 1024,
        "truncated": false
      }
    ],
    "converter": {"path": "...", "source": "path", "version": "0.1.1 (anydoc 0.1.6)"}
  }
}
```

Failed documents keep the converter's machine-readable error kind
(`unsupported`, `malformed`, `encrypted`, `resourceLimit`, `missingPart`,
`io`, ...) under `documents[].error.kind`. The step emits the `has_markdown`
and `has_failures` transition flags so a workflow can branch on partial
success.

## Configuration

| Key | Default | Purpose |
| --- | --- | --- |
| `format` | unset | Name the input format instead of detecting it (needed for CSV read from a path without a `.csv` extension); accepts the canonical names and extension aliases such as `xlsx`, `docm`, `ppsx` |
| `continueOnError` | `false` | Record failed documents and keep converting instead of failing the step |
| `maxDocuments` | `10` | Reject a request with more paths than this (ceiling 50) |
| `maxInputBytes` | `25000000` | Reject documents larger than this before starting the converter (ceiling 256000000) |
| `maxMarkdownBytes` | `1000000` | Truncate Markdown above this size and flag `truncated` (ceiling 8000000) |
| `allowedRoots` | unset | Restrict inputs to these directories after resolving symlinks |

Document paths come from `addon.inputs.path` / `addon.inputs.paths` only, and
the executable comes from config or the environment only, so a node payload
cannot redirect the add-on at another binary.

## Composing

The add-on is a worker step, so the Markdown can feed any downstream node.
A common pairing is document ingestion into notes:

```json
{
  "id": "save-note",
  "addon": {
    "name": "kaiba/note-create",
    "version": "1",
    "config": {"noteRoot": "{{noteRoot}}"},
    "inputs": {"bodyMarkdown": "{{inbox.latest.output.payload.markdown}}"}
  }
}
```
