# Task repair loop

This workflow supplies one repair step and one required verification gate. A Work Runtime task selects this workflow as its entry; task run reserves and executes the attempt. The deterministic director uses the persisted gate result, completion evidence, guard state, and attempt budget to accept, recover, wait for a human, or stop.

Validate and run the standalone success fixture with:

    riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
    riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --output json

The mock run proves the workflow bundle loads and reaches the accepted gate. It does not create a task. TaskRuntimeExampleTests must create task fixtures and exercise acceptance, a rejected gate followed by bounded recovery, repeated-finding guard stop, and capacity wait with no attempt or session. The tests should change deterministic mock responses for those cases; the bundled success fixture contains no live credentials.
