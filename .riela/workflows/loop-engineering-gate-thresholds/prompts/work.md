Return concise business JSON only. Preserve unrelated dirty worktree changes. Do not commit or push. Do not start nested Riela or Codex processes.

Implement loop gate threshold enforcement:
- Add deterministic acceptance evaluation for authored `LoopGateAcceptancePolicy`.
- When a required gate emits a structured result that violates `acceptWhen`, project it as rejected or needs-work with blocking diagnostics instead of counting it as accepted.
- Preserve optional/non-required gate payloads unless a required gate policy applies.
- Add focused tests for accepted gates, wrong decision, high finding threshold, medium finding threshold, and missing required gates.
