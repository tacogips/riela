# Workflow defect detection and verified repair implementation plan

Status: Five-item serial plan, 2026-09-26. Step 3 accepted the design via
`comm-000004`, `step3-design-review-attempt-1-exec-4`; findings=[]. Step 5 pending.
Mode `issue-resolution`; issue **Split and finish bounded workflow defect implementation
T2-T6**, `tacogips/riela`, Draft PR #109; no issue number supplied.
`codexAgentReferences=[]`; no new Cursor mapping or intentional divergence.
Accepted design: `design-docs/specs/design-workflow-defect-detection-and-repair.md`;
SHA-256 `269a9030892e9ff6da2765776d677b9bff08e0a2cf374d407730900a07b66915`. Do not edit those accepted bytes.
HEAD `e04c1c124a5a5370ff56e2785ff01b6d6f8e67a3`, branch `feat/remaining-impl-plans`.
Runner-resolved immutable user-scope workflow 0.3.44 and effective input are authority;
no registry discovery or readiness work is included.

## Step 5 review correction — comm-000006

The mid finding requires final adapter reconciliation coverage after T4 adapter
writes. T6 must additionally run the following on the final combined source:

```bash
arch -arm64 /bin/zsh -lc "swift test --filter 'AdapterUtilitiesTests'"
```

Require a positive selected-test count, zero failures, source hashes, complete
foreground log and terminal exit 0. This rechecks T2 completion-review controls
after later adapter changes. The same command is in T6's manifest and dispatch.
All five IDs, exact ownership and native serial dependencies remain unchanged.
Step 5 re-review is pending; the design remains accepted without revision.
Author verification: `python3 tmp/workflow-defect-step4-review-revision/verify.py`;
complete log `tmp/workflow-defect-step4-review-revision/verification.log`, exit 0.
No implementation test pass is claimed by this plan correction.

## Current bounded execution contract

Intent: finish accepted behavior without discarding productive partial work or
raising continuation limits. T1 is complete. T2 terminal evidence under
`tmp/workflow-defect-implementation/T2-terminal/` records V2 32/32, V2b 38/38,
raw-model 35/35 and focused validation 14/14 with exit 0. These are prior passing
runs, not full T2 acceptance. Preserve every dirty source/test/progress file and log.
T2 remaining is typed diagnostics, captured-source digest, when-only/add-on provenance,
raw/typed integration and the full publication-entry rejection matrix.

Authoritative dispatch:
`impl-plans/active/workflow-defect-repair-20260926-comm000006-a8e1beb-dispatch.json`.
This revision replaces its oversized item using the corrected 115-path baseline in
`impl-plans/active/workflow-defect-t2-continuation-20260926-comm000006-6e2caa3-dispatch.json`,
which remains historical evidence. The manifest below and outgoing plans must match.
Five stable IDs: `workflow-defect-t2-remaining` → `workflow-defect-t3` →
`workflow-defect-t4` → `workflow-defect-t5` → `workflow-defect-t6`.
The first item has no native dependency; T1 is preserved input, not a missing plan ID.
Each successor waits for native predecessor acceptance. No parallel editing is safe.

Only the owning child edits each item's writePaths. Its exact changes, rationale,
invariants and test intent are the matching T2–T6 section below; T4/T6 additionally
consume the activity extension. T2's reconciliation amendment is already implemented:
fresh-read and preserve it, do not repeat it. Existing dirty agent-contract tests are
preserved read-only input; add remaining coverage in T2's owned tests. Before alleging
ownership mismatch inspect actual dispatch, fanoutItem and runtimeVariables arrays
in `tmp/workflow-defect-t2-owned/sessions/`, not a prose summary.

Non-goals: T1 rewrite, weakened route checks, generic rewriter, new scheduler/store,
provider-auth repair, activity-as-progress, global limit changes, broad formatting,
lockfile generation, private branches/worktrees or concurrent Git operations.
Protect main, Monja and all other worktrees. No unsupported abstractions or cleanup.

For every edit fresh-read and compare predecessor hashes; save immutable requirement,
intent and pre/post SHA-256 evidence under `tmp/workflow-defect-implementation/<planId>/`.
Use attempt subfolders, never overwrite evidence. On drift stop the conflicting edit
and retain both intents for serial repair. Each worker's `progress.md` in that folder
records task/attempt, exact changed paths, acceptance state, test command/cwd, source
and fixture hashes, positive test counts, complete log path, final exit status and
remaining findings. Foreground commands only; poll any yielded handle through exit.
Generate the exact changed-Swift NUL manifest for its strict lint command. No zero-test
or incomplete-log pass; expected negative runs pass only through asserted outcomes.

Each item completes its own implementation and behavioral gates, not later formal
reviews or Git publication. T6 updates its owned docs and fixture trace matrix.
After join, the serial owner checks combined deltas against immutable intents,
repairs drift and reruns affected gates. Independent test-integrity, adversarial and
combined review must have no unresolved material findings. Serial finalization updates
this plan, accepted design status, `impl-plans/README.md`, `README.md` and the preserved
shared progress file. Commit/push only exact reviewed paths, non-force to
`feat/remaining-impl-plans`, with remote and Draft PR #109 matching the reviewed tree.

## Review and checkpoint gate

Step 5 must accept these revised bytes first. Then checkpoint only the accepted
design, this plan and revised dispatch, excluding dirty Swift and shared progress.
Bind plan/design hashes and current review receipts in outgoing reviewContext; do
not reuse historical acceptance. Validate nonempty string arrays, exact paths,
five unique IDs, dependency references/DAG and shared-path ordering. The runner's
outgoing payload-schema validation remains mandatory before checkpoint/dispatch;
local structural checks do not replace that runtime operation. A failed checkpoint
push prevents native dispatch. No commit or push occurs in this author node.

Author check: `python3 tmp/workflow-defect-step4-bounded/verify.py`;
complete log `tmp/workflow-defect-step4-bounded/verification.log`, final exit 0.
This current header and five-item manifest supersede historical single-item,
checkpoint and incomplete-task observations below; accepted behavior is unchanged.

## Historical activity extension authority (2026-09-22)

Mode: `design-plan-only`. Issue: **Expose authoritative backend activity and session
liveness**, `workflow-input`, repository `tacogips/riela`, issue number/URL null.
Original communication `comm-000001`; intake receipt `comm-000002` from
`step1-issue-intake-attempt-1-exec-2`, workflow execution
`codex-design-and-implement-review-loop-session-1`. Base
`991f619fd13e548275ba20ac4073a4168f97a2d3`, main tracking origin/main;
the accepted design and draft plan are the two existing working-tree changes.
The immutable user-scope package manifest is
`/Users/taco/.riela/packages/codex-design-and-implement-review-loop/riela-package.json`,
version 0.3.6. Planning updates only this plan and its existing design; later workflow
review/finalization owns accepted documentation commit/push. Runtime dispatch remains
disabled. Preserve other worktrees and Monja tenant-sharding-d48.

D9 in `design-docs/specs/design-workflow-defect-detection-and-repair.md` is the new
activity authority, with intake A1–A8 named L1–L8 to preserve original A1–A16 IDs.
Current design acceptance: `comm-000004`,
`step3-design-review-attempt-1-exec-4`, decision `accepted`,
independentAcceptance `accepted`, accepted=true, needs_revision=false, findings=[].
Accepted design SHA-256:
`998818586b15ab158a6dd956ef9a69de52b3bbdcd3a008702a2e96e593b45a0c`.
The reviewed draft plan SHA-256 was
`19a5671acc4a303fa6e354757cda8856585fe51797cbb89ca36f1e24752759c5`;
this Step 4 revision requires fresh Step 5 acceptance. The design's pending-review
prose records its authoring stage; the supplied Step 3 receipt accepts these exact
bytes. Preserve that design unchanged. No current Step 5 feedback was supplied;
the older comm-000008 finding below remains resolved by T6 Package.swift ownership.
Step 3 could read the complete Step 2 log but could not overwrite it in its sandbox.
This node writes fresh verification evidence under `tmp/backend-activity-plan/`;
it does not overwrite or claim a rerun of the earlier verifier.

