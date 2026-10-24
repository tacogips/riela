# ISW2-74a: dynamic-workflow transition types and DynamicWorkflowPolicy

**Status**: Completed 2026-10-24 (accepted at f85d9add; combined-tree integration review accepted, comm-000178)
**planId**: ISW2-74a-dynamic-workflow-policy
**Issue**: https://github.com/tacogips/riela/issues/74
**Design Reference**: design-docs/specs/design-loop-engineering-brain-generated-workflow-loop.md, sections "Authored contract", "Brain decision envelope" and "Privilege and bounds" (rules 1-5, 9 and 10)
**dependsOn**: ISW2-27b-gateway-cancellation (serial operator amendment; ISW2-27a accepted in 7f087cc4)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-74a-dynamic-workflow-policy.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-74a/

## Intent and context

This plan pins the shared types and the pure, deterministic privilege and bounds checker. ISW2-74b wires the types into `WorkflowStepTransition`; ISW2-74c calls the checker at runtime. The checker reads the **raw envelope JSON**, because Codable materialization silently drops unknown keys. It must not depend on the runner or the store.

## Non-goals

- No edits to existing files: no `WorkflowModel.swift`, `WorkflowValidation.swift` or runner files.
- No iteration counting (rule 6), clamping (rule 8) or stamping of `agentSandbox`/`agentToolPolicy`. ISW2-74c does those after materialization.
- No envelope materialization; ISW2-74b owns the shared temp-workflow materializer.

## Write ownership

- `Sources/RielaCore/DynamicWorkflowPolicy.swift` (new)
- `Tests/RielaCoreTests/DynamicWorkflowPolicyTests.swift` (new)
- `impl-plans/progress/issue-sweep-2-20261024-74a-dynamic-workflow-policy.md` (new)

## Contract (pinned shapes; other plans depend on these exact names)

```swift
public struct WorkflowDynamicWorkflowTransition: Codable, Equatable, Sendable {
  public var maxIterations: Int?            // default 4, 1...16
  public var onFailure: WorkflowDynamicWorkflowOnFailure?   // default .return
  public var limits: WorkflowDynamicWorkflowLimits?
  public var allow: WorkflowDynamicWorkflowAllow?
}
public enum WorkflowDynamicWorkflowOnFailure: String, Codable, Sendable { case `return`, fail }
public struct WorkflowDynamicWorkflowLimits: Codable, Equatable, Sendable {
  public var maxDefinitionBytes: Int?; public var maxNodes: Int?; public var maxSteps: Int?; public var childMaxSteps: Int?
}
public struct WorkflowDynamicWorkflowAllow: Codable, Equatable, Sendable {
  public var nodeTypes: [String]?; public var backends: [String]?; public var models: [String]?; public var addons: [String]?
}
public struct ResolvedDynamicWorkflowBounds: Equatable, Sendable { maxIterations, onFailure, maxDefinitionBytes, maxNodes, maxSteps, childMaxSteps,
  nodeTypes: Set<String>, backends: Set<String>, models: Set<String>, addons: Set<String> }
public enum DynamicWorkflowPolicy {
  public static let ceilings: (maxIterations: Int, maxDefinitionBytes: Int, maxNodes: Int, maxSteps: Int, childMaxSteps: Int) // (16, 262144, 32, 64, 256)
  public static func authoredDiagnostics(_ t: WorkflowDynamicWorkflowTransition, path: String) -> [WorkflowValidationDiagnostic]
  public static func resolve(_ t: WorkflowDynamicWorkflowTransition, parentNodePayloads: [String: AgentNodePayload]) -> ResolvedDynamicWorkflowBounds
  public static func check(envelope: JSONObject, parentWorkflowId: String, bounds: ResolvedDynamicWorkflowBounds) -> [WorkflowValidationDiagnostic]
}
```

Initialisers and `public init`s follow the repository style (see `Sources/RielaCore/WorkflowModel.swift:WorkflowStepTransition`). The design's defaults are 4 iterations, 65536 bytes, 8 nodes, 16 steps and 32 child steps.

