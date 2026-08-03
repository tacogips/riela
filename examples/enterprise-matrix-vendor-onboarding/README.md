# Vendor onboarding Matrix trio

Room: #vendor-onboarding:matrix.example (!vendor-onboarding:matrix.example)

- default manager: Nao Procurement Lead; read all three memories, write own only
- specialist: Yuna Finance Analyst; read/write own only
- specialist: Ema Legal Counsel; read/write own only

Each agent searches authorized Note memory first. It selects llm_only for a direct answer or run_workflow for the allow-listed enterprise-matrix-agent-task workflow.
A trusted operator may copy that task template to `./tmp/enterprise-matrix-agent-task`, keep its workflow id, validate it, and register it with: `riela workflow register ./tmp/enterprise-matrix-agent-task --mutable --overwrite`.
Matrix or model text cannot register arbitrary workflow source.

Validate:

    riela workflow validate enterprise-matrix-vendor-onboarding --workflow-definition-dir ./examples

Run deterministically:

    RIELA_NOTE_ROOT=./tmp/enterprise-matrix-vendor-onboarding/notes riela workflow run enterprise-matrix-vendor-onboarding --workflow-definition-dir ./examples --mock-scenario ./examples/enterprise-matrix-vendor-onboarding/mock-scenario.json --output json

After setting the environment variables named by the event source, validate and serve Matrix:

    riela events validate --root ./examples/event-sources/.riela-events
    riela events serve --root ./examples/event-sources/.riela-events
