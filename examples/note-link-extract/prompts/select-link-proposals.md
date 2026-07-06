Review the subject note from `get-subject-note` and candidate search results
from `search-candidates`.

Return JSON only:

```json
{
  "proposals": [
    {
      "targetNoteId": "note-id",
      "linkKind": "related",
      "reason": "Short user-facing reason"
    }
  ]
}
```

Rules:
- Exclude the subject note.
- Exclude candidates that are only keyword noise.
- Prefer `related` unless the candidate is clearly a source citation.
