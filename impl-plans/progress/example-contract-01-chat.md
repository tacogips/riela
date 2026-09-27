# example-contract-01-chat implementation progress

- Mode: `issue-resolution`; issue reference: `comm-000002`; Codex-agent references: `[]`.
- Branch: `fix/example-contract-migration`; assigned dependencies: `[]`; accepted design: `design-docs/specs/design-agent-node-output-contract.md` §12.
- State: implementation incomplete and blocked on the installed 0.2.1 add-on host-resolution failure; downstream independent review, shared documentation, commit, and push remain pending.
- CLI: `riela --version` exit 0, `0.2.1`; complete log: `tmp/example-contract-migration/example-contract-01-chat/attempt-1/riela-version.log`.
- Evidence directory: `tmp/example-contract-migration/example-contract-01-chat/attempt-1`; per-edit preimages, intentions, and postimages: `edit-01` through `edit-05`.
- Current `git diff --check` exit 0; log: `tmp/example-contract-migration/example-contract-01-chat/attempt-1/diff-check.log`.

## Per-bundle inventory and verification

Each path listed below was read and SHA-256 recorded in `inventory.json`. Commands ran from the repository root, with full combined stdout/stderr in the named logs. Nonzero host-resolution outcomes are failures, not passes.

### chat-event-attachment-judgement

Reviewed paths: `examples/chat-event-attachment-judgement/EXPECTED_RESULTS.md`, `examples/chat-event-attachment-judgement/mock-scenario-unsupported.json`, `examples/chat-event-attachment-judgement/mock-scenario.json`, `examples/chat-event-attachment-judgement/nodes/node-judge-attachments.json`, `examples/chat-event-attachment-judgement/prompts/judge-attachments.md`, `examples/chat-event-attachment-judgement/workflow.json`.

- `riela workflow validate chat-event-attachment-judgement --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-event-attachment-judgement-validate.log`.
- `riela workflow inspect chat-event-attachment-judgement --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-event-attachment-judgement-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.
- Mock `mock-scenario-unsupported.json`: `riela workflow run chat-event-attachment-judgement --workflow-definition-dir examples --mock-scenario examples/chat-event-attachment-judgement/mock-scenario-unsupported.json --variables-file tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario-unsupported/variables.json --session-store tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario-unsupported/sessions --artifact-root tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario-unsupported/artifacts --output json` → exit 0, status `completed`, node executions 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario-unsupported/run.log`.
- Mock `mock-scenario.json`: `riela workflow run chat-event-attachment-judgement --workflow-definition-dir examples --mock-scenario examples/chat-event-attachment-judgement/mock-scenario.json --variables-file tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario/variables.json --session-store tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario/sessions --artifact-root tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario/artifacts --output json` → exit 0, status `completed`, node executions 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-event-attachment-judgement-mock-scenario/run.log`.

### chat-reply-webhook

Reviewed paths: `examples/chat-reply-webhook/EXPECTED_RESULTS.md`, `examples/chat-reply-webhook/workflow.json`.

- `riela workflow validate chat-reply-webhook --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-reply-webhook-validate.log`.
- `riela workflow inspect chat-reply-webhook --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-reply-webhook-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.

### chat-supervisor-collaboration

Reviewed paths: `examples/chat-supervisor-collaboration/.riela-events/bindings/chat-task-to-collaboration.json`, `examples/chat-supervisor-collaboration/.riela-events/destinations/coordinator-chat.json`, `examples/chat-supervisor-collaboration/.riela-events/destinations/shared-brainstorm-chat.json`, `examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-a-review-chat.json`, `examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-b-review-chat.json`, `examples/chat-supervisor-collaboration/.riela-events/sources/collaboration-chat.json`, `examples/chat-supervisor-collaboration/EXPECTED_RESULTS.md`, `examples/chat-supervisor-collaboration/mock-scenario.json`, `examples/chat-supervisor-collaboration/nodes/node-workflow-a-brainstorm.json`, `examples/chat-supervisor-collaboration/nodes/node-workflow-b-brainstorm.json`, `examples/chat-supervisor-collaboration/nodes/node-workflow-c-request-review.json`, `examples/chat-supervisor-collaboration/nodes/node-workflow-c-spec-and-implementation.json`, `examples/chat-supervisor-collaboration/nodes/node-workflow-output.json`, `examples/chat-supervisor-collaboration/prompts/workflow-a-brainstorm.md`, `examples/chat-supervisor-collaboration/prompts/workflow-b-brainstorm.md`, `examples/chat-supervisor-collaboration/prompts/workflow-c-request-review.md`, `examples/chat-supervisor-collaboration/prompts/workflow-c-spec-and-implementation.md`, `examples/chat-supervisor-collaboration/prompts/workflow-output.md`, `examples/chat-supervisor-collaboration/workflow.json`.

