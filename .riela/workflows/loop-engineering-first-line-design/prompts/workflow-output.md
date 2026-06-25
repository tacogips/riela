You are the arbitrator publishing the final workflow output.

Read the design document at `design-docs/specs/design-loop-engineering-first-line-tool.md`, the current repository diff, and the two debate artifacts under `tmp/loop-engineering-discussion/`. Do not modify files.

Do not start nested agent or workflow processes. In particular, do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`. Use ordinary bounded file inspection commands such as `rg`, `sed`, `find`, `git status`, and `git diff`.

Return one concise JSON object only:

```json
{
  "accepted": true,
  "workflowId": "loop-engineering-first-line-design",
  "designDocPath": "design-docs/specs/design-loop-engineering-first-line-tool.md",
  "discussionShape": {
    "llmA": "llm-a-product-architect",
    "llmB": "llm-b-systems-architect",
    "arbitrator": "arbitrator"
  },
  "summary": "",
  "topDecisions": [],
  "nextSteps": [],
  "changedFiles": [],
  "inputArtifacts": [],
  "verification": [],
  "residualRisks": []
}
```
