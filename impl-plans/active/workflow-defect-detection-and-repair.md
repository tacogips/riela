# Workflow defect detection and verified repair implementation plan

Status: Step 4 authored 2026-09-22; Step 3 design accepted; Step 5 plan review pending. All runtime tasks remain unimplemented.

## Intent, authority and repository context

Mechanically detect broken routing controls and unproductive completed cycles,
then produce digest-bound, verified repair proposals. Preserve existing routing,
publication, loop-policy and transaction ownership. Raising max-steps or eventually
returning a mock success is not a repair.

- workflowMode: `planning-only`; issueReference: `Workflow defect detection and repair`.
- Issue title: Mechanically detect workflow routing contract defects and stalled cycles; provide verified repair proposals. Issue number/URL were not supplied.
- workflowExecutionId: `codex-design-and-implement-review-loop-session-2`.
- Accepted design: `design-docs/specs/design-workflow-defect-detection-and-repair.md`, SHA-256 `258cc1d34f78d64971e96e4f130ed8ee8db02eba5209657ee39f8a0ac416b170`.
- Review authority: `comm-000006`, `step3-design-review-attempt-1-exec-3`, decision `accepted`, accepted=true, needs_revision=false, findings=[].
- Latest Step 5 review: `comm-000008`, `step5-impl-plan-review-attempt-1-exec-5`,
  decision `revision_required`; one mid finding on missing Package.swift write ownership.
  This revision addresses that finding; independent re-review remains pending.
- codexAgentReferences: `[]`; no external agent-reference behavior or intentional divergence applies.
- Inspected base: `62bf0ec28b6e0c5013fbd1b3b5d2d2de457d095f`. The design's older draft/pending prose is historical; the supplied Step 3 receipt accepts this exact digest. Do not rewrite the accepted design during Step 4.

The incident report is one dispatch, 22 reconciliation visits, 22 integration
reviews and maxStepsExceeded(53), with two initially failed branches. Captured
historical definition and ledger are absent. Package 0.3.3's authored
`workflow.loop.convergence` 4/2 and its unannotated integration-review are intake
facts; current installed 0.3.5 is separate evidence. Do not infer a unique historical
cause from missing flags or current metadata. The fixture is explicitly synthetic.

Current `WorkflowBranchEvaluator` resolves when first, then payload Boolean, then
false, with reserved always/true/never/false constants. There is no shared AST yet.
`RuntimePublication.publish` selects after schema validation, but candidate-path
finalization currently precedes it. Route rejection must precede downstream
finalization/reservation as well as transition publication. Current T3 output retry
default is still 1 in `DeterministicWorkflowRunner+Prompting.swift`; the prerequisite
plan owns changing it to two total attempts. Do not silently duplicate that work.

## Non-goals and external ownership gates

No runtime code in this planning run; no generic rewriter, SAT service, scheduler,
parallel database, second guard/parser, provider-auth repair, unrelated refactor,
UI change or historical replay claim. Do not change Monja, installed immutable
packages, other worktrees, existing plan scope or their completion claims.

| Dependency owner | Before proceeding / retained scope |
| --- | --- |
| `agent-node-output-contract` T2/T3 | Before T2, verify accepted producer walk/schema API and bounded validation-retry implementation with its tests. That owner retains general schemas, template references, extraction and retry budgets. This plan owns Boolean guarantees and publication routing semantics only. Missing prerequisite blocks T2 onward, not T1 or planning acceptance. |
| `loop-engineering-convergence-and-operations` | T3/T4 consume current effective policy, gate parser, disabled/authoredInactive handling, terminal corridor and reservations. Preserve its unchecked verification and full scope. |
| Work Runtime P1 | Owns director decisions, attempts, retry reservation and fencing. Until available use authoritative native join/change/accepted-plan records and reviewed native retry decisions. No substitute P1 dispatcher. |
| Execution-environment E0/E6 | E0 owns definition-store replacement; E6 owns Ready/liveness conditions, not branch syntax. If these land first, stop affected tasks for a reviewed path/API rebase onto the active owner. Never implement both stores or a readiness parser. |
| Work Runtime P2 | If self-improve is removed first, rebase T5 onto its accepted proposeWorkflowChange path; no parallel proposal API. |
| Package source maintainer | Owns separately authorized producer repairs, digest/version publication and installation. Retain full follow-up scope; never patch the installed 0.3.5 tree. |

These are external readiness checks, not fictitious IDs in the native DAG. Record
owner commit, API/test evidence and readiness in the progress log before each gate.
No missing upstream feature may be marked implemented by this plan.

## Plan-set manifest and same-directory execution

One complete plan and one future native implementation item are sufficient: all
six tasks touch coupled contracts, so execute serially T1 → T2 → T3 → T4 → T5 → T6.
`dependsOn: []` is the plan-level DAG; task dependencies below are internal ordering,
not a newly invented Riela scheduler. Do not dispatch these tasks as six copies of
one plan. Only the installed user-scope workflow orchestrates later execution.
Current planning mode cannot dispatch runtime implementation. A later explicitly
requested implementation run must checkpoint the accepted design/plan first and
supply its checkpoint commit, full review context and native trackedPaths derived
from exact authorized paths. This manifest's runtime paths describe future work;
the current commit/push allowlist remains only design, plan and narrow index entry.

The accepted design names `design-docs/specs/command.md` and
`design-docs/specs/architecture.md`, but neither exists at this base. Resolve those
documentation responsibilities to existing `docs/output-contracts.md`,
`design-docs/specs/design-riela-workflow-internals.md` and serial README command
examples below. This path correction changes no accepted behavior or scope.

The worker owns one progress file. Plan text/checklists and shared indexes belong
to serial reconciliation. T6 exclusively owns the narrow Package.swift resource
registration through its task and top-level writePaths, after T5 and before V6–V9.
Its sharedPaths listing flags coordination only; the explicit writePaths grant this
edit. Package.resolved requires no dependency change and must remain unchanged. No directory wildcard grants or unresolved owner placeholders.
`sharedPaths` are coordination declarations, not permission for worker edits.
Within a task's writePaths, edits are allowed only for its specific changes below;
read-only dependencies remain in reviewContext.sourcePaths.

