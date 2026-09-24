# Task repair loop

This workflow supplies one repair step and one required verification gate. A Work Runtime task selects this workflow as its entry; task run reserves and executes the attempt. The deterministic director uses the persisted gate result, completion evidence, guard state, and attempt budget to accept, recover, wait for a human, or stop.

Validate and run the standalone success fixture with:

    riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
    riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --output json

The mock run proves the workflow bundle loads and reaches the accepted gate. It does not create or accept a task. `TaskExampleHarness` in `TaskDispatcherIntegrationTests.swift` creates a task through `WorkStore`, then runs `TaskDispatch` and `WorkflowRunCommand` with the deterministic scenario. `TaskRuntimeExampleTests.swift` checks acceptance, gate-visit guard stop, capacity wait, and rejected-gate recovery through the task ledger. The required gate still demands an accepted result for task completion; its finding-count policy avoids creating a persistent synthetic finding solely because the first decision was rejected. A standalone rejected or needs-work gate instead fails the workflow run and retains gate evidence. The bundled success fixture contains no live credentials.