Codex references: reported reasoning, tool-call, subagent communication and process
activity, behavioral only, each filePath null. `/Users/taco/gits/codex-agent` is
absent and no reference URL/fixture is available. Use the inspected ACP gateway
mapping; Cursor handling stays in adapters. Process activity intentionally does
not establish responsiveness. Historical provenance below is not current approval.

## Intent, authority and repository context (historical baseline)

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
finalization/reservation as well as transition publication. The historical T3 default of 1 has been replaced by two total attempts for
output-bearing requests in the current Prompting implementation; reuse it.

## Non-goals and external ownership gates

No runtime code in this Step 4 node; no generic rewriter, SAT service, scheduler,
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

Five native items share this coupled plan document. Select the task by nativePlanId;
read its T2–T6 section and, for T4/T6, the activity extension below. Never execute the
whole task list for each item. Native dependsOn, not internal prose, controls release.
The aggregate writePaths below preserve the corrected 115-path ownership baseline;
only each dispatched item's writePaths grant worker edits. Completed T1 is read-only
input. The existing shared progress file belongs to serial finalization; each worker
writes only its own tmp progressLogPath. SharedPaths are coordination, not grants.
The accepted design names architecture/command docs absent at this base; retain the
existing T6 mapping to docs/output-contracts.md and the owned workflow design docs.
Package.swift has only the T6 fixture resource change; Package.resolved is unchanged.