```json
{
  "planId": "workflow-defect-detection-and-repair",
  "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
  "dependsOn": [],
  "workflowMode": "planning-only",
  "implementationDispatchEnabled": false,
  "executionStrategy": "one-native-plan-item-with-serial-internal-tasks",
  "writePaths": [
    "Package.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Sources/RielaCLI/ParityCommands.swift",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/WorkflowChangeSetStore.swift",
    "Sources/RielaCLI/WorkflowCommands.swift",
    "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
    "Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift",
    "Sources/RielaCLI/WorkflowRepairProposal.swift",
    "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
    "Sources/RielaCLI/WorkflowStagedVerification.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+FailurePublication.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/LoopConvergenceTracker.swift",
    "Sources/RielaCore/RuntimeOutputValidation.swift",
    "Sources/RielaCore/RuntimePublication+Routing.swift",
    "Sources/RielaCore/RuntimePublication.swift",
    "Sources/RielaCore/RuntimeSession.swift",
    "Sources/RielaCore/RuntimeStore.swift",
    "Sources/RielaCore/RuntimeStorePublicationTransactions.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/WorkflowBranchEvaluation.swift",
    "Sources/RielaCore/WorkflowConditionAnalysis.swift",
    "Sources/RielaCore/WorkflowCycleProgress.swift",
    "Sources/RielaCore/WorkflowDefectDiagnostic.swift",
    "Sources/RielaCore/WorkflowGraphAnalysis.swift",
    "Sources/RielaCore/WorkflowLoopGuardEligibility.swift",
    "Sources/RielaCore/WorkflowLoopValidation.swift",
    "Sources/RielaCore/WorkflowRawValidation.swift",
    "Sources/RielaCore/WorkflowRouteContract.swift",
    "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift",
    "Sources/RielaCore/WorkflowValidation.swift",
    "Sources/RielaCore/WorkflowValidationHelpers.swift",
    "Tests/RielaCLITests/WorkflowDefectIncidentCommandTests.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionBoundaryTests.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift",
    "Tests/RielaCLITests/WorkflowRepairProposalTests.swift",
    "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
    "Tests/RielaCLITests/WorkflowStagedVerificationTests.swift",
    "Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift",
    "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/EXPECTED_RESULTS.md",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/accepted-plan-evidence.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/branch-evidence.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/change-evidence.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/expected-diagnostics.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-missing-control.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-dispatch.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-reconcile.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-review.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-worker.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/verification-evidence.json",
    "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/workflow.json",
    "Tests/RielaCoreTests/LoopConvergenceTrackerTests.swift",
    "Tests/RielaCoreTests/RuntimeOutputValidationTests.swift",
    "Tests/RielaCoreTests/RuntimePublicationTests.swift",
    "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
    "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift",
    "Tests/RielaCoreTests/WorkflowCycleProgressPersistenceTests.swift",
    "Tests/RielaCoreTests/WorkflowCycleProgressTests.swift",
    "Tests/RielaCoreTests/WorkflowDefectIncidentTests.swift",
    "Tests/RielaCoreTests/WorkflowGraphAnalysisTests.swift",
    "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift",
    "Tests/RielaCoreTests/WorkflowRouteContractTests.swift",
    "design-docs/specs/design-riela-workflow-internals.md",
    "design-docs/specs/design-workflow-json.md",
    "docs/output-contracts.md",
    "impl-plans/active/workflow-defect-detection-and-repair-progress.md"
  ],
  "sharedPaths": [
    "impl-plans/active/workflow-defect-detection-and-repair.md",
    "design-docs/specs/design-workflow-defect-detection-and-repair.md",
    "impl-plans/README.md",
    "README.md",
    "Package.swift",
    "Package.resolved"
  ],
  "progressLogPath": "impl-plans/active/workflow-defect-detection-and-repair-progress.md",
  "reviewContext": {
    "sourcePaths": [
      "design-docs/specs/design-workflow-defect-detection-and-repair.md",
      "impl-plans/active/workflow-defect-detection-and-repair.md",
      "impl-plans/active/agent-node-output-contract.md",
      "design-docs/specs/design-agent-node-output-contract.md",
      "impl-plans/active/loop-engineering-convergence-and-operations.md",
      "design-docs/specs/design-loop-engineering-convergence-and-operations.md",
      "impl-plans/active/execution-environment-consolidation.md",
      "design-docs/specs/design-execution-environment-consolidation.md",
      "design-docs/specs/design-work-runtime-consolidation.md",
      "Sources/RielaCore/WorkflowFanoutScheduling.swift",
      "Sources/RielaCore/WorkflowFanoutChangeEvidence.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift",
      "Sources/RielaCLI/ParityCommandSupport.swift",
      "Sources/RielaCLI/ParityCommands.swift",
      "Sources/RielaCLI/ParsedWorkflowOptions.swift",
      "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
      "Sources/RielaCLI/RielaCLIApplication.swift",
      "Sources/RielaCLI/RielaCommand.swift",
      "Sources/RielaCLI/WorkflowChangeSetStore.swift",
      "Sources/RielaCLI/WorkflowCommands.swift",
      "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
      "Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift",
      "Sources/RielaCLI/WorkflowRepairProposal.swift",
      "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
      "Sources/RielaCLI/WorkflowStagedVerification.swift",
      "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+FailurePublication.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner.swift",
      "Sources/RielaCore/LoopConvergenceTracker.swift",
      "Sources/RielaCore/RuntimeOutputValidation.swift",
      "Sources/RielaCore/RuntimePublication+Routing.swift",
      "Sources/RielaCore/RuntimePublication.swift",
      "Sources/RielaCore/RuntimeSession.swift",
      "Sources/RielaCore/RuntimeStore.swift",
      "Sources/RielaCore/RuntimeStorePublicationTransactions.swift",
      "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
      "Sources/RielaCore/WorkflowBranchEvaluation.swift",
      "Sources/RielaCore/WorkflowConditionAnalysis.swift",
      "Sources/RielaCore/WorkflowCycleProgress.swift",
      "Sources/RielaCore/WorkflowDefectDiagnostic.swift",
      "Sources/RielaCore/WorkflowGraphAnalysis.swift",
      "Sources/RielaCore/WorkflowLoopGuardEligibility.swift",
      "Sources/RielaCore/WorkflowLoopValidation.swift",
      "Sources/RielaCore/WorkflowRawValidation.swift",
      "Sources/RielaCore/WorkflowRouteContract.swift",
      "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift",
      "Sources/RielaCore/WorkflowValidation.swift",
      "Sources/RielaCore/WorkflowValidationHelpers.swift",
      "Tests/RielaCLITests/WorkflowDefectIncidentCommandTests.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionBoundaryTests.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift",
      "Tests/RielaCLITests/WorkflowRepairProposalTests.swift",
      "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
      "Tests/RielaCLITests/WorkflowStagedVerificationTests.swift",
      "Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift",
      "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
      "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/EXPECTED_RESULTS.md",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/accepted-plan-evidence.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/branch-evidence.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/change-evidence.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/expected-diagnostics.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-missing-control.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-dispatch.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-reconcile.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-review.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-worker.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/verification-evidence.json",
      "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/workflow.json",
      "Tests/RielaCoreTests/LoopConvergenceTrackerTests.swift",
      "Tests/RielaCoreTests/RuntimeOutputValidationTests.swift",
      "Tests/RielaCoreTests/RuntimePublicationTests.swift",
      "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
      "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift",
      "Tests/RielaCoreTests/WorkflowCycleProgressPersistenceTests.swift",
      "Tests/RielaCoreTests/WorkflowCycleProgressTests.swift",
      "Tests/RielaCoreTests/WorkflowDefectIncidentTests.swift",
      "Tests/RielaCoreTests/WorkflowGraphAnalysisTests.swift",
      "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift",
      "Tests/RielaCoreTests/WorkflowRouteContractTests.swift",
      "design-docs/specs/design-riela-workflow-internals.md",
      "design-docs/specs/design-workflow-json.md",
      "docs/output-contracts.md",
      "Package.swift"
    ]
  },
  "tasks": [
    {
      "taskId": "T1",
      "dependsOn": [],
      "requirements": [
        "D1",
        "A1",
        "A3",
        "A4"
      ],
      "writePaths": [
        "Sources/RielaCore/WorkflowBranchEvaluation.swift",
        "Sources/RielaCore/WorkflowConditionAnalysis.swift",
        "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
        "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [],
      "verificationIds": [
        "V1"
      ]
    },
    {
      "taskId": "T2",
      "dependsOn": [
        "T1"
      ],
      "requirements": [
        "D1",
        "D8",
        "A2",
        "A5"
      ],
      "writePaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/WorkflowValidationHelpers.swift",
        "Sources/RielaCore/WorkflowRawValidation.swift",
        "Sources/RielaCore/WorkflowDefectDiagnostic.swift",
        "Sources/RielaCore/WorkflowRouteContract.swift",
        "Sources/RielaCore/RuntimeOutputValidation.swift",
        "Sources/RielaCore/RuntimePublication.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+FailurePublication.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift",
        "Tests/RielaCoreTests/WorkflowRouteContractTests.swift",
        "Tests/RielaCoreTests/RuntimeOutputValidationTests.swift",
        "Tests/RielaCoreTests/RuntimePublicationTests.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/RuntimePublication.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift"
      ],
      "verificationIds": [
        "V2"
      ]
    },
    {
      "taskId": "T3",
      "dependsOn": [
        "T2"
      ],
      "requirements": [
        "D2",
        "A3",
        "A4",
        "A5",
        "A6",
        "A7"
      ],
      "writePaths": [
        "Sources/RielaCore/WorkflowGraphAnalysis.swift",
        "Sources/RielaCore/WorkflowLoopGuardEligibility.swift",
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/WorkflowLoopValidation.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift",
        "Tests/RielaCoreTests/WorkflowGraphAnalysisTests.swift",
        "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift"
      ],
      "verificationIds": [
        "V3"
      ]
    },
    {
      "taskId": "T4",
      "dependsOn": [
        "T3"
      ],
      "requirements": [
        "D3",
        "D6",
        "A8",
        "A9",
        "A10",
        "A11",
        "A12",
        "A16"
      ],
      "writePaths": [
        "Sources/RielaCore/WorkflowCycleProgress.swift",
        "Sources/RielaCore/LoopConvergenceTracker.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift",
        "Sources/RielaCore/RuntimePublication.swift",
        "Sources/RielaCore/RuntimeSession.swift",
        "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift",
        "Sources/RielaCore/RuntimeStorePublicationTransactions.swift",
        "Sources/RielaCore/RuntimeStore.swift",
        "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
        "Tests/RielaCoreTests/WorkflowCycleProgressTests.swift",
        "Tests/RielaCoreTests/WorkflowCycleProgressPersistenceTests.swift",
        "Tests/RielaCoreTests/LoopConvergenceTrackerTests.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift",
        "Sources/RielaCore/RuntimePublication.swift"
      ],
      "verificationIds": [
        "V4"
      ]
    },
    {
      "taskId": "T5",
      "dependsOn": [
        "T4"
      ],
      "requirements": [
        "D4",
        "D5",
        "A13",
        "A14",
        "A15"
      ],
      "writePaths": [
        "Sources/RielaCLI/WorkflowRepairProposal.swift",
        "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
        "Sources/RielaCLI/WorkflowCommands.swift",
        "Sources/RielaCLI/ParsedWorkflowOptions.swift",
        "Sources/RielaCLI/RielaCommand.swift",
        "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
        "Sources/RielaCLI/ParityCommandSupport.swift",
        "Sources/RielaCLI/ParityCommands.swift",
        "Sources/RielaCLI/RielaCLIApplication.swift",
        "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
        "Sources/RielaCLI/WorkflowChangeSetStore.swift",
        "Sources/RielaCLI/WorkflowStagedVerification.swift",
        "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
        "Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift",
        "Tests/RielaCLITests/WorkflowRepairProposalTests.swift",
        "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
        "Tests/RielaCLITests/WorkflowStagedVerificationTests.swift",
        "Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift",
        "Tests/RielaCLITests/WorkflowDirectoryTransactionBoundaryTests.swift",
        "Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [],
      "verificationIds": [
        "V5"
      ]
    },
    {
      "taskId": "T6",
      "dependsOn": [
        "T5"
      ],
      "requirements": [
        "D6",
        "D7",
        "D8",
        "A1",
        "A2",
        "A3",
        "A4",
        "A5",
        "A6",
        "A7",
        "A8",
        "A9",
        "A10",
        "A11",
        "A12",
        "A13",
        "A14",
        "A15",
        "A16"
      ],
      "writePaths": [
        "Package.swift",
        "Tests/RielaCoreTests/WorkflowDefectIncidentTests.swift",
        "Tests/RielaCLITests/WorkflowDefectIncidentCommandTests.swift",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/workflow.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-dispatch.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-worker.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-reconcile.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/node-review.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-missing-control.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/branch-evidence.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/accepted-plan-evidence.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/change-evidence.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/verification-evidence.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/expected-diagnostics.json",
        "Tests/RielaCoreTests/Fixtures/workflow-defect-incident/EXPECTED_RESULTS.md",
        "docs/output-contracts.md",
        "design-docs/specs/design-riela-workflow-internals.md",
        "design-docs/specs/design-workflow-json.md"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [],
      "verificationIds": [
        "V6",
        "V7",
        "V8",
        "V9"
      ]
    }
  ],
  "acceptanceCriteria": "All D1-D8 and A1-A16 contracts below; six task gates, foreground evidence and no unresolved high/mid findings. Planning-only does not authorize implementation.",
  "verification": "Future V1-V9 exact commands and required evidence are defined below. Step 4 documentation verification is tmp/workflow-defect-plan/verify-plan.py."
}
```

