# note-notebook-compact Expected Results

Stable assertions for deterministic verification. Ignore session ids,
timestamps, and artifact paths.

## Validate

```bash
riela workflow validate note-notebook-compact --workflow-definition-dir ./examples
```

Expected result: the workflow is valid.

## Compact

Run with `mock-scenario.json` and `workflowInput.operation` set to `compact`.
The completed root output contains non-empty `summaryMarkdown` and `version: 1`.
Full source bodies are allowed only in this operation.

## Answer

Run with `mock-scenario-answer.json` and `workflowInput.operation` set to
`answer`. The completed root output contains non-empty `assistantMarkdown`.
The input contains only `compactSummaryMarkdown` and `questionMarkdown`; it has
no notebook object, source-note ids, bodies, attachments, or search results.
