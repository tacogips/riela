Extract pages from the source document for Riela Note ingestion.

Inputs:
- sourceDocumentRef: {{workflowInput.sourceDocumentRef}}
- title: {{workflowInput.title}}

Return JSON with:
- `pages`: ordered objects with `title`, `bodyMarkdown`, optional `readOnly`, optional `tags`, and optional `meta`.
- `status`: `"ready"`.

Do not create notes directly. The next step calls `riela/notebook-ingest-pages`.