New paths in the manifest are explicit deliverables; other paths existed at the
inspected base. The future fixture directory has no current resources registration
in RielaCoreTests. T6, executing serially after T5, adds `.copy("Fixtures")` to
that test target in its explicitly authorized Package.swift write path before V6; Core tests use Bundle.module and CLI tests locate the same committed
fixture by repository path, avoiding a second fixture copy. This is the only
planned package-manifest edit. No lockfile generation or broad formatting is needed.

Before every edit, fresh-read its current bytes, record SHA-256 (or `absent`),
and compare with the latest accepted predecessor evidence. Save an immutable intent
snapshot with requirement IDs, exact paths, before hashes and planned changes under
`tmp/workflow-defect-implementation/<taskId>/<attempt>/intent.json`. Never rewrite
an earlier attempt snapshot. After editing record after hashes and a bounded diff.
Drift means stop the conflicting edit, retain both intents, and notify the serial
owner; never overwrite another accepted change or copy back a stale whole file.
Native fanout.changeTracking is evidence, not overwrite prevention. After join the
serial owner fresh-reads the combined tree, compares intended/actual deltas and
repairs conflicts serially, then repeats only affected gates before independent
combined-tree review. No worktrees, private branches or concurrent git operations.

## T1 — one parsed condition contract

Intent: D1 with A1/A3/A4; preserve complete valid expression meaning while exposing
missing/type errors to strict publication. No second parser or persistent cache.

