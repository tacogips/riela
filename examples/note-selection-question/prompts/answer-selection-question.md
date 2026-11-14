Answer the user's question about the selected range of a Riela Note.

Note id: `{{workflowInput.noteId}}`

Question:

```text
{{workflowInput.question}}
```

Selected text (the question is scoped to this range):

```markdown
{{workflowInput.selectedText}}
```

Full note body, for context only:

```markdown
{{workflowInput.bodyMarkdown}}
```

Return JSON only:

```json
{
  "answerMarkdown": "A concise markdown answer to the question about the selection",
  "summary": "One short line summarizing the answer"
}
```

Rules:
- Answer strictly about `workflowInput.selectedText`; use the full body only for context.
- Keep `answerMarkdown` concise and valid markdown. Do not rewrite or return the note body.
- Do not include code fences around the returned JSON.
