# ISW-104: bind protected git finalization evidence on step rerun

**Status**: Ready (wave 2)
**planId**: ISW-104-rerun-finalization-evidence
**Issue**: https://github.com/tacogips/riela/issues/104
**Design Reference**: design-docs/specs/design-rerun-input-carryover-and-finalization-evidence.md (D3, including the trace table)
**dependsOn**: ISW-135-retry-timeout-rerun-carryover (wave 1). Start only after it is complete. Both edit `DeterministicWorkflowRunner+Recovery.swift`, `DeterministicWorkflowRunner+RerunCarryover.swift` and `docs/preserved-history-recovery.md`.
**Created**: 2026-10-24

## Intent and context

The protected workflow `codex-design-and-implement-review-loop` validates its
terminal `workflow-output` against the session's accepted git evidence
(`validateGitFinalizationEvidence` and `expectedGitFinalizationMode` in
`Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`).

A step rerun session lacks the source's accepted plan, commit, push,
integration and mode evidence. It therefore fails late, after agents run,
with "authoritative workflow mode evidence is missing" or "required accepted
step evidence is missing". This plan adds a preflight that does one of two
things:

- binds the latest accepted source evidence (imported via ISW-135's import
  path), or
- rejects before any session is created, with a recovery message.

## Non-goals

- Do not change the semantics of `validateGitFinalizationEvidence`,
  `expectedGitFinalizationMode`, `gitFinalizationEvidencePolicy`,
  `requiresGitFinalizationEvidence` or `gitFinalizationPromptEvidence`. A
  visibility change from `private` to internal is allowed; see below.
- No new CLI, request or GraphQL fields and no store tables.
- No change to unprotected workflows. When the policy is nil, the new code
  is a no-op.

## Write ownership

writePaths (owned only by this plan):

- `Sources/RielaCore/DeterministicWorkflowRunner+RerunFinalizationEvidence.swift` (new)
- `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+History.swift`
- `Tests/RielaCoreTests/WorkflowRerunFinalizationEvidenceTests.swift` (new)
- `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift`
- `Tests/RielaCoreTests/WorkflowPreservedHistoryTests.swift`
- `impl-plans/progress/issue-sweep-20261024-104-rerun-finalization-evidence.md`

