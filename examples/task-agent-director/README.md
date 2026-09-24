# Task agent director

The Work Runtime may start this workflow once as an ordinary child after it reconciles the work attempt. The child reads the retained TaskView and recommends a decision; the parent validates allowed kinds, causality, completion, and budget before applying anything. The child session and cost are charged once to the parent task. It cannot recursively invoke another director.

Validate and run the standalone mock with:

    riela workflow validate task-agent-director --workflow-definition-dir examples --output json
    riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --output json

The mock recommends kind accept. A standalone workflow run cannot prove the parent accepts that recommendation. `TaskExampleHarness` seeds judged work through `WorkStore` and executes the linked child through `TaskDispatch` and `WorkflowRunCommand`. `TaskRuntimeExampleTests.swift` checks allowed output against judged completion, seven-token child accounting after store reopen, and forbidden or failed child escalation with replay stability.