```json
{
  "planId": "workflow-defect-detection-and-repair",
  "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
  "dependsOn": [],
  "workflowMode": "issue-resolution",
  "implementationDispatchEnabled": false,
  "executionStrategy": "five-native-items-with-serial-dependsOn",
  "writePaths": [
    "Package.swift",
    "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Sources/RielaCLI/ParityCommands.swift",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/SessionObservabilityComposition.swift",
    "Sources/RielaCLI/SessionObservabilityRendering.swift",
    "Sources/RielaCLI/WorkflowChangeSetStore.swift",
    "Sources/RielaCLI/WorkflowCommands.swift",
    "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
    "Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift",
    "Sources/RielaCLI/WorkflowRepairProposal.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
    "Sources/RielaCLI/WorkflowStagedVerification.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCore/AdapterContracts.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+FailurePublication.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/LoopCompletionReviewRouting.swift",
    "Sources/RielaCore/LoopConvergenceTracker.swift",
    "Sources/RielaCore/RuntimeOutputValidation.swift",
    "Sources/RielaCore/RuntimePublication+Routing.swift",
    "Sources/RielaCore/RuntimePublication.swift",
    "Sources/RielaCore/RuntimeSession.swift",
    "Sources/RielaCore/RuntimeStore.swift",
    "Sources/RielaCore/RuntimeStorePublicationTransactions.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/SessionObservability.swift",
    "Sources/RielaCore/WorkflowBranchEvaluation.swift",
    "Sources/RielaCore/WorkflowConditionAnalysis.swift",
    "Sources/RielaCore/WorkflowCycleProgress.swift",
    "Sources/RielaCore/WorkflowDefectDiagnostic.swift",
    "Sources/RielaCore/WorkflowGraphAnalysis.swift",
    "Sources/RielaCore/WorkflowLoopGuardEligibility.swift",
    "Sources/RielaCore/WorkflowLoopValidation.swift",
    "Sources/RielaCore/WorkflowRawValidation.swift",
    "Sources/RielaCore/WorkflowRouteContract.swift",
    "Sources/RielaCore/WorkflowRunEvent.swift",
    "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift",
    "Sources/RielaCore/WorkflowValidation.swift",
    "Sources/RielaCore/WorkflowValidationHelpers.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift",
    "Sources/RielaGraphQL/RielaGraphQL.swift",
    "Sources/RielaServer/DistributedWorkerEventSender.swift",
    "Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift",
    "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
    "Tests/RielaCLITests/SessionCommandJSONLStreamingTests.swift",
    "Tests/RielaCLITests/SessionObservabilityCommandTests.swift",
    "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
    "Tests/RielaCLITests/WorkflowCommandProgressHeartbeatTests.swift",
    "Tests/RielaCLITests/WorkflowDefectIncidentCommandTests.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionBoundaryTests.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift",
    "Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift",
    "Tests/RielaCLITests/WorkflowRepairProposalTests.swift",
    "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
    "Tests/RielaCLITests/WorkflowStagedVerificationTests.swift",
    "Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift",
    "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift",
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
    "Tests/RielaCoreTests/RuntimeSessionTests.swift",
    "Tests/RielaCoreTests/RuntimeStoreTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
    "Tests/RielaCoreTests/SessionObservabilityTests.swift",
    "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
    "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift",
    "Tests/RielaCoreTests/WorkflowCycleProgressPersistenceTests.swift",
    "Tests/RielaCoreTests/WorkflowCycleProgressTests.swift",
    "Tests/RielaCoreTests/WorkflowDefectIncidentTests.swift",
    "Tests/RielaCoreTests/WorkflowGraphAnalysisTests.swift",
    "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift",
    "Tests/RielaCoreTests/WorkflowRouteContractTests.swift",
    "Tests/RielaGraphQLTests/GraphQLContractsTests.swift",
    "Tests/RielaGraphQLTests/SessionObservabilityGraphQLTests.swift",
    "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
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
    "issueReference": {
      "repository": "tacogips/riela",
      "draftPR": 109,
      "intakeCommunication": "comm-000002",
      "checkpoint": "e04c1c124a5a5370ff56e2785ff01b6d6f8e67a3"
    },
    "userProblem": "Split the oversized item into bounded serial T2-remaining, T3, T4, T5 and T6; preserve completed T1 and dirty partial T2.",
    "requiredOutcomes": [
      "Fresh T2 diagnostic/digest/provenance/publication matrix and V2/V2b.",
      "D1-D9, A1-A16 and L1-L8 acceptance with V3-V9/L-V1-L-V5.",
      "No unresolved material review findings; reviewed exact-file non-force publication to Draft PR #109."
    ],
    "nonGoals": [
      "No generic rewriter, silent max-step increase, mock-success repair, second scheduler or parallel database.",
      "No upstream producer-contract or Work Runtime P1 reimplementation, provider-auth repair or release."
    ],
    "constraints": [
      "Five native serial items; no global continuation-limit increase.",
      "Preserve all dirty T1/T2 files and source-matched evidence; no reset, stash or broad rewrite.",
      "Exact task paths only; fresh reads, pre/post hashes, immutable intents and serial drift repair.",
      "Scratch and per-item progress under repository-root tmp; shared finalization is serial.",
      "Runner-resolved immutable user-scope 0.3.44 authority; no registry rediscovery."
    ],
    "designDecisionsAndRationale": [
      "D1 shares parsed Boolean syntax and typed lookup between validation and publication; all referenced controls are checked, including short-circuited paths.",
      "For recognized completion reviews, derive accepted from needs_replan and needs_work and reconcile the complete three-control map; this repairs the producer without a generic missing-control fallback.",
      "D2 bounds assignment enumeration to 12 identifiers; reachable SCC/gate analysis uses effective loop policy.",
      "D3/D6 compare persisted completed authoritative cycle projections and reuse existing convergence/persistence/retry ownership.",
      "D9 records correlated activity and liveness without treating activity as semantic progress or proof of responsiveness.",
      "D4/D5 classify digest-bound proposals; meaning-changing edits require review and existing staged transaction verification."
    ],
    "intentionalTradeoffs": [
      "Analysis above 12 identifiers and unresolved cross-workflow composition remains explicitly incomplete.",
      "Incident fixture is synthetic because captured definition and ledger are unavailable.",
      "Opaque pre-ingress activity and cross-host freshness remain unverified; Cursor normalization stays in its adapter."
    ],
    "supportedEdgeCases": [
      "Malformed expressions, constants, short-circuited identifiers, missing/wrong-type/conflicting when and payload values.",
      "Overlap/uncovered exclusive routes, bypassed guards, missing policy references and intentional external loops.",
      "Live/pending work, unknown evidence, equal completed projections, recovery, authorized and unsafe retries.",
      "Stale digest, path escape, verification failure and immutable-package source routing.",
      "Recognized completion-review decisions with missing or contradictory accepted, already-correct maps, goal-not-achieved decisions and non-review pass-through."
    ],
    "outOfScopeEdgeCases": [
      "General SAT, generic repair synthesis, remote clock synchronization and autonomous provider actions.",
      "Reconstruction of uncaptured historical incident or unsupported upstream Codex schema equivalence."
    ],
    "sourcePaths": [
      "Package.swift",
      "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
      "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
      "Sources/RielaCLI/ParityCommandSupport.swift",
      "Sources/RielaCLI/ParityCommands.swift",
      "Sources/RielaCLI/ParsedWorkflowOptions.swift",
      "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
      "Sources/RielaCLI/RielaCLIApplication.swift",
      "Sources/RielaCLI/RielaCommand.swift",
      "Sources/RielaCLI/RielaLibrary.swift",
      "Sources/RielaCLI/SessionCommands.swift",
      "Sources/RielaCLI/SessionObservabilityComposition.swift",
      "Sources/RielaCLI/SessionObservabilityRendering.swift",
      "Sources/RielaCLI/TaskDispatch+Director.swift",
      "Sources/RielaCLI/WorkflowChangeSetStore.swift",
      "Sources/RielaCLI/WorkflowCommands.swift",
      "Sources/RielaCLI/WorkflowDirectoryTransaction.swift",
      "Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift",
      "Sources/RielaCLI/WorkflowRepairProposal.swift",
      "Sources/RielaCLI/WorkflowRunCommand.swift",
      "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
      "Sources/RielaCLI/WorkflowSelfImproveVersioning.swift",
      "Sources/RielaCLI/WorkflowStagedVerification.swift",
      "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
      "Sources/RielaCore/AdapterContracts.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+FailurePublication.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift",
      "Sources/RielaCore/DeterministicWorkflowRunner.swift",
      "Sources/RielaCore/DistributedJobController.swift",
      "Sources/RielaCore/LoopCompletionReviewRouting.swift",
      "Sources/RielaCore/LoopConvergenceTracker.swift",
      "Sources/RielaCore/RuntimeOutputValidation.swift",
      "Sources/RielaCore/RuntimePublication+Routing.swift",
      "Sources/RielaCore/RuntimePublication.swift",
      "Sources/RielaCore/RuntimeSession.swift",
      "Sources/RielaCore/RuntimeStore.swift",
      "Sources/RielaCore/RuntimeStorePublicationTransactions.swift",
      "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+Rollup.swift",
      "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift",
      "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
      "Sources/RielaCore/SessionObservability.swift",
      "Sources/RielaCore/WorkflowBranchEvaluation.swift",
      "Sources/RielaCore/WorkflowConditionAnalysis.swift",
      "Sources/RielaCore/WorkflowCycleProgress.swift",
      "Sources/RielaCore/WorkflowDefectDiagnostic.swift",
      "Sources/RielaCore/WorkflowFanoutChangeEvidence.swift",
      "Sources/RielaCore/WorkflowFanoutScheduling.swift",
      "Sources/RielaCore/WorkflowGraphAnalysis.swift",
      "Sources/RielaCore/WorkflowLoopGuardEligibility.swift",
      "Sources/RielaCore/WorkflowLoopValidation.swift",
      "Sources/RielaCore/WorkflowRawValidation.swift",
      "Sources/RielaCore/WorkflowRouteContract.swift",
      "Sources/RielaCore/WorkflowRunEvent.swift",
      "Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift",
      "Sources/RielaCore/WorkflowValidation.swift",
      "Sources/RielaCore/WorkflowValidationHelpers.swift",
      "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
      "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
      "Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift",
      "Sources/RielaGraphQL/RielaGraphQL.swift",
      "Sources/RielaServer/DistributedWorkerEventSender.swift",
      "Sources/RielaWork/DecisionApplier.swift",
      "Sources/RielaWork/WorkStore+Decisions.swift",
      "Sources/RielaWork/WorkStore+Director.swift",
      "Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift",
      "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
      "Tests/RielaCLITests/SessionCommandJSONLStreamingTests.swift",
      "Tests/RielaCLITests/SessionObservabilityCommandTests.swift",
      "Tests/RielaCLITests/TaskDispatcherIntegrationTests+Director.swift",
      "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
      "Tests/RielaCLITests/WorkflowCommandProgressHeartbeatTests.swift",
      "Tests/RielaCLITests/WorkflowDefectIncidentCommandTests.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionBoundaryTests.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift",
      "Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift",
      "Tests/RielaCLITests/WorkflowOutputContractPreflightTests.swift",
      "Tests/RielaCLITests/WorkflowRepairProposalTests.swift",
      "Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift",
      "Tests/RielaCLITests/WorkflowStagedVerificationTests.swift",
      "Tests/RielaCoreTests/AgentNodeOutputContractValidationTests.swift",
      "Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift",
      "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
      "Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift",
      "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift",
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
      "Tests/RielaCoreTests/RuntimeSessionTests.swift",
      "Tests/RielaCoreTests/RuntimeStoreTests.swift",
      "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
      "Tests/RielaCoreTests/SessionObservabilityTests.swift",
      "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
      "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift",
      "Tests/RielaCoreTests/WorkflowCycleProgressPersistenceTests.swift",
      "Tests/RielaCoreTests/WorkflowCycleProgressTests.swift",
      "Tests/RielaCoreTests/WorkflowDefectIncidentTests.swift",
      "Tests/RielaCoreTests/WorkflowGraphAnalysisTests.swift",
      "Tests/RielaCoreTests/WorkflowLoopValidationTests.swift",
      "Tests/RielaCoreTests/WorkflowOutputContractPreflightTests.swift",
      "Tests/RielaCoreTests/WorkflowRouteContractTests.swift",
      "Tests/RielaGraphQLTests/GraphQLContractsTests.swift",
      "Tests/RielaGraphQLTests/SessionObservabilityGraphQLTests.swift",
      "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
      "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
      "Tests/RielaWorkTests/DecisionApplierCausalityStoreTests.swift",
      "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
      "Tests/RielaWorkTests/DecisionApplierTests.swift",
      "design-docs/specs/design-agent-node-output-contract.md",
      "design-docs/specs/design-execution-environment-consolidation.md",
      "design-docs/specs/design-loop-engineering-convergence-and-operations.md",
      "design-docs/specs/design-riela-workflow-internals.md",
      "design-docs/specs/design-work-runtime-consolidation.md",
      "design-docs/specs/design-workflow-defect-detection-and-repair.md",
      "design-docs/specs/design-workflow-json.md",
      "docs/output-contracts.md",
      "impl-plans/active/execution-environment-consolidation.md",
      "impl-plans/active/workflow-defect-detection-and-repair.md",
      "impl-plans/completed/agent-node-output-contract.md",
      "impl-plans/completed/loop-engineering-convergence-and-operations.md",
      "impl-plans/completed/work-runtime-p1-dispatcher-guard-director.md"
    ],
    "reviewDecision": "Step 3 comm-000004 accepted design with no findings. Step 5 review and checkpoint pending.",
    "codexAgentReferences": [],
    "planningVerification": {
      "command": "python3 tmp/workflow-defect-step4-bounded/verify.py",
      "completeLogPath": "tmp/workflow-defect-step4-bounded/verification.log"
    },
    "acceptedReview": {
      "designCommunicationId": "comm-000004",
      "designDecision": "accepted",
      "designSHA256": "269a9030892e9ff6da2765776d677b9bff08e0a2cf374d407730900a07b66915",
      "planDecision": "pending",
      "findings": []
    }
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
      ],
      "status": "complete-preserved-input"
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
        "Tests/RielaCoreTests/RuntimePublicationTests.swift",
        "Sources/RielaCore/LoopCompletionReviewRouting.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
        "Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/RuntimePublication.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift"
      ],
      "verificationIds": [
        "V2",
        "V2b"
      ],
      "nativePlanId": "workflow-defect-t2-remaining",
      "progressLogPath": "tmp/workflow-defect-implementation/workflow-defect-t2-remaining/progress.md"
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
      ],
      "nativePlanId": "workflow-defect-t3",
      "progressLogPath": "tmp/workflow-defect-implementation/workflow-defect-t3/progress.md"
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
        "A16",
        "D9",
        "L1",
        "L2",
        "L3",
        "L4",
        "L5",
        "L6",
        "L7",
        "L8"
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
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
        "Sources/RielaCore/AdapterContracts.swift",
        "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
        "Sources/RielaServer/DistributedWorkerEventSender.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
        "Sources/RielaCore/WorkflowRunEvent.swift",
        "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
        "Sources/RielaCore/SessionObservability.swift",
        "Sources/RielaCLI/SessionCommands.swift",
        "Sources/RielaCLI/SessionObservabilityRendering.swift",
        "Sources/RielaCLI/SessionObservabilityComposition.swift",
        "Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift",
        "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
        "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
        "Sources/RielaGraphQL/RielaGraphQL.swift",
        "Sources/RielaCLI/RielaLibrary.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift",
        "Tests/RielaCoreTests/RuntimeStoreTests.swift",
        "Tests/RielaCoreTests/RuntimeSessionTests.swift",
        "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
        "Tests/RielaCoreTests/SessionObservabilityTests.swift",
        "Tests/RielaCLITests/SessionCommandJSONLStreamingTests.swift",
        "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
        "Tests/RielaCLITests/WorkflowCommandProgressHeartbeatTests.swift",
        "Tests/RielaCLITests/SessionObservabilityCommandTests.swift",
        "Tests/RielaGraphQLTests/SessionObservabilityGraphQLTests.swift",
        "Tests/RielaGraphQLTests/GraphQLContractsTests.swift",
        "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
        "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
        "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift",
        "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift"
      ],
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "sharedPaths": [
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift",
        "Sources/RielaCore/RuntimePublication.swift"
      ],
      "verificationIds": [
        "V4",
        "L-V1",
        "L-V2",
        "L-V3",
        "L-V4",
        "L-V5"
      ],
      "nativePlanId": "workflow-defect-t4",
      "progressLogPath": "tmp/workflow-defect-implementation/workflow-defect-t4/progress.md"
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
      ],
      "nativePlanId": "workflow-defect-t5",
      "progressLogPath": "tmp/workflow-defect-implementation/workflow-defect-t5/progress.md"
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
        "A16",
        "D9",
        "L1",
        "L2",
        "L3",
        "L4",
        "L5",
        "L6",
        "L7",
        "L8"
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
        "V9",
        "L-V1",
        "L-V2",
        "L-V3",
        "L-V4",
        "L-V5"
      ],
      "nativePlanId": "workflow-defect-t6",
      "progressLogPath": "tmp/workflow-defect-implementation/workflow-defect-t6/progress.md"
    }
  ],
  "acceptanceCriteria": [
    "Five serial native items pass their scoped acceptance and source-matched gates.",
    "All D1-D9, A1-A16 and L1-L8 behavior verified; no unresolved material review findings.",
    "Review-dependent docs/index and exact-file non-force publication complete downstream."
  ],
  "verification": [
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'AgentNodeOutputContractValidationTests|WorkflowOutputContractPreflightTests|RuntimeOutputValidationTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowModelTests|AgentNodeOutputContractValidationTests'\"",
    "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t2-remaining/changed-swift.nul",
    "git diff --check",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowGraphAnalysisTests|WorkflowLoopValidationTests|DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests'\"",
    "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t3/changed-swift.nul",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowCycleProgressTests|WorkflowCycleProgressPersistenceTests|LoopConvergenceTrackerTests|DefaultLoopGuardTests|DefaultLoopGuardRecoveryTests|DeterministicWorkflowRunnerLoopPolicyTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'DeterministicWorkflowRunnerBackendEventTests|RuntimeStoreTests|RuntimeSessionTests|SQLiteRuntimeSchemaMigrationTests|SessionObservabilityTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionCommandJSONLStreamingTests|WorkflowCommandLivePersistenceEventTests|WorkflowCommandProgressHeartbeatTests|SessionObservabilityCommandTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionObservabilityGraphQLTests|GraphQLContractsTests|SurfaceParityDTO'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'LoopConvergenceTrackerTests|DeterministicWorkflowRunnerLoopPolicyTests|DeterministicWorkflowRunnerFanoutTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'AgentGatewayNodeAdapterTests|DistributedWorkerHTTPTests'\"",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|TaskDispatcherIntegrationTests'\"",
    "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t4/changed-swift.nul",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowRepairProposalTests|WorkflowSelfImproveVersioningTests|WorkflowStagedVerificationTests|WorkflowDirectoryTransaction'\"",
    "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t5/changed-swift.nul",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowDefectIncidentTests|WorkflowDefectIncidentCommandTests'\"",
    "arch -arm64 /bin/zsh -lc 'swift build'",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'RielaCoreTests|RielaCLITests'\"",
    "swiftlint lint --quiet --no-cache",
    ".build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --output json",
    ".build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-stall/artifacts --session-store tmp/workflow-defect-implementation/cli-stall/sessions --output json",
    ".build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-retry/artifacts --session-store tmp/workflow-defect-implementation/cli-retry/sessions --output json",
    ".build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --repair-proposals --output json",
    "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t6/changed-swift.nul",
    "arch -arm64 /bin/zsh -lc \"swift test --filter 'AdapterUtilitiesTests'\""
  ],
  "plans": [
    {
      "planId": "workflow-defect-t2-remaining",
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "dependsOn": [],
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
        "Tests/RielaCoreTests/RuntimePublicationTests.swift",
        "Sources/RielaCore/LoopCompletionReviewRouting.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
        "Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift"
      ],
      "sharedPaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/RuntimePublication.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Tests/RielaCoreTests/DefaultLoopGuardTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift"
      ],
      "acceptanceCriteria": [
        "Typed WorkflowDefectDiagnostic binds the captured source digest and stable sorted raw/typed locations; unknown guarantees remain incomplete, never proved safe.",
        "Explicit when-only and catalog-backed add-on provenance retain payload schema requirements and forwarding/overwrite proof.",
        "Ordinary, inline, fanout-join, callee-resume and recovered publication reject missing/type/conflicting controls before downstream effects; two-total-attempt agent correction and one-shot add-on/direct calls remain bounded.",
        "Fresh V2/V2b and producer/raw tests pass with positive counts; preserve completed T1 and passing T2 reconciliation."
      ],
      "verification": [
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowRouteContractTests|RuntimeOutputValidationTests|RuntimePublicationTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'AgentNodeOutputContractValidationTests|WorkflowOutputContractPreflightTests|RuntimeOutputValidationTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowModelTests|AgentNodeOutputContractValidationTests'\"",
        "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t2-remaining/changed-swift.nul",
        "git diff --check"
      ]
    },
    {
      "planId": "workflow-defect-t3",
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "dependsOn": [
        "workflow-defect-t2-remaining"
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
      "sharedPaths": [
        "Sources/RielaCore/WorkflowValidation.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift"
      ],
      "acceptanceCriteria": [
        "D2/A3-A7 bounded truth assignments and reachable SCC/gate bypass checks report reproducible witnesses or explicit incomplete status.",
        "Existing firstMatch, completion, fanout/call semantics and effective disabled/warn/default policy remain unchanged; V3 passes."
      ],
      "verification": [
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowGraphAnalysisTests|WorkflowLoopValidationTests|DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests'\"",
        "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t3/changed-swift.nul",
        "git diff --check"
      ]
    },
    {
      "planId": "workflow-defect-t4",
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "dependsOn": [
        "workflow-defect-t3"
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
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift",
        "Sources/RielaCore/AdapterContracts.swift",
        "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
        "Sources/RielaServer/DistributedWorkerEventSender.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
        "Sources/RielaCore/WorkflowRunEvent.swift",
        "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
        "Sources/RielaCore/SessionObservability.swift",
        "Sources/RielaCLI/SessionCommands.swift",
        "Sources/RielaCLI/SessionObservabilityRendering.swift",
        "Sources/RielaCLI/SessionObservabilityComposition.swift",
        "Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift",
        "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
        "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
        "Sources/RielaGraphQL/RielaGraphQL.swift",
        "Sources/RielaCLI/RielaLibrary.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift",
        "Tests/RielaCoreTests/RuntimeStoreTests.swift",
        "Tests/RielaCoreTests/RuntimeSessionTests.swift",
        "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
        "Tests/RielaCoreTests/SessionObservabilityTests.swift",
        "Tests/RielaCLITests/SessionCommandJSONLStreamingTests.swift",
        "Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift",
        "Tests/RielaCLITests/WorkflowCommandProgressHeartbeatTests.swift",
        "Tests/RielaCLITests/SessionObservabilityCommandTests.swift",
        "Tests/RielaGraphQLTests/SessionObservabilityGraphQLTests.swift",
        "Tests/RielaGraphQLTests/GraphQLContractsTests.swift",
        "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
        "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
        "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
        "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift",
        "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift"
      ],
      "sharedPaths": [
        "Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift",
        "Sources/RielaCore/DeterministicWorkflowRunner.swift",
        "Sources/RielaCore/RuntimePublication+Routing.swift",
        "Sources/RielaCore/RuntimePublication.swift"
      ],
      "acceptanceCriteria": [
        "D3/D6 A8-A12/A16 compare authoritative completed cycles, atomically persist decisions and preserve deduplication, recovery and attempt fences; V4 passes.",
        "D9 L1-L8 activity, responsiveness and semantic progress remain separate; L-V1-L-V5 pass with privacy, surface parity and unsupported freshness cases."
      ],
      "verification": [
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowCycleProgressTests|WorkflowCycleProgressPersistenceTests|LoopConvergenceTrackerTests|DefaultLoopGuardTests|DefaultLoopGuardRecoveryTests|DeterministicWorkflowRunnerLoopPolicyTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'DeterministicWorkflowRunnerBackendEventTests|RuntimeStoreTests|RuntimeSessionTests|SQLiteRuntimeSchemaMigrationTests|SessionObservabilityTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionCommandJSONLStreamingTests|WorkflowCommandLivePersistenceEventTests|WorkflowCommandProgressHeartbeatTests|SessionObservabilityCommandTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionObservabilityGraphQLTests|GraphQLContractsTests|SurfaceParityDTO'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'LoopConvergenceTrackerTests|DeterministicWorkflowRunnerLoopPolicyTests|DeterministicWorkflowRunnerFanoutTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'AgentGatewayNodeAdapterTests|DistributedWorkerHTTPTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|TaskDispatcherIntegrationTests'\"",
        "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t4/changed-swift.nul",
        "git diff --check"
      ]
    },
    {
      "planId": "workflow-defect-t5",
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "dependsOn": [
        "workflow-defect-t4"
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
      "sharedPaths": [],
      "acceptanceCriteria": [
        "D4/D5 A13-A15 proposals bind source, dependency and review digests and use existing transaction/review authorities.",
        "Only proven formatting equivalence is automatic; stale input, escape, mock failure and recovery leave live bytes unchanged; V5 passes without shell/provider fallback."
      ],
      "verification": [
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowRepairProposalTests|WorkflowSelfImproveVersioningTests|WorkflowStagedVerificationTests|WorkflowDirectoryTransaction'\"",
        "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t5/changed-swift.nul",
        "git diff --check"
      ]
    },
    {
      "planId": "workflow-defect-t6",
      "planPath": "impl-plans/active/workflow-defect-detection-and-repair.md",
      "dependsOn": [
        "workflow-defect-t5"
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
      "sharedPaths": [],
      "acceptanceCriteria": [
        "D6-D9 A1-A16/L1-L8 map to named executable tests; synthetic incident variants isolate route rejection, completed-cycle stall and real permitted retry progress.",
        "V6-V9 and L-V1-L-V5 pass including asserted expected failures, complete evidence and narrow fixture registration; Package.resolved stays unchanged.",
        "Update owned behavior documentation; final independent review, shared indexes and exact-file publication remain later workflow gates, not child completion prerequisites."
      ],
      "verification": [
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'WorkflowDefectIncidentTests|WorkflowDefectIncidentCommandTests'\"",
        "arch -arm64 /bin/zsh -lc 'swift build'",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'RielaCoreTests|RielaCLITests'\"",
        "swiftlint lint --quiet --no-cache",
        "git diff --check",
        ".build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --output json",
        ".build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-stall.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-stall/artifacts --session-store tmp/workflow-defect-implementation/cli-stall/sessions --output json",
        ".build/debug/riela workflow run workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --mock-scenario Tests/RielaCoreTests/Fixtures/workflow-defect-incident/mock-scenario-safe-retry.json --max-steps 53 --artifact-root tmp/workflow-defect-implementation/cli-retry/artifacts --session-store tmp/workflow-defect-implementation/cli-retry/sessions --output json",
        ".build/debug/riela workflow validate workflow-defect-incident --workflow-definition-dir Tests/RielaCoreTests/Fixtures --repair-proposals --output json",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'DeterministicWorkflowRunnerBackendEventTests|RuntimeStoreTests|RuntimeSessionTests|SQLiteRuntimeSchemaMigrationTests|SessionObservabilityTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionCommandJSONLStreamingTests|WorkflowCommandLivePersistenceEventTests|WorkflowCommandProgressHeartbeatTests|SessionObservabilityCommandTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'SessionObservabilityGraphQLTests|GraphQLContractsTests|SurfaceParityDTO'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'LoopConvergenceTrackerTests|DeterministicWorkflowRunnerLoopPolicyTests|DeterministicWorkflowRunnerFanoutTests'\"",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'AgentGatewayNodeAdapterTests|DistributedWorkerHTTPTests'\"",
        "xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/workflow-defect-t6/changed-swift.nul",
        "arch -arm64 /bin/zsh -lc \"swift test --filter 'AdapterUtilitiesTests'\""
      ]
    }
  ],
  "preservedCompletedPaths": [
    "Sources/RielaCore/WorkflowBranchEvaluation.swift",
    "Sources/RielaCore/WorkflowConditionAnalysis.swift",
    "Tests/RielaCoreTests/WorkflowBranchEvaluationTests.swift",
    "Tests/RielaCoreTests/WorkflowConditionAnalysisTests.swift"
  ],
  "serialFinalizerWritePaths": [
    "impl-plans/active/workflow-defect-detection-and-repair-progress.md"
  ]
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

### Preserved bounded reconciliation amendment (already implemented)

The accepted design's three-control table is normative. Fresh-read the dirty T2
source/tests and failed V2 before editing. No T1 rewrite or route-validation bypass.

- `Sources/RielaCore/LoopCompletionReviewRouting.swift`: derive accepted as
  `!needs_replan && !needs_work` for already-recognized completion-review payloads.
  Retain existing decision/goalAchieved precedence, including accepted plus
  goalAchieved=false routing to needs_work. Include accepted in the expected map
  and disagreement/missing-control check, including the old otherwise-correct
  two-control path. Emit the existing reconciliation diagnostic when correcting
  it. A corrected map is idempotent. Non-review input passes through; preserve
  unrelated controls on the existing non-rewrite path, without broad map cleanup.
- `Tests/RielaCoreTests/RuntimePublicationTests.swift`: update the existing failed
  test's exact map to include accepted=false and retain its route and diagnostic
  assertions. Add accepted/needs_work/needs_replan, goal-false precedence,
  missing/contradictory accepted, idempotence and non-review passthrough coverage.
  A missing accepted on otherwise matching needs flags must be exercised. Keep
  existing strict missing/type/conflict/short-circuit and publication-order negatives.
- `Tests/RielaCoreTests/DefaultLoopGuardTests.swift` and
  `Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift`: update
  the existing reconciliation exact-map expectations with accepted=false while
  preserving execution-sequence, terminal routing and diagnostic-count assertions.
  Later T4 edits to these shared paths remain serial after T2 and T3.
- `Tests/RielaAdaptersTests/AdapterUtilitiesTests.swift`: update the existing
  reconciliation exact-map expectation with accepted=false; preserve its diagnostic
  count and adapter normalization behavior. No adapter production change is added.

These T2 ownership entries were already accepted before this continuation.
Preserve the existing task and aggregate allowlists without additions or removals.
Review context includes all five paths; no further ownership approval is needed.
Run V2 and V2b, then changed-file strict lint using a NUL-delimited exact changed
Swift path manifest at `tmp/workflow-defect-implementation/T2/changed-swift.nul`:
`xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/workflow-defect-implementation/T2/changed-swift.nul`.
Run `git diff --check`. Capture complete attempt-specific logs and final exits.
Passing this repair alone does not complete the remaining original T2 obligations
below. Do not rewrite the failed V2 log or claim 25/26 was passing.

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

## T4 — authoritative progress and separate activity in existing runtime paths

Intent: D3/D6/D9, A8–A12/A16 and L1–L8. Requires T3 and native durable evidence;
not P1 implementation. Apply the exact activity ownership, serial waves and tests
below as part of this same task. No model-prose progress, universal retry or new
semantic limit.

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

Intent: D6/D7/D8/D9, A1–A16 and L1–L8. Requires T5 for final integration. Fixture drafting may
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
  examples. D9 adds versioned serialized activity metadata with legacy unknown defaults; no new workflow schema Boolean/limit or SQL table/column migration. Older-binary rollback uses
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

All commands below are FUTURE implementation gates, not tests run in the current Step 4 documentation revision.
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
| V2b | `arch -arm64 /bin/zsh -lc "swift test --filter 'DefaultLoopGuardTests|DeterministicWorkflowRunnerLoopPolicyTests|AdapterUtilitiesTests'"` | Three-control exact maps, loop termination/policy and adapter reconciliation retain behavior; positive test count and exit 0 |
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

- [x] T1: Shared AST/typed lookup implemented; carried-forward V1 6/6 and strict lint evidence valid; final combined review still required.
- [ ] T2: Partial implementation preserved; repaired reconciliation and complete route validation/publication require passing V2/V2b and original acceptance evidence.
- [ ] T3: Bounded routing/SCC/guard analysis and V3 evidence accepted.
- [ ] T4: Persisted authoritative progress plus separate D9 activity/recovery/surfaces; V4 and L-V1–L-V5 evidence accepted.
- [ ] T5: Digest-bound reviewed repair/staged apply and V5 evidence accepted.
- [ ] T6: Original incident matrix plus L1–L8 integration, V6–V9 and L-V1–L-V5, docs, combined review and serial scope reconciliation accepted.

T1 evidence is retained; T2–T6 remain pending. Final completion requires named
acceptance tests, complete logs/exit statuses and no high/mid findings; unknown
historical causality is a residual evidence limitation, not a runtime test pass.
Failures/blocked dependencies remain pending. Shared finalizer may archive only this
plan after every criterion passes; no global plan archiving or unrelated edits.

The serial finalizer appends per-item receipts to the existing manifest progressLogPath. Each
entry records task/attempt, requirement IDs, dependency readiness, immutable intent
path, pre/post hashes, exact changed files/API decisions, command/log/final status,
positive test counts, findings/review disposition and remaining risks. Keep verified
facts separate from hypotheses. Worker does not check boxes in this plan.

### Historical Step 4 author progress, 2026-09-22

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

### Historical Step 4 revision after Step 5, comm-000008

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

## Activity extension: T4/T6 execution contract (current Step 4)

This extension is part of the single existing plan, not a seventh task or a separate
implementation item. Original T1–T6 duties and external readiness gates remain.
The native plan-level item keeps planId `workflow-defect-detection-and-repair`,
`dependsOn: []`, this planPath and the union of manifest writePaths as trackedPaths.
Native `fanout.dependencies` and `fanout.changeTracking` own readiness/change evidence;
acceptedPlanIds may exclude only the whole independently accepted plan, never an
unfinished internal task. Failed review leaves this item pending. A single worker
executes internal waves serially; do not create duplicate plan IDs, inferred native
subtask IDs or another scheduler to parallelize this coupled ownership.

| Internal wave | Prerequisite | Deliverable / evidence |
| --- | --- | --- |
| W1 | Existing output-contract readiness as applicable | T1 → T2 → T3 unchanged, V1–V3 |
| W2 | W1, fresh shared-file hashes | T4 D3/D6 progress first, then D9 DTO/receipt/persistence; V4, L-V1 |
| W3 | W2 durable DTO accepted locally | T4 local gateway normalization, distributed unsupported-freshness handling, classifier and warning-summary preparation; L-V1/L-V2/L-V4/L-V5 for available contracts |
| W4 | W3 classifier contract stable | T4 CLI/GraphQL/library projections and complete-set rollup; complete L-V1–L-V5 privacy/recovery/parity evidence, then switch the existing silence monitor to the authoritative projection and rerun affected L-V1/L-V2 warning cases |
| W5 | T4 W2–W4 complete | T5 repair contract unchanged, V5 |
| W6 | W5 and fixture registration | T6 combined incident/activity matrix and documentation; post-registration V6–V9 and L-V1–L-V5 |

These are dependency-ready execution instructions inside the supported singleton
native branch, not extra dispatchable manifest items. Shared writePaths are safe
because W1–W6 are serial. Dispatch requires current Step 5 acceptance and the
committed/pushed plan checkpoint.
W2/W3 subset results are development evidence, not passes for unfinished L-V gates.
The W4 activation order implements D9.6; no new feature flag or parallel monitor
is required. Do not activate authoritative warnings based only on DTO unit tests.

### T4 exact activity ownership and failure semantics

All paths below are exact manifest entries (full paths in writePaths/reviewContext):

- `Sources/RielaCore/AdapterContracts.swift`: closed activity value and typed optional
  callback on the existing execution context; execution/turn binding private to
  runtime, no generic JSON metadata carrier. `Sources/RielaCore/WorkflowRunEvent.swift`:
  `backend_activity` typed payload and shared summary on warnings. Exhaustive switch
  consumers in authorized CLI/GraphQL files must handle the additive event. Verify
  Codable encode/decode, convenience accessors and event-type switches in
  `WorkflowRunEvent.swift`, `DeterministicWorkflowRunner+Events.swift` and
  `WorkflowRunLivePersistence.swift`; `backend_activity` must never be encoded as
  generic `backend_event`. If another
  consumer requires an edit, record exact path/reason and obtain workflow scope
  reconciliation before dispatch rather than silently broadening authorization.
- `Sources/RielaCore/RuntimeSession.swift`, `RuntimeStore.swift`,
  `WorkflowRuntimePersistenceSnapshot.swift`, `SQLiteWorkflowRuntimePersistenceStore.swift`:
  one <=2KiB activity extension per execution, producer epoch/seen high-water,
  qualifying sequence/latest observation, coverage and terminal fence. Reuse existing
  receipt serialization and durable session/message checkpoint. Persist before emit,
  bypass generic-event throttling, and reject stale/duplicate/cross-execution events
  without refreshing activity. No activity ring or new SQL table/column/version bump.
  Legacy absent metadata is unknown, foreign versions block activity enforcement.
  Do not route activity through content-bearing `recordStepBackendEvent` inputs.
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`: map known ACP discriminators
  at first live ingress, stamp before queues, deliver the content-free callback.
  Current Cursor CLI/SDK use this seam. Do not infer delegation from tool name or
  heartbeat from transport. `Sources/RielaServer/DistributedWorkerEventSender.swift`:
  retain typed sanitized provenance through existing bounded relay, preserving the
  existing lease fence/order/retry behavior; do not turn remote receipt time into
  origin freshness or enable a distributed active claim. No new clock-sync protocol.
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`: collect
  activity even without eventHandler, fence callbacks by running session/execution
  and epoch, emit only accepted receipts, and use shared classifier for warnings.
  Unsupported/process-only activity reports unknown; no-first-event uses owned-start
  waitingAgeMs. Existing warning throttle and explicit request threshold remain.
- `Sources/RielaCLI/WorkflowRunLivePersistence.swift`: activity checkpoint precedes
  JSONL and is not skipped by the one-second generic-event throttle; wire the existing
  durable save path so all entry surfaces agree. Persistence failure/late commit
  cannot appear as a new responsive observation. Terminal flush is ordered with
  callback admission. In-memory library execution explicitly reports memory durability.
- `Sources/RielaCore/SessionObservability.swift`: extend the current classifier and
  reducer per D9.4/D9.5; 30000/180000 boundaries, unknown/first-event/clock failure,
  definitive stalled only with existing runtime timeout evidence, terminal freezing.
  Evaluate all outstanding own/child executions with stable ordering and 256-session,
  1024-execution, depth-32 bounds. Missing/truncated membership defeats healthy aggregate.
- `Sources/RielaCLI/SessionCommands.swift`, `SessionObservabilityRendering.swift`,
  `SessionObservabilityComposition.swift`: shared DTO for status/progress/health,
  text/JSON/JSONL. Remove generic-time/probe authority, label old generic fields.
  `Sources/RielaCLI/RielaLibrary.swift`: use same projection and clock/coverage inputs.
- `Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift`,
  `GraphQLContractProjector+Schema.swift`, `GraphQLSchemaGenerator.swift`,
  `RielaGraphQL.swift`: shared activity record/summary, enums, nullability and source
  identity; update existing embedded schema expectations in owned tests. Never expose
  provider evidence paths/detail or content by projecting generic backend payloads.
- `Sources/RielaCore/LoopConvergenceTracker.swift` and
  `DeterministicWorkflowRunner+LoopPolicy.swift` retain original T4 progress ownership.
  For D9 these are a verification boundary only: no new activity input into semantic
  projection, fingerprints, counters, gate visits, accepted evidence or retry eligibility.

- `Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift`: extend the existing
  production wrapper with the typed activity receipt. Privately stage a candidate,
  commit an activity-only SQLite update with running/epoch/high-water fences,
  then expose it through the backing cache; failed writes never leak candidate state
  through loadSession or later live snapshots. `SQLiteWorkflowRuntimePersistenceStore.swift`
  owns the field-preserving transaction and merge/fence rules for other snapshot
  saves, preventing old snapshots from overwriting newer activity or terminal state.
  CLI/library/GraphQL production paths already construct this wrapper in
  `WorkflowRunCommand.swift` (read-only context), so no new persistence adapter.
- `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift`: content-free accepted
  activity emitter and warning summary. `DeterministicWorkflowRunner+Prompting.swift`
  and existing deadline call sites in `DeterministicWorkflowRunner.swift`: capture
  one effective deadline with the injected clock before invocation, persist it in
  execution activity metadata, retain current timeout precedence on recovery.
  `DeterministicWorkflowRunner+Cancellation.swift`: expose only existing typed timeout
  ownership/source for classification, not raw exception prose or a new timeout policy.
  Extend L-V1/L-V2 tests with failed-write cache isolation, stale snapshot after
  terminal, concurrent semantic save, captured deadline and resume invariants.
  Production-wrapper failure tests belong to
  `Tests/RielaCLITests/WorkflowCommandLivePersistenceEventTests.swift` (L-V2),
  which can exercise the CLI-owned wrapper; Core tests alone cannot establish this
  boundary. Use the existing injected writer/failpoint and assert both immediate
  loadSession and a later unrelated save after failure.

Use the current implementations at dispatch time: no new persistence layer or gateway
client abstraction. Production durability comes from the existing fail-closed wrapper,
not from event-handler success. Any necessary
new exact file must be reconciled in the plan before editing; directory-wide scope
and speculative supporting modules are not authorized.

### Test ownership and acceptance

| Exact test ownership (manifest paths) | Required assertions |
| --- | --- |
| `Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift` | Known ACP discriminator -> sanitized kind; thought/tool content discarded from activity, silent assistant with ongoing tool/thought input, unmapped/transport/process input never qualifies |
| `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift` | Relay order/lease/retries remain; remote freshness unverified, no false active, no raw activity payload expansion |
| `Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift` | No-handler collection, warning suppression on qualifying traffic, stale/old-epoch/post-terminal events rejected, no fabricated delegation/heartbeat, first-event baseline |
| `Tests/RielaCoreTests/RuntimeStoreTests.swift`, `RuntimeSessionTests.swift`, `SQLiteRuntimeSchemaMigrationTests.swift` | Sequence/epoch round trip, 2KiB bound, seen-vs-accepted high-water, duplicate/delayed/reordered/wrong execution rejection, commit failure, crash before/after commit/emit, retry/new execution, legacy/unknown-version migration and terminal freeze |
| `Tests/RielaCoreTests/SessionObservabilityTests.swift` | Injected time at 30000/30001/180000/180001, deadline authority, dropped input, partial/process-only evidence, backwards/forward clock cases, active sibling with overdue child, bounds/cycles/missing membership |
| `Tests/RielaCLITests/SessionCommandJSONLStreamingTests.swift`, `WorkflowCommandLivePersistenceEventTests.swift`, `WorkflowCommandProgressHeartbeatTests.swift`, `SessionObservabilityCommandTests.swift` | Exact shared fields on status/progress/health, JSON/JSONL ordering/reconciliation, durable receipt despite throttle, no heartbeat-as-progress, fixed reasons/privacy and unknown nulls |
| `Tests/RielaGraphQLTests/SessionObservabilityGraphQLTests.swift`, `GraphQLContractsTests.swift`, `SurfaceParityDTOSchemaTests.swift` | Same fixed session snapshot/evaluation time as CLI/library produces equal fields, typed stalled/terminal and no sensitive generic evidence projection |
| `Tests/RielaCoreTests/LoopConvergenceTrackerTests.swift`, `DeterministicWorkflowRunnerLoopPolicyTests.swift`, `DeterministicWorkflowRunnerFanoutTests.swift` | Activity-only changes leave projection/fingerprint/counters/visits/retry decisions identical; real accepted semantic change still works; child provenance and oldest outstanding blocker retained |

Use deterministic fake producers and clocks; do not sleep to cross thresholds or
claim an absent Codex fixture was exercised. Insert distinct secret sentinels into
all forbidden payload categories, then inspect new activity JSONL, SQLite session
record, snapshot, warning diagnostics and CLI/GraphQL/library DTOs. This must test
negative sinks as well as decoding the new struct. Existing generic assistant output
is not a privacy failure unless this activity path newly captures/exposes it.

The following edge cases are required parts of those suites, not additional tasks:

- L-V1 store/runner tests admit total ingress-to-commit delay 5000ms and reject
  5001ms; use injected ticks for admission plus commit delay. Reject ingress
  before epoch start or previous accepted ingress, but accept same-millisecond
  observations with increasing producer sequence. A recognized stale sequence
  advances seen high-water only; later fresh activity cannot erase interrupted coverage.
  Test invalid/oversize identities without truncation, foreign versions, epoch
  reattachment and durable sequence continuation; retry gets its own execution.
- L-V1 classifier tests cover wall/monotonic disagreement at 5000/5001ms,
  backward time against observation/checkpoint, cross-restart forward jumps,
  fresh-epoch recovery and immutable checkpoint timestamps on repeated queries.
  Silence alone never creates definitive stalled; test a correlated owner timeout,
  timeout invalidation through owner fencing, and direct terminal timeout precedence.
- L-V1/L-V4 reducer tests cover independent parent and child activity, structural
  parents, queued `unknown/not-started`, `quiet/authorized-wait`, duplicate ownership,
  snapshot revision drift and exact limits plus one for 256 sessions, 1024 executions
  and depth 32. Assert stable blocker order, known/omitted counts, partial coverage,
  worstKnownVerdict and terminal-root/unresolved-child behavior across surfaces.
- L-V2 wrapper tests inject failure before commit, crash after commit before emit,
  concurrent semantic save and delayed save after terminal. Assert no candidate leak,
  no lost accepted output/message ordering, no emitted failed receipt, frozen terminal
  age and durable recovery without a JSONL line. Memory-only library runs explicitly
  report memory durability; CLI handler absence cannot disable durable collection.
- L-V3 compares every D9.5 field and null against the same persisted snapshot and
  injected evaluation time for CLI status/progress/health and GraphQL/library DTOs;
  L-V2 supplies JSONL/warning parity. L-V4 interleaves activity between otherwise
  identical completed semantic cycles and asserts byte-equal projections/fingerprints,
  unchanged counters/gate visits/retry eligibility and unchanged limit enforcement.

T6 owns adding L1–L8 references to the original fixture EXPECTED_RESULTS.md and
integrated Core/CLI fixture tests already in its manifest, reusing focused T4 tests
where sufficient. Keep original A1–A16 assertions intact. Update existing owned
docs/output-contracts.md and design-riela-workflow-internals.md with activity vs
progress, supported/unsupported producers and warning/terminal semantics. README
examples and final design/plan status belong to serial finalization. No UI work,
provider network fixture, installed package change or digest refresh is required
by this documentation-only revision.

### Additional future verification commands

Run from the active repository checkout root in the foreground. Write complete stdout,
stderr, exact command, reviewed tree/fixture hashes, positive selected-test counts
and terminal exit code to
`tmp/workflow-defect-implementation/verification/<attempt>/<ID>.log`. Preserve failed
attempts; retain and poll any returned session handle through terminal exit. A
truncated log, zero selected tests or unobserved exit is not passing evidence.

| ID | Exact command | Acceptance |
| --- | --- | --- |
| L-V1 | `arch -arm64 /bin/zsh -lc "swift test --filter 'DeterministicWorkflowRunnerBackendEventTests|RuntimeStoreTests|RuntimeSessionTests|SQLiteRuntimeSchemaMigrationTests|SessionObservabilityTests'"` | L1–L4/L6: ingress, ordering, migration, recovery, classification/privacy |
| L-V2 | `arch -arm64 /bin/zsh -lc "swift test --filter 'SessionCommandJSONLStreamingTests|WorkflowCommandLivePersistenceEventTests|WorkflowCommandProgressHeartbeatTests|SessionObservabilityCommandTests'"` | L2/L3/L5: privacy, durable JSONL, warnings and surfaces |
| L-V3 | `arch -arm64 /bin/zsh -lc "swift test --filter 'SessionObservabilityGraphQLTests|GraphQLContractsTests|SurfaceParityDTO'"` | L5: CLI/GraphQL/library equality and schema/nullability |
| L-V4 | `arch -arm64 /bin/zsh -lc "swift test --filter 'LoopConvergenceTrackerTests|DeterministicWorkflowRunnerLoopPolicyTests|DeterministicWorkflowRunnerFanoutTests'"` | L6/L7: mixed child rollup, no semantic counter changes |
| L-V5 | `arch -arm64 /bin/zsh -lc "swift test --filter 'AgentGatewayNodeAdapterTests|DistributedWorkerHTTPTests'"` | L1/L2: adapter mapping/privacy and unsupported remote freshness |

Also run original V7a `arch -arm64 /bin/zsh -lc 'swift build'`, V7c
`swiftlint lint --quiet --no-cache`, V7d `git diff --check`, and all original
required V1–V9 gates. These are future implementation verification, not claimed
passes from this planning turn. The historical activity Step 4 author check was
`python3 tmp/backend-activity-plan/verify.py`, complete log
`tmp/backend-activity-plan/verification.log`; it checks the accepted design digest,
manifest ownership/dependencies, six preserved unchecked tasks, documentation scope,
package identity and whitespace. Independent Step 5 review is still required.

## Historical activity Step 4 author self-check and handoff (2026-09-22)

Only this plan is edited by this node. Fresh baseline and immutable intent are in
`tmp/backend-activity-plan/intent.json`; pre-edit plan/design copies are alongside it.
The verifier records the final plan hash and proves the accepted design and all
other tracked working-tree changes remain byte-for-byte unchanged. Preserve the
complete log through Step 5; finalization removes task scratch after the owning
workflow archives its evidence. No runtime tests, implementation, commit or push
are claimed by this node.

Author review maps D1–D9/A1–A16/L1–L8 to T1–T6 and V1–V9/L-V1–L-V5. One stable
plan ID with serial tasks retains the accepted decomposition; no independent edit
fanout is justified. Every task has exact ownership, deliverables, dependency and
acceptance evidence; shared indexes, lockfiles, broad formatting and archiving
remain serial finalization responsibilities. The worker owns only its progress log.

Resolved author findings: stale current review provenance (mid); warning activation
before privacy/recovery/parity gates (mid); production-wrapper failure-test ownership
needed explicit CLI placement (mid). Added deterministic boundary cases to make the
existing D9 requirements executable without inferred test scope. No design change or
unsupported architecture was needed. Historical Step 5 Package.swift ownership
remains fixed. Step 5 independent acceptance is pending, not an author claim.

Run `python3 tmp/backend-activity-plan/verify.py` and require terminal exit 0 plus
`FINAL_EXIT_STATUS 0` in the complete log before handing off. Future Swift build,
tests and SwiftLint remain required implementation gates. The missing Codex source,
pre-ingress provider buffering and unverified distributed freshness remain accepted
evidence/capability limits; they do not authorize broader producer claims.
