# Rerun input carry-over, timeout retry and finalization evidence (#135, #104)

Issues: https://github.com/tacogips/riela/issues/135,
https://github.com/tacogips/riela/issues/104

Baseline: `docs/preserved-history-recovery.md` (preserve-history import) and
the runtime-owned import path `importAcceptedHistory`
(`Sources/RielaCore/RuntimeHistoryImport.swift`). This design reuses that
import path. It does not add a second lineage mechanism.

## Current behavior (verified in source)

- `resolveResumeEntry` (`DeterministicWorkflowRunner+Recovery.swift`) accepts
  `--retry-failed-step` only for `failureKind` `adapterFailure` or
  `policyBlocked`. An `AdapterExecutionError(.timeout)` is classified as
  `nodeTimeout` (`DeterministicWorkflowRunner+Cancellation.swift`), so a
  timed-out step cannot be retried. The CLI hint in
  `SessionCommands.nonBudgetFailureResumeMessage` mirrors the same two kinds.
- Without `--preserve-history`, `resolveRerunEntry` creates an empty session.
  `DefaultWorkflowMessageInputResolver` therefore finds no inbox for the rerun
  target. A command target such as `dispatch-plans` fails with "requires exactly
  one checkpoint commit or push message".
- The protected finalization validator
  (`DeterministicWorkflowRunner+GitFinalizationEvidence.swift`) reads
  `session.executions`. In a plain rerun session, prior accepted steps
  (`integration-review`, `step6-implement`, `plan-git-*`) are absent. The
  `workflow-output` step therefore fails late, after its agent ran, with
  "authoritative workflow mode evidence is missing".

## Decisions

### D1. `--retry-failed-step` accepts `nodeTimeout` (#135)

The retryable kinds become `adapterFailure`, `policyBlocked` and `nodeTimeout`.
All other guards stay:

- the session is failed;
- the last execution is the failed current step;
- that execution has no `acceptedOutput` and no `pendingRoutePublication`.

The error text and the CLI hint name all three kinds. Retrying a timed-out step
is an explicit operator opt-in. It does not deduplicate side effects (same note
as the preserve-history doc).

### D2. A plain step rerun carries the target's recorded inbox (#135)

For `session rerun SID STEP` without `--preserve-history`, preflight selects
the carried inbox before creating the new session:

1. Let `T` be the latest source execution of `STEP`. This is the execution that
   `rerunRecoveryLineage.sourceStepExecutionId` already names. If the target
   never executed, nothing is carried and the rerun starts with fresh input,
   as today.
2. Read the communication ids recorded in
   `T.inputSnapshot.mergedVariables._rielaInput.communicationIds`. If `T` has
   no recorded `_rielaInput` (its input was never resolved), nothing is
   carried. For each id,
   the source message must exist, be addressed to `STEP`, have `routingScope`
   `workflow` and be resolvable (`delivered` or `consumed`).
3. Carry only messages whose `sourceStepExecutionId` is a source execution with
   status `completed` and an `acceptedOutput`. Messages from non-execution
   producers are not carried. These are manager, handover or event injections,
   not accepted upstream outputs.
4. If an id from step 2 is missing, or fails its checks, reject in preflight:
   `rerunValidation("cannot carry rerun input: recorded inbox communication <id> is missing or unaccepted; use --preserve-history or rerun an earlier step")`.
   No session is created.
5. Import the producing executions and the carried messages with
   `importAcceptedHistory`. Imported records keep the existing semantics:
   - new execution and communication ids, with `importedFrom` mapping back to
     the source;
   - no backend events, usage, adapter output or finalization tokens;
   - they do not count as new executions (`newExecutionCount`).

   The target then resolves `_rielaInput` from the imported messages, which
   carry their new identities.

Source status: carrying requires the source to be `failed`, `suspended` or
`completed`. The session-source guard in both
`InMemoryWorkflowRuntimeStore.importAcceptedHistory` and the
`FailClosedSQLiteWorkflowRuntimeStore` pass-through accepts `completed` in
addition to `failed`/`suspended`. The preserve-history and handover callers
keep their own stricter checks: preserve-history still requires `failed`. A
rerun from a `created` or `running` source is rejected in preflight with
"rerun source session must be failed, suspended or completed".

With `--preserve-history`, the existing prefix import already contains the
target inbox, so D2 does not apply.

### D3. Finalization evidence binding for protected workflows (#104)

D3 applies only when `gitFinalizationEvidencePolicy(workflow:terminalStep:)`
resolves a policy for the workflow's terminal `workflow-output` step. The
predicate is unchanged.

Evidence steps fall into two classes, read from the resolved policy:

- **Mode-determining:** `implementationReviewStepId?`, `step6-implement` and
  `planningModeStepIds`. `expectedGitFinalizationMode` reads them with
  `contains(where:)`, so an imported stale execution could change the mode.
- **Git evidence:** `commitStepId`, `pushStepId`, `integrationStepId?`,
  `planCommitStepId?` and `planPushStepId?`. The validator reads them only with
  `acceptedPayload` (`executions.last(where:)`). Plan evidence is read only in
  issue-resolution mode.