- `WorkflowConditionAnalysis.swift` (new): `ParsedWorkflowCondition` with source spans,
  identifiers, parse failure and evaluate(lookup:); a typed lookup result separates
  missing, wrongType and boolean(value, source). Enforce structural validity rather
  than token consumption alone. Keep values keyed by captured digest/transition
  pointer within an execution, not a global mutable service.
- `WorkflowBranchEvaluation.swift`: extract the tokenizer/parser into that value;
  delegate existing entry point to it. Valid nil-label unconditional, constants,
  precedence, parentheses, hyphenated/case-sensitive identifiers retain meaning.
  An empty label is invalid, not an unconditional transition. Strict callers must
  receive parse errors, never rely on the old Bool wrapper's false-on-error result.
- `WorkflowBranchEvaluationTests.swift` and new `WorkflowConditionAnalysisTests.swift`:
  complete-input equivalence, false present vs absent, nested negation, constants,
  trailing `!`, unmatched parentheses, missing operands and exact error spans.

Acceptance: A1 and parser portions of A3/A4 pass V1 with positive test counts;
AST construction is shared by analysis and evaluation. No output retry or template
reference parsing change. Record exported API names for T2/T3; do not mark T1 done
until its own tests and changed-file lint pass.

## T2 — Boolean guarantees and rejection before routing

Intent: D1/D8, A2/A5. Requires T1 and externally accepted output-contract T2/T3.
No new retry engine, schema on an add-on, or requirement to mirror valid payload
controls into when.

- New `WorkflowDefectDiagnostic.swift`: stable code, severity, complete/incomplete/
  notApplicable status, source digest, file/JSON pointer, step/node/transition,
  bounded witness, type information and remediation class. Never log payloads or
  secrets. Sort by file/pointer/code; valid=true means no proven error, not safety.
- New `WorkflowRouteContract.swift`: consume T1 AST identifiers and upstream producer
  contracts. Prove required top-level Boolean fields including Boolean const/enum;
  optional/nullable/untyped fields do not prove presence. anyOf/oneOf require every
  alternative; allOf intersects only demonstrably consistent bounded constraints.
  Unsupported/unbounded proof reports incomplete at its schema pointer. Use the
  4,096-node analysis budget and report exhaustion; never narrow using unproven facts.
  Catalog-backed add-on guarantees require proven forwarding/overwrites; unknown
  add-on provenance is unverified, not an invented agent schema.
- `WorkflowValidation.swift`, `WorkflowValidationHelpers.swift`, `WorkflowRawValidation.swift`:
  wire shared parse/producer/guarantee diagnostics into current validation, preserving
  raw schema checks and upstream producer walk. No parallel schema validator.