sharedPaths (first written by ISW-135; edit only after ISW-135 completes):

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`: merge bound
  evidence executions into the rerun import, and call the check on the
  preserve-history path.
- `Sources/RielaCore/DeterministicWorkflowRunner+RerunCarryover.swift`: only
  if a small helper for merging or deduplicating import executions is needed.
  The `rerunCarriedInbox` signature must not change.
- `docs/preserved-history-recovery.md`: append a "Protected finalization
  evidence" paragraph.

## Contract (pin exactly)

In the new file, add an `extension DeterministicWorkflowRunner` with:

```swift
static func rerunFinalizationEvidenceExecutions(
  workflow: WorkflowDefinition, source: WorkflowSession,
  targetStepId: String, available: [WorkflowStepExecution]
) throws -> [WorkflowStepExecution]
```

- `available` is `source.executions` for a plain rerun, or the
  preserved-prefix executions for a preserve-history rerun.
- It returns the canonical source executions to bind, in source order.
- It returns `[]` when `workflow.steps` has no `workflow-output` step or
  `gitFinalizationEvidencePolicy(workflow:terminalStep:)` is nil.
- It throws `DeterministicWorkflowRunnerError.rerunValidation(...)` on a
  completeness failure.
- It is a pure static function and must not touch the store.

## Algorithm (from D3; implement exactly)

**Graph edges.** For each step, the edges are:

- `transitions[].toStepId` when `toWorkflowId == nil`;
- `transitions[].resumeStepId` when `toWorkflowId != nil`;
- `transitions[].fanout?.joinStepId`.

**Sets and predicates.**

- **R** is the target plus every step reachable from it (BFS).
- **Planning routes** are transitions from a `policy.planningModeStepIds` step
  to a commit-preparation step (a step with a transition to
  `policy.commitStepId`) whose `label?.contains("planning_only") == true`. Use
  exactly the edge test in `gitFinalizationEvidencePolicy` (lines ~142-151).
  Do not drop other labeled edges. `!(planning_only || ...)` edges stay.
- **Guaranteed(S, filtered)** holds when `S == target`, or when `S` is
  reachable from the target and `workflow-output` is unreachable from the
  target in the graph with node `S` removed. `filtered` additionally removes
  the planning routes. Use `filtered` only for `planCommitStepId` and
  `planPushStepId`.
- **Bindable(S)** holds when `available.last { $0.stepId == S }` exists, has
  `status == .completed` and has `acceptedOutput != nil`.

**Classes.**

- Mode steps are `implementationReviewStepId?`, `"step6-implement"` and
  `planningModeStepIds`.
- Git steps are `commitStepId`, `pushStepId`, `integrationStepId?`,
  `planCommitStepId?` and `planPushStepId?`.

**Binding.**

- For each mode step not in R that is Bindable, bind its latest execution.
- For each git step that is Bindable, bind its latest execution, whether or
  not it is in R.

**Preflight rules, in order.** Collect the failing step ids, then throw once:

1. A mode step not in R has any execution in `available` but is not Bindable.
2. No mode step is in R, and `expectedGitFinalizationMode` throws on a
   session built from the bound mode executions.
3. `commitStepId`, `pushStepId` or `integrationStepId` is neither Bindable
   nor Guaranteed (unfiltered).
4. `planCommitStepId` or `planPushStepId` is neither Bindable nor Guaranteed
   (filtered), and either some mode step is in R or the derived mode is
   issue-resolution.

**Rejection message.** Use exactly:
`"cannot rerun <target>: protected git finalization evidence for <comma-joined ids> is not bound in the source session; rerun from <first failing id in workflow.steps order> or use session resume --retry-failed-step"`.

**Visibility.** Rules 2 and 4 need `expectedGitFinalizationMode` and
`WorkflowGitFinalizationMode`. Change only their `private` visibility to
internal (file-external), with no other edit to that file.

## Recovery.swift integration

- **Plain rerun.** After the D2 source-status check and before
  `createSession`:
  1. `let carried = try await rerunCarriedInbox(...)`.
  2. `let bound = try Self.rerunFinalizationEvidenceExecutions(workflow: request.workflow, source: sourceSession, targetStepId: entryStepId, available: sourceSession.executions)`.
  3. When either is non-empty, build one `WorkflowHistoryImportInput`:
     - executions: the union of `carried?.executions` and `bound`,
       deduplicated by `executionId` and ordered by index in
       `sourceSession.executions`;
     - messages: `carried?.messages ?? []`.
- **Preserve-history.** After `preservedHistory(...)` returns, call
  `rerunFinalizationEvidenceExecutions(..., available: history.executions)`
  for the check only. Discard the result; the prefix already holds the
  evidence.
- **`DeterministicWorkflowRunner+History.swift`.** For the
  `reject("ambiguous repeated or non-accepted step boundary")` case only,
  append `"; rerun without --preserve-history or use session resume --retry-failed-step"`.

## Invariants

- Imported evidence precedes newly executed records, so re-executed evidence
  supersedes it through `last(where:)`.
- Reachable mode steps are never bound. A full restart must not inherit a
  stale mode.
- A rejection creates no session and invokes no adapter.
- Unprotected workflows behave exactly as after ISW-135.

## Pitfalls

- BFS over `resumeStepId` and `joinStepId` as well as `toStepId`. Missing
  `joinStepId` breaks fanout topologies.
- The dominance test must remove the node, not just its outgoing edges. When
  the target is S itself, S is Guaranteed.
- Never use a substring filter over all labels; see the design finding
  DR3-D3-GUARANTEED-PLANNING-ONLY-FILTER.
- Pass canonical source execution structs into the import. The importer
  rejects altered copies.
- Do not bind `step6-implement` fanout children individually. Use only the
  latest execution with that step id.

## Tests (`Tests/RielaCoreTests/WorkflowRerunFinalizationEvidenceTests.swift`, new)

**Topology fixture.** Build a protected topology `WorkflowDefinition` in code,
with `workflowId` `"codex-design-and-implement-review-loop"`. Its
`riela/git-commit@1` and `riela/git-push@1` addon nodes are `step10-git-commit`,
`step11-git-push`, `plan-git-commit` and `plan-git-push`, and it must satisfy
`gitFinalizationEvidencePolicy`. Imitate
`Tests/RielaCoreTests/WorkflowModelTests.swift:testProtectedGitFinalizationPolicyAcceptsOnlyCheckpointPushChain`.
The edges are:

- step1 → step4;
- step4 → step5;
- step5 → step2 (`needs_design_revision`), step4
  (`needs_revision && !(needs_design_revision)`), step9-commit-message
  (`planning_only && !(needs_design_revision || needs_revision)`), and
  plan-checkpoint (`!(planning_only || needs_design_revision || needs_revision)`);
- step2 → step4;
- plan-checkpoint → plan-contract-validate → {plan-git-commit, step4};
- plan-git-commit → plan-git-push → dispatch-plans (fanout step6-implement,
  join reconcile-implementations);
- reconcile-implementations → integration-review → {dispatch-plans
  (`plans_remaining`), runtime-tracking-contract-check};
- runtime-tracking-contract-check → {step4 (`tracking_contract_rejected`),
  step8};
- step8 → step9 → step10 → step11 → base-branch-integrate → workflow-output.

Assert first that `policy.planCommitStepId`, `planPushStepId` and
`integrationStepId` are as expected. Source executions use the
`execution(...)` helper pattern from `WorkflowGitFinalizationEvidenceTests`.

| Situation (issue-resolution source, all evidence accepted unless stated) | Expected outcome |
| --- | --- |
| target `dispatch-plans` | binds plan-git-commit, plan-git-push, step10, step11 and base-branch-integrate; binds no mode step |
| target `integration-review`, `reconcile-implementations` | same binding; no throw |
| target `workflow-output`, step10 history `[failed, completed]` | binds the completed step10 retry plus the mode steps (integration-review, step6-implement) |
| target `step10-git-commit` | binds mode and plan evidence; no throw |
| latest plan-git-commit failed; target `dispatch-plans` | throws; message names `plan-git-commit` |
| latest plan-git-commit failed, and the fixture has no accepted plan-git-push (the source failed at plan-git-commit); target `step4-impl-plan-create` and `step1-issue-intake` | no throw; plan-git-commit is not bound (it is Guaranteed); the result contains no plan-step execution |
| latest integration-review failed; target `workflow-output` | throws (rule 1) |
| target `step1-issue-intake` | binds no mode step (stale-mode safeguard) |
| filter unit check | in the filtered graph, step5 → plan-checkpoint is kept and step5 → step9-commit-message is removed (assert via `Guaranteed(plan-git-commit)` from step5 = true) |
| unprotected workflow (different workflowId) | returns `[]` |

**Validator round trip.** For the dispatch-plans and integration-review
targets:

- build a session of the bound executions followed by simulated re-executed
  completed executions of the tail (step6 through base-branch-integrate)
  carrying consistent hashes;
- run `validateGitFinalizationEvidence` with the derived policy and a
  matching final payload, imitating `makeContext` in
  `WorkflowGitFinalizationEvidenceTests`;
- it must not throw.

**Runner level** (one test, seeding the source via
`InMemoryWorkflowRuntimeStore` APIs `createSession`, `recordStepExecution` and
`updateStepExecution` with `acceptedOutput`; the source fails at
`workflow-output`):

- a plain rerun of `workflow-output`, with a `StaticAdapter` returning a
  payload that matches the evidence, completes;
- with the latest `integration-review` failed, the run throws
  `rerunValidation`, the store holds no new session, and the adapter was never
  invoked.

**`WorkflowPreservedHistoryTests`.** Add one case: a sequential source with a
failed-then-retried prefix step, rerun with `--preserve-history`, imports the
completed retry, and preflight passes. Also assert the new recovery-hint
suffix on a repeated-boundary rejection.

## Verification commands

Run from the repository root. Logs go under
`tmp/issue-sweep-20261024/ISW-104/`, each ending with an `exitStatus=$?` line:

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-104/build.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowRerunFinalizationEvidenceTests > tmp/issue-sweep-20261024/ISW-104/rerun-evidence.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/rerun-evidence.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGitFinalizationEvidenceTests > tmp/issue-sweep-20261024/ISW-104/git-evidence.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/git-evidence.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowPreservedHistoryTests > tmp/issue-sweep-20261024/ISW-104/preserved.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/preserved.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowRerunInputCarryoverTests|DeterministicWorkflowRunnerFailureStateTests|DeterministicWorkflowRunnerTests|WorkflowModelTests" > tmp/issue-sweep-20261024/ISW-104/regression.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/regression.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DeterministicWorkflowRunner+RerunFinalizationEvidence.swift Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift Sources/RielaCore/DeterministicWorkflowRunner+History.swift Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift Tests/RielaCoreTests/WorkflowRerunFinalizationEvidenceTests.swift > tmp/issue-sweep-20261024/ISW-104/lint.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-104/lint.log'
```

Each command must show exitStatus 0. Every test filter must show testsRun > 0
and failureCount 0.

## Edit discipline

Apply the common rules:

- fresh read and pre/post `shasum -a 256` for every edit;
- on drift, stop, re-read, and re-apply the recorded intent only;
- do not edit outside writePaths and sharedPaths;
- run no index- or worktree-changing git commands.

In addition, before editing a sharedPath, confirm that ISW-135's progress log
shows it complete. Record the shared file's hash before your first edit.

## Completion criteria

- [ ] The contract function exists with the pinned signature and is wired
      into both rerun paths.
- [ ] Every test table row passes, plus the validator round trip and the
      runner-level test.
- [ ] Visibility is the only change in the GitFinalizationEvidence file
      (check with `git diff`).
- [ ] `docs/preserved-history-recovery.md` documents the D3 binding rule and
      the recovery message.
- [ ] All verification commands exit 0, with the integer fields recorded.

## Progress log expectations

`impl-plans/progress/issue-sweep-20261024-104-rerun-finalization-evidence.md`
records hashes (including the sharedPath pre-edit hashes), commands, integer
fields, log paths and any drift.
