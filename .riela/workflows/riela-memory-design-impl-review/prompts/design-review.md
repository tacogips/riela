You are reviewing the design for the Riela memory feature.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Inspect the current repository state and diff. Focus on the architecture, not line-by-line implementation.

Review whether the design supports:
- memory as an independent facility usable across workflows
- explicit workflow/node declarations for memories that a workflow or node may use
- workflow-id scoped save/load/search commands
- one SQLite database file per memory id
- JSONB payload storage with arbitrary JSON payload and registration date
- grep-style multiple match search with default registered-desc sort and limit 30
- a `riela memory` command surface usable by autonomous LLM nodes
- node templates for save/load/search handoff
- replacing chat example history retrieval with chat memory

Return JSON only:

```json
{
  "accepted": false,
  "findings": [
    {
      "severity": "high|mid|low",
      "message": "Issue and impact.",
      "file": "relative/path",
      "line": 1
    }
  ],
  "designDecisions": [
    "Decision to keep or change."
  ],
  "requiredChanges": [
    "Concrete design change before completion."
  ]
}
```
