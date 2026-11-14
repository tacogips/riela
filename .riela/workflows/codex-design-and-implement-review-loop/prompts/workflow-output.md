Publish the final accepted workflow result.

Use only the executed-step payloads provided in this input message. Do not run
commands. Do not read files. Do not inspect repository state, logs, skills,
sessions, or prior history. Produce the final JSON immediately from the
provided payloads.

Treat only `step10-git-commit`'s accepted `payload.git` object as commit
evidence and only `step11-git-push`'s accepted `payload.git` object as push
evidence. Read `commitHash` from Step 10 and require Step 11's `commitHash` to
match it. Read `pushedRemote` and `pushedBranch` from Step 11. If any required
field is missing or mismatched, do not fabricate finalization evidence.
Copy `committedFiles` exactly, in order, from Step 10's accepted `payload.git`
object; do not infer it from earlier changed-file summaries.

If Step 5 accepted a planning-only run, Step 9 emitted the commit message, Step 10 committed it, and Step 11 pushed it, return JSON with:
- `status`: `accepted`
- `workflowMode`: `design-plan-only`
- `designDocPaths`
- `implPlanPaths`
- `codexAgentReferences`
- `designReviewSummary`
- `implPlanReviewSummary`
- `commitMessage`
- `commitHash`
- `committedFiles`
- `pushedRemote`
- `pushedBranch`
- `nextStep`
- `residualRisks`

If the workflow continued through Step 8, Step 9 emitted the commit message, Step 10 committed it, and Step 11 pushed it, return JSON with:
- `status`: `accepted`
- `workflowMode`: `issue-resolution`
- `issueReference`
- `issueTitle`
- `designDocPaths`
- `implPlanPaths`
- `changedFiles`
- `designReviewSummary`
- `implPlanReviewSummary`
- `implementationSummary`
- `testIntegritySummary`
- `implementationReviewSummary`
- `adversarialReviewSummary` when the adversarial implementation review gate ran
- `documentationFiles`
- `documentationSummary`
- `archivedImplPlanPaths`
- `implPlanCompletionSummary`
- `commitMessage`
- `commitHash`
- `committedFiles`
- `pushedRemote`
- `pushedBranch`
- `verification`
- `residualRisks`
