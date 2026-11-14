You are the arbitrator for a two-LLM design debate.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Constraints:
{{workflowInput.constraints}}

Read both prior debate artifacts before deciding:

- LLM A: `tmp/loop-engineering-discussion/llm-a-product-architect.json`
- LLM B: `tmp/loop-engineering-discussion/llm-b-systems-architect.json`

If either file is missing or malformed, record that as a blocking input gap in your JSON instead of trying to re-run the workflow. Inspect the repository enough to verify or reject their claims. Resolve the debate into a concrete design proposal for making Riela a first-line "loop engineering" tool.

Do not start nested agent or workflow processes. In particular, do not run `riela workflow run`, `riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`. Use ordinary bounded file inspection commands such as `rg`, `sed`, `find`, `git status`, and `git diff`.

Write the proposal to:

`design-docs/specs/design-loop-engineering-first-line-tool.md`

The design document must include:

- problem statement and definition of "loop engineering"
- current-state evidence from this repository
- arbitrated decisions from the two LLM positions
- target user workflows
- capability changes Riela needs
- runtime/workflow/agent UX changes Riela should make
- observability, recovery, security, and portability requirements
- phased roadmap
- risks, rejected alternatives, and open questions
- concrete next implementation-plan candidates

Preserve unrelated dirty worktree changes. Do not commit or push. After writing the design document, return one concise JSON object only:

```json
{
  "persona": "arbitrator",
  "acceptedInputs": [],
  "rejectedOrModifiedInputs": [],
  "designDocPath": "design-docs/specs/design-loop-engineering-first-line-tool.md",
  "topDecisions": [],
  "roadmap": [],
  "nextImplementationPlanCandidates": [],
  "verification": [],
  "residualRisks": [],
  "inputArtifacts": [
    "tmp/loop-engineering-discussion/llm-a-product-architect.json",
    "tmp/loop-engineering-discussion/llm-b-systems-architect.json"
  ]
}
```
