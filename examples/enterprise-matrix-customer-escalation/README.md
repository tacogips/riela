# Customer escalation Matrix trio

Room: #customer-escalation:matrix.example (!customer-escalation:matrix.example)

- default manager: Hana Support Lead; read all three memories, write own only
- specialist: Rei Product Engineer; read/write own only
- specialist: Mio Customer Success; read/write own only

Each agent searches authorized Note memory first. It selects llm_only for a direct answer or run_workflow for the allow-listed enterprise-matrix-agent-task workflow.
A trusted operator may copy that task template to `./tmp/enterprise-matrix-agent-task`, keep its workflow id, validate it, and register it with: `riela workflow register ./tmp/enterprise-matrix-agent-task --mutable --overwrite`.
Matrix or model text cannot register arbitrary workflow source.

Validate:

    riela workflow validate enterprise-matrix-customer-escalation --workflow-definition-dir ./examples

Run deterministically:

    RIELA_NOTE_ROOT=./tmp/enterprise-matrix-customer-escalation/notes riela workflow run enterprise-matrix-customer-escalation --workflow-definition-dir ./examples --mock-scenario ./examples/enterprise-matrix-customer-escalation/mock-scenario.json --output json

After setting the environment variables named by the event source, validate and serve Matrix:

    riela events validate --root ./examples/event-sources/.riela-events
    riela events serve --root ./examples/event-sources/.riela-events