Graph terms (static, over `request.workflow`; edges are
`transitions[].toStepId` when `toWorkflowId` is nil, `resumeStepId` for
cross-workflow transitions and `fanout.joinStepId`):

- **Re-executed set R:** the rerun target plus every step reachable from it.
- **Guaranteed(S):** `S` is the target; or `S` is reachable from the target and
  `workflow-output` is unreachable from the target once `S` is removed (every
  path passes through `S`). For plan evidence, first remove only the policy's
  own planning routes, then compute dominance. A planning route is a
  transition that starts at a `planningModeStepIds` step, ends at a
  commit-preparation step (a step that transitions to `commitStepId`) and has
  a `label` containing `planning_only`. This is the same edge test
  `gitFinalizationEvidencePolicy` uses to derive `planningModeStepIds`.
  Planning routes lead to design-plan-only mode, where plan evidence is not
  read.

  Other labeled edges stay, even when their label mentions `planning_only`.
  For example, `step5-impl-plan-review` -> `plan-checkpoint` is labeled
  `!(planning_only || needs_design_revision || needs_revision)` and stays, and
  so does `step5-feature-plan-join` -> `step6-implement` (`!(planning_only)`).
  In the protected topology, this removes only `step5-impl-plan-review` ->
  `step9-commit-message`, plus `step5-feature-plan-join` ->
  `step9-commit-message` where that edge exists.
- **Bindable(S):** the latest source execution of `S` is `completed` with an
  `acceptedOutput` ("latest accepted attempt wins"). A failed attempt followed
  by a successful retry binds the retry. A success followed by a later failure
  is not bindable.

Rules:

- **Mode-determining binding.** Bind a mode-determining step only when it is
  outside R and Bindable. A reachable mode step is never bound. This is the
  full-restart stale-mode safeguard: a rerun from `step1` that ends in
  planning-only mode must not inherit `integration-review` or
  `step6-implement` from the source.
- **Git-evidence binding.** Bind every Bindable git-evidence step, whether or
  not it is in R. This is safe because:
  - imported executions precede new ones in `session.executions`, so a
    re-executed commit, push, integration or plan step supersedes the bound
    one through `last(where:)`;
  - a bound plan step not re-executed on a planning-only run is never read,
    because plan evidence is read only in issue-resolution mode.

  This covers the loop back-edges in the protected topology
  (`runtime-tracking-contract-check` -(tracking_contract_rejected)->
  `step4-impl-plan-create`, and the `needs_revision`/`plans_remaining`
  routes). Those edges make `plan-git-commit` and `plan-git-push` reachable
  from mid-pipeline targets without re-running them on the accepted path.
- **Import.** Bound executions join the D2 import, deduplicated by source
  execution id (for example, `plan-git-push` is also the `dispatch-plans`
  inbox producer). Bound executions are not attached to any message.
- **Preflight completeness.** Checks run before the session is created; any
  failure rejects:
  1. A mode-determining step outside R that has source executions but is not
     Bindable. This prevents a failed `integration-review` from being silently
     dropped so the mode falls through to `step6-implement`.
  2. No mode-determining step is in R, and `expectedGitFinalizationMode`
     cannot be derived from the bound mode executions.
  3. `commitStepId`, `pushStepId` or `integrationStepId` is neither Bindable
     nor Guaranteed. Because the policy requires the linear
     commit→push→[integrate]→`workflow-output` chain, these are Guaranteed
     whenever they are reachable.
  4. `planCommitStepId` or `planPushStepId` is neither Bindable nor
     Guaranteed, and the mode is issue-resolution or not statically
     derivable (some mode step is in R). Once planning routes are removed,
     plan evidence is Guaranteed for every target whose remaining paths to
     `workflow-output` all pass through the plan chain. In the protected
     topology, both plan steps are Guaranteed for these targets:
     `step1-issue-intake` through `step5-impl-plan-review`, `plan-checkpoint`,
     `plan-contract-validate` and `plan-git-commit`. For a `plan-git-push`
     target, only `plan-git-push` is Guaranteed, so `plan-git-commit` must be
     Bindable. Targets downstream of `plan-git-push` reach the chain only
     through back-edges and never have Guaranteed plan evidence.

  The rejection is
  `rerunValidation("cannot rerun <step>: protected git finalization evidence for <stepIds> is not bound in the source session; rerun from <first unbound evidence step> or use session resume --retry-failed-step")`.
  "First" means the first of those steps in `workflow.steps` order. Rerunning
  from that step makes it Guaranteed.