## Behaviour

### `authoredDiagnostics`

Errors, each at `path.<field>` with severity `.error`:

- `maxIterations` outside 1...16;
- any limit that is ≤ 0 or above its ceiling;
- `allow.nodeTypes` entries that are not `NodeType` raw values (`agent`, `command`, `container`, `sleep`, plus any others in `WorkflowModel.swift:NodeType`);
- `allow.backends` entries that are not `NodeExecutionBackend` raw values.

Add-on names: if no add-on registry is reachable from RielaCore, the only check is that each name is a non-empty string matching `^[a-z0-9-]+/[a-z0-9-]+$`. Record that decision in the progress log.

### `resolve`

- Defaults as above.
- `nodeTypes` defaults to `["agent"]`.
- `backends` defaults to the set of non-nil `executionBackend.rawValue` across `parentNodePayloads`.
- `models` defaults to the set of non-empty `model` values across `parentNodePayloads`.
- `addons` defaults to `[]`.

### `check(envelope:...)`

The input is the brain's accepted output payload as a `JSONObject`. Return diagnostics; an empty array means it passed. Every message is prefixed `dynamic workflow policy:`.

**Shape.**

- `decision` must be `"execute_workflow"`.
- `workflow` must be an object.
- `nodePayloads` must be an object, or absent (absent counts as empty).
- `input`, when present, must be an object.
- `rationale`, when present, must be a string of at most 2000 characters.

**Rule 1, size.**

- Measure the UTF-8 byte count of the JSON encoding of `{workflow, nodePayloads}` with `JSONEncoder` and `.sortedKeys`. It must be ≤ `maxDefinitionBytes`.
- `workflow.nodes.count` ≤ `maxNodes`.
- `workflow.steps.count` ≤ `maxSteps`.

**Rule 9, key allowlist.** Walk the raw objects with the allowed-key table from the design, verbatim:

| Object | Allowed keys |
|---|---|
| `workflow` | `workflowId`, `description`, `defaults`, `prompts`, `entryStepId`, `managerStepId`, `nodes`, `steps` |
| `defaults` | `nodeTimeoutMs`, `maxLoopIterations`, `fanoutConcurrency` |
| `nodes[]` | `id`, `nodeFile`, `kind`, `execution`, `repeat`, and `addon` (gated by rule 2) |
| `steps[]` | `id`, `nodeId`, `description`, `role`, `promptVariant`, `timeoutMs`, `stallTimeoutMs`, `failurePolicy`, `sessionPolicy`, `transitions`, `loop` |
| `steps[].loop` | `while`, `restartAt`, `maxIterations` |
| `transitions[]` | `toStepId`, `label`, `fanout` |
| `fanout` | `groupId`, `itemsFrom`, `itemVariable`, `concurrency`, `joinStepId`, `failurePolicy`, `resultOrder` |
| payload | `id`, `description`, `nodeType`, `executionBackend`, `model`, `modelFreeze`, `effort`, `systemPromptTemplate`, `promptTemplate`, `sessionStartPromptTemplate`, `includeRuntimeVariablesInPrompt`, `promptVariants`, `sessionPolicy`, `variables`, `input`, `output` |
| `promptVariants.*` | `systemPromptTemplate`, `promptTemplate`, `sessionStartPromptTemplate` |
| payload `input` | `description`, `jsonSchema` |
| payload `output` | `description`, `jsonSchema`, `maxValidationAttempts` |

- Any other key → `field '<json path>' is not allowed in generated workflows`.
- Do not recurse into `jsonSchema`, `variables`, `prompts` or `execution` values. These are data, or a closed small struct; `execution` keys are `mode` and `decisionBy`, so check those two only.

**Rule 5.**

- `workflowId` must be a non-empty string that differs from `parentWorkflowId`.
- Keys `dynamicWorkflow`, `toWorkflowId` and `resumeStepId` in transitions are already denied by rule 9. Additionally emit an explicit message, `generated workflows cannot call other workflows`, for `dynamicWorkflow` and `toWorkflowId`.

