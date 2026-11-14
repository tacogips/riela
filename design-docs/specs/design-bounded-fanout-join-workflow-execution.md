# Bounded Fanout Join Workflow Execution Design

## Status

Accepted Step 2 design for issue-resolution workflow execution work.

## Feature Contract

- Workflow mode: issue-resolution
- Issue title: Implement local fanout-transition execution in
  `DeterministicWorkflowRunner` and `InMemoryWorkflowOutputPublisher`
- Issue reference: `codex-design-and-implement-review-loop-session-564`, from
  `fable-and-improve-session-563`; no GitHub issue URL, repository, or issue
  number was provided
- Scope: one cohesive runtime feature; do not split into feature fanout while
  building fanout itself
- Primary files:
  `Sources/RielaCore/RuntimePublication.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`,
  `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`,
  `Sources/RielaCLI`, and `Tests/RielaCoreTests`
- Reference repository: none supplied; no Codex-agent behavioral reference is
  used for this design

## Problem

The authored workflow schema already models `transitions[].fanout`, but the
Swift live runtime rejects selected fanout transitions. This blocks
`examples/design-and-implement-review-loop/workflow.json` when
`step1-issue-intake` emits `has_feature_fanout: true` and selects the transition
that starts `feature-local-plan` work and joins at
`step5-feature-plan-join`.

The runtime must replace the rejection with local bounded fanout execution:
resolve items from the accepted output, run each branch sub-path, aggregate
branch outputs in input order, inject `runtimeVariables.fanoutJoin`, and
continue at the join step.

## Runtime Boundary

Fanout execution is owned by `DeterministicWorkflowRunner`. Workers, adapters,
and output validators continue to produce and validate one accepted output for a
step. `InMemoryWorkflowOutputPublisher` records that accepted output and returns
a dispatch directive instead of attempting to execute branches.

The design mirrors live cross-workflow dispatch:

- `WorkflowPublicationRequest` carries the selected transition candidates.
- `InMemoryWorkflowOutputPublisher` evaluates labels against the accepted
  output and records the source step execution.
- A new `WorkflowFanoutDispatchDirective` is returned on
  `WorkflowPublicationResult.fanoutDispatch`.
- `DeterministicWorkflowRunner` consumes the directive at the two existing
  `crossWorkflowDispatch` handling sites: after a skipped filtered step
  publishes and after a normal node execution publishes.

The publisher must not append a direct workflow message for a live fanout
transition. The runner owns branch execution and the single joined message.

## Directive Shape

`WorkflowFanoutDispatchDirective` should carry only runtime-owned dispatch
facts:

- `groupId`
- `sourceStepId`
- `targetStepId` from `transition.toStepId`
- `joinStepId` from `transition.fanout.joinStepId`
- `transitionLabel`
- `sourceStepExecutionId`
- `itemsFrom`
- `itemVariable`
- `concurrency`
- `failurePolicy`
- `resultOrder`
- `writeOwnership`
- `sourcePayload`

`sourcePayload` is the accepted output payload from the producing step. The
runner resolves `itemsFrom` against this payload using JSON Pointer semantics.
The current feature only requires local in-workflow fanout; if a selected
transition combines `fanout` with `toWorkflowId`, the implementation must either
prove and test that cross-workflow branch dispatch is supported or fail with a
clear capability diagnostic before the publisher emits a partial directive.

## Fanout Data Flow

1. The source step runs normally and its candidate output is validated.
2. The publisher filters transitions using the existing branch evaluator.
3. If the selected transition has `fanout`, the publisher records the accepted
   source output and emits `WorkflowFanoutDispatchDirective`.
4. The runner resolves `itemsFrom` against the source payload. The pointer must
   resolve to an array; non-array or missing values fail the run with a typed,
   actionable runtime error naming `itemsFrom`.
5. Each array item creates one branch run. The branch starts at
   `targetStepId`, binds the current item under `itemVariable` when provided,
   and runs until a selected transition targets `joinStepId` or the branch
   sub-path terminates.
6. The runner aggregates branch terminal outputs in original item order,
   regardless of completion order.
7. The runner appends one workflow message to `joinStepId` containing
   `fanoutJoin`, updates the effective request variables so the join prompt sees
   `runtimeVariables.fanoutJoin`, and continues execution at `joinStepId`.

The join payload is:

```json
{
  "fanoutJoin": {
    "fanoutGroupRunId": "feature-local-planning:<source-step-execution-id>",
    "groupId": "feature-local-planning",
    "sourceStepId": "step1-issue-intake",
    "sourceStepExecutionId": "<execution-id>",
    "targetStepId": "feature-local-plan",
    "joinStepId": "step5-feature-plan-join",
    "resultOrder": "input",
    "failurePolicy": "fail-fast",
    "branches": [
      {
        "index": 0,
        "item": {},
        "status": "completed",
        "output": {},
        "sessionId": "<branch-session-id>"
      }
    ]
  }
}
```

`runtimeVariables.fanoutJoin` is injected through the existing prompt-variable
path in `DeterministicWorkflowRunner+Prompting.swift`: request variables are
merged with resolved input payload, then exposed under `runtimeVariables`.
Therefore the runner must both append the joined workflow message and place the
same `fanoutJoin` object into the effective request variables before executing
the join step.

## Branch Execution Model

Branches should reuse `run()` recursion instead of adding a second step
interpreter. For each item, the runner constructs a child
`DeterministicWorkflowRunRequest` with:

