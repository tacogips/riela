# ISW2-74c: runtime dispatch of brain-generated workflows

**Status**: Active (not started)
**planId**: ISW2-74c-dynamic-workflow-dispatch
**Issue**: https://github.com/tacogips/riela/issues/74
**Design Reference**: design-docs/specs/design-loop-engineering-brain-generated-workflow-loop.md, sections "Runtime data flow", "Result message", "Session lineage and provenance", "Privilege and bounds" (rules 6-8 plus stamping), "Failure, timeout and cancellation", "Mock scenarios", "Resume and rerun" and "Session scope"
**dependsOn**: ISW2-74b-dynamic-workflow-contract, ISW2-74a-dynamic-workflow-policy (serial operator amendment; ISW2-27a accepted in 7f087cc4)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-74c-dynamic-workflow-dispatch.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-74c/

## Intent and context

When a step selects a transition carrying `dynamicWorkflow`, the runner does the following. It runs inside the same process, adapter, store and admission; never through a nested `riela workflow run`.

1. Policy-check the accepted output envelope with `DynamicWorkflowPolicy.check` (ISW2-74a).
2. Materialize the definition with `materializeTemporaryWorkflowPayload` (ISW2-74b).
3. Validate it with `DefaultWorkflowValidator().validate(workflow, nodePayloads:)`.
4. Reserve and run a child session with parent/root lineage, `generatedWorkflow` provenance and a digest, reusing the cross-workflow nested-reservation machinery.
5. Deliver one `dynamicWorkflowResult` message to `transition.toStepId`.

## Existing code to imitate

- `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift:dispatchCrossWorkflowCallee`: reservation reuse, the running-child fence, the child request built from the parent request, terminal persistence, and cancellation rethrow.
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedPublication.swift:nestedInvocationPreCommitPublicationHook`: immutable reservation before the parent commit.
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift`: `reserveNestedSession`, `appendNestedResultOnce` and `recoverNestedInvocationsBeforeResuming`.
- `Sources/RielaCore/RuntimePublication.swift`:
  - `liveCrossWorkflowDispatchDirective` and `isLiveCrossWorkflowDispatchTransition` (about lines 974-1000);
  - `unsupportedTransitionReason` (about line 944);
  - `nextStepId(from:)`.
- `Sources/RielaCore/DeterministicWorkflowRunner.swift:410-417`: post-commit `crossWorkflowDispatch` handling.

## Non-goals