- `riela workflow validate chat-supervisor-collaboration --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-supervisor-collaboration-validate.log`.
- `riela workflow inspect chat-supervisor-collaboration --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/chat-supervisor-collaboration-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.
- Mock `mock-scenario.json`: `riela workflow run chat-supervisor-collaboration --workflow-definition-dir examples --mock-scenario examples/chat-supervisor-collaboration/mock-scenario.json --variables-file tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-supervisor-collaboration-mock-scenario/variables.json --session-store tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-supervisor-collaboration-mock-scenario/sessions --artifact-root tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-supervisor-collaboration-mock-scenario/artifacts --output json` → exit 0, status `completed`, node executions 5; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/chat-supervisor-collaboration-mock-scenario/run.log`.

### discord-agent-trio-chat

Reviewed paths: `examples/discord-agent-trio-chat/EXPECTED_RESULTS.md`, `examples/discord-agent-trio-chat/assets/icons/mika-claude.png`, `examples/discord-agent-trio-chat/assets/icons/rina-cursor.png`, `examples/discord-agent-trio-chat/assets/icons/yui-codex.png`, `examples/discord-agent-trio-chat/mock-scenario.json`, `examples/discord-agent-trio-chat/nodes/node-read-mika-memory.json`, `examples/discord-agent-trio-chat/nodes/node-read-rina-memory.json`, `examples/discord-agent-trio-chat/nodes/node-read-yui-memory.json`, `examples/discord-agent-trio-chat/nodes/node-write-mika-memory.json`, `examples/discord-agent-trio-chat/nodes/node-write-rina-memory.json`, `examples/discord-agent-trio-chat/nodes/node-write-yui-memory.json`, `examples/discord-agent-trio-chat/workflow.json`.

- `riela workflow validate discord-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-agent-trio-chat-validate.log`.
- `riela workflow inspect discord-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-agent-trio-chat-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: installed CLI cannot resolve an add-on executable before execution. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### discord-codex-chat

Reviewed paths: `examples/discord-codex-chat/EXPECTED_RESULTS.md`, `examples/discord-codex-chat/mock-scenario.json`, `examples/discord-codex-chat/nodes/node-answer-discord-message.json`, `examples/discord-codex-chat/prompts/answer-discord-message.md`, `examples/discord-codex-chat/workflow.json`.

- `riela workflow validate discord-codex-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-codex-chat-validate-post.log`.
- `riela workflow inspect discord-codex-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-codex-chat-inspect-post.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.
- Mock `mock-scenario.json`: `riela workflow run discord-codex-chat --workflow-definition-dir examples --mock-scenario examples/discord-codex-chat/mock-scenario.json --variables-file tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/discord-codex-chat-mock-scenario/variables.json --session-store tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/discord-codex-chat-mock-scenario/sessions --artifact-root tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/discord-codex-chat-mock-scenario/artifacts --output json` → exit 0, status `completed`, node executions 2; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/discord-codex-chat-mock-scenario/run.log`.

### discord-persona-chat

Reviewed paths: `examples/discord-persona-chat/EXPECTED_RESULTS.md`, `examples/discord-persona-chat/nodes/node-answer-persona-message.json`, `examples/discord-persona-chat/prompts/answer-persona-message.md`, `examples/discord-persona-chat/workflow.json`.

- `riela workflow validate discord-persona-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-persona-chat-validate.log`.
- `riela workflow inspect discord-persona-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/discord-persona-chat-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.

### enterprise-matrix-agent-personas