- `RuntimeOutputValidation.swift`, `RuntimePublication.swift`: normalize envelope,
  validate payload schema, check EVERY referenced control (including short-circuited
  operands), then select, apply policy, persist and enqueue. Accept payload-only or
  explicitly guaranteed when-only controls. Schema-required payload fields remain
  required even if when supplies the control. Boolean locations must agree; missing,
  wrong type, null and contradiction produce typed validationRejected. Inspect the
  same candidate used by selection; carried payload cannot rescue or overwrite a
  missing producer control. Revalidate policy-derived controls with policy provenance.
  Move any candidate finalization with downstream effects behind this validation;
  preserve already-executed producer tool effects without claiming rollback.
- `DeterministicWorkflowRunner.swift`, `+Addons.swift`, `+FailurePublication.swift`,
  `+InputFilters.swift`: thread the shared route-contract/parsed-definition context
  through existing publication request construction only. Verify ordinary, inline,
  fanout join, callee resume and recovered pending-publication call paths. Do not
  fork checks by caller or hide retries in direct/library calls.
- `WorkflowRouteContractTests.swift`, `RuntimeOutputValidationTests.swift`,
  `RuntimePublicationTests.swift`: assert precise error/pointer, false validity,
  schema-required + when distinction, shadowing/conflict/short-circuit cases and zero
  messages, child reservations or finalization on rejected output. Exhausted agent
  correction uses two TOTAL attempts from upstream T3 (explicit authored bound wins).
  A side-effecting add-on executes once; direct callers get validationRejected once.

Acceptance: V2 covers A2/A5 including bounded exhaustion and all publication entry
paths. Failing assertions for missing-under-negation and pre-validation finalization
must fail on the old implementation; keep explicit before/after evidence.

## T3 — bounded branch and reachable-cycle diagnostics

Intent: D2, A3–A7. Requires T2 because validation wiring is shared. No universal
exact-one assumption, static termination claim, new route flag or SCC-only guard.

- `RuntimePublication+Routing.swift`: expose one internal selection/completion
  descriptor derived from real caller contract; graph analysis consumes it.
- New `WorkflowGraphAnalysis.swift`: enumerate lexical identifiers false-before-true;
  bound to 12 identifiers / 4,096 assignments, 256 transitions, 4,096 AST nodes per
  step. rejectMultiple with completion allowed diagnoses overlap, not gaps;
  firstMatch respects order; exact-one gap tests explicitly pass that contract.
  Nil terminal transitions, fanout items, events and call/resume retain their parent
  routing contract. Unknown/custom predicates produce incomplete. Report unsatisfiable
  routes with locations; remove only proven-false edges from graph analysis.
- Compute entry-reachable SCCs including self-loops; separately report unreachable
  defects. Remove eligible ENFORCING gate vertices and recompute SCCs for bypass
  witnesses. Possible exits do not prove termination. Deterministic sorted paths;
  preserve local evidence when cross-workflow composition cannot be completed.
  Bounds: 10,000 vertices, 50,000 edges, 32 resolved pinned workflow identities.
  Recursive/unresolved/over-limit composition is incomplete, not a call-only proof.
- New `WorkflowLoopGuardEligibility.swift`, `DeterministicWorkflowRunner+LoopPolicy.swift`:
  extract shared pure eligibility using effectiveLoopConvergencePolicy, loopGateParser
  and hook predicates. Missing loop may synthesize 4/2; authoredInactive and disabled
  do not. Step gateId/role annotation, parseable output and finite applicable limits
  matter; declaration membership alone is insufficient. warn is not an enforcing cut.
  Report declared post-publication vs default pre-persistence timing. Global max-steps
  and terminal reservations do not prove SCC convergence. Preserve existing runner
  behavior while extracting helpers; do not add gates or limits.
- `WorkflowValidation.swift`, `WorkflowLoopValidation.swift` wire diagnostics;
  `WorkflowGraphAnalysisTests.swift`, `WorkflowLoopValidationTests.swift` exercise
  all semantics/bounds, gate bypass with an exit, pinned and unresolved calls,
  policy disablement and intentional long-lived event loops without false errors.

Acceptance: V3 proves A3–A7 and parity with default/declared policy tests. Every
unsupported/over-limit check includes status, limit and observed size. Overlap/gap
witnesses are reproducible; default no-match completion stays valid.

## T4 — authoritative progress in the existing convergence path

Intent: D3/D6, A8–A12/A16. Requires T3 and native durable evidence; not P1
implementation. No model-prose progress, universal retry or new semantic limit.

- New `WorkflowCycleProgress.swift`: `WorkflowCycleProgressProjection` consumes native
  join/accepted-plan/change/verification records (read `WorkflowFanoutScheduling.swift`,
  `WorkflowFanoutChangeEvidence.swift`, `DeterministicWorkflowRunner+Fanout.swift`).
  Comparison key = root invocation + session + captured definition digest + stable
  wave/plan-set + SCC + lexically first SCC boundary step. Compare only completed
  returns to that step with all participating results durably settled.
- Canonical semantic content: sorted stable branch IDs and typed terminal outcomes,
  pending/dispatched sets, independently accepted plan IDs/content digests, accepted
  change-content digests, verification (check, subjectDigest, outcome, resultDigest).
  Execution/attempt IDs, ordinals/publication IDs (dedup only), timestamps, token
  totals and prose are excluded. Repeated pass on the same subject is unchanged;
  newly passing check or new accepted plan/content is progress.
- `LoopConvergenceTracker.swift`, `DeterministicWorkflowRunner+LoopPolicy.swift`,
  `DeterministicWorkflowRunner.swift`: use the existing tracker/effective policy at
  completed cycle boundaries even without gate annotation. First complete count=1,
  equal next=2, material change resets to 1. Reuse maxRepeatedFindingRounds, including
  incident bound 2; absent bound observes only; disabled remains disabled. Preserve
  existing gate counters. declared fail prevents next enqueue, warn records once and
  continues, default uses safe terminal corridor or failure with existing finalization
  checks. Emit prior/current evidence references and selected policy.
- Live owned worker, queued accepted dispatch, reserved authorized retry, external
  subscription/wait or unread result is non-comparable. Missing readiness/evidence is
  unknown. Stale/cancelled lifecycle requires its owner to reconcile first. E6 may
  supply Ready later; existing budgets apply meanwhile. Do not reset counts on silence.
