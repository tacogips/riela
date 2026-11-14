# Customer escalation Matrix trio

Room: #customer-escalation:matrix.example (!customer-escalation:matrix.example)

- default manager: Hana Support Lead; read all three memories, write own only
- specialist: Rei Product Engineer; read/write own only
- specialist: Mio Customer Success; read/write own only

Each agent reads its declared persona memory from the SQLite-backed persona-chat-memory database first. It selects llm_only for a direct answer or run_workflow to generate, register, and execute a normal mutable Riela workflow.
The generated workflow accepts only the agent-authored title and standalone prompt; Riela owns the bundle structure, backend, model, paths, registration, and execution. The prompt is stored separately under the generated bundle's prompts directory.
The workflow id is content-derived, so an identical task reuses the same registered workflow. Matrix or model text cannot supply commands, paths, credentials, or arbitrary workflow JSON.

Validate:

    riela workflow validate enterprise-matrix-customer-escalation --workflow-definition-dir ./examples

Run deterministically:

    RIELA_MEMORY_ROOT=./tmp/enterprise-matrix-customer-escalation/memory riela workflow run enterprise-matrix-customer-escalation --workflow-definition-dir ./examples --mock-scenario ./examples/enterprise-matrix-customer-escalation/mock-scenario.json --output json

After setting the environment variables named by the event source, validate and serve Matrix:

    riela events validate --event-root ./examples/event-sources/.riela-events --workflow-definition-dir ./examples
    riela events serve --event-root ./examples/event-sources/.riela-events --workflow-definition-dir ./examples