Reviewed paths: `examples/enterprise-matrix-agent-personas/EXPECTED_RESULTS.md`, `examples/enterprise-matrix-agent-personas/nodes/node-compliance-counsel.json`, `examples/enterprise-matrix-agent-personas/nodes/node-customer-success.json`, `examples/enterprise-matrix-agent-personas/nodes/node-finance-analyst.json`, `examples/enterprise-matrix-agent-personas/nodes/node-incident-lead.json`, `examples/enterprise-matrix-agent-personas/nodes/node-legal-counsel.json`, `examples/enterprise-matrix-agent-personas/nodes/node-procurement-lead.json`, `examples/enterprise-matrix-agent-personas/nodes/node-product-engineer.json`, `examples/enterprise-matrix-agent-personas/nodes/node-security-analyst.json`, `examples/enterprise-matrix-agent-personas/nodes/node-support-lead.json`, `examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-reply.md`, `examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-system.md`, `examples/enterprise-matrix-agent-personas/workflow.json`.

- `riela workflow validate enterprise-matrix-agent-personas --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-agent-personas-validate.log`.
- `riela workflow inspect enterprise-matrix-agent-personas --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-agent-personas-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.

### enterprise-matrix-customer-escalation

Reviewed paths: `examples/enterprise-matrix-customer-escalation/EXPECTED_RESULTS.md`, `examples/enterprise-matrix-customer-escalation/README.md`, `examples/enterprise-matrix-customer-escalation/mock-scenario.json`, `examples/enterprise-matrix-customer-escalation/workflow.json`.

- `riela workflow validate enterprise-matrix-customer-escalation --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-customer-escalation-validate.log`.
- `riela workflow inspect enterprise-matrix-customer-escalation --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-customer-escalation-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: `riela/workflow-create-register-run` may register and execute generated workflows. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### enterprise-matrix-security-incident

Reviewed paths: `examples/enterprise-matrix-security-incident/EXPECTED_RESULTS.md`, `examples/enterprise-matrix-security-incident/README.md`, `examples/enterprise-matrix-security-incident/mock-scenario.json`, `examples/enterprise-matrix-security-incident/workflow.json`.

- `riela workflow validate enterprise-matrix-security-incident --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-security-incident-validate.log`.
- `riela workflow inspect enterprise-matrix-security-incident --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-security-incident-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: `riela/workflow-create-register-run` may register and execute generated workflows. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### enterprise-matrix-vendor-onboarding

Reviewed paths: `examples/enterprise-matrix-vendor-onboarding/EXPECTED_RESULTS.md`, `examples/enterprise-matrix-vendor-onboarding/README.md`, `examples/enterprise-matrix-vendor-onboarding/mock-scenario.json`, `examples/enterprise-matrix-vendor-onboarding/workflow.json`.

- `riela workflow validate enterprise-matrix-vendor-onboarding --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-vendor-onboarding-validate.log`.
- `riela workflow inspect enterprise-matrix-vendor-onboarding --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/enterprise-matrix-vendor-onboarding-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: `riela/workflow-create-register-run` may register and execute generated workflows. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### gmail-latest-mail-digest-telegram

Reviewed paths: `examples/gmail-latest-mail-digest-telegram/EXPECTED_RESULTS.md`, `examples/gmail-latest-mail-digest-telegram/nodes/node-summarize-new-mail.json`, `examples/gmail-latest-mail-digest-telegram/prompts/summarize-new-mail.md`, `examples/gmail-latest-mail-digest-telegram/workflow.json`.

- `riela workflow validate gmail-latest-mail-digest-telegram --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/gmail-latest-mail-digest-telegram-validate-post.log`.
- `riela workflow inspect gmail-latest-mail-digest-telegram --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/gmail-latest-mail-digest-telegram-inspect-post.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.

### matrix-agent-trio-chat

Reviewed paths: `examples/matrix-agent-trio-chat/EXPECTED_RESULTS.md`, `examples/matrix-agent-trio-chat/assets/icons/mika-claude.png`, `examples/matrix-agent-trio-chat/assets/icons/rina-cursor.png`, `examples/matrix-agent-trio-chat/assets/icons/yui-codex.png`, `examples/matrix-agent-trio-chat/mock-scenario.json`, `examples/matrix-agent-trio-chat/nodes/node-read-mika-memory.json`, `examples/matrix-agent-trio-chat/nodes/node-read-rina-memory.json`, `examples/matrix-agent-trio-chat/nodes/node-read-yui-memory.json`, `examples/matrix-agent-trio-chat/nodes/node-write-mika-memory.json`, `examples/matrix-agent-trio-chat/nodes/node-write-rina-memory.json`, `examples/matrix-agent-trio-chat/nodes/node-write-yui-memory.json`, `examples/matrix-agent-trio-chat/workflow.json`.

- `riela workflow validate matrix-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/matrix-agent-trio-chat-validate.log`.
- `riela workflow inspect matrix-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/matrix-agent-trio-chat-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: installed CLI cannot resolve an add-on executable before execution. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### matrix-chat-reply

