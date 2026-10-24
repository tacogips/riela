# Brain-Generated Workflow Loop

The `dynamicWorkflow` transition lets a brain node ask the Riela runtime to validate an inline workflow definition, execute it as a child session, and deliver a structured result back to the parent. The checked-in [example bundle](../../examples/brain-generated-workflow-loop/) runs an inventory child, a verification child, and then a finish decision.

## Authoring the transition

Add `dynamicWorkflow` to a transition with a `toStepId` that receives the result, usually the brain step itself:

```json
{
  "label": "execute_workflow",
  "toStepId": "brain",
  "dynamicWorkflow": {
    "maxIterations": 4,
    "onFailure": "return",
    "allow": {
      "nodeTypes": ["agent"],
      "backends": ["claude-code-agent"],
      "models": ["claude-opus-5-5"]
    }
  }
}
```

`maxIterations` defaults to 4 and must be between 1 and 16. `onFailure` defaults to `return`; `fail` instead fails the parent when a generated definition is invalid or a child fails. Optional limits default to 65,536 definition bytes, 8 nodes, 16 steps, and 32 child steps, within hard ceilings of 262,144 bytes, 32 nodes, 64 steps, and 256 child steps. A self-targeting loop should set the parent `maxLoopIterations` above `maxIterations` so the ordinary loop guard does not stop it first.

The runtime validates the parent definition with the same `DefaultWorkflowValidator` used by `riela workflow validate`. A dynamic transition cannot combine with `toWorkflowId`, `resumeStepId`, or `fanout`, and the generated dynamic transition must be the only selected transition for that execution.

## Brain decision envelope

For an execution decision, the node returns an object with `decision: "execute_workflow"`, a rationale, the inline authored workflow, `nodePayloads`, and an object `input`. `workflow` and `nodePayloads` use the same shapes as the temporary workflow JSON format. Node prompt content must be embedded as `promptTemplate`; external template file references are rejected.

For a terminal decision, return `decision: "finish"`, a rationale, `finalResult`, and `evidenceRefs`. A finish output selects no dynamic transition, so the parent completes normally and retains that envelope as its root output.

## Runtime result

After each child run, the runtime appends one `dynamicWorkflowResult` message to `toStepId`. The result includes the iteration and maximum, outcome (`completed`, `failed`, `cancelled`, or `invalid`), child session and workflow identifiers when available, definition digest, rationale, root output, failure details, and validation diagnostics. The next brain execution receives this message through its inbox in the runtime variables. Do not rely on the `{{inbox.latest.output}}` prompt-template placeholder: it currently renders empty for `dynamicWorkflowResult` messages.

Invalid definitions and child failures count as iterations. With `onFailure: "return"`, their result returns to the brain for another decision. Selecting another execution after the limit fails with `budgetExceeded` before a child reservation is made.

## Privileges and limits

Generated workflows are deny-by-default and session-scoped. `allow` can grant node types, backends, models, and add-ons; the generated workflow cannot exceed those grants or the parent's authority. Only the rule-9 key allowlist is accepted across the generated workflow and node payloads. Authority-bearing fields such as commands, working directories, sandbox/tool policy, environment, providers, external template files, and memories are rejected. The runtime applies the brain's sandbox and tool policy to generated agent payloads.

The runtime bounds definition size, node/step counts, child steps, loop iterations, depth, and inherited timeouts. Generated workflows cannot recursively dispatch another dynamic workflow or call a registered workflow. They do not create registry entries or promotion records.

## Resume and inspection

The child reservation, generated definition digest, provenance, and result message are persisted. Resume uses that recorded work and does not ask the brain to generate the same iteration again. Each child records `generatedWorkflow.iteration`, `definitionDigest`, `sourceStepExecutionId`, and rationale, alongside its normal parent/root session lineage.

Inspect the full session tree and iteration evidence with:

```bash
riela session status <brain-session-id> --output json
riela session export <brain-session-id> --output json
```

The [example's EXPECTED_RESULTS.md](../../examples/brain-generated-workflow-loop/EXPECTED_RESULTS.md) lists the assertions for two child sessions, distinct digests, carried verification input, final decision, and brain execution count.

See the [brain-generated workflow loop design](../../design-docs/specs/design-loop-engineering-brain-generated-workflow-loop.md) for the full contract and allowlist.
