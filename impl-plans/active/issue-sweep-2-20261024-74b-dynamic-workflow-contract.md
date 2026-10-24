# ISW2-74b: authored `transition.dynamicWorkflow`, child provenance field, shared temp-workflow materializer

**Status**: Active (not started)
**planId**: ISW2-74b-dynamic-workflow-contract
**Issue**: https://github.com/tacogips/riela/issues/74
**Design Reference**: design-docs/specs/design-loop-engineering-brain-generated-workflow-loop.md, sections "Authored contract", "Brain decision envelope" (shared materializer) and "Session lineage and provenance"
**dependsOn**: ISW2-74a-dynamic-workflow-policy, ISW2-32-recovery-hydration, ISW2-27c-session-reconcile (serial operator amendment; ISW2-27a accepted in 7f087cc4)

Wave 2.

**Progress log**: impl-plans/progress/issue-sweep-2-20261024-74b-dynamic-workflow-contract.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-74b/

## Intent and context

This plan makes the dynamic transition authorable and validated by the same `DefaultWorkflowValidator` that `riela workflow validate` uses. It also adds the child-session provenance field, and moves the private `TemporaryWorkflowPayload` decoding and materialization (`Sources/RielaCLI/WorkflowRunCommand.swift:681-737,823-826`) into RielaCore, so the CLI temp-workflow path and ISW2-74c share one function.

Runtime behaviour is unchanged in this plan. A workflow carrying `dynamicWorkflow` validates, but until ISW2-74c wires it, the runtime ignores the field and treats the transition as an ordinary `toStepId` transition.

## Non-goals

- No runtime dispatch and no publisher change; ISW2-74c owns both.
- No change to temp-workflow behaviour; the extraction is pure.
- No change to the policy file (ISW2-74a).

## Write ownership

- `Sources/RielaCore/WorkflowModel.swift`: only `WorkflowStepTransition`
- `Sources/RielaCore/WorkflowValidation.swift`: only the transition validation paths (about lines 120-130, 205-215, 535-560)
- `Sources/RielaCore/RuntimeSession.swift`: only `WorkflowSession` gains a field; do not touch the enums ISW2-27a edited
- `Sources/RielaCore/TemporaryWorkflowPayload.swift` (new)
- `Sources/RielaCLI/WorkflowRunCommand.swift`: only `loadTemporaryWorkflowIfPresent`, `nodePayloads(from:workflow:)` and the private `TemporaryWorkflowPayload` struct
- `Tests/RielaCoreTests/WorkflowDynamicWorkflowContractTests.swift` (new)
- `impl-plans/progress/issue-sweep-2-20261024-74b-dynamic-workflow-contract.md` (new)

## File-level changes

1. **`WorkflowStepTransition`**: add `public var dynamicWorkflow: WorkflowDynamicWorkflowTransition?` and an init parameter `dynamicWorkflow: ... = nil` as the last argument. Synthesized Codable stays; the field is optional, so existing JSON decodes unchanged.
2. **`WorkflowValidation.swift`**, for a transition with `dynamicWorkflow != nil`:
   - error if `toWorkflowId`, `resumeStepId` or `fanout` is also set (path `...transitions[i].dynamicWorkflow`);
   - `toStepId` must be an existing parent step. Reuse the existing `stepIds.contains` check, which already runs because `toWorkflowId == nil`;
   - append `DynamicWorkflowPolicy.authoredDiagnostics(t, path:)`;
   - **warning** when the transition's `toStepId` equals its own step id and the effective `defaults.maxLoopIterations` is ≤ the resolved `maxIterations` (default 4);
   - the existing rules for `toWorkflowId` transitions stay unchanged.
3. **`RuntimeSession.swift`**:
   - Add the type:

     ```swift
     public struct WorkflowGeneratedWorkflowOrigin: Codable, Equatable, Sendable {
       iteration: Int; definitionDigest: String; sourceStepExecutionId: String; rationale: String?
     }
     ```

   - Add `public var generatedWorkflow: WorkflowGeneratedWorkflowOrigin?` to `WorkflowSession`.
   - Add a `case generatedWorkflow` coding key, `decodeIfPresent`, and `encodeIfPresent`. Follow how `suspend`/`parentSessionId` are handled in the custom Codable in that file.
   - The init gains `generatedWorkflow: ... = nil`.