Reviewed paths: `examples/matrix-chat-reply/EXPECTED_RESULTS.md`, `examples/matrix-chat-reply/README.md`, `examples/matrix-chat-reply/local-synapse/.gitignore`, `examples/matrix-chat-reply/local-synapse/compose.yaml`, `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh`, `examples/matrix-chat-reply/workflow.json`.

- `riela workflow validate matrix-chat-reply --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/matrix-chat-reply-validate.log`.
- `riela workflow inspect matrix-chat-reply --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/matrix-chat-reply-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.

### routine-chat-manager

Reviewed paths: `examples/routine-chat-manager/EXPECTED_RESULTS.md`, `examples/routine-chat-manager/mock-scenario.json`, `examples/routine-chat-manager/nodes/node-parse-instruction.json`, `examples/routine-chat-manager/prompts/parse-instruction.md`, `examples/routine-chat-manager/workflow.json`.

- `riela workflow validate routine-chat-manager --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/routine-chat-manager-validate-final.log`.
- `riela workflow inspect routine-chat-manager --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/routine-chat-manager-inspect-final.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.
- Mock `mock-scenario.json`: blocked; prerequisite: `riela/routine-create` writes `.riela/routines/routines.sqlite` and event source/binding files in the working directory. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### shared-agent-trio-personas

Reviewed paths: `examples/shared-agent-trio-personas/nodes/node-mika-claude.json`, `examples/shared-agent-trio-personas/nodes/node-rina-cursor.json`, `examples/shared-agent-trio-personas/nodes/node-yui-codex.json`, `examples/shared-agent-trio-personas/prompts/mika-system.md`, `examples/shared-agent-trio-personas/prompts/persona-reply.md`, `examples/shared-agent-trio-personas/prompts/rina-system.md`, `examples/shared-agent-trio-personas/prompts/yui-system.md`, `examples/shared-agent-trio-personas/workflow.json`.

- `riela workflow validate shared-agent-trio-personas --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/shared-agent-trio-personas-validate.log`.
- `riela workflow inspect shared-agent-trio-personas --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/shared-agent-trio-personas-inspect.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.

### slack-agent-trio-chat

Reviewed paths: `examples/slack-agent-trio-chat/EXPECTED_RESULTS.md`, `examples/slack-agent-trio-chat/assets/icons/mika-claude.png`, `examples/slack-agent-trio-chat/assets/icons/rina-cursor.png`, `examples/slack-agent-trio-chat/assets/icons/yui-codex.png`, `examples/slack-agent-trio-chat/mock-scenario.json`, `examples/slack-agent-trio-chat/nodes/node-read-mika-memory.json`, `examples/slack-agent-trio-chat/nodes/node-read-rina-memory.json`, `examples/slack-agent-trio-chat/nodes/node-read-yui-memory.json`, `examples/slack-agent-trio-chat/nodes/node-write-mika-memory.json`, `examples/slack-agent-trio-chat/nodes/node-write-rina-memory.json`, `examples/slack-agent-trio-chat/nodes/node-write-yui-memory.json`, `examples/slack-agent-trio-chat/workflow.json`.

- `riela workflow validate slack-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/slack-agent-trio-chat-validate.log`.
- `riela workflow inspect slack-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/slack-agent-trio-chat-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: installed CLI cannot resolve an add-on executable before execution. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### slack-codex-chat

Reviewed paths: `examples/slack-codex-chat/EXPECTED_RESULTS.md`, `examples/slack-codex-chat/mock-scenario.json`, `examples/slack-codex-chat/nodes/node-answer-slack-message.json`, `examples/slack-codex-chat/prompts/answer-slack-message.md`, `examples/slack-codex-chat/workflow.json`.

