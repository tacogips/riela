Consolidate the short-term chat memory window below into durable long-term
memory entries.

Recent short-term records (riela memory store):

{{recordsText}}

Rules:

- Write one entry per durable topic. Skip small talk and anything already
  obvious from a single message.
- `content` is Markdown: a short heading followed by the decisions, facts, and
  commitments worth remembering months from now.
- `topicTags` are lowercase topic slugs, no `notebook-kind:` or
  `long-term-memory:` prefixes.
- `sourceMemoryRecordIds` are the exact riela short-term record ids
  (the `#<id>` numbers above) the entry was distilled from. They are riela
  memory records, not kaiba note ids.
- `relatedNoteIds` are existing kaiba note ids only; omit the field when you
  have none.
- `periodStart` and `periodEnd` bound the window the entry covers, in ISO8601.

Return JSON only:

```json
{
  "memoryEntries": [
    {
      "content": "# ...\n\n- ...",
      "topicTags": ["..."],
      "sourceMemoryRecordIds": [1],
      "periodStart": "2026-08-01T00:00:00Z",
      "periodEnd": "2026-08-08T00:00:00Z"
    }
  ]
}
```
