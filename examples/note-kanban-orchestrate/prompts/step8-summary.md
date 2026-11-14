Compose the final orchestration summary.

The latest payloads contain the review verdicts (`verdicts`, `passedTasks`,
`failedTasks`, `round`) and `{{fanoutJoin}}` holds the
finalize branch records (cards moved `review → done`).

Return JSON only:

{
  "when": {},
  "payload": {
    "summaryTitle": "Kanban orchestration: <short goal>",
    "summaryMarkdown": "## Outcome\n\n- per-card verdicts with links (notebookId)\n- unresolved cards left in review, if any\n- rounds used",
    "goal": "{{workflowInput.task}}",
    "verdicts": [],
    "unresolvedTasks": []
  }
}

`unresolvedTasks` lists cards that never passed (they remain in `review`).
