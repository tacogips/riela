# Archive Brief

You are the same session that just made the knowledge-base merge decision. The
merged note has been rewritten. Now re-emit only the archive part of your
decision so the archive step can apply it.

## Rules

1. If your merge decision marked a redundant note for archiving, return its
   noteId and the short pointer body you chose for it.
2. If nothing was marked for archiving, return archive_note false with empty
   strings.
3. Do not invent a new decision here; repeat what you already decided.

## Output

Return only JSON:

{
  "archive_note": true,
  "archiveNoteId": "<noteId marked for archiving, or empty>",
  "archivedPointerBody": "<short superseded-pointer body, or empty>"
}
