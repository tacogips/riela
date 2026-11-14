Return concise business JSON only. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex processes.

Implement stdio policy context:
- Add optional policy context to `WorkflowStdioNodeExecutionInput` and invocation envelope.
- Pass step policy decisions from `DeterministicWorkflowRunner` into stdio node execution.
- Make `LocalWorkflowStdioNodeExecutor` block denied command/container execution before process launch.
- Add summary-only command evidence to `WorkflowStdioNodeExecutionResult`, without storing raw stdout/stderr.
- Add focused tests for envelope projection, pre-process policy blocking, and runner propagation.