- Retry decisions require authored policy, eligible class, remaining budget, stable
  branch identity and replay-safety evidence, rechecked by the existing reservation
  authority. Accepted branches never replay. Without P1, consume explicitly reviewed
  native decisions only; no inferred replay for auth/environment/non-idempotent or
  cancelled failures. No available safe action yields a cause/stall and proposal.
- `RuntimeSession.swift`: additive optional version-1 cycleProgress on
  WorkflowAcceptedOutputMetadata and the pending-route recovery decision. Persist key,
  projection/count, last comparable publication and decision as runtime metadata,
  never model payload. `RuntimePublication.swift`, `RuntimePublication+Routing.swift`,
  `RuntimeStorePublicationTransactions.swift`, `RuntimeStore.swift`: compose decision
  with existing checkpoint so output/route/progress commit atomically; pending recovery
  carries the decision rather than recomputing against later external state.
- `WorkflowRuntimePersistenceSnapshot.swift`, `SQLiteWorkflowRuntimePersistenceStore.swift`:
  preserve record in snapshot/session_json save/load. No SQL migration/new table.
  Old missing evidence is unknown; reconstruct only from complete captured records,
  else await next completed cycle. Unknown versions block semantic enforcement and
  report incompatible while retaining budgets. Same-version resume cannot reset.
  New root/rerun starts fresh with lineage; children contribute only via parent join.
  Concurrent completions use checkpoint conflict/fresh-snapshot retry and cannot count
  twice. Rollback to an older binary requires new run or reviewed recovery; never
  assert that an older binary can safely resume new records.
- `WorkflowCycleProgressTests.swift`, `WorkflowCycleProgressPersistenceTests.swift`,
  `LoopConvergenceTrackerTests.swift`, `DefaultLoopGuardTests.swift`,
  `DefaultLoopGuardRecoveryTests.swift`, `DeterministicWorkflowRunnerLoopPolicyTests.swift`:
  test churn/progress, liveness/unknown, retry negatives, policy composition, crash
  before/after checkpoint, file snapshot + SQLite round-trip, duplicate/replayed
  acceptance, unknown versions, concurrent completion, new roots and child isolation.

Acceptance: V4 proves A9–A12/A16; T6 joins actual incident A8. Two equal complete
unresolved cycles at bound 2 block a third round; no test may substitute an in-memory
Codable round-trip for transaction/recovery evidence.

## T5 — reviewed repair proposals using existing transactions

Intent: D4/D5, A13–A15. Requires T4; no second apply command/store/review authority.

- New `Sources/RielaCLI/WorkflowRepairProposal.swift`: format-version-1 diagnostic
  input/view of existing change-set model with bundle and per-file original digests,
  dependency digests, exact RFC 6901 pointers, before/after values and readable diff,
  rationale/assumptions, semantic class, ownership, review evidence and verification
  IDs/commands/expected results. Proposal digest binds every field. Runtime review
  binds that digest/reviewer/decision; proposal text cannot self-approve.
- `WorkflowCommands.swift`, `WorkflowValidateInspectCommands.swift`: additive analysis
  results and explicit read-only --repair-proposals output; deterministic codes/status
  and source-directed proposals for immutable targets. Validation never writes.
- `ParsedWorkflowOptions.swift`, `RielaCommand.swift`,
  `RielaArgumentParser+WorkflowAndMemory.swift`: thread new validate flag through actual
  typed options/parser. `ParityCommandSupport.swift`, `ParityCommands.swift`: parse
  --repair-proposal <path> only with self-improve dry-run; reject conflicting apply or
  finalization modes. `RielaCLIApplication.swift`: update actual CLI help.
- `WorkflowSelfImproveVersioning.swift`, `WorkflowChangeSetStore.swift`: register the
  proposal into existing history/review evidence instead of the marker-only mutation;
  preserve finalized --yes --change-set-id --expected-digest apply contract. Reuse
  WorkflowRuntimeGateEvidenceStore/WorkflowReviewGatePolicy; no new approval file.
  Formatting equivalence never bypasses existing required review/authorization gates.
- Prove the only initial verified-equivalent transform by valid AST → canonical
  rendering → reparse → identical normalized AST, identifiers/constants and semantics.
  Touch only the pointed expression. Missing flags, defaults, schema required, gates,
  new limits, reroutes and retry policies always require review and paired before-fail/
  after-pass mocks; unknown truth never authorizes a substitution.
- `WorkflowStagedVerification.swift`: explicitly require selected deterministic mocks
  for repair regardless of loop.selfEvolution metadata. Allow expected typed negative
  outcomes with assertions; process nonzero alone never passes. Capture consumed
  response counts, disposition, assertions and final exit. Verification IDs map to
  allowlisted argument arrays/adapters; proposal shell strings are inert review text.
  Missing response fails closed with no live provider/stdio/add-on fallback.
- `WorkflowDirectoryTransaction.swift`, `WorkflowDirectoryTransactionRecoveryPreparation.swift`:
  reuse source digest/before-value checks before staging and inside transaction; reject
  changed dependencies, symlink/escape, unsupported pointer or stale bytes. Failed
  validation/mock or crash recovery cannot publish an unverified stage. Extend only
  metadata/check threading needed for this contract; preserve existing recovery journal.
- `WorkflowRepairProposalTests.swift`, `WorkflowSelfImproveVersioningTests.swift`,
  `WorkflowStagedVerificationTests.swift`, `WorkflowDirectoryTransactionTests.swift`,
  `WorkflowDirectoryTransactionBoundaryTests.swift`,
  `WorkflowDirectoryTransactionTests+DetachedRecovery.swift`: equivalence, reviewed
  semantic repair, forged approval, digest drift, escape/rollback/recovery, immutable
  targets, inert shell text and missing-response negatives. Assert live before/after
  bytes and no provider effects, not merely a rejected return code.

Acceptance: V5 proves A13–A15. No implicit commit/push/install/live action; immutable
apply remains rejected and names its source follow-up. Proposed flags are future
interfaces, not currently available commands.

## T6 — integrated incident fixture, rollout and documentation

