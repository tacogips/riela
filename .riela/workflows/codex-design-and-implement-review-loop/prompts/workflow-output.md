Publish the final accepted workflow result.

Use only the executed-step payloads provided in this input message. Do not run
commands. Do not read files. Do not inspect repository state, logs, skills,
sessions, or prior history. Produce the final JSON immediately from the
provided payloads.

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
- `pushedRemote`
- `pushedBranch`
- `verification`
- `residualRisks`
