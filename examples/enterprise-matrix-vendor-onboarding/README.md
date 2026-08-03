# Vendor onboarding Matrix trio

Room: #vendor-onboarding:matrix.example (!vendor-onboarding:matrix.example)

- default manager: Nao Procurement Lead; read all three memories, write own only
- specialist: Yuna Finance Analyst; read/write own only
- specialist: Ema Legal Counsel; read/write own only

Each agent searches authorized Note memory first. It selects llm_only for a direct answer or run_workflow to generate, register, and execute a normal mutable Riela workflow.
The generated workflow accepts only the agent-authored title and standalone prompt; Riela owns the bundle structure, backend, model, paths, registration, and execution. The prompt is stored separately under the generated bundle's prompts directory.
The workflow id is content-derived, so an identical task reuses the same registered workflow. Matrix or model text cannot supply commands, paths, credentials, or arbitrary workflow JSON.

Validate:

    riela workflow validate enterprise-matrix-vendor-onboarding --workflow-definition-dir ./examples

Run deterministically:

    RIELA_NOTE_ROOT=./tmp/enterprise-matrix-vendor-onboarding/notes riela workflow run enterprise-matrix-vendor-onboarding --workflow-definition-dir ./examples --mock-scenario ./examples/enterprise-matrix-vendor-onboarding/mock-scenario.json --output json

After setting the environment variables named by the event source, validate and serve Matrix:

    riela events validate --event-root ./examples/event-sources/.riela-events --workflow-definition-dir ./examples
    riela events serve --event-root ./examples/event-sources/.riela-events --workflow-definition-dir ./examples