- **Protected-topology traces** (`codex-design-and-implement-review-loop`,
  issue-resolution source with accepted plan and final git evidence):

  | Rerun target | Mode steps | Plan evidence | commit/push/integrate | Result |
  | --- | --- | --- | --- | --- |
  | `dispatch-plans` | `step6-implement` and `integration-review` in R, re-executed | in R only through back-edges, not Guaranteed → bound | Guaranteed; source copy superseded | passes; rejected in preflight if latest `plan-git-commit` not accepted |
  | `reconcile-implementations`, `integration-review` | in R (`plans_remaining` back-edge reaches `step6-implement`) | bound | Guaranteed | passes; same plan rejection |
  | `step7b-e2e-evidence` | same as above; a multi-branch fanout target is rejected first by `describeAmbiguousFanoutBranchRerunTarget` | bound | Guaranteed | passes or the existing fanout rejection |
  | `step10-git-commit`, `workflow-output` | outside R → bound (rule 1 rejects a non-bindable review) | outside R → bound | commit Guaranteed for `step10`; for `workflow-output`, bound or rejected | passes or preflight rejection |
  | `step4-impl-plan-create`, `step5-impl-plan-review`, `plan-checkpoint`, `plan-contract-validate` | in R, never bound | Guaranteed (planning routes removed; every remaining path traverses `plan-git-commit` -> `plan-git-push`); source copy bound when Bindable, superseded on re-execution | Guaranteed | passes even when the source's latest `plan-git-commit` failed |
  | `step1-issue-intake` | in R, never bound | Guaranteed (planning routes removed) | Guaranteed | passes even when the source's latest `plan-git-commit` failed; no stale mode |
- **With `--preserve-history`.** The preserved prefix is the evidence source.
  No extra executions are imported. The same completeness check runs against
  the prefix. A preserve-history rejection caused by a repeated or non-accepted
  boundary adds a recovery hint: rerun without `--preserve-history` (D2 + D3)
  or resume with `--retry-failed-step`.
- **Unchanged.** The validator itself (`validateGitFinalizationEvidence`) and
  the prompt evidence supplement are unchanged. Both already use
  `executions.last(where:)`, and imported executions precede new ones, so
  re-executed evidence supersedes bound evidence.

## Boundaries

- The runtime store still owns every identity. Imported records are evidence.
  They are never re-dispatched, and they never republish routes.
- No new CLI flag, request field or GraphQL field is added.
  `inputReusePolicy: "source-session"` in rerun lineage now matches behavior.
- Fanout-branch rerun ambiguity (`describeAmbiguousFanoutBranchRerunTarget`) is
  unchanged and still rejected first.
- Implementation order: the D1 + D2 plan (#135) lands before the D3 plan
  (#104). Both edit `DeterministicWorkflowRunner+Recovery.swift`, so they must
  not run concurrently.

## Documentation

`docs/preserved-history-recovery.md` replaces "Ordinary rerun without the flag
still starts with fresh input" with D2. It adds a "Protected finalization
evidence" paragraph covering the D3 binding rule and its preflight recovery
message, and it names `nodeTimeout` in the retry guidance.

## Acceptance evidence

- `--filter DeterministicWorkflowRunnerFailureStateTests` (or the suite that
  holds the retry tests): a session failed with `nodeTimeout` at its current
  step resumes with `retryFailedStep: true`. A `nodeTimeout` step that has
  accepted output is still rejected.
- `--filter SessionAddonRecoveryTests`: CLI rerun of `dispatch-plans`-style
  command targets.
- Rerun carry-over test: the source runs plan-checkpoint, then a command node
  that requires exactly one checkpoint message, and fails downstream. A plain
  rerun of the command step succeeds. Its `_rielaInput` lists new
  communication ids. `importedFrom` maps to the source. `newExecutionCount`
  excludes the imported producers. A recorded inbox id that is missing is
  rejected in preflight.
- `--filter WorkflowGitFinalizationEvidenceTests` and
  `--filter WorkflowPreservedHistoryTests` cases:
  - a protected-workflow history with a failed-then-retried
    `step10-git-commit`, followed by a failed `workflow-output`: a plain rerun
    of `workflow-output` (and of `step10-git-commit`) binds the latest
    accepted evidence and completes;
  - a protected issue-resolution history: a plain rerun of `dispatch-plans`
    and a plain rerun of `integration-review` each bind the source
    `plan-git-commit`/`plan-git-push` (and step10/step11/base-branch-integrate
    copies, which re-execution supersedes), re-execute the tail and pass
    `workflow-output` validation;
  - a history whose latest `plan-git-commit` attempt failed:
    - a rerun of `dispatch-plans` is rejected in preflight with the recovery
      message naming `plan-git-commit`, and no session is created;
    - a plain rerun of `step4-impl-plan-create` (and of `step1-issue-intake`)
      on the same history is not rejected in preflight. It re-executes the
      plan chain and passes `workflow-output` validation;
  - a Guaranteed unit test on the protected topology fixture:
    `step5-impl-plan-review` -> `plan-checkpoint` (label
    `!(planning_only || ...)`) is kept and only the planning route into
    `step9-commit-message` is removed;
  - a history whose latest `integration-review` attempt failed: a rerun of
    `workflow-output` is rejected in preflight (rule 1), and no session is
    created;
  - a full-restart rerun from `step1-issue-intake` that ends in planning-only
    mode does not inherit the source `integration-review` or
    `step6-implement`;
  - a `--preserve-history` sequential variant with a failed-then-retried
    prefix step binds the retry.
