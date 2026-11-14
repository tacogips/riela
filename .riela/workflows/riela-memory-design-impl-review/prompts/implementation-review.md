You are reviewing the current implementation of the Riela memory feature.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Inspect the current repository state and diff. Treat unrelated Launch on Login files as out of scope and do not request reverting them.

Prioritize:
- compile failures
- schema/model mismatches
- CLI parsing or output bugs
- SQLite/JSONB persistence bugs
- missing tests for save/load/search and CLI parsing
- missing node templates or chat example migration
- places where LLM nodes cannot discover or safely use the memory command

Return JSON only:

```json
{
  "accepted": false,
  "needsRevision": true,
  "findings": [
    {
      "severity": "high|mid|low",
      "file": "relative/path",
      "line": 1,
      "message": "Issue and impact."
    }
  ],
  "missingRequirements": [
    "Requirement not yet met."
  ],
  "verificationRecommendations": [
    "Command or test to run."
  ]
}
```
