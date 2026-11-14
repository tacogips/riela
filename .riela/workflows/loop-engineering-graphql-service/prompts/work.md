Return concise business JSON only. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex processes.

Implement GraphQL loop evidence query wiring:
- Add request/result/service surface needed for `loopEvidence(workflowId:sessionId:)`.
- Provide a concrete runtime snapshot-backed service that can inspect sessions and return loop evidence summaries.
- Preserve existing manager mutations and session query DTO shapes.
- Add focused tests proving found, missing-session, and missing-evidence behavior.
- Return changed files and verification commands.