**Rule 10.**

- Every `nodes[]` entry resolves to a payload keyed by `nodeFile`, or else by `id`, in `nodePayloads`.
- A missing payload → `node '<id>' has no payload in nodePayloads`.
- Never look at the file system.

**Rule 2.**

- Each payload's `nodeType` (absent = `agent`) must be in `nodeTypes`.
- A node entry with `addon` must have `addon.name` in `addons`.

**Rule 3.**

- `executionBackend` must be present for `agent` nodes and in `backends`. Absent → error `executionBackend is required for generated agent nodes`, so that no implicit default can widen authority.
- `model` must be in `models`.

**Rule 4** is implied by rule 9. Do not duplicate it; one diagnostic per offending key.

## Pitfalls

- Deterministic diagnostic order: walk arrays by index and keys sorted, so resume re-validation yields identical results.
- `JSONObject`/`JSONValue` is RielaCore's own JSON type (see `Sources/RielaCore/` `JSONValue`). Do not use `JSONSerialization`.
- Do not reject `fanout` (rule 5 allows it). Only its effect keys are denied.
- The checker must be total: no crash on wrong JSON types. A wrong type is an error diagnostic.

## Test cases (`DynamicWorkflowPolicyTests`)

- A clean two-node agent workflow within defaults → `[]`.
- Each of these is rejected, and the diagnostic path names the field:
  - `workflow.handover.sinks[0].command`;
  - `workflow.memories` with scope `cross-workflow`;
  - `nodes[0].memories`;
  - `nodes[0].inputFilters` with language `javascript`;
  - `nodes[0].nodeRef`;
  - workflow and node `requiredEnvironment`;
  - workflow `loop`;
  - `triggerDefaults`;
  - `steps[0].placement`;
  - `steps[0].stepFile`;
  - fanout `writeOwnership`;
  - payload `workingDirectory`, `command`, `agentSandbox`, `agentToolPolicy`, `agentEnvironment`, `promptTemplateFile`, and `promptVariants.x.promptTemplateFile`;
  - output `deliverables`;
  - an unknown key `futureField`.
- Transition `toWorkflowId` / `dynamicWorkflow` → rejected with "cannot call other workflows".
- `workflowId` equal to the parent's → rejected.
- A node without a payload → rejected.
- A backend outside the allow set, a model outside the allow set, `nodeType: command` with the default allow, or an add-on not allowed → each rejected.
- Size: a definition over `maxDefinitionBytes`, 9 nodes with the default limit, or 17 steps → each rejected.
- `decision: "finish"` passed to `check` → rejected (shape).
- `authoredDiagnostics`: `maxIterations` 0 or 17, `maxDefinitionBytes` 300000, an unknown node type → each produces errors. Valid values → `[]`.
- `resolve` defaults: parent payloads with backend `claude-code-agent` and model `claude-opus-5-5` → `backends` and `models` sets equal those.
- Determinism: calling `check` twice on the same input → identical arrays.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-74a/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74a/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter DynamicWorkflowPolicyTests > tmp/issue-sweep-2-20261024/isw2-74a/focused.log 2>&1'` → exit 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/DynamicWorkflowPolicy.swift Tests/RielaCoreTests/DynamicWorkflowPolicyTests.swift'` → no warnings.

Wave-1 siblings may break the build in their own files. Do not edit those files; record and retry.

## Execution protocol

Both files are new, so no drift is expected. Still save a post-hash under `tmp/issue-sweep-2-20261024/isw2-74a/snapshots/`. Write only to your own progress log.

## Done criteria

- [x] All public names match the Contract block exactly.
- [x] Every listed policy case is covered and `DynamicWorkflowPolicyTests` passes; `swift build` and strict lint of the exact changed Swift files pass with plan-local logs.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.

> Operator amendment 2 (2026-10-24): every remaining plan also owns its own active plan file (this file) so it can update its completion checklist.
