# Loop Engineering: Brain-Generated Workflow Loop

## Status and issue

- Status: design, ready for implementation planning (2026-10-24)
- Workflow mode: `issue-resolution`
- Issue: tacogips/riela#74 "[Loop engineering] Brain-driven generation and
  iterative execution of workflows" (local copy `tmp/run/issue-74.md`)
- Related: #40 (promotion of evidence-backed improvements) stays separate. This
  design adds no promotion path.
- Ordering: implement after the #27 `cancelled` status work in
  `design-cancellation-and-orphan-session-resilience.md` §"2026-10-24 contract",
  because the child terminal status handed back to the brain includes
  `cancelled`.

## Problem

Cross-workflow transitions (`toWorkflowId`) can only call workflows that are
known when the caller is authored. There is no typed contract that lets an LLM
node produce a workflow definition during a run and have the runtime validate
it, run it as a child session, and give the result back to the same node.

## Decision summary

| Open question (issue #74) | Decision |
|---|---|
| Typed brain output + in-process dynamic call, or a dedicated addon? | A **runner-level transition extension**, `transition.dynamicWorkflow`, not an addon. Addons run outside the runner and cannot reach `run(_:)`, nested reservations, or session lineage. The transition reuses the existing cross-workflow child-session path (`dispatchCrossWorkflowCallee` shape, nested reservations, `appendNestedResultOnce`). It does not add a second engine. |
| Does validation failure automatically return control to the brain? | Yes, by default. One authored field, `onFailure: "return" \| "fail"` (default `return`), covers both invalid definitions and child failures. |
| Which node kinds/add-ons/models are allowed by default? | Deny by default. Only `agent` nodes are allowed. Backends and models default to the set used by the parent workflow's own nodes. Add-ons default to none. Widening is possible only through the authored, reviewable `dynamicWorkflow.allow` on the parent. |
| Promotion via #40? | Out of scope. Generated definitions are session-scoped evidence only. |

## Authored contract (parent workflow)

The brain step has a labeled transition carrying `dynamicWorkflow`. Its
`toStepId` is the step that receives the child result. That is normally the
brain step itself, which forms the loop.

```json
{
  "id": "brain",
  "nodeId": "brain",
  "transitions": [
    {
      "label": "execute_workflow",
      "toStepId": "brain",
      "dynamicWorkflow": {
        "maxIterations": 4,
        "onFailure": "return",
        "limits": { "maxDefinitionBytes": 65536, "maxNodes": 8, "maxSteps": 16, "childMaxSteps": 32 },
        "allow": { "nodeTypes": ["agent"], "backends": ["claude-code-agent"], "models": ["claude-opus-5-5"], "addons": [] }
      }
    }
  ]
}
```

When the brain emits `when.finish` (or any flags that match no transition), the
session completes normally. The brain's accepted `finish` envelope becomes the
root output. No new terminal mechanism is added.

Authored-definition validation (`DefaultWorkflowValidator`, the same validator
`riela workflow validate` uses):

- `dynamicWorkflow` cannot be combined with `toWorkflowId`, `resumeStepId` or
  `fanout` on the same transition. `toStepId` must name an existing step of the
  parent.
- `maxIterations` must be in 1...16 (default 4). Each limit must be a positive
  value at or below its hard ceiling: 262144 bytes, 32 nodes, 64 steps, 256
  child steps. Defaults are 65536 bytes, 8 nodes, 16 steps and 32 child steps.
- `allow.nodeTypes` may only contain existing `NodeType` raw values. An unknown
  backend or add-on name is a validation error.
- A warning (not an error) is emitted when the effective `maxLoopIterations`
  for a self-targeting dynamic transition is at or below `maxIterations`,
  because the default loop guard would then stop the loop first.
- At runtime, a dynamic transition must be the only selected transition of its
  step execution. Selecting it together with another transition is rejected,
  the same way the existing "more than one nested callee" rule works.

## Brain decision envelope

The brain node's accepted output payload, validated by the runtime when the
dynamic transition is selected:

```json
{
  "decision": "execute_workflow",
  "rationale": "string, <= 2000 chars",
  "workflow": { "...": "AuthoredWorkflowJSON (same shape as workflow.json)" },
  "nodePayloads": { "<nodeId or nodeFile>": { "...": "AgentNodePayload" } },
  "input": { "...": "JSON object handed to the child as its run variables" }
}
```

```json
{ "decision": "finish", "rationale": "string", "finalResult": {}, "evidenceRefs": ["string"] }
```

- `workflow` + `nodePayloads` mean exactly what they mean in the temporary
  workflow payload (`riela workflow run --workflow-json`). The private
  `TemporaryWorkflowPayload` materialization in `WorkflowRunCommand.swift`
  moves into `RielaCore` as one shared function. The CLI temp-workflow path and
  the dynamic transition both call it (DRY).
- If the dynamic transition is selected but `decision != "execute_workflow"`
  or the envelope does not decode, that is an invalid definition (see below),
  not a crash.
- The example ships a JSON-schema output contract for the brain node. A schema
  is optional for other authors; the runtime check above is authoritative.

## Runtime data flow

```text
brain execution E_n accepted (when.execute_workflow)
  -> pre-commit publication hook (parent route staged)
       materialize envelope.workflow/nodePayloads   (shared temp-workflow materializer)
       validateAuthoredWorkflowJSON + DefaultWorkflowValidator.validate(workflow, nodePayloads:)
       DynamicWorkflowPolicy.check(definition, parent, transition)  -> diagnostics
       iteration n = 1 + persisted prior dynamic iterations of this session
       valid   -> immutable reservation (branchId "dynamic-workflow",
                  calleeWorkflow, calleeNodePayloads, calleeRevision digest,
                  child session created with parent/root lineage + generatedWorkflow origin)
       invalid -> no reservation
  -> commit (parent cursor pinned at transition.toStepId)
  -> post-commit dispatch
       valid   -> run child in-process (same runner, adapter, store, admission;
                  crossWorkflowDispatchDepth + 1; maxSteps = limits.childMaxSteps)
       invalid -> no child
  -> appendWorkflowMessageOnce to toStepId with payload.dynamicWorkflowResult
  -> brain executes again with the result in its inbox
```

### Result message (`payload.dynamicWorkflowResult`)

```json
{
  "iteration": 2,
  "maxIterations": 4,
  "outcome": "completed | failed | cancelled | invalid",
  "childSessionId": "string | null",
  "workflowId": "string | null",
  "definitionDigest": "sha256:... | null",
  "rationale": "string",
  "rootOutput": {},
  "failureKind": "string | null",
  "failureReason": "string | null",
  "diagnostics": [{ "severity": "error", "path": "string", "message": "string" }]
}
```

The persisted message is the per-iteration evidence record. Together with the
child session and the nested reservation it makes every iteration inspectable
through `session status/export`, the message log and the session tree. No new
evidence table is added.

### Session lineage and provenance

- The child session sets `parentSessionId` to the brain session and
  `rootSessionId` to the brain session's root, the same as cross-workflow
  children. Existing session-tree/rollup inspection therefore lists every
  generated run.
- New optional `WorkflowSession.generatedWorkflow`, persisted only on generated
  children and decoded with `decodeIfPresent`:
  `{ iteration, definitionDigest, sourceStepExecutionId, rationale }`.
- `definitionDigest` = the existing `nestedCalleeRevision(workflow:nodePayloads:)`
  sha256 over the materialized definition. The same value is stored as the
  reservation's `calleeRevision`.
- The iteration number comes from persisted state, never an in-memory
  counter: 1 + the number of distinct source executions in this session that
  already have a `dynamic-workflow` reservation or a delivered
  `dynamicWorkflowResult` message.

### Privilege and bounds (runtime-enforced, `DynamicWorkflowPolicy`)

The parent's authority is what its reviewed definition grants: the
backends/models its own nodes use, plus the static `dynamicWorkflow.allow`
grant. The generated definition can only narrow that authority. The policy
covers the whole generated `AuthoredWorkflowJSON` (workflow, node registry,
steps and transitions) as well as `nodePayloads` (rules 9-10). Each violation
becomes an `error` diagnostic (`path` + message prefixed
`dynamic workflow policy:`). Rules:

1. Size: canonical JSON of `{workflow, nodePayloads}` <= `maxDefinitionBytes`.
   Node and step counts must be within the limits.
2. Node types: every generated node's `nodeType` (absent = `agent`) must be in
   `allow.nodeTypes` (default `["agent"]`). Add-on nodes are allowed only if
   the add-on name is in `allow.addons` (default `[]`).
3. Backend/model: `executionBackend` must be in `allow.backends` (default: the
   backends of the parent's nodes) and `model` in `allow.models` (default: the
   parent's node models).
4. Authority-bearing payload fields must be absent from generated payloads:
   `workingDirectory`, `command`, `container`, `sandbox`, `agentSandbox`,
   `agentToolPolicy`, non-empty `agentEnvironment`, `baseURL`,
   `apiKeyEnvironment`, `provider`, `providerProxy`, `backendPolicy`,
   `requiredEnvironment`, every `*TemplateFile` field, and `memories`. Generated
   agent nodes then receive `agentSandbox` and `agentToolPolicy` from the
   emitting brain node's payload, and inherit the parent run's working
   directory.
5. No recursion or escape: a generated workflow cannot contain
   `dynamicWorkflow` or `toWorkflowId` transitions, and its `workflowId` must
   differ from the parent's. Fanout branches inside a generated workflow are
   allowed, because they stay inside the child session tree.
6. Iterations: when the dynamic transition is selected for iteration
   `maxIterations + 1`, the parent fails with failureKind `budgetExceeded` and
   reason `dynamic workflow iteration budget exhausted (<max>)`. Invalid
   definitions count as iterations.
7. Depth: the child runs at `crossWorkflowDispatchDepth + 1` under the existing
   `maxCrossWorkflowDispatchDepth` (8). Rule 5 already caps generated children
   at depth 1 under the brain.
8. Steps/time: the child request uses `maxSteps = limits.childMaxSteps`. It
   inherits the parent's `defaultTimeoutMs` and `maxLoopIterations`, and every
   generated `defaults.nodeTimeoutMs` is clamped to the parent's. The parent's
   own `--max-steps` and `--timeout-ms` still bound the whole run, because the
   child runs inside the same process and task.
9. Structural key allowlist over the **whole** generated definition, not only
   `nodePayloads`: the policy checks the raw envelope JSON object keys before
   materialization. Any key not listed here is an `error` diagnostic
   (`dynamic workflow policy: field '<path>' is not allowed in generated
   workflows`), so fields added to the model later are denied by default.
   Rules 1-8 still apply to the allowed keys. Rule 4 stays as the explicit
   statement of the authority-bearing payload fields; rule 9 covers them as
   well.

   | Object | Allowed keys |
   |---|---|
   | `workflow` (AuthoredWorkflowJSON) | `workflowId`, `description`, `defaults`, `prompts`, `entryStepId`, `managerStepId`, `nodes`, `steps` |
   | `workflow.defaults` | `nodeTimeoutMs`, `maxLoopIterations`, `fanoutConcurrency` (each clamped to the parent's value) |
   | `workflow.nodes[]` (WorkflowNodeRegistryRef) | `id`, `nodeFile`, `kind`, `execution`, `repeat`, and `addon` only when its name is in `allow.addons` (rule 2) |
   | `workflow.steps[]` | `id`, `nodeId`, `description`, `role`, `promptVariant`, `timeoutMs` (clamped to the parent's `defaultTimeoutMs`), `stallTimeoutMs`, `failurePolicy`, `sessionPolicy`, `transitions`, `loop` (step loop: `while`, `restartAt`, `maxIterations`) |
   | `workflow.steps[].transitions[]` | `toStepId`, `label`, `fanout` (rule 5) |
   | `...transitions[].fanout` | `groupId`, `itemsFrom`, `itemVariable`, `concurrency`, `joinStepId`, `failurePolicy`, `resultOrder` |
   | `nodePayloads.<key>` (AgentNodePayload) | `id`, `description`, `nodeType`, `executionBackend`, `model`, `modelFreeze`, `effort`, `systemPromptTemplate`, `promptTemplate`, `sessionStartPromptTemplate`, `includeRuntimeVariablesInPrompt`, `promptVariants` (entries limited to `systemPromptTemplate`, `promptTemplate`, `sessionStartPromptTemplate`), `sessionPolicy`, `variables`, `input` (`description`, `jsonSchema`), `output` (`description`, `jsonSchema`, `maxValidationAttempts`) |

   This explicitly denies the following authority-bearing fields:
   - workflow-level `handover`: `HandoverSinkConfig` `command`/`path`/`remote`
     can run commands or write files when a handover trigger fires;
   - workflow-level `memories`, including `cross-workflow` scope, which would
     reach memory shared with other workflows;
   - workflow-level `requiredEnvironment`;
   - workflow-level `loop`: its gates, notifications, concurrency leases and
     self-evolution reach external sinks or shared leases;
   - workflow-level `triggerDefaults`: it is inert for an in-process child, but
     it is outside the allowlist and is denied;
   - node-registry `nodeRef`, which would import another workflow's payload and
     bypass the payload checks;
   - node-registry `inputFilters`, which can run JavaScript;
   - node-registry `memories` and `requiredEnvironment`;
   - step `placement` (distributed or remote execution) and `stepFile`;
   - fanout `writeOwnership`, `changeTracking` and `dependencies`
     (ChangeRuntime/worktree effects);
   - output `jsonSchemaFrom`, `projection` and `deliverables`.
10. Payload sourcing: every generated node is resolved only from the envelope's
    `nodePayloads`, keyed by `nodeFile` or `id` as in the temp-workflow
    payload. A node with no matching entry is a policy error. There is never a
    file-system fallback, either relative to the parent's workflow directory
    or to any other directory.

### Failure, timeout and cancellation

- Invalid definition: `outcome: "invalid"` plus diagnostics, returned to the
  brain (`onFailure: "return"`). With `onFailure: "fail"` the parent fails
  through the existing `crossWorkflowDispatchFailed` path, carrying the
  diagnostics in the reason.
- Child `failed`, including `nodeTimeout`, `maxStepsExceeded` and adapter
  failures: `outcome: "failed"` with the child's `failureKind`/`failureReason`
  and `rootOutput` (if any), or the parent fails under `onFailure: "fail"`.
- A child that ends `cancelled` because the parent's task was cancelled is
  rethrown as cancellation. The parent then finalizes `cancelled`, as defined
  by #27. A child that ended `cancelled` while the parent was still live (for
  example after an operator move) returns `outcome: "cancelled"`.

### Mock scenarios

`simulatesCrossWorkflowDispatch` (on under `--mock-scenario`) only short-cuts
`toWorkflowId` calls whose callee would need registry resolution. Dynamic
transitions need no resolver, so they always dispatch live in-process, with
the same scenario-backed adapter. Generated node ids are looked up in the mock
scenario `responses` map like any other node id. This is what lets the example
run real child sessions deterministically. The nested publication hook for
dynamic transitions is not gated on `simulatesCrossWorkflowDispatch` or
`calleeResolver`. Without a `nestedInvocationPersistenceStore` (in-memory unit
tests), dispatch runs without durable reservations, as cross-workflow does.

### Resume and rerun

- Resume: `recoverNestedInvocationsBeforeResuming` reconstructs pending
  `dynamic-workflow` reservations from the persisted `calleeWorkflow` /
  `calleeNodePayloads` / `calleeRevision`, the same way it handles
  `cross-workflow` ones. It never re-asks the brain. A reservation whose digest
  does not match fails closed, as today. Invalid-definition iterations are
  re-derived deterministically from the persisted accepted output and
  delivered through `appendWorkflowMessageOnce`, so a replay cannot add a
  second message.
- Rerun: rerunning the brain step creates a new session. Earlier iteration
  results arrive only through the existing rerun inbox carry-over and history
  import. Re-generating at the rerun target is the explicit purpose of a
  rerun. Already-created iterations in the source session are never
  re-executed.

### Session scope

Generated definitions are never written to project/user/mutable registries.
They exist only in the nested reservation, the child snapshot and the result
message. They are removed by the same terminal retention as their session
family.

## Example: `examples/brain-generated-workflow-loop/`

- `workflow.json`: one agent node `brain`, one step `brain` with the dynamic
  transition above. `defaults.maxLoopIterations` must be high enough that the
  default loop guard never triggers before `maxIterations` (for example 6).
- `nodes/node-brain.json` plus `prompts/brain.md`: the prompt asks for the next
  minimal workflow from the objective and `dynamicWorkflowResult`. The output
  contract is the envelope schema.
- `mock-scenario.json`: brain responses
  1. `execute_workflow` generating `generated-inventory` (node `inventory`).
  2. `execute_workflow` generating `generated-verify` (node `verify`), whose
     `input` quotes the missing-verification item from iteration 1's
     `rootOutput`.
  3. `finish` with combined evidence.

  It also has scenario responses for `inventory`, which reports
  `missingVerification`, and `verify`.
- `README.md` (live and mock commands) and `EXPECTED_RESULTS.md`. The expected
  results assert: two child sessions with `parentSessionId`/`rootSessionId` =
  the brain session; `generatedWorkflow.iteration` 1 and 2; distinct
  `definitionDigest`s; iteration 2's `input` derived from iteration 1's
  `rootOutput`; status `completed`; root output = the finish envelope.
- Registration: `Tests/RielaCLITests/RielaExampleCatalog.swift`
  (`rielaExampleWorkflowNames()`) and `ExampleCatalog.expectedMockScenarioCount`
  +1. Verify with `riela workflow run examples/brain-generated-workflow-loop
  --mock-scenario examples/brain-generated-workflow-loop/mock-scenario.json
  --output json` directly. `testMockScenarioExamplesRunThroughSwiftCLI` stays
  skipped, because it is red on main for an unrelated example.

## Tests (focused)

- Core: a valid envelope runs the child with lineage, digest and iteration and
  delivers the result. Two iterations with different definitions. An invalid
  definition returns diagnostics. Each privilege rule (backend, model, node
  type, add-on, forbidden field, nested `dynamicWorkflow`/`toWorkflowId`, size,
  nodes, steps) rejects. The iteration budget gives `budgetExceeded`.
  `onFailure: "fail"`. A failed child returns `outcome: failed`. Parent
  cancellation propagates.
- Structural allowlist (rules 9-10): each of these, inside an otherwise clean
  envelope with plain agent `nodePayloads`, yields outcome `invalid` with a
  `dynamic workflow policy:` diagnostic naming the field path, and no child
  session is created:
  - `workflow.handover.sinks[]` carrying `command`;
  - workflow-level `memories` with `cross-workflow` scope;
  - node-level `memories`;
  - a JavaScript `nodes[].inputFilters`;
  - `nodes[].nodeRef`;
  - workflow/node `requiredEnvironment`;
  - workflow `loop`;
  - step `placement`;
  - an unknown future key;
  - a node with no `nodePayloads` entry.
- Resume: crash after reservation, before delivery. Resume runs the persisted
  definition (same digest) without a brain execution.
- Authored validation of the `dynamicWorkflow` field combinations and limits.
- Static `toWorkflowId` cross-workflow tests and the temp-workflow tests stay
  green, because the shared materializer is a pure extraction.

## Out of scope / follow-up

- Wall-clock budgets for the whole loop and token/cost budgets beyond the
  inherited `--timeout-ms` and existing loop budget guards.
- Promotion of a generated definition to a registry or package (#40).
- Generated workflows that call registered workflows or nest dynamic calls.
- GraphQL/web surfaces specific to generated iterations. Existing session
  views show them as ordinary child sessions.
