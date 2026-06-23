Adversarially review the current Riela session persistence design from the repository state and diff.

User objective:
{{workflowInput.requestedWork}}

Acceptance criteria:
{{workflowInput.acceptanceCriteria}}

Do not modify files. Return one JSON object only with keys:
- `accepted`
- `findings`
- `designDecisions`
- `requiredChanges`

User intent: memory is already SQLite, and session persistence should also be SQLite by default. Normal workflow run, event serve, session commands, viewer, resume, and rerun must not depend on `<sessionId>.json` or `runtime-records/<sessionId>/runtime-snapshot.json`. JSON should remain only for explicit debug export or artifact output.

Review whether:
- the design should keep `workflow_messages` in `runtime-message-log.sqlite` or merge session/snapshot tables into the same database
- `WorkflowSession`, `workflowName`, resolution, `mockScenarioPath`, `rootOutput`, diagnostics, and `workflowMessages` are preserved
- existing JSON backcompat should be removed when the user said backcompat is unnecessary
- stale JSON files are avoided
- session list/load/status/progress/viewer query SQLite
- tests prove no default JSON is created
