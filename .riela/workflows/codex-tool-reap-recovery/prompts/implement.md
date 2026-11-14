# Task

Implement every unfinished checklist item in `impl-plans/active/codex-unified-exec-stall-followup.md` Section 5 according to the design contract established by the prior plan step.

Read `.codex/skills/swift-coding-agent/SKILL.md` completely and obey it. Preserve unrelated dirty changes, use only repository-root `tmp/codex-tool-reap-recovery/` for scratch/logs, and do not commit or push.

Also inspect the sibling `../riela-packages` registry. If this implementation changes packaged Riela workflow-run, auto-improve, troubleshooting, project-workflow, or model-catalog guidance, update only the affected packages there. Read every applicable `AGENTS.md` before editing, preserve its dirty worktree, keep its scratch files under its own repository-root `tmp/codex-tool-reap-recovery/`, refresh each affected `riela-package.json` digest with the registry's release tooling, and validate the registry. Do not change that repository when no packaged contract is affected.

Required implementation outcomes:

- Riela directly owns, process-groups, terminates, and reaps each agent backend child exactly once.
- Codex tool lifecycle correlation is per workflow execution/step/attempt/tool-call and persists a redacted command fingerprint plus direct-agent and descendant process identities.
- `item.started`/matching terminal lifecycle is evaluated separately from generic backend heartbeat recency.
- The classifier refuses uncorrelated, PID-reused, parent-mismatched, running, merely silent, or already-remediated processes.
- Detection supports macOS and Linux through a protocol-backed process-tree observer with deterministic fake implementations; unsupported observations fail closed to observe-only behavior.
- Recovery is bounded: host completion request when supported, ownership revalidation, TERM, cleanup grace, KILL when still live, then direct-child reap. No signal may target a PID/process group after identity mismatch.
- Same-attempt continuation is allowed only with explicit terminal acknowledgement and intact stream state. Otherwise integrate with auto-improve targeted retry/rerun budgets and mutation-safety refusal.
- Durable compare-and-set incident/remediation state makes polling, cancellation, resume, and supervisor replay idempotent.
- Cancellation wins races and leaves no detector task or directly owned child live.
- Add off/observe/recover policy plus observation/cleanup grace and same-attempt controls across CLI, library, serialized session/supervision state, GraphQL inputs, help, and docs with backward-compatible defaults.
- Session inspection exposes redacted active tool/recovery state.

Add deterministic unit and integration fixtures for misleading wait/status events, zombie versus running/silent children, PID reuse, parent mismatch, TERM/KILL/reap ordering, host acknowledgement, retry selection, duplicate suppression, cancellation, mutation-safety refusal, serialization/defaults, and macOS/Linux process observations. The integration fixture must print a completed test/lint-style summary, leave the command child terminal/unreaped while the host emits wait/status events, and prove bounded recovery without duplicate execution or mutation.

Keep each Swift file under 1000 lines by responsibility-based extraction. Run focused tests and strict SwiftLint on every changed Swift file. Redirect long logs under the task tmp directory. Update design, plan, progress/inventory documentation honestly. Return concise JSON with files, tests, lint, package-registry changes or explicit no-change rationale, and remaining blockers.
