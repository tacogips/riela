Rewrite the Riela Note draft according to the user instruction.

Note id: `{{workflowInput.noteId}}`

Instruction:

```text
{{workflowInput.instruction}}
```

Current draft body:

```markdown
{{workflowInput.bodyMarkdown}}
```

Selected text, if provided:

```markdown
{{workflowInput.selectedText}}
```

Return JSON only:

```json
{
  "rewrittenMarkdown": "Markdown rewrite or selected-range replacement",
  "summary": "Brief description of what changed"
}
```

Rules:
- If `workflowInput.selectedText` is present and non-empty, return only the replacement markdown for that selection in `rewrittenMarkdown`.
- If no selection is present, return the full rewritten note body in `rewrittenMarkdown`.
- Preserve user-authored facts unless the instruction explicitly asks to change them.
- Keep markdown valid and do not include code fences around the returned JSON.