- No registry persistence; generated workflows stay session-scoped.
- No wall-clock or cost budget for the whole loop.
- No promotion (#40).
- No GraphQL or web additions.
- Do not change `toWorkflowId` semantics or `simulatesCrossWorkflowDispatch` behaviour for static calls.

## Write ownership

- `Sources/RielaCore/DeterministicWorkflowRunner+DynamicWorkflow.swift` (new)
- `Sources/RielaCore/RuntimePublication.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`: only the post-commit dispatch block, plus a stored property if one is needed
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedPublication.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`: only if you extract a shared child-run helper
- `Sources/RielaCore/RuntimeStore.swift`: only `WorkflowSessionCreateInput` and `createSession`, to carry `generatedWorkflow`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerDynamicWorkflowTests.swift` (new)
- `impl-plans/progress/issue-sweep-2-20261024-74c-dynamic-workflow-dispatch.md` (new)

## File-level changes

1. **`RuntimePublication.swift`**
   - Add `public struct WorkflowDynamicWorkflowDispatchDirective: Equatable, Sendable { resumeStepId: String; transitionLabel: String?; envelope: JSONObject; sourceStepExecutionId: String; transition: WorkflowDynamicWorkflowTransition }`.
   - Add `dynamicWorkflowDispatch: WorkflowDynamicWorkflowDispatchDirective?` to the publish result struct, with an init parameter defaulting to nil.
   - When the selected transitions include one with `dynamicWorkflow != nil`:
     - if more than one transition is selected → throw the same invalid-workflow error as "more than one nested callee";
     - otherwise produce the directive from the accepted payload. This happens regardless of `simulatesCrossWorkflowDispatch` and `supportsLiveCrossWorkflowDispatch`.
   - `nextStepId` for that transition is `toStepId`, which is already the default.
   - `unsupportedTransitionReason` must not flag dynamic transitions.
2. **`DeterministicWorkflowRunner.swift`**: after the `crossWorkflowDispatch` block, `if let dispatch = publishResult.dynamicWorkflowDispatch { try await dispatchDynamicWorkflow(directive: dispatch, parentSessionId:, parentStepId:, request:) ; publishedTransitions += 1 }`. Ordering is the same as cross-workflow.
3. **`DeterministicWorkflowRunner+DynamicWorkflow.swift`** (new): `func dispatchDynamicWorkflow(...) async throws`.
   1. **Iteration.** `n = 1 +` the number of distinct `sourceStepExecutionId`s, *excluding* the current one, among:
      - this session's messages to `resumeStepId` whose payload has the key `dynamicWorkflowResult`;
      - `nestedInvocationPersistenceStore` records for this parent with `branchId == "dynamic-workflow"`.

      Use `store.listMessages(for:toStepId:)` and the nested record listing already used in `recoverNestedInvocationsBeforeResuming`. If `n > maxIterations` → throw so that the parent fails with `failureKind` `budgetExceeded` and reason `dynamic workflow iteration budget exhausted (<max>)`. Reuse `DeterministicWorkflowRunnerError.loopBudgetExceeded(diagnostic)`, which `workflowRunFailureKind` already maps to `.budgetExceeded`.
   2. **Validation.**
      - `bounds = DynamicWorkflowPolicy.resolve(transition, parentNodePayloads: request.nodePayloads)`.
      - `diags = DynamicWorkflowPolicy.check(envelope:..., parentWorkflowId:, bounds:)`.
      - If there are no errors: decode `TemporaryWorkflowPayload` from `{workflow, nodePayloads}` (`JSONEncoder` then `JSONDecoder`), call `materializeTemporaryWorkflowPayload`, then `DefaultWorkflowValidator().validate(workflow, nodePayloads:)`. Collect the diagnostics in a stable order.
   3. **Invalid** (any error):
      - `onFailure == .fail` → throw `crossWorkflowDispatchFailed(workflowId: <generated id or "generated">, reason: "invalid generated workflow: <first 5 messages>")`.
      - Otherwise call `appendNestedResultOnce`-style `appendWorkflowMessageOnce` to `resumeStepId`, with payload `dynamicWorkflowResult {iteration, maxIterations, outcome:"invalid", childSessionId:null, workflowId, definitionDigest:null, rationale, rootOutput:{}, failureKind:null, failureReason:null, diagnostics}`, and return.
   4. **Valid.**
      - Stamp authority: for every generated agent payload, set `agentSandbox` and `agentToolPolicy` from the emitting node's payload (`request.nodePayloads[<parent step's nodeId>]`). Clamp `defaults.nodeTimeoutMs` and step `timeoutMs` to the parent's value (`request.defaultTimeoutMs`, or else the parent `defaults.nodeTimeoutMs`), and `maxLoopIterations` to the parent's.
      - `digest = nestedCalleeRevision(workflow:nodePayloads:)`, computed **after** stamping and clamping, so resume compares the same material.
      - Reserve through `reserveNestedSession(... branchId: "dynamic-workflow", resumeStepId:)`, passing `generatedWorkflow: WorkflowGeneratedWorkflowOrigin(iteration:n, definitionDigest:digest, sourceStepExecutionId:, rationale:)`. This needs `WorkflowSessionCreateInput.generatedWorkflow` (change 6).
      - Apply the same running-child fence and existing-terminal checks as `dispatchCrossWorkflowCallee`. Prefer extracting a shared helper into `+CrossWorkflow.swift` over copying, but keep the cross-workflow behaviour byte-identical.
      - Child request: `variables = envelope.input ?? [:]`, `maxSteps = bounds.childMaxSteps`, `crossWorkflowDispatchDepth + 1`, parent/root lineage, `resumeSessionId = reserved id`, the same `eventHandler` and `sessionExecutionAdmission`.
   5. **Child outcome.**
      - Completed → `outcome:"completed"`, `rootOutput = result.rootOutput ?? [:]`.
      - Child throws or ends `failed`:
        - if `isWorkflowRunCancellation(error)` and the parent task is cancelled → rethrow;
        - otherwise `outcome:"failed"` (or `"cancelled"` when the child status is `.cancelled`), with the child's `failureKind`/`failureReason`;
        - `onFailure == .fail` → throw `crossWorkflowDispatchFailed`.
      - Persist the nested terminal (`persistNestedTerminalIfNeeded`), then deliver `dynamicWorkflowResult` through `appendNestedResultOnce`, generalized as in change 5.
4. **`DeterministicWorkflowRunner+NestedPublication.swift`**: add a second hook branch for dynamic transitions.
   - Condition: `nestedInvocationPersistenceStore != nil`, **not** gated on `simulatesCrossWorkflowDispatch` or `calleeResolver`.
   - **First, the iteration gate.** Compute iteration `n` with the same shared function as 3.1. If `n > maxIterations`, return nil: no reservation and no child session. The post-commit `dispatchDynamicWorkflow` then throws `budgetExceeded`.
   - Next, the same validation as 3.2, from `context`'s accepted payload. When valid, create the immutable reservation with `branchId "dynamic-workflow"` and a child `WorkflowSession` carrying `generatedWorkflow`.
   - When invalid, return nil (no reservation).
   - **Single shared helper.** Define one function in `+DynamicWorkflow.swift`, for example:

     ```swift
     func prepareDynamicIteration(sessionId:sourceStepExecutionId:step:transition:envelope:request:) async throws -> DynamicIterationPlan
     ```

     `DynamicIterationPlan` has three cases: `.overBudget(max)`, `.invalid(iteration, diagnostics, workflowId?, rationale)`, and `.valid(iteration, workflow, nodePayloads, digest, origin)`.
   - That helper does the iteration count, policy, materialize, validate, stamp/clamp and digest. The hook (change 4), the post-commit dispatch (change 3) and resume recovery (change 5) all call it. None of them may re-implement any part of it.
5. **`DeterministicWorkflowRunner+NestedReservations.swift`**
   - `appendNestedResultOnce` gains `branchId: String = "cross-workflow"` and `payloadOverride: JSONObject? = nil`. The default behaviour is unchanged, including `_rielaCrossWorkflow`. With an override, it writes exactly `{"dynamicWorkflowResult": ...}`.
   - `recoverNestedInvocationsBeforeResuming`: for pending records with `branchId == "dynamic-workflow"`, find the parent step's dynamic transition whose `toStepId == record.reservation.resumeStepId`, rebuild the directive from the source execution's accepted payload, and call `dispatchDynamicWorkflow`. The reservation's persisted `calleeWorkflow`/`calleeNodePayloads`/`calleeRevision` are used; never regenerate.
   - A digest mismatch → the same fail-closed error as cross-workflow.
   - **Invalid-iteration recovery (no nested record).**
     - Gate it on `request.resumeSessionId != nil`.
     - It runs before the early `guard !matching.isEmpty else { return }` at about lines 27-29. Restructure so the dynamic branch is evaluated even when there are no matching records. Keep the cross-workflow and fanout branches byte-identical.
     - Find the latest execution in `session.executions` that meets all of these:
       - its step has a `dynamicWorkflow` transition with `toStepId == session.currentStepId`;
       - its accepted output selected that transition (the transition label is true in the accepted `when`);
       - no `dynamicWorkflowResult` message exists for its `sourceStepExecutionId`;
       - no nested record with `branchId "dynamic-workflow"` exists for it.
     - Call `prepareDynamicIteration` on its accepted payload.
       - `.invalid`: deliver the invalid result with `appendWorkflowMessageOnce` (the same message input as the live path), then continue with the normal resume.
       - `.valid`: call `dispatchDynamicWorkflow`, which takes the reservation path.
       - `.overBudget`: throw `budgetExceeded`, as live dispatch does.
     - Never execute the brain step to recover an iteration.
6. **`RuntimeStore.swift`**: `WorkflowSessionCreateInput.generatedWorkflow: WorkflowGeneratedWorkflowOrigin? = nil`, applied in `InMemoryWorkflowRuntimeStore.createSession`.

## Invariants

- Static `toWorkflowId` dispatch and fanout behave unchanged: their existing tests stay green.
- Exactly one `dynamicWorkflowResult` message is delivered per source execution, idempotently across resume.
- A generated definition is never written to any registry.
- Every child session has `parentSessionId` = the brain session, `rootSessionId` = the brain's root, and `generatedWorkflow` set.

## Pitfalls

- Re-validation on resume must be deterministic. The policy and the validator are pure; do not include timestamps or random ids in the diagnostics.
- In mock mode (`simulatesCrossWorkflowDispatch == true`) the dynamic child must still **really run**, through the same `adapter` (the scenario adapter) with generated node ids.
- Do not mutate `request.nodePayloads` for the parent.
- If the parent task is cancelled while the child runs, propagate the cancellation (`isWorkflowRunCancellation`). Do not deliver a result message.
- `maxIterations + 1`-th selection: fail before any validation or reservation, in **both** the durable hook and the post-commit dispatch. The hook returns nil without reserving.
- Invalid iterations never create a nested record, so resume must re-derive them from the persisted accepted output (change 5). An early return on "no matching records" would silently re-run the brain.

## Test cases (`DeterministicWorkflowRunnerDynamicWorkflowTests`)

Use `InMemoryWorkflowRuntimeStore`, plus a `SQLiteWorkflowRuntimePersistenceStore` under a temp dir for the durable cases.

Script the brain and the generated node ids with a local scripted `NodeAdapter` defined in the test file. Key it by node id with sequential responses, like `ScenarioNodeAdapter`. `RielaCoreTests` does not import `RielaAdapters`, so do not use `ScenarioNodeAdapter` itself; copy the pattern from an existing scripted adapter in `Tests/RielaCoreTests` (for example the one used by `DeterministicWorkflowRunnerCrossWorkflowDispatchTests`).

- Two iterations: brain envelope A (node `inventory`), then envelope B (node `verify`), whose `input` is copied from A's `rootOutput`, then `finish`. Expected:
  - the parent is completed and its root output is the finish envelope;
  - two children exist, with iterations 1 and 2, distinct digests, and correct lineage;
  - two result messages exist, with `outcome: completed`.
- Under `simulatesCrossWorkflowDispatch: true` → the same result; the children really ran, which the scenario consumption counts prove.
- An invalid envelope (one with `handover`) → `outcome: invalid` with the diagnostics, no child session, and the brain runs again.
- `onFailure: fail` with an invalid envelope → the parent fails.
- A child node that fails → `outcome: failed` with `failureKind`, and the brain runs again.
- A fifth selection with `maxIterations: 4` → the parent fails with `budgetExceeded`.
- Cancelling the parent while the child is running → the parent ends `cancelled` and no result message exists.
- Durable resume: crash after the reservation and before delivery (use the existing `nestedInvocationRecoveryCheckpointer` failpoints, as in the cross-workflow recovery tests). Resume → the child runs from the persisted definition with the same digest, the brain node is not executed again for that iteration, and exactly one message is delivered.
- Durable over-budget: `maxIterations` 4 and the brain selects the dynamic transition a 5th time → for that source execution there is no nested record with `branchId "dynamic-workflow"` and no child session (check `nestedInvocationRecords(parentSessionId:)` and the store's sessions). The parent fails with `failureKind` `budgetExceeded` and reason `dynamic workflow iteration budget exhausted (4)`.
- Durable invalid-iteration crash window: the brain emits an invalid envelope (for example one with `handover`), `onFailure` is `return`, and the run is interrupted after the parent publication commit but before the invalid `dynamicWorkflowResult` is appended. Use the store's append-failure predicate (`InMemoryWorkflowRuntimeStore` `appendFailurePredicate`) or a recovery checkpointer failpoint, as the cross-workflow recovery tests do. Resume → exactly one `outcome: invalid` message for that source execution, and the brain execution count does not grow for that iteration before the message is delivered.
- The stamped `agentSandbox` equals the brain's.
- A generated `nodeTimeoutMs` above the parent's is clamped.
- Two dynamic transitions selected together → an error.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-74c/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74c/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerDynamicWorkflowTests|DynamicWorkflowPolicyTests|WorkflowDynamicWorkflowContractTests" > tmp/issue-sweep-2-20261024/isw2-74c/focused.log 2>&1'` → exit 0.
3. `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerCrossWorkflowDispatchTests|DeterministicWorkflowRunnerFanoutTests|ScopedParityCallStepFanoutTests|WorkflowCancelledStatusTests" > tmp/issue-sweep-2-20261024/isw2-74c/regression.log 2>&1'` → exit 0. Also add every suite named `*Nested*` that `ls Tests/RielaCoreTests Tests/RielaCLITests` finds.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <owned Swift files>'` → no new warnings.

## Execution protocol

Per-edit fresh read, with pre/post hash and intent snapshots under `tmp/issue-sweep-2-20261024/isw2-74c/snapshots/`. `RuntimeStore.swift` and `+CrossWorkflow.swift` were edited by ISW2-27a: re-read them and confirm its hunks are intact. Write only to your own progress log.

## Done criteria

- [ ] All listed tests pass, and verification 1-4 pass, with logs.
- [ ] `grep -rn "dynamic-workflow" Sources/RielaCore` shows the branch id in the dispatch, the hook and the recovery code.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.

> Operator amendment 2 (2026-10-24): every remaining plan also owns its own active plan file (this file) so it can update its completion checklist.
