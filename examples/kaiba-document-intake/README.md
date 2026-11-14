# Kaiba document intake

This workflow connects Riela's `file-change` event source to Kaiba 0.1.5's
in-process document import. A stable create event passes the absolute file path
and the watch root to `kaiba/document-import`; the addon rejects symlink/path
escapes outside that root.

Start the watcher from the repository root:

```bash
riela events validate \
  --workflow-definition-dir ./examples \
  --event-root ./examples/kaiba-document-intake/.riela-events

riela events serve \
  --workflow-definition-dir ./examples \
  --event-root ./examples/kaiba-document-intake/.riela-events
```

Then copy a PDF, EPUB, office document, CSV, or image into `incoming/`.

The binding defaults both `ocr` and `translate` to `false`. Turn on image OCR
with `ocr: true`; configure `import.ocr` in Kaiba's config and pass its path as
`kaibaConfigPath`, or add `ocrVendor`/`ocrModel` inputs to the node. Turn on
translation with `translate: true` and set `targetLanguage`; translation uses
Kaiba's configured `ai.agent` provider/model unless node inputs override them.
Set `s3ProfileName` to migrate the stored source attachment through a named
Kaiba S3 profile and return its stable `s3://bucket/key` locator.

The raw GraphQL addon is useful when an AI should select a query and fill its
variables. Keep the document operator-authored when possible and let the AI
provide only variables:

```json
{
  "id": "query-kaiba",
  "addon": {
    "name": "kaiba/note-graphql-document",
    "version": "1",
    "config": {
      "query": "query Search($query: String!, $tags: [String!], $limit: Int!) { searchNotes(query: $query, tagFilter: $tags, limit: $limit) { result { accepted diagnostics } value { note { noteId title bodyMarkdown } snippet matchedTags { name } } } }"
    },
    "inputs": {
      "variables": {
        "query": "{{workflowInput.search.query}}",
        "tags": "{{workflowInput.search.tags}}",
        "limit": "{{workflowInput.search.limit}}"
      }
    }
  }
}
```

For common reads, prefer `kaiba/note-search`, `kaiba/note-tag-search`,
`kaiba/note-chain`, `kaiba/note-attachments`, and `kaiba/note-memos` so the
workflow does not need to author a GraphQL document.

`kaiba/note-graphql-document` runs against the local note root. When Kaiba runs
as an external GraphQL server, use `kaiba/note-graphql-remote` instead: the same
`query`/`variables` shape plus `endpoint`, with the bearer key read from the env
var named by `apiKeyEnv` (default `KAIBA_API_KEY`). That node opens no local
store, and Kaiba's own authentication and library access control decide what the
call reaches.