- `riela workflow validate slack-codex-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/slack-codex-chat-validate-post.log`.
- `riela workflow inspect slack-codex-chat --workflow-definition-dir examples --output json` → exit 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/slack-codex-chat-inspect-post.log`.
- Finding: no further material authoring defect observed in referenced files beyond repairs below; validate and inspect passed.
- Mock `mock-scenario.json`: `riela workflow run slack-codex-chat --workflow-definition-dir examples --mock-scenario examples/slack-codex-chat/mock-scenario.json --variables-file tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/slack-codex-chat-mock-scenario/variables.json --session-store tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/slack-codex-chat-mock-scenario/sessions --artifact-root tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/slack-codex-chat-mock-scenario/artifacts --output json` → exit 0, status `completed`, node executions 2; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/slack-codex-chat-mock-scenario/run.log`.

### telegram-agent-trio-chat

Reviewed paths: `examples/telegram-agent-trio-chat/EXPECTED_RESULTS.md`, `examples/telegram-agent-trio-chat/assets/icons/mika-claude.png`, `examples/telegram-agent-trio-chat/assets/icons/rina-cursor.png`, `examples/telegram-agent-trio-chat/assets/icons/yui-codex.png`, `examples/telegram-agent-trio-chat/mock-scenario.json`, `examples/telegram-agent-trio-chat/nodes/node-read-mika-memory.json`, `examples/telegram-agent-trio-chat/nodes/node-read-rina-memory.json`, `examples/telegram-agent-trio-chat/nodes/node-read-yui-memory.json`, `examples/telegram-agent-trio-chat/nodes/node-write-mika-memory.json`, `examples/telegram-agent-trio-chat/nodes/node-write-rina-memory.json`, `examples/telegram-agent-trio-chat/nodes/node-write-yui-memory.json`, `examples/telegram-agent-trio-chat/workflow.json`.

- `riela workflow validate telegram-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-agent-trio-chat-validate.log`.
- `riela workflow inspect telegram-agent-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-agent-trio-chat-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: installed CLI cannot resolve an add-on executable before execution. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

### telegram-agent-trio-time-signal

Reviewed paths: `examples/telegram-agent-trio-time-signal/EXPECTED_RESULTS.md`, `examples/telegram-agent-trio-time-signal/workflow.json`.

- `riela workflow validate telegram-agent-trio-time-signal --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-agent-trio-time-signal-validate.log`.
- `riela workflow inspect telegram-agent-trio-time-signal --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-agent-trio-time-signal-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.

### telegram-sdk-trio-chat

Reviewed paths: `examples/telegram-sdk-trio-chat/EXPECTED_RESULTS.md`, `examples/telegram-sdk-trio-chat/mock-scenario.json`, `examples/telegram-sdk-trio-chat/workflow.json`.