Intent: D6/D7/D8 and A1–A16. Requires T5 for final integration. Fixture drafting may
be read-only preparation earlier; there is no independent implementation branch.
No eventually-successful scripted loop or fabricated historical recording.

- `Package.swift`: T6 owns only adding `resources: [.copy("Fixtures")]` to the
  existing RielaCoreTests test target, with the adjacent separator needed for valid
  Swift syntax. Preserve its dependencies, other targets and package settings.
  Fresh-read and record pre/post hashes of Package.swift and Package.resolved using
  `shasum -a 256 Package.swift Package.resolved`; the lockfile hash must remain equal.
  Register the fixture resource before V6 tests use Bundle.module. After this edit,
  run V7a build/typecheck, V6, V7b combined Core/CLI regression, V7c/V7d lint/diff,
  then V8a–V8c and V9 on the combined tree. Earlier results cannot substitute for
  these post-registration V6–V9 gates. Record the edited manifest digest in each log.
- Fixture files listed in the manifest live only at
  `Tests/RielaCoreTests/Fixtures/workflow-defect-incident/`. workflow.json pins a
  synthetic dispatch → native collect-partial join → reconcile → integration-review
  graph with cycle, explicit selective redispatch and terminal routes. Node files
  define valid sandbox/output schemas. Strict mock files and branch/accepted-plan/
  change/verification records drive actual native state. expected-diagnostics.json
  names codes/pointers; EXPECTED_RESULTS.md records provenance synthetic-incident-shape,
  fixture digests, expected route/attempt counts and each A1–A16 owner.
- Variant A patches the base fixture in a test-owned tmp directory: remove the required
  discriminator under negation; assert static contract error, runtime rejection and
  correction exhaustion with zero next publications. Variant B uses valid controls and
  declared 4/2 fail policy, bypasses annotated gates, and retains identical failed
  branches through two complete cycles; stall before round 3, independently of A.
- Safe-retry variant has an explicit reviewed native retry policy/decision; dispatch
  only eligible failed branch, preserve accepted branches, then observe actual changed
  outcome/accepted-plan or verification identity. Failures are keyed to durable state,
  never a mock round number alone. No auth/environment/non-idempotent replay by default.
- New `WorkflowDefectIncidentTests.swift` integrates Core runner/store assertions;
  `WorkflowDefectIncidentCommandTests.swift` exercises real CLI validate/run options in
  isolated temp roots and asserts structured results. Allocate test scratch under
  repository tmp/. Keep fixtures portable with relative paths and mock-only adapters.
- Every A1–A16 row in accepted design D7 must map to a named test, expected failure,
  assertion and log. The focused earlier suites own negatives; do not duplicate tests
  simply to populate this row. Show pre-change failure through an assertion on legacy
  behavior or saved pre-change fixture result, without checking out an old worktree.
- `docs/output-contracts.md`: route-control diagnostics, bounded correction and
  read-only proposal/review boundaries. Serial finalizer updates `README.md` workflow
  command examples for additive validate output/new flags, runtime-owned review/apply
  and inert command text. `design-docs/specs/design-riela-workflow-internals.md`:
  shared AST, routing boundary, eligibility/progress/checkpoint ownership and unknowns.
  `design-docs/specs/design-workflow-json.md`: payload-only and when-only rules, required
  payload distinction, constants/limits/incomplete results and bounded correction.
  Serial finalizer updates only this design's implementation status and this plan's
  checkboxes/progress evidence when earned; other plans retain their scopes/statuses.
- Rollout: AST + graph diagnostics first; reconcile producer schemas and output-contract
  T2/T3 before strict control rejection; enable progress only for complete authoritative
  records after crash/negative gates; expose reviewed apply only after transaction gates.
  Required-control rejection is a deliberate tightening, documented with migration
  examples. No new schema Boolean/limit or SQL migration. Older-binary rollback uses
  a new run/reviewed recovery. E0/P2 landing first requires accepted rebase, not dual APIs.
- Record package follow-up: authorized source checkout → reviewed producer/route patch
  → manifest digest refresh → validate/mocks → version/publish → install new immutable
  version → verify installed identity. No installed/source workflow-package edits
  in this task or planning run; the future SwiftPM fixture registration is owned above.
  Repository riela-package.json needs no refresh for these documentation-only edits;
  future packaged workflow/prompt/script/skill changes require their owner to refresh it.

Acceptance: T6 resource registration is followed by V6–V9, including V7b combined
regression; Package.resolved is unchanged and all A1–A16 have executable evidence.
Independent review has no unresolved high/mid findings. Serial finalization owns index,
scope audit, any necessary narrow formatting and later archiving; worker edits only its progress file, never other plan checklists.

## Verification commands and required evidence

All commands below are FUTURE implementation gates, not tests run in Step 4.
Run from repository root in an arm64 shell. Every process stays foreground;
retain and poll a yielded session to terminal exit. Write complete stdout/stderr
and actual exit status to `tmp/workflow-defect-implementation/verification/<id>.log`;
record cwd, reviewed commit, input/fixture digest, positive selected-test counts,
assertions and mock consumption. A wrapper must preserve the child's exit status
(no success from tee), fail on zero selected tests and never truncate the log.
Keep failed attempts immutable in attempt-numbered directories.

