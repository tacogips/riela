Classify the note for Riela Note auto-tagging.

Inputs:
- noteId: {{noteId}}
- trigger: {{trigger}}
- body: {{noteBodyMarkdown}}

Return JSON with:
- `tags`: 1-5 topical tags. Use objects with `name` and optional `classId` when a class is useful.
- `status`: `"ready"`.

Do not include tags that imply human provenance. The next step applies the tags with AI provenance.