- `riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-sdk-trio-chat-validate.log`.
- `riela workflow inspect telegram-sdk-trio-chat --workflow-definition-dir examples --output json` → exit 1; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/telegram-sdk-trio-chat-inspect.log`.
- Finding: installed CLI reports `unresolvedAddonExecutable` on an authored `riela/*` add-on; source has handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` / `ProductionNodeAdapter+StatefulAddonDispatch.swift` where applicable. Add-on executable host resolution must be repaired or the required host capability supplied before a green run. This is an upstream/runtime prerequisite candidate, not a passing authoring check.
- Mock `mock-scenario.json`: blocked; prerequisite: installed CLI cannot resolve an add-on executable before execution. Resume after add-on host resolution or an explicitly isolated service lifecycle, without live external calls.

## Repairs and self-check

- `examples/discord-codex-chat/nodes/node-answer-discord-message.json` and `examples/slack-codex-chat/nodes/node-answer-slack-message.json`: require nonempty `replyText` consumed by chat reply add-ons. Fresh validate/inspect pass. The two dry-run mocks completed with `intent-only` reply dispatch and stable repeated root outputs.
- `examples/routine-chat-manager/nodes/node-parse-instruction.json`: require name, task, schedule, timezone, and completionCriteria in the parse payload; preserve optional downstream routine/routineId schema declarations required by validator. First post-edit check failed because those declarations were removed; final validate/inspect both pass. The failed post-edit logs remain under this evidence directory.
- `examples/gmail-latest-mail-digest-telegram/nodes/node-summarize-new-mail.json`: remove `codexAdditionalArgs` workspace-write override from a read-only digest role; require concrete payload fields and nested message digest fields matching its prompt and downstream add-on. Validate/inspect remain blocked at add-on host resolution, so this change has no green CLI proof.
- Static role/path review: all owned CLI agent nodes have `agentSandbox: read-only`; SDK nodes have no agentSandbox; referenced node prompts exist. Add-on nodes do not take agentSandbox.
- Source state: `git diff` plus current file SHA-256 are preserved below; no TypeScript or Swift files changed.

## Remaining implementation work / blocked checks

- Resolve or report the `unresolvedAddonExecutable` runtime prerequisite for the ten named bundles, then rerun validate/inspect and safe deterministic scenarios on the resulting source state. Minimal reproduction: `riela workflow validate telegram-agent-trio-time-signal --workflow-definition-dir examples --output json` reports `unresolvedAddonExecutable(... nodeId: "prepare-time-signal")` for built-in `riela/time-signal`; handler exists in `Sources/RielaCLI/ProductionNodeAdapter.swift` and `ProductionNodeAdapter+TimeSignal.swift`. No engine file was edited.
- `routine-chat-manager/mock-scenario.json` requires an isolated working directory or owned service lifecycle before executing `riela/routine-create`; its documented write targets are explicit in `examples/routine-chat-manager/EXPECTED_RESULTS.md`.
- Compare remaining safe mock results with `EXPECTED_RESULTS.md` after prerequisite repair. This plan has not entered independent review; downstream plans own serial reconciliation and finalization.

## Post-edit SHA-256

- `examples/discord-codex-chat/nodes/node-answer-discord-message.json`: `1617f3d8b603ee452410b685b010546f6865efb071f392af088822aad10bcb7e`
- `examples/slack-codex-chat/nodes/node-answer-slack-message.json`: `c0e18f574431171970659a8aa97349131f32b30eaaaea8bb7caa2b9e1611903e`
- `examples/routine-chat-manager/nodes/node-parse-instruction.json`: `0a2a40d12201302c36d4e27411d64754e05c14bf939e21e07c8b1ee1d9e6b35d`
- `examples/gmail-latest-mail-digest-telegram/nodes/node-summarize-new-mail.json`: `5fb39ddd5bb0e646a3b558a671c06e2d477b9d4822b2d9107d1304518e383614`

## Upstream report handoff

- `tmp/example-contract-migration/example-contract-01-chat/attempt-1/upstream-repro.json` records the minimal existing-bundle reproduction, exact failed command and log, installed-CLI diagnostic, source/catalog mismatch, impact, and resume criterion. The catalog omission is an upstream runtime defect; engine files are outside this plan and remain unchanged.
- Repeat mock evidence: `tmp/example-contract-migration/example-contract-01-chat/attempt-1/repeat-runs.json` records two additional exact commands, exit 0 and full logs. Discord and Slack repeated root outputs are equal and each run executed two nodes.
- Final routine CLI outcomes: `tmp/example-contract-migration/example-contract-01-chat/attempt-1/routine-chat-manager-validate-final.log` and `routine-chat-manager-inspect-final.log`, both exit 0. The earlier post-edit failures are preserved in `routine-chat-manager-validate-post.log` and `routine-chat-manager-inspect-post.log`.
- Final `git diff --check` after the progress write exited 0; log `tmp/example-contract-migration/example-contract-01-chat/attempt-1/diff-check-final.log`.

## Routine mock unblock and source-matched rerun

The earlier routine-mock blocked classification is superseded. `Sources/RielaCLI/ProductionNodeAdapter+RoutineAddon.swift` constructs `RoutineService` from the process working directory, so the run was isolated under task-local `tmp/` and required no external service. The two foreground commands and final exits are recorded in `tmp/example-contract-migration/example-contract-01-chat/attempt-1/runs/routine-chat-manager-isolated/result.json` and `.../routine-chat-manager-isolated-repeat/result.json`; both exit 0 with complete `run.log`, `status: completed`, three node executions, `created: true`, six-field schedule `0 */30 * * * *`, timezone `Asia/Tokyo`, and `intent-only` chat reply. Generated IDs, times, and task-local paths differ as expected; stable business fields agree. All SQLite/event writes are under the two task-local run directories. The remaining mock blocks are the add-on catalog/host-resolution failures described in the upstream report.