| ID | Exact command | Evidence required |
| --- | --- | --- |
| V1 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowBranchEvaluationTests|WorkflowConditionAnalysisTests'"` | A1/A3 parser negatives and complete-input equivalence; positive test count |
| V2 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'"` | A2/A5 exact errors, schema/when behavior, two-attempt bound, all publication paths, no downstream effects |
| V3 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowGraphAnalysisTests|WorkflowLoopValidationTests|DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests'"` | A3–A7 witnesses, incomplete bounds, routing semantics and policy/eligibility parity |
| V4 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowCycleProgressTests|WorkflowCycleProgressPersistenceTests|LoopConvergenceTrackerTests|DefaultLoopGuardTests|DefaultLoopGuardRecoveryTests|DeterministicWorkflowRunnerLoopPolicyTests'"` | A9–A12/A16 authoritative comparison, liveness, retries, file/SQLite crash and concurrent recovery |
| V5 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowRepairProposalTests|WorkflowSelfImproveVersioningTests|WorkflowStagedVerificationTests|WorkflowDirectoryTransaction'"` | A13–A15 source/review binding, unchanged live bytes on rejection, no shell/provider fallback |
| V6 | `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefectIncidentTests|WorkflowDefectIncidentCommandTests'"` | A8 variant A/B isolated failures, actual safe retry progress, exact disposition/counts and A1–A16 trace map |
| V7a | `arch -arm64 /bin/zsh -lc 'swift build'` | Swift compile/typecheck of shared Core/CLI contracts, no new dependency |
| V7b | `arch -arm64 /bin/zsh -lc "swift test --filter 'RielaCoreTests|RielaCLITests'"` | Combined existing/new suites, positive count and zero failures; catch shared publication/CLI regressions |
| V7c | `swiftlint lint --quiet --no-cache` | Record actual status and separate pre-existing findings; touched Swift files satisfy repository rules |
| V7d | `git diff --check` | No whitespace errors; separately scan new untracked files until checkpointed |
| V8a | `.build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --output json` | Base valid schema/controls; graph diagnostic for bypass, no invented exact-one error; deterministic sorted diagnostics |
| V8b | `.build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-stall/artifacts --session-store tmp/workflow-defect-implementation/cli-stall/sessions --output json` | Expected runtime failure, NOT maxStepsExceeded: two complete equal projections, no third round; V6 command harness asserts typed failure and consumed responses |
| V8c | `.build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-retry/artifacts --session-store tmp/workflow-defect-implementation/cli-retry/sessions --output json` | Authorized selective dispatch advances actual durable evidence and completes; no accepted-branch replay |
| V9 | `.build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --repair-proposals --output json` | After T5 only: read-only proposal binding/classification and unchanged fixture digests; negative apply scenarios exercised by V5 |

V8 validates/runs the local synthetic fixture, not another orchestration workflow;
only installed user-scope codex-design-and-implement-review-loop owns orchestration.
CLI option spellings above are grounded in current ParsedWorkflowOptions. Reset or
choose a new owned evidence directory on each attempt, never reuse session IDs.
V8b is expected nonzero and passes only through the V6 harness's typed assertions;
record the raw failure code, not a forged exit 0. Missing-control commands run in
V6 against its exact patched fixture copy, with path/digest/argv recorded in that log.
No tests/build are needed for the current documentation-only authoring step.

## Completion and progress contract

- [ ] T1: Shared AST/typed lookup and V1 evidence accepted.
- [ ] T2: Upstream contracts ready; route validation/publication and V2 evidence accepted.
- [ ] T3: Bounded routing/SCC/guard analysis and V3 evidence accepted.
- [ ] T4: Persisted authoritative progress, recovery and V4 evidence accepted.
- [ ] T5: Digest-bound reviewed repair/staged apply and V5 evidence accepted.
- [ ] T6: Incident matrix, V6–V9, docs, combined review and serial scope reconciliation accepted.

All six original scopes/checklists remain unimplemented. Completion requires named
acceptance tests, complete logs/exit statuses and no high/mid findings; unknown
historical causality is a residual evidence limitation, not a runtime test pass.
Failures/blocked dependencies remain pending. Shared finalizer may archive only this
plan after every criterion passes; no global plan archiving or unrelated edits.

Future worker creates its sole progress log at the manifest progressLogPath. Each
entry records task/attempt, requirement IDs, dependency readiness, immutable intent
path, pre/post hashes, exact changed files/API decisions, command/log/final status,
positive test counts, findings/review disposition and remaining risks. Keep verified
facts separate from hypotheses. Worker does not check boxes in this plan.

### Step 4 author progress, 2026-09-22

Expanded the pre-existing six-task draft after accepted Step 3 receipt comm-000006;
no runtime, tests, workflows, skills or package files were edited. Corrected the
when-mirror restriction, T2/T3 ordering and execution-environment condition ownership.
Resolved two nonexistent documentation paths to existing owned docs and serial README examples.
Added explicit paths/APIs, atomic metadata/rollback contract, native single-item
serialization, test/CLI gates, drift protocol and full A1–A16 traceability. Existing
user changes are preserved; only this plan and its narrow README registration are
owned by this node. Step 5 independent plan acceptance and later authorized checkpoint
commit/push remain workflow stages; runtime implementation is not performed here.

Author verification: `python3 tmp/workflow-defect-plan/verify-plan.py`, complete log
`tmp/workflow-defect-plan/verification.log`; see that log for final exit and hashes.
The check verifies accepted-design digest, embedded manifest and DAG, path existence
or explicit new deliverable, task coverage and shared-file ordering, six unchecked
items/index parity, untracked whitespace and baseline preservation of all other files.
Its structural checks supplement the author's semantic read-through of D1–D8/A1–A16.
Retain this evidence through Step 5/finalization, then remove task scratch after its
required evidence has been preserved in the owning workflow's durable artifacts.

### Step 4 revision after Step 5, comm-000008

Review decision: revision_required, one mid finding; needs_design_revision=false.
Confirmed that RielaCoreTests currently has no resources declaration. Added
Package.swift to T6 and top-level writePaths and review context, making T6 the
explicit serial owner of fixture registration after T5 and before V6. Removed the
conflicting finalization-only ownership language. Required fresh Package.swift /
Package.resolved hashes and all post-registration V6–V9 gates, including V7b combined
Core/CLI regression. Package.resolved stays outside all writePaths and unchanged.

This revision changes only this plan; the accepted design, index, Package.swift,
Package.resolved and other existing files remain byte-for-byte preserved. All six
tasks remain unchecked. No runtime or fixture implementation has been performed.
Author verification command: `python3 tmp/workflow-defect-plan/revision-comm-000008/verify-revision.py`.
Complete log: `tmp/workflow-defect-plan/revision-comm-000008/verification.log`.
The verifier checks T6/top-level authorization, serial ordering, post-write gates,
lockfile exclusion, accepted design digest and preservation against a fresh baseline,
in addition to the original plan-contract checks. Prior review evidence remains
unchanged. Author status: ready_for_plan_rereview; independent acceptance pending.