4. **`TemporaryWorkflowPayload.swift`** (new, RielaCore):

   ```swift
   public struct TemporaryWorkflowPayload: Codable, Sendable { public var workflow: AuthoredWorkflowJSON; public var nodePayloads: [String: AgentNodePayload] }
   public struct MaterializedTemporaryWorkflow: Sendable { public var validation: AuthoredWorkflowValidationResult; public var nodePayloads: [String: AgentNodePayload] }
   public func materializeTemporaryWorkflowPayload(_ payload: TemporaryWorkflowPayload) -> MaterializedTemporaryWorkflow
   ```

   - It calls `validateAuthoredWorkflowJSON(payload.workflow)`.
   - When a workflow results, it maps payloads by node id, taking the `nodeFile` key first and then the `id` key, exactly like today's `nodePayloads(from:workflow:)`.
   - When validation fails, `nodePayloads` is empty.
5. **`WorkflowRunCommand.swift`**:
   - Delete the private `TemporaryWorkflowPayload` struct and the private `nodePayloads(from:workflow:)`.
   - `loadTemporaryWorkflowIfPresent` decodes the RielaCore type and calls `materializeTemporaryWorkflowPayload`.
   - Behaviour must stay identical, including thrown errors (`WorkflowResolutionError.invalidWorkflow(validation.diagnostics)`), `sourceScope` and `workflowDirectory`.

## Invariants

- Existing workflows, including those using `toWorkflowId`, validate with exactly the same diagnostics as before.
- The temp-workflow CLI behaves the same (`WorkflowCommandCatalogTests+Temporary` stays green).
- Persisted sessions without `generatedWorkflow` decode unchanged.

## Pitfalls

- `RuntimeSession.swift` was just edited by ISW2-27a. Re-read it, and change only the `WorkflowSession` struct, its `CodingKeys`, `init(from:)`, `encode(to:)` and `init`.
- Do not make `TemporaryWorkflowPayload` decoding lenient. It must stay strict Codable, matching today's `try?` fallback flow in `loadTemporaryWorkflowIfPresent`.
- Keep the authored transition JSON key exactly `dynamicWorkflow`.

## Test cases (`WorkflowDynamicWorkflowContractTests`)

- An authored workflow with a valid self-loop `dynamicWorkflow` transition and `maxLoopIterations` 6 → no errors and no warnings.
- The same transition with `maxLoopIterations` 3 → one warning.
- `dynamicWorkflow` together with `toWorkflowId` → error. With `fanout` → error.
- `maxIterations` 0 → error, through `DynamicWorkflowPolicy.authoredDiagnostics`.
- `toStepId` naming a missing step → error.
- A `WorkflowSession` JSON round trip with `generatedWorkflow` → equal. Legacy JSON without the field → decodes, and the field is nil.
- `materializeTemporaryWorkflowPayload` with payloads keyed by `nodeFile` and by `id` → both resolve. An invalid workflow → `validation.workflow == nil` and `nodePayloads` empty.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-74b/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74b/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDynamicWorkflowContractTests|DynamicWorkflowPolicyTests|WorkflowCommandCatalogTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests" > tmp/issue-sweep-2-20261024/isw2-74b/focused.log 2>&1'` → exit 0.
3. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowValidat" > tmp/issue-sweep-2-20261024/isw2-74b/validation.log 2>&1'` → exit 0. This runs every existing validation suite whose name contains `WorkflowValidat`.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <owned Swift files>'` → no new warnings.

## Execution protocol

Per-edit fresh read, with pre/post hash and intent snapshots under `tmp/issue-sweep-2-20261024/isw2-74b/snapshots/`. For the shared files `RuntimeSession.swift` and `WorkflowRunCommand.swift`, confirm the prior plans' hunks are intact after your edit. Write only to your own progress log.

## Done criteria

- [ ] `grep -n "private struct TemporaryWorkflowPayload" Sources/RielaCLI/WorkflowRunCommand.swift` → empty.
- [ ] `grep -n "dynamicWorkflow" Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowValidation.swift` → matches.
- [ ] Verification 1-4 pass, with logs.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.

> Operator amendment 2 (2026-10-24): every remaining plan also owns its own active plan file (this file) so it can update its completion checklist.
