Implement first-line loop metadata validation for the Riela Swift codebase.

Required scope:
- Validate authored workflow loop gates:
  - gate id must be a non-empty string.
  - gate stepId must be a non-empty string and must reference workflow.steps[].
  - acceptWhen.decision, when present, must be one of accepted, rejected, needs_work, skipped.
  - maxHighFindings and maxMediumFindings, when present, must be non-negative integers.
- Validate loop policy values:
  - mutation.commit and mutation.push: allow, deny, prompt.
  - process.nestedRiela and process.nestedCodex: allow, deny, prompt.
  - network.mode: allow, deny, inherit-command.
  - evidence.artifactRootPolicy: runtime-owned.
- Validate safe workflow-relative loop paths:
  - mutation.allowedWriteRoots[].
  - mutation.scratchRoot.
  - implementationPlan.pathPattern.
- Add focused tests in WorkflowLoopValidationTests.
- Preserve existing workflows and unrelated dirty worktree changes.

Return JSON with changedFiles, testsAdded, and verificationNeeded.