- the same workflow and node payloads
- `entryStepId` rewritten to the fanout target step for the branch request
- request variables copied from the parent and augmented with the current item
  under `itemVariable`
- existing timeout, memory, event, attachment, instance, and monitoring options
- branch-local session state so concurrent branches do not mutate the parent
  session's current step or execution array unsafely

The branch must stop before executing the join step. A branch transition that
targets `joinStepId` is terminal for that branch and contributes the branch
output to aggregation. A branch path that terminates without reaching
`joinStepId` is allowed only when the branch result is otherwise terminal and
has a root output; otherwise it is a branch failure.

## Concurrency And Determinism

Fanout must execute with true bounded concurrency through structured Swift
concurrency. The effective bound is:

1. `transition.fanout.concurrency` when present
2. item count when no per-transition bound is authored
3. `run.maxConcurrency` as an optional command-level cap when present and lower
   than the per-transition-or-item-count bound

The effective bound must be at least one and no greater than the item count.
The runner should start at most that many branch tasks at once using a bounded
task-group scheduling loop.

Determinism requirements:

- aggregation order is the source item order for `resultOrder: input`
- branch completion order must not affect `runtimeVariables.fanoutJoin`
- branch session ids and `fanoutGroupRunId` are stable enough for inspection but
  not used for ordering
- parent session message delivery to the join step happens once after the
  relevant branch policy completes

## Failure Policy

`failurePolicy` defaults to `fail-fast`.

For `fail-fast`, the first branch failure cancels outstanding tasks promptly,
records the failed branch result, and fails the fanout dispatch with an error
that names the group id, item index, and branch failure reason. Completed branch
results before cancellation may remain inspectable, but no join step runs.

For `collect-all`, all branches run to terminal state. The join step receives
ordered branch records that include per-branch status and output or failure
reason. The overall fanout dispatch should fail after aggregation if any branch
failed unless a later explicit workflow contract adds partial-success joins.

Cancellation from the parent run must propagate to every active branch task.

## Write Ownership

`writeOwnership` is validated before any branch task starts:

- `read-only`: allowed. The runtime does not grant branch write ownership.
- `disjoint-paths`: allowed only when authored paths or directories are present
  and each path/directory is normalized, relative to the workflow worktree, and
  non-overlapping across declared branch ownership. The initial implementation
  may treat the declared set as a shared allowed-write envelope, but it must
  reject empty or unsafe declarations.
- `isolated-workspace`: deferred. The runner and CLI preflight must report a
  clear unsupported capability diagnostic until per-branch worktree isolation is
  implemented.

Capability diagnostics must remove the blanket "fanout transitions are not
supported" error only for supported ownership modes. Unsupported ownership modes
remain surfaced as specific fanout capability gaps.

## Capability And CLI Behavior

`WorkflowRuntimeCapabilityGap.unsupportedFeatures` should no longer emit a gap
for reachable fanout transitions that use supported local fanout settings. It
should continue to diagnose:

- `isolated-workspace` fanout ownership
- cross-workflow fanout if not implemented in the same change
- malformed `run.maxConcurrency` values or unsupported combinations
- existing cross-workflow and resume-step gaps unrelated to supported fanout

`Sources/RielaCLI` should stop describing `--max-concurrency` as reserved and
unsupported once it is wired as the run-level cap for fanout. CLI validation and
help text should describe it as a fanout concurrency cap.

## Validation And Rollout Constraints

- Create exactly one design document for this feature and one implementation
  plan before code changes.
- Preserve Swift 6 strict concurrency and actor isolation.
- Keep source files under repository file-size limits; put fanout execution in
  `DeterministicWorkflowRunner+Fanout.swift`.
- Keep existing non-fanout execution unchanged, including the current
  `codex-design-and-implement-review-loop` non-fanout mock scenario counts:
  29 node executions, 28 transitions, exit code 0.
- Add deterministic RielaCore coverage for fanoutJoin ordering, result-order
  stability under out-of-order completion, concurrency bound overlap,
  fail-fast cancellation, collect-all aggregation, publisher directive emission,
  and capability preflight behavior.
- Add a deterministic fanout mock scenario that reaches completed/exitCode 0.
- Verify `swift build`, `swift test`, SwiftLint if configured,
  `riela workflow validate codex-design-and-implement-review-loop`, the new
  fanout scenario, the existing non-fanout scenario, and a
  `has_feature_fanout: true` end-to-end run reaching
  `step5-feature-plan-join` without `unsupportedTransition`.

## Intentional Divergences

- No Codex-agent or Cursor-specific behavior is part of this design; fanout is a
  runtime scheduling feature and adapter behavior remains behind existing
  adapter modules.
- `isolated-workspace` ownership is intentionally deferred with diagnostics
  because the requested issue allows deferral and requires only read-only and
  disjoint-paths support in this slice.
- Partial-success joins are not introduced. `collect-all` records all branch
  results but does not make failed fanout groups successful without an explicit
  future workflow contract.

## Risks

- Branch recursion may accidentally execute the join step inside a branch unless
  join-target termination is enforced in the branch request.
- Concurrent branch runs may contend on the shared store if branch sessions are
  not isolated.
- Fail-fast cancellation can become nondeterministic if branch errors race with
  branch completion; ordered aggregation and first-failure reporting must be
  deterministic.
- Capability-gap removal could hide unsupported fanout combinations unless
  ownership and cross-workflow fanout diagnostics remain specific.
