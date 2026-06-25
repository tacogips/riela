Return concise business JSON only. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex processes.

Implement loop runtime policy enforcement:
- Add `LoopPolicyEvaluator.swift` with preflight evidence and step decisions.
- Enforce required-loop preflight in `DeterministicWorkflowRunner` before step execution.
- Validate required `codex-agent` and `gpt-5.5` policies, command/container denial, nested Riela/Codex policy, commit/push default deny, and mutation root diagnostics.
- Add focused model/evaluator tests and runner preflight tests outside oversized legacy files.
- Return changed files and verification commands.
